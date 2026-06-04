"""Speech-to-text client for KCD2 AI NPC server.

Implements a push-to-talk (PTT) workflow:
  1. The Lua mod signals press of V → /ptt/start (or log-IPC) → ``STTClient.start()``.
  2. We open a ``sounddevice.InputStream`` and accumulate float32 PCM chunks
     in a buffer (16 kHz mono).
  3. The Lua mod signals release of V → ``STTClient.stop()`` which closes the
     stream, hands the WAV/ndarray to the selected provider (faster-whisper
     local OR an OpenAI-compatible Whisper endpoint like OpenAI/Groq) and
     returns the transcribed text.

Patterns borrowed from Mantella (``other mods/Mantella/src/stt/stt.py``):
  - sounddevice InputStream → callback → list-of-ndarrays buffer.
  - Min PTT duration filter (drops accidental taps).
  - Whisper hallucination filter for typical silence-leakage phrases.
  - OpenAI SDK with custom base_url for both OpenAI Whisper and Groq Whisper.

The module is intentionally tolerant of missing optional deps: if
``faster-whisper`` or ``sounddevice`` is not installed, methods raise a clear
``RuntimeError`` instead of failing at import time.
"""

from __future__ import annotations

import io
import logging
import threading
import time
import wave
from typing import Any

logger = logging.getLogger(__name__)

SAMPLING_RATE = 16000

# Whisper is famous for hallucinating these phrases on silence / very short
# clips. Suppress them outright; the player can always speak again.
_HALLUCINATIONS = {
    "",
    ".",
    "the",
    "you",
    "bye",
    "thank you",
    "thanks",
    "thanks.",
    "thank you.",
    "thank you very much",
    "thank you for watching",
    "thanks for watching",
    "thanks for watching!",
    "see you next time",
    "see you in the next video",
    "subscribe",
    "subtitles by the amara.org community",
    "субтитры подогнал «victor-akhlynin»",
    "продолжение следует",
    "продолжение следует...",
}


def _filter_hallucination(text: str) -> str:
    """Return text unless it matches a known Whisper-on-silence artefact."""
    cleaned = (text or "").strip()
    if cleaned.lower().strip(".,!? ") in _HALLUCINATIONS:
        return ""
    return cleaned


class STTClient:
    """Provider-agnostic push-to-talk speech-to-text helper.

    One instance lives on the server and is reused across PTT sessions.
    ``start()`` is cheap; ``stop()`` performs the actual transcription.
    """

    def __init__(self, config):
        self.config = config
        self._lock = threading.Lock()
        self._recording = False
        self._buffer: list[Any] = []  # list[np.ndarray]
        self._stream = None
        self._record_start = 0.0
        # Lazy-loaded local model — load on first transcription, not at startup.
        self._local_model = None
        self._local_model_key: tuple | None = None

    # ------------------------------------------------------------------ helpers

    def _np(self):
        try:
            import numpy as np  # noqa: PLC0415
        except ImportError as e:  # pragma: no cover
            raise RuntimeError(
                "numpy is required for STT. Install with: pip install numpy"
            ) from e
        return np

    def _load_local_model(self):
        """Load faster-whisper lazily and cache it across calls."""
        try:
            from faster_whisper import WhisperModel  # noqa: PLC0415
        except ImportError as e:
            raise RuntimeError(
                "faster-whisper is not installed. Run: pip install faster-whisper"
            ) from e

        device = (self.config.device or "cpu").lower()
        compute = (self.config.compute_type or ("int8" if device == "cpu" else "float16")).lower()
        key = (self.config.model, device, compute)
        if self._local_model is not None and self._local_model_key == key:
            return self._local_model

        logger.info(
            f"[STT] Loading faster-whisper model='{self.config.model}' "
            f"device={device} compute_type={compute} ..."
        )
        t0 = time.perf_counter()
        try:
            self._local_model = WhisperModel(
                self.config.model, device=device, compute_type=compute
            )
        except Exception as exc:
            logger.error(f"[STT] Failed to load faster-whisper model: {exc}")
            raise
        self._local_model_key = key
        logger.info(
            f"[STT] faster-whisper ready in {(time.perf_counter() - t0):.2f}s"
        )
        return self._local_model

    # ------------------------------------------------------------------ recording

    def _audio_callback(self, indata, frames, time_info, status):  # noqa: ARG002
        if status:
            logger.debug(f"[STT] audio status: {status}")
        with self._lock:
            if self._recording:
                self._buffer.append(indata.copy().flatten())

    def start(self) -> None:
        """Open the input stream and begin accumulating chunks.

        Idempotent: calling ``start()`` while already recording is a no-op.
        Raises ``RuntimeError`` if sounddevice is missing or the device fails
        to open.
        """
        try:
            import sounddevice as sd  # noqa: PLC0415
        except ImportError as e:
            raise RuntimeError(
                "sounddevice is not installed. Run: pip install sounddevice"
            ) from e

        np = self._np()

        with self._lock:
            if self._recording:
                logger.debug("[STT] start() ignored — already recording")
                return
            self._buffer = []
            self._recording = True
            self._record_start = time.perf_counter()

        stream_kwargs = {
            "samplerate": SAMPLING_RATE,
            "channels": 1,
            "dtype": np.float32,
            "callback": self._audio_callback,
            "blocksize": 1024,
        }
        if getattr(self.config, "input_device", -1) is not None and self.config.input_device >= 0:
            stream_kwargs["device"] = self.config.input_device

        try:
            self._stream = sd.InputStream(**stream_kwargs)
            self._stream.start()
            logger.info(
                f"[STT] PTT recording started (device={stream_kwargs.get('device', 'default')}, "
                f"provider={self.config.provider})"
            )
        except Exception as exc:
            with self._lock:
                self._recording = False
            if self._stream is not None:
                try:
                    self._stream.close()
                except Exception:
                    pass
                self._stream = None
            logger.error(f"[STT] Failed to open input stream: {exc}")
            raise

    def stop(self, *, prompt: str = "") -> str:
        """Close the stream, transcribe the buffer, return text.

        Returns an empty string if nothing useful was captured (too short,
        all silence, or a known Whisper hallucination).
        """
        with self._lock:
            if not self._recording:
                logger.debug("[STT] stop() ignored — not recording")
                return ""
            self._recording = False
            chunks = list(self._buffer)
            self._buffer = []
            elapsed = time.perf_counter() - self._record_start

        if self._stream is not None:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception as exc:
                logger.warning(f"[STT] error closing stream: {exc}")
            finally:
                self._stream = None

        if not chunks:
            logger.info("[STT] stop() — no audio captured")
            return ""

        np = self._np()
        audio = np.concatenate(chunks)
        duration = len(audio) / SAMPLING_RATE
        logger.info(
            f"[STT] PTT released: hold={elapsed:.2f}s audio={duration:.2f}s "
            f"samples={len(audio)}"
        )

        min_dur = (self.config.min_duration_ms or 300) / 1000.0
        if duration < min_dur:
            logger.info(
                f"[STT] discarded — duration {duration:.2f}s < min {min_dur:.2f}s"
            )
            return ""

        max_dur = self.config.max_duration_sec or 30
        if duration > max_dur:
            logger.warning(f"[STT] clipping audio: {duration:.2f}s → {max_dur}s")
            audio = audio[: int(max_dur * SAMPLING_RATE)]

        try:
            t0 = time.perf_counter()
            text = self._transcribe(audio, prompt=prompt)
            dt = (time.perf_counter() - t0) * 1000
            logger.info(f"[STT] transcribed in {dt:.0f} ms → {text!r}")
        except Exception as exc:
            logger.error(f"[STT] transcription failed: {exc}")
            return ""

        return _filter_hallucination(text)

    def cancel(self) -> None:
        """Stop recording and discard the buffer without transcribing."""
        with self._lock:
            self._recording = False
            self._buffer = []
        if self._stream is not None:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception:
                pass
            finally:
                self._stream = None
        logger.info("[STT] PTT cancelled")

    @property
    def is_recording(self) -> bool:
        with self._lock:
            return self._recording

    # ------------------------------------------------------------------ transcription

    def _transcribe(self, audio, *, prompt: str) -> str:
        provider = (self.config.provider or "faster-whisper").lower()
        lang = (self.config.language or "auto").strip().lower()
        lang_hint = None if lang in ("", "auto") else lang

        if provider in ("faster-whisper", "local", "whisper-local"):
            return self._transcribe_local(audio, prompt=prompt, lang=lang_hint)
        return self._transcribe_api(audio, prompt=prompt, lang=lang_hint)

    def _transcribe_local(self, audio, *, prompt: str, lang: str | None) -> str:
        model = self._load_local_model()
        segments, info = model.transcribe(
            audio,
            language=lang,
            initial_prompt=prompt or None,
            beam_size=1,
            vad_filter=False,
        )
        text = "".join(seg.text for seg in segments)
        if info and getattr(info, "language", None):
            logger.debug(
                f"[STT-local] detected_language={info.language} "
                f"prob={getattr(info, 'language_probability', 0):.2f}"
            )
        return text.strip()

    def _transcribe_api(self, audio, *, prompt: str, lang: str | None) -> str:
        from openai import OpenAI  # noqa: PLC0415

        url = (self.config.api_url or "").strip()
        if not url:
            # Sensible defaults per provider for convenience.
            prov = (self.config.provider or "").lower()
            url = {
                "openai": "https://api.openai.com/v1",
                "groq": "https://api.groq.com/openai/v1",
            }.get(prov, "")
        if not url:
            raise RuntimeError(
                f"STT provider '{self.config.provider}' requires api_url to be set."
            )
        key = (self.config.api_key or "").strip()
        if not key:
            raise RuntimeError(
                f"STT provider '{self.config.provider}' requires api_key to be set."
            )

        model = (self.config.model or "whisper-1").strip()

        # Encode float32 buffer to in-memory WAV the API can ingest.
        np = self._np()
        audio_int16 = (np.clip(audio, -1.0, 1.0) * 32767).astype(np.int16)
        wav_io = io.BytesIO()
        with wave.open(wav_io, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(SAMPLING_RATE)
            wf.writeframes(audio_int16.tobytes())
        wav_io.seek(0)
        wav_io.name = "audio.wav"  # OpenAI SDK needs a filename hint.

        client = OpenAI(base_url=url, api_key=key)
        try:
            kwargs: dict[str, Any] = {"model": model, "file": wav_io}
            if lang:
                kwargs["language"] = lang
            if prompt:
                kwargs["prompt"] = prompt
            resp = client.audio.transcriptions.create(**kwargs)
        finally:
            try:
                client.close()
            except Exception:
                pass
        return (getattr(resp, "text", "") or "").strip()

    # ------------------------------------------------------------------ misc

    def list_devices(self) -> list[dict]:
        """Return all input-capable audio devices on the host."""
        try:
            import sounddevice as sd  # noqa: PLC0415
        except ImportError:
            return []
        try:
            devs = sd.query_devices()
        except Exception as exc:
            logger.warning(f"[STT] query_devices failed: {exc}")
            return []
        out = []
        try:
            default_idx = sd.default.device[0] if sd.default.device else -1
        except Exception:
            default_idx = -1
        for i, d in enumerate(devs):
            if int(d.get("max_input_channels", 0) or 0) <= 0:
                continue
            out.append(
                {
                    "index": i,
                    "name": d.get("name", f"Device {i}"),
                    "channels": int(d.get("max_input_channels", 0)),
                    "default_samplerate": float(d.get("default_samplerate", 0) or 0),
                    "is_default": i == default_idx,
                }
            )
        return out

    async def test(self, duration_sec: float = 3.0, prompt: str = "") -> str:
        """Record for ``duration_sec`` seconds, then transcribe.

        Used by the web UI's "Test mic" button. Runs the blocking stop on a
        worker so we don't tie up the FastAPI event loop.
        """
        import asyncio  # noqa: PLC0415

        self.start()
        try:
            await asyncio.sleep(max(0.5, float(duration_sec)))
        finally:
            text = await asyncio.to_thread(self.stop, prompt=prompt)
        return text

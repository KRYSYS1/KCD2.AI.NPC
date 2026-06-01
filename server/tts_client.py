"""TTS client for KCD2 AI NPC server."""

import asyncio
import logging
import os
import tempfile
import threading
import time
from pathlib import Path

logger = logging.getLogger(__name__)

_CYR_MAP = {
    "\u0430": "a", "\u0431": "b", "\u0432": "v", "\u0433": "g", "\u0434": "d", "\u0435": "e", "\u0451": "yo", "\u0436": "zh", "\u0437": "z",
    "\u0438": "i", "\u0439": "y", "\u043a": "k", "\u043b": "l", "\u043c": "m", "\u043d": "n", "\u043e": "o", "\u043f": "p", "\u0440": "r",
    "\u0441": "s", "\u0442": "t", "\u0443": "u", "\u0444": "f", "\u0445": "kh", "\u0446": "ts", "\u0447": "ch", "\u0448": "sh", "\u0449": "sch",
    "\u044a": "", "\u044b": "y", "\u044c": "", "\u044d": "e", "\u044e": "yu", "\u044f": "ya",
}


def _has_cyrillic(text: str) -> bool:
    return any("\u0430" <= ch.lower() <= "\u044f" or ch.lower() == "\u0451" for ch in text)


def _transliterate_cyrillic(text: str) -> str:
    out = []
    for ch in text:
        low = ch.lower()
        repl = _CYR_MAP.get(low)
        if repl is None:
            out.append(ch)
        elif ch.isupper() and repl:
            out.append(repl[0].upper() + repl[1:])
        else:
            out.append(repl)
    return "".join(out)

_pygame_ready = False
_pygame_lock = threading.Lock()


def _init_pygame(volume: float = 1.0):
    global _pygame_ready
    try:
        import pygame
        with _pygame_lock:
            if not _pygame_ready:
                pygame.mixer.init(frequency=22050, size=-16, channels=1, buffer=512)
                _pygame_ready = True
            pygame.mixer.music.set_volume(max(0.0, min(1.0, volume)))
    except Exception as e:
        logger.warning(f"pygame init failed: {e}")


def _play_file(path: str, volume: float = 1.0):
    try:
        import pygame
        _init_pygame(volume)
        # Hold the lock only for the load/play handoff; release before the
        # busy-wait so a second TTS thread is not serialized on top of an
        # already-finished playback. pygame.mixer.music itself is a singleton
        # channel, so concurrent plays would still preempt each other, but
        # in practice replies arrive sequentially with gaps and the lock was
        # the dominant cause of perceived voice queueing.
        t_play_start = time.perf_counter()
        with _pygame_lock:
            pygame.mixer.music.load(path)
            pygame.mixer.music.set_volume(volume)
            pygame.mixer.music.play()
        logger.info(f"TTS play started in {(time.perf_counter()-t_play_start)*1000:.0f} ms")
        while True:
            try:
                if not pygame.mixer.music.get_busy():
                    break
            except Exception:
                break
            time.sleep(0.05)
    except Exception as e:
        logger.error(f"Audio playback failed: {e}")
    finally:
        try:
            os.unlink(path)
        except Exception:
            pass


def warmup(volume: float = 1.0) -> None:
    """Initialize pygame mixer eagerly to remove cold-start delay on first reply."""
    _init_pygame(volume)


class TTSClient:
    def __init__(self, config):
        self.config = config
        self._output_dir = Path(config.output_dir)
        self._output_dir.mkdir(parents=True, exist_ok=True)

    def _is_female(self, gender: int | None) -> bool:
        return gender == 2

    def _resolve_voice(self, engine: str, npc_id: str | None, npc_name: str | None, gender: int | None, npc_name_resolved: str | None = None) -> str:
        """Look up per-NPC voice override, fall back to gender default."""
        npc_voices = getattr(self.config, "npc_voices", {}) or {}
        if not npc_voices:
            return ""
        # Try npc_name first, then npc_name_resolved, then npc_id
        voice_map = None
        for key in ((npc_name or "").strip(), (npc_name_resolved or "").strip(), (npc_id or "").strip()):
            if key:
                voice_map = npc_voices.get(key)
                if voice_map is not None:
                    break
        if isinstance(voice_map, dict):
            voice = voice_map.get(engine, "")
            if voice:
                return voice
        # Fall back to gender default (caller handles empty string)
        return ""

    def _resolve_engine(self, npc_id: str | None, npc_name: str | None, npc_name_resolved: str | None = None) -> str:
        """Pick TTS engine for this NPC. Global engine wins if NPC has a voice
        for it; otherwise fallback to any engine the NPC has a voice for."""
        default = self.config.engine
        npc_voices = getattr(self.config, "npc_voices", {}) or {}
        if not npc_voices:
            return default
        vm = None
        for key in ((npc_name or "").strip(), (npc_name_resolved or "").strip(), (npc_id or "").strip()):
            if key:
                vm = npc_voices.get(key)
                if vm is not None:
                    break
        if not isinstance(vm, dict) or not vm:
            return default
        # If NPC has an explicit voice for the default engine, use it.
        if vm.get(default):
            return default
        # Otherwise pick the first configured engine this NPC has a voice for.
        for eng in ("elevenlabs", "openai", "edge"):
            if eng == default:
                continue
            if not vm.get(eng):
                continue
            if eng == "elevenlabs" and not self.config.elevenlabs_api_key:
                continue
            if eng == "openai" and not self.config.openai_api_key:
                continue
            return eng
        return default

    async def speak(self, text: str, gender: int | None = None, npc_id: str | None = None, npc_name: str | None = None, npc_name_resolved: str | None = None) -> None:
        """Fire-and-forget speak: swallows engine errors after logging
        so a failing TTS does not crash chat handling."""
        try:
            await self._synth_and_play(text, gender, npc_id, npc_name, npc_name_resolved)
        except Exception as e:
            engine = self._resolve_engine(npc_id, npc_name, npc_name_resolved)
            logger.error(f"TTS speak failed [{engine}]: {e}")

    async def _synth_and_play(self, text: str, gender: int | None = None, npc_id: str | None = None, npc_name: str | None = None, npc_name_resolved: str | None = None) -> None:
        """Engine dispatch that propagates errors to the caller."""
        if not self.config.enabled or not text.strip():
            return
        engine = self._resolve_engine(npc_id, npc_name, npc_name_resolved)
        if engine == "edge":
            await self._speak_edge(text, gender, npc_id, npc_name, npc_name_resolved)
        elif engine == "elevenlabs":
            await self._speak_elevenlabs(text, gender, npc_id, npc_name, npc_name_resolved)
        elif engine == "openai":
            await self._speak_openai(text, gender, npc_id, npc_name, npc_name_resolved)
        else:
            raise RuntimeError(f"Unknown TTS engine: {engine}")

    async def _speak_edge(self, text: str, gender: int | None = None, npc_id: str | None = None, npc_name: str | None = None, npc_name_resolved: str | None = None) -> None:
        try:
            import edge_tts
        except ImportError as e:
            raise RuntimeError("edge-tts not installed. Run: pip install edge-tts") from e
        is_female = self._is_female(gender)
        voice = self._resolve_voice("edge", npc_id, npc_name, gender, npc_name_resolved)
        if not voice:
            if is_female and self.config.voice_female:
                voice = self.config.voice_female
            elif self.config.voice:
                voice = self.config.voice
            elif self.config.voice_female:
                voice = self.config.voice_female
        if not (voice or "").strip():
            raise RuntimeError("Edge TTS voice is empty")
        tmp = tempfile.NamedTemporaryFile(suffix=".mp3", delete=False)
        tmp.close()
        t0 = time.perf_counter()
        synth_text = text
        voice_lang = voice.split("-", 2)[0].lower() if "-" in voice else ""

        async def save_edge_audio(value: str) -> None:
            try:
                os.unlink(tmp.name)
            except OSError:
                pass
            communicate = edge_tts.Communicate(value, voice)
            await communicate.save(tmp.name)
            size = os.path.getsize(tmp.name) if os.path.exists(tmp.name) else 0
            if size < 512:
                raise RuntimeError(f"Edge TTS returned empty audio ({size} bytes)")

        try:
            await save_edge_audio(synth_text)
        except Exception as first_exc:
            if _has_cyrillic(text) and voice_lang != "ru":
                synth_text = _transliterate_cyrillic(text)
                logger.warning(f"edge-tts failed for Cyrillic text with voice={voice}; retrying transliterated text: {first_exc}")
                await save_edge_audio(synth_text)
            else:
                raise
        logger.info(f"edge-tts synth in {(time.perf_counter()-t0)*1000:.0f} ms, chars={len(text)}, synth_chars={len(synth_text)}, gender={gender}, voice={voice}")
        thread = threading.Thread(
            target=_play_file, args=(tmp.name, self.config.volume), daemon=True
        )
        thread.start()

    async def _speak_elevenlabs(self, text: str, gender: int | None = None, npc_id: str | None = None, npc_name: str | None = None, npc_name_resolved: str | None = None) -> None:
        api_key = self.config.elevenlabs_api_key
        if not api_key:
            raise RuntimeError("ElevenLabs API key not set")
        voice_id = self._resolve_voice("elevenlabs", npc_id, npc_name, gender, npc_name_resolved)
        if not voice_id:
            is_female = self._is_female(gender)
            if is_female and self.config.elevenlabs_voice_female:
                voice_id = self.config.elevenlabs_voice_female
            elif self.config.elevenlabs_voice:
                voice_id = self.config.elevenlabs_voice
            elif self.config.elevenlabs_voice_female:
                voice_id = self.config.elevenlabs_voice_female
            else:
                voice_id = "21m00Tcm4TlvDq8ikWAM"
        url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}"
        payload = {
            "text": text,
            "model_id": "eleven_multilingual_v2",
            "voice_settings": {"stability": 0.5, "similarity_boost": 0.75},
        }
        headers = {
            "xi-api-key": api_key,
            "Content-Type": "application/json",
            "Accept": "audio/mpeg",
        }
        import aiohttp
        t0 = time.perf_counter()
        async with aiohttp.ClientSession() as session:
            async with session.post(url, json=payload, headers=headers) as resp:
                if resp.status != 200:
                    body = await resp.text()
                    raise RuntimeError(f"ElevenLabs HTTP {resp.status}: {body[:200]}")
                audio_bytes = await resp.read()
        logger.info(f"elevenlabs synth in {(time.perf_counter()-t0)*1000:.0f} ms, chars={len(text)}, gender={gender}, voice={voice_id}")
        tmp = tempfile.NamedTemporaryFile(suffix=".mp3", delete=False)
        tmp.write(audio_bytes)
        tmp.close()
        thread = threading.Thread(
            target=_play_file, args=(tmp.name, self.config.volume), daemon=True
        )
        thread.start()

    async def _speak_openai(self, text: str, gender: int | None = None, npc_id: str | None = None, npc_name: str | None = None, npc_name_resolved: str | None = None) -> None:
        api_key = self.config.openai_api_key
        if not api_key:
            raise RuntimeError("OpenAI TTS API key not set")
        url = "https://api.openai.com/v1/audio/speech"
        voice = self._resolve_voice("openai", npc_id, npc_name, gender, npc_name_resolved)
        if not voice:
            is_female = self._is_female(gender)
            if is_female and self.config.openai_voice_female:
                voice = self.config.openai_voice_female
            elif self.config.openai_voice:
                voice = self.config.openai_voice
            elif self.config.openai_voice_female:
                voice = self.config.openai_voice_female
            else:
                voice = "onyx"
        payload = {
            "model": "tts-1",
            "input": text,
            "voice": voice,
        }
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        }
        import aiohttp
        t0 = time.perf_counter()
        async with aiohttp.ClientSession() as session:
            async with session.post(url, json=payload, headers=headers) as resp:
                if resp.status != 200:
                    body = await resp.text()
                    raise RuntimeError(f"OpenAI TTS HTTP {resp.status}: {body[:200]}")
                audio_bytes = await resp.read()
        logger.info(f"openai-tts synth in {(time.perf_counter()-t0)*1000:.0f} ms, chars={len(text)}, gender={gender}, voice={voice}")
        tmp = tempfile.NamedTemporaryFile(suffix=".mp3", delete=False)
        tmp.write(audio_bytes)
        tmp.close()
        thread = threading.Thread(
            target=_play_file, args=(tmp.name, self.config.volume), daemon=True
        )
        thread.start()

    _TEST_PHRASES = {
        "ru": "Здравствуй, путник. Чем могу помочь?",
        "en": "Hello, traveller. How can I help you?",
        "cs": "Dobrý den, poutníče. Jak vám mohu pomoci?",
        "de": "Guten Tag, Reisender. Wie kann ich Euch helfen?",
        "fr": "Bonjour, voyageur. Comment puis-je vous aider?",
        "es": "Hola, viajero. ¿En qué puedo ayudarle?",
        "pl": "Witaj, wędrowcze. Jak mogę ci pomóc?",
        "zh": "你好，旅行者。我能帮你什么？",
        "ja": "こんにちは、旅人よ。何かお役に立てますか？",
    }

    async def test(self, text: str = "") -> str:
        if not text:
            lang = getattr(self.config, '_server_language', 'en')
            text = self._TEST_PHRASES.get(lang, self._TEST_PHRASES["en"])
        if not self.config.enabled:
            raise RuntimeError("TTS disabled")
        # Use the raising path so the UI surfaces real engine failures
        # (missing API key, HTTP error, voice not installed, etc.).
        await self._synth_and_play(text)
        return "ok"

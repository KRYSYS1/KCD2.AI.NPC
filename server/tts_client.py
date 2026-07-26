"""TTS client for KCD2 AI NPC server."""

import asyncio
import logging
import os
import shutil
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


def _init_pygame():
    global _pygame_ready
    try:
        import pygame
        with _pygame_lock:
            if not _pygame_ready:
                try:
                    pygame.mixer.init(frequency=22050, size=-16, channels=2, buffer=512)
                except pygame.error:
                    pygame.mixer.quit()
                    pygame.mixer.init(frequency=22050, size=-16, channels=2, buffer=512)
                pygame.mixer.set_num_channels(16)
                _pygame_ready = True
    except Exception as e:
        logger.warning(f"pygame init failed: {e}")


# Сглаживание пана между репликами (модульное состояние).
_last_pan = 0.0


def _distance_muffle(distance):
    """0 вблизи, растёт с дистанцией (дальние голоса глуше). ~1 на 15+ м."""
    if distance is None:
        return 0.0
    m = (distance - 2.0) / 13.0
    return 0.0 if m < 0.0 else (1.0 if m > 1.0 else m)


def _apply_lowpass(arr, amount):
    """Однополюсный low-pass по mono numpy-массиву. amount 0..1 (глуше)."""
    try:
        import numpy as np
        if amount <= 0.02 or arr is None or len(arr) == 0:
            return arr
        alpha = 1.0 - min(0.9, amount * 0.9)
        src2 = arr.astype(np.float32)
        out = np.empty_like(src2)
        y = float(src2[0])
        om = 1.0 - alpha
        for k in range(len(src2)):
            y = alpha * float(src2[k]) + om * y
            out[k] = y
        return out.astype(arr.dtype)
    except Exception:
        return arr


def _compute_spatial_volume(base_volume: float, npc_pos, player_pos, player_fwd):
    """Return (left, right, distance, pan, muffle) for NPC-relative TTS.
    muffle 0..1 = сила low-pass (дистанция + «за спиной»)."""
    import math
    global _last_pan
    try:
        nx = float(npc_pos.get("x", 0)) if hasattr(npc_pos, "get") else float(npc_pos[0])
        ny = float(npc_pos.get("y", 0)) if hasattr(npc_pos, "get") else float(npc_pos[1])
        px = float(player_pos.get("x", 0)) if hasattr(player_pos, "get") else float(player_pos[0])
        py = float(player_pos.get("y", 0)) if hasattr(player_pos, "get") else float(player_pos[1])
    except Exception:
        return base_volume, base_volume, None, None, 0.0

    dx = nx - px
    dy = ny - py
    distance = math.sqrt(dx * dx + dy * dy)

    ref = 3.0
    min_gain = 0.10
    dist_atten = 1.0 / (1.0 + (distance / ref) ** 2)
    if dist_atten < min_gain:
        dist_atten = min_gain

    muffle = _distance_muffle(distance)

    # Слайдер «затухание с расстоянием»: 0 → без затухания и приглушения.
    dist_atten = (1.0 - _spatial_falloff) + _spatial_falloff * dist_atten
    muffle = muffle * _spatial_falloff

    if not player_fwd or distance < 0.001:
        _last_pan = 0.0
        vol = base_volume * dist_atten
        return vol, vol, distance, 0.0, muffle

    try:
        fx = float(player_fwd.get("x", 0)) if hasattr(player_fwd, "get") else float(player_fwd[0])
        fy = float(player_fwd.get("y", 0)) if hasattr(player_fwd, "get") else float(player_fwd[1])
    except Exception:
        vol = base_volume * dist_atten
        return vol, vol, distance, 0.0, muffle

    fwd_len = math.sqrt(fx * fx + fy * fy)
    if fwd_len < 0.001:
        vol = base_volume * dist_atten
        return vol, vol, distance, 0.0, muffle

    fx /= fwd_len
    fy /= fwd_len
    ndx = dx / distance
    ndy = dy / distance
    rx = fy
    ry = -fx
    pan = max(-1.0, min(1.0, (ndx * rx + ndy * ry) * 1.5))
    front = ndx * fx + ndy * fy

    pan = 0.5 * _last_pan + 0.5 * pan
    _last_pan = pan

    left = 1.0 - max(0.0, pan) * 0.9
    right = 1.0 - max(0.0, -pan) * 0.9

    back_atten = 1.0
    if front < 0.0:
        back_atten = 1.0 + front * 0.4
        if back_atten < 0.55:
            back_atten = 0.55
        muffle = min(1.0, muffle + (-front) * 0.35)

    l = left * base_volume * dist_atten * back_atten
    r = right * base_volume * dist_atten * back_atten
    return l, r, distance, pan, muffle


_face_cb = None


def set_face_callback(cb) -> None:
    """Колбэк (npc_id, duration_ms): сервер дёргает Lua — 'говорящее лицо'
    NPC на время реплики (липсинк-лайт, слой 12)."""
    global _face_cb
    _face_cb = cb


_pos_provider = None
_spatial_enabled = True
_spatial_falloff = 1.0


def set_spatial_falloff(percent) -> None:
    """Сила затухания с расстоянием (слайдер панели, 0-100%).
    0 = голос одинаково громкий на любой дистанции, 100 = полное затухание."""
    global _spatial_falloff
    try:
        _spatial_falloff = max(0.0, min(100.0, float(percent))) / 100.0
    except Exception:
        _spatial_falloff = 1.0


def set_spatial_enabled(value) -> None:
    """Тумблер пространственной озвучки (веб-панель, interaction.enable_spatial_audio)."""
    global _spatial_enabled
    _spatial_enabled = bool(value)


def set_position_provider(cb) -> None:
    """Провайдер свежих позиций {npc_pos, player_pos, player_fwd, ts} —
    для real-time обновления панорамы во время воспроизведения."""
    global _pos_provider
    _pos_provider = cb


def _play_file(path: str, volume: float = 1.0, npc_pos=None, player_pos=None, player_fwd=None, npc_id=None):
    try:
        import pygame
        _init_pygame()
        t_play_start = time.perf_counter()
        sound = pygame.mixer.Sound(path)
        channel = pygame.mixer.find_channel(force=True)
        if channel is None:
            channel = pygame.mixer.Channel(0)

        left_vol = volume
        right_vol = volume
        distance = None
        pan = None
        muffle = 0.0
        if npc_pos and player_pos and _spatial_enabled:
            left_vol, right_vol, distance, pan, muffle = _compute_spatial_volume(volume, npc_pos, player_pos, player_fwd)

        # TTS services output mono MP3. pygame Channel.set_volume(left,right)
        # is ignored for mono sources, so we bake the pan into a stereo Sound.
        orig_left, orig_right = left_vol, right_vol
        try:
            import pygame.sndarray
            import numpy as np
            arr = pygame.sndarray.array(sound)
            if arr.ndim == 1:
                # Пан НЕ запекаем: панораму рулит channel.set_volume(l, r) на
                # лету (real-time обновление по POS|-фиду во время реплики).
                # Запекаем только low-pass — его на лету не поменять.
                arr = _apply_lowpass(arr, muffle)
                stereo = np.zeros((len(arr), 2), dtype=arr.dtype)
                stereo[:, 0] = arr
                stereo[:, 1] = arr
                sound = pygame.sndarray.make_sound(stereo)
        except Exception:
            pass  # источник останется как есть; set_volume всё равно применится

        if _face_cb and npc_id:
            try:
                _face_cb(npc_id, int(sound.get_length() * 1000))
            except Exception:
                pass  # лицо — некритично, звук важнее

        channel.set_volume(left_vol, right_vol)
        channel.play(sound)
        logger.info(
            f"TTS play started in {(time.perf_counter()-t_play_start)*1000:.0f} ms "
            f"(L={orig_left:.2f} R={orig_right:.2f} dist={distance if distance is not None else 'n/a'} "
            f"pan={pan if pan is not None else 'n/a'} npc_pos={npc_pos} player_pos={player_pos} player_fwd={player_fwd})"
        )
        while channel.get_busy():
            time.sleep(0.1)
            if _pos_provider is not None and npc_pos and player_pos and _spatial_enabled:
                try:
                    fresh = _pos_provider() or {}
                    if fresh.get("ts", 0.0) >= time.time() - 2.0:
                        l2, r2, _d, _p, _m = _compute_spatial_volume(
                            volume,
                            fresh.get("npc_pos") or npc_pos,
                            fresh.get("player_pos") or player_pos,
                            fresh.get("player_fwd") or player_fwd,
                        )
                        channel.set_volume(l2, r2)
                except Exception:
                    pass
    except Exception as e:
        logger.error(f"Audio playback failed: {e}")
    finally:
        try:
            os.unlink(path)
        except Exception:
            pass


def warmup() -> None:
    """Initialize pygame mixer eagerly to remove cold-start delay on first reply."""
    _init_pygame()


class TTSClient:
    def __init__(self, config):
        self.config = config
        self._output_dir = Path(config.output_dir)
        self._output_dir.mkdir(parents=True, exist_ok=True)
        self._engine_playback_callback = None

    def set_engine_playback_callback(self, callback) -> None:
        """Register a server callback that asks the Lua mod to play TTS in-engine.

        The callback receives (audio_path, npc_id, npc_name, npc_name_resolved,
        npc_pos, player_pos, volume) and returns True when the command was
        queued. External pygame playback remains available as a fallback.
        """
        self._engine_playback_callback = callback

    def _durable_audio_path(self, suffix: str) -> Path:
        stamp = int(time.time() * 1000)
        return self._output_dir / f"ai_npc_tts_{stamp}_{threading.get_ident()}{suffix}"

    def _queue_engine_playback(self, path: str, npc_id: str | None, npc_name: str | None, npc_name_resolved: str | None, npc_pos=None, player_pos=None) -> bool:
        if not self._engine_playback_callback:
            return False
        try:
            return bool(self._engine_playback_callback(
                path,
                npc_id,
                npc_name,
                npc_name_resolved,
                npc_pos,
                player_pos,
                self.config.volume,
            ))
        except Exception as exc:
            logger.warning(f"engine TTS dispatch failed: {exc}")
            return False

    def _dispatch_playback(self, tmp_path: str, volume: float, npc_id: str | None, npc_name: str | None, npc_name_resolved: str | None, npc_pos=None, player_pos=None, player_fwd=None) -> None:
        mode = (os.getenv("AI_NPC_TTS_PLAYBACK") or "engine").strip().lower()
        if mode not in {"engine", "external", "both"}:
            mode = "engine"

        engine_queued = False
        if mode in {"engine", "both"}:
            src = Path(tmp_path)
            durable = self._durable_audio_path(src.suffix or ".mp3")
            try:
                durable.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, durable)
                engine_queued = self._queue_engine_playback(
                    str(durable), npc_id, npc_name, npc_name_resolved, npc_pos, player_pos
                )
                if engine_queued:
                    logger.info(f"TTS queued for engine playback: {durable}")
            except Exception as exc:
                logger.warning(f"engine TTS file handoff failed: {exc}")

        if mode == "external" or mode == "both" or not engine_queued:
            thread = threading.Thread(
                target=_play_file, args=(tmp_path, volume, npc_pos, player_pos, player_fwd, npc_id), daemon=True
            )
            thread.start()
            return

        try:
            os.unlink(tmp_path)
        except Exception:
            pass

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

    async def speak(self, text: str, gender: int | None = None, npc_id: str | None = None, npc_name: str | None = None, npc_name_resolved: str | None = None, npc_pos=None, player_pos=None, player_fwd=None) -> None:
        """Fire-and-forget speak: swallows engine errors after logging
        so a failing TTS does not crash chat handling."""
        try:
            await self._synth_and_play(text, gender, npc_id, npc_name, npc_name_resolved, npc_pos, player_pos, player_fwd)
        except Exception as e:
            engine = self._resolve_engine(npc_id, npc_name, npc_name_resolved)
            logger.error(f"TTS speak failed [{engine}]: {e}")

    async def _synth_and_play(self, text: str, gender: int | None = None, npc_id: str | None = None, npc_name: str | None = None, npc_name_resolved: str | None = None, npc_pos=None, player_pos=None, player_fwd=None) -> None:
        """Engine dispatch that propagates errors to the caller."""
        if not self.config.enabled or not text.strip():
            return
        engine = self._resolve_engine(npc_id, npc_name, npc_name_resolved)
        if engine == "edge":
            await self._speak_edge(text, gender, npc_id, npc_name, npc_name_resolved, npc_pos, player_pos, player_fwd)
        elif engine == "elevenlabs":
            await self._speak_elevenlabs(text, gender, npc_id, npc_name, npc_name_resolved, npc_pos, player_pos, player_fwd)
        elif engine == "openai":
            await self._speak_openai(text, gender, npc_id, npc_name, npc_name_resolved, npc_pos, player_pos, player_fwd)
        else:
            raise RuntimeError(f"Unknown TTS engine: {engine}")

    async def _speak_edge(self, text: str, gender: int | None = None, npc_id: str | None = None, npc_name: str | None = None, npc_name_resolved: str | None = None, npc_pos=None, player_pos=None, player_fwd=None) -> None:
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

        # edge-tts периодически флейкает ("No audio was received") — ретраим
        # до 3 попыток с паузой; отдельно сохраняем транслит-фолбэк для кириллицы
        # на не-русском голосе.
        attempt_exc = None
        for attempt in range(3):
            try:
                await save_edge_audio(synth_text)
                attempt_exc = None
                break
            except Exception as exc:
                attempt_exc = exc
                if _has_cyrillic(text) and voice_lang != "ru":
                    synth_text = _transliterate_cyrillic(text)
                    logger.warning(f"edge-tts failed for Cyrillic text with voice={voice}; retrying transliterated text: {exc}")
                else:
                    logger.warning(f"edge-tts synth attempt {attempt + 1}/3 failed ({exc}); retrying")
                    await asyncio.sleep(0.4 * (attempt + 1))
        if attempt_exc is not None:
            raise attempt_exc
        logger.info(f"edge-tts synth in {(time.perf_counter()-t0)*1000:.0f} ms, chars={len(text)}, synth_chars={len(synth_text)}, gender={gender}, voice={voice}")
        self._dispatch_playback(tmp.name, self.config.volume, npc_id, npc_name, npc_name_resolved, npc_pos, player_pos, player_fwd)

    async def _speak_elevenlabs(self, text: str, gender: int | None = None, npc_id: str | None = None, npc_name: str | None = None, npc_name_resolved: str | None = None, npc_pos=None, player_pos=None, player_fwd=None) -> None:
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
        self._dispatch_playback(tmp.name, self.config.volume, npc_id, npc_name, npc_name_resolved, npc_pos, player_pos, player_fwd)

    async def _speak_openai(self, text: str, gender: int | None = None, npc_id: str | None = None, npc_name: str | None = None, npc_name_resolved: str | None = None, npc_pos=None, player_pos=None, player_fwd=None) -> None:
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
        self._dispatch_playback(tmp.name, self.config.volume, npc_id, npc_name, npc_name_resolved, npc_pos, player_pos, player_fwd)

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




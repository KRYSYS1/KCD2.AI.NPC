"""KCD2 AI NPC Server — FastAPI application."""

import asyncio
import json
import logging
import os
import re
import subprocess
import sys
import threading
import time
import signal
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from server.config import HUDConfig, InputConfig, LLMConfig, STTConfig, TTSConfig, ServerConfig
from server.conversation import ConversationManager
from server.llm_client import LLMClient
from server.npc_context import (
    build_system_prompt,
    normalize_game_extra_context,
    reload_character_db,
    resolve_npc_name,
    set_prompt_template,
)
from server.tts_client import TTSClient, warmup as tts_warmup
from server.stt_client import STTClient
from server.input_overlay import InputOverlay
from server.key_monitor import KeyMonitor

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(Path(__file__).parent.parent / "server.log", encoding="utf-8"),
    ],
)
logger = logging.getLogger(__name__)

CONFIG_PATH = Path(__file__).parent.parent / "config.json"
EXAMPLE_CONFIG_PATH = Path(__file__).parent.parent / "config.example.json"
STATIC_DIR = Path(__file__).parent / "static"


def load_config() -> ServerConfig:
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
        return ServerConfig(**data)
    if EXAMPLE_CONFIG_PATH.exists():
        CONFIG_PATH.write_text(EXAMPLE_CONFIG_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        logger.warning(
            "config.json was missing, so it was created from config.example.json. "
            "Open config.json and set your API key before chatting with NPCs."
        )
    return ServerConfig()


config = load_config()
llm_client = LLMClient(config.llm)
tts_client = TTSClient(config.tts)
stt_client = STTClient(config.stt)
conversations = ConversationManager()
input_overlay = InputOverlay(style=config.input.overlay_style)
# Server-side V-key monitor — see server/key_monitor.py for the rationale
# (CryEngine "+/-" prefix fires both events on key-down in this build, so we
# poll the keyboard directly and route taps/holds to the right pipeline).
# Callbacks are wired in lifespan() once _main_loop and the helpers below
# (_on_v_tap / _on_v_hold_start / _on_v_hold_end) are in scope.
key_monitor = KeyMonitor(
    chat_key=(config.input.chat_key or "v"),
    threshold_ms=int(config.stt.hold_threshold_ms or 200),
)
_main_loop: asyncio.AbstractEventLoop | None = None
_overlay_request_counter = 0
_ptt_request_counter = 0

def detect_game_root() -> Path | None:
    candidates: list[Path] = []
    env_game_dir = os.getenv("KCD2_GAME_DIR", "").strip()
    if env_game_dir:
        candidates.append(Path(env_game_dir))
    # config.json game_path (if set)
    cfg_path = getattr(config, "game_path", None)
    if cfg_path:
        candidates.append(Path(cfg_path))
    # Common Steam library locations
    for steam_root in [
        Path(r"C:\SteamLibrary"),
        Path(r"D:\SteamLibrary"),
        Path(r"C:\Program Files (x86)\Steam"),
        Path(r"D:\Program Files (x86)\Steam"),
    ]:
        if steam_root.exists():
            for name in ["KingdomComeDeliverance2", "Kingdom Come Deliverance II"]:
                p = steam_root / "steamapps" / "common" / name
                if p.exists():
                    candidates.append(p)
    # GOG
    for gog_root in [
        Path(r"C:\GOG Games"),
        Path(r"D:\GOG Games"),
        Path(r"C:\Program Files (x86)\GOG Galaxy\Games"),
        Path(r"D:\Program Files (x86)\GOG Galaxy\Games"),
    ]:
        if gog_root.exists():
            for name in ["KingdomComeDeliverance2", "Kingdom Come Deliverance II"]:
                p = gog_root / name
                if p.exists():
                    candidates.append(p)
    # Epic Games Store
    for epic_root in [
        Path(r"C:\Program Files\Epic Games"),
        Path(r"D:\Program Files\Epic Games"),
    ]:
        if epic_root.exists():
            for name in ["KingdomComeDeliverance2", "Kingdom Come Deliverance II"]:
                p = epic_root / name
                if p.exists():
                    candidates.append(p)
    # Generic library scan across available Windows drives. This covers custom
    # install drives without hardcoding one developer's machine.
    for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
        drive = Path(f"{letter}:\\")
        if not drive.exists():
            continue
        for template in [
            ("Games", "{name}"),
            ("GOG Games", "{name}"),
            ("SteamLibrary", "steamapps", "common", "{name}"),
            ("Program Files", "Epic Games", "{name}"),
        ]:
            for name in ["KingdomComeDeliverance2", "Kingdom Come Deliverance II"]:
                parts = [name if part == "{name}" else part for part in template]
                p = drive.joinpath(*parts)
                if p.exists():
                    candidates.append(p)
    seen: set[Path] = set()
    unique_candidates: list[Path] = []
    for candidate in candidates:
        try:
            key = candidate.resolve()
        except Exception:
            key = candidate
        if key not in seen:
            seen.add(key)
            unique_candidates.append(candidate)
    candidates = unique_candidates

    with_logs = [candidate for candidate in candidates if candidate.exists() and (candidate / "kcd.log").exists()]
    if with_logs:
        return max(with_logs, key=lambda candidate: (candidate / "kcd.log").stat().st_mtime)
    for candidate in candidates:
        if candidate.exists():
            return candidate
    logger.warning(
        "Game directory not found. Set KCD2_GAME_DIR environment variable "
        "or create a config.json with 'game_path' pointing to your KCD2 folder. "
        "The server will start but game-file features (log tailing, resp.lua, etc.) will be disabled."
    )
    return None


def detect_bin_dir(game_root: Path | None) -> Path | None:
    if game_root is None:
        return None
    bin_root = game_root / "Bin"
    gog = bin_root / "Win64MasterMasterGogPGO"
    steam = bin_root / "Win64MasterMasterSteamPGO"
    if gog.exists():
        return gog
    if steam.exists():
        return steam
    return gog


GAME_ROOT = detect_game_root()
BIN_DIR = detect_bin_dir(GAME_ROOT) if GAME_ROOT else None

RESP_LUA_PATH     = GAME_ROOT / "Data" / "Scripts" / "ai_npc" / "resp.lua" if GAME_ROOT else None
RESP_LUA_PATH_BIN = BIN_DIR / "resp.lua" if BIN_DIR else None
COMMAND_LUA_PATH  = GAME_ROOT / "Data" / "Scripts" / "ai_npc" / "command.lua" if GAME_ROOT else None
REQUEST_JSON_PATH = GAME_ROOT / "Data" / "Scripts" / "ai_npc" / "request.json" if GAME_ROOT else None
KCD_LOG_PATH      = GAME_ROOT / "kcd.log" if GAME_ROOT else None
ACTION_MAP_PATH   = GAME_ROOT / "Data" / "Libs" / "Config" / "ai_npc_actions.xml" if GAME_ROOT else None
# The Lua mod tracks `last_web_command_id` in module-level state that
# survives across Python server restarts; if we naively reset to 0 every
# time the server reboots, Lua silently drops the first N commands until
# our counter catches up to its remembered max (see AI_NPC_HandleWebCommand's
# `if command_id <= last_web_command_id then return`). To stay monotonic
# across restarts we persist the counter to a small text file in the user's
# project state. We deliberately avoid seeding from `time.time() * 1000`:
# CryEngine's Lua may coerce numbers to a 32-bit int on comparison, and
# epoch-ms (~1.78e12) overflows that range — comparisons then produce
# garbage and the mod looks frozen.
_WEB_CMD_STATE_FILE = Path(__file__).resolve().parent.parent / ".web_command_id"


def _load_web_command_id() -> int:
    try:
        raw = _WEB_CMD_STATE_FILE.read_text(encoding="utf-8").strip()
        return max(0, int(raw))
    except FileNotFoundError:
        return 0
    except Exception as exc:
        logger.warning(f"web_command_id: failed to read state file: {exc}")
        return 0


def _save_web_command_id(value: int) -> None:
    try:
        _WEB_CMD_STATE_FILE.write_text(str(int(value)), encoding="utf-8")
    except Exception as exc:
        logger.debug(f"web_command_id: failed to persist state: {exc}")


web_command_id = _load_web_command_id()
active_npc: dict[str, str] | None = None
# Most recent NPC the player has aimed the crosshair at, populated from the
# Lua mod's "[AI NPC] TARGET|" / "TARGET_CTX|" broadcasts. Unlike active_npc
# (which is only set when a chat is open), target_npc is updated continuously
# while aiming. We use it as a fallback for push-to-talk so the user can
# hold V to speak with an NPC *without* having to first tap-open and close
# the overlay to seed active_npc.
target_npc: dict[str, str] | None = None
ptt_locked_npc: dict[str, str] | None = None


def normalize_key(key: str, default: str = "v", allow_empty: bool = False) -> str:
    key = (key or "").strip().lower()
    if not key:
        if allow_empty:
            return ""
        return default
    allowed = set("abcdefghijklmnopqrstuvwxyz0123456789")
    if len(key) == 1 and key in allowed:
        return key
    if key.startswith("f") and key[1:].isdigit():
        num = int(key[1:])
        if 1 <= num <= 12:
            return key
    return default


def write_action_map(chat_key: str, end_key: str) -> None:
    if ACTION_MAP_PATH is None:
        return
    chat_key = normalize_key(chat_key, "v")
    end_key = normalize_key(end_key, "", allow_empty=True)
    end_action = ""
    if end_key:
        end_action = f"    <Action name=\"ai_npc_end\"  onPress=\"1\" keyboard=\"{end_key}\"/>\n"
    ACTION_MAP_PATH.parent.mkdir(parents=True, exist_ok=True)
    ACTION_MAP_PATH.write_text(
        "<ActionMaps version=\"22\">\n"
        "  <ActionMap name=\"ai_npc\">\n"
        f"    <Action name=\"ai_npc_chat\" onPress=\"1\" keyboard=\"{chat_key}\"/>\n"
        f"{end_action}"
        "  </ActionMap>\n"
        "</ActionMaps>\n",
        encoding="utf-8",
    )
    logger.info(f"ActionMap updated: chat={chat_key}, end={end_key}")


async def file_ipc_watcher() -> None:
    """Poll kcd.log for structured request lines written by the Lua mod, process them, write resp.lua."""
    if KCD_LOG_PATH is None:
        logger.warning("file_ipc_watcher disabled — game directory not found")
        while True:
            await asyncio.sleep(60)
    logger.info(f"Log IPC watcher started — watching {KCD_LOG_PATH}")
    last_pos = KCD_LOG_PATH.stat().st_size if KCD_LOG_PATH.exists() else 0
    handled_requests: set[tuple[str, int]] = set()
    while True:
        await asyncio.sleep(0.4)
        if not KCD_LOG_PATH.exists():
            continue
        try:
            current_size = KCD_LOG_PATH.stat().st_size
            if current_size < last_pos:
                last_pos = 0
            if current_size == last_pos:
                continue
            with KCD_LOG_PATH.open("r", encoding="utf-8", errors="ignore") as f:
                f.seek(last_pos)
                chunk = f.read()
                last_pos = f.tell()
        except Exception as e:
            logger.warning(f"Log IPC: failed to read kcd.log: {e}")
            continue

        for line in chunk.splitlines():
            # ------------------------------------------------------------
            # Push-to-talk (smart V: hold) — Lua writes these markers.
            # PTT_START opens the mic; PTT_STOP closes it, transcribes, and
            # feeds the result into the normal chat pipeline.
            # ------------------------------------------------------------
            if "[AI NPC] PTT_START" in line:
                logger.info("Log IPC: PTT_START received")
                try:
                    stt_client.start()
                except Exception as exc:
                    logger.error(f"[PTT] start failed: {exc}")
                continue
            if "[AI NPC] PTT_STOP" in line:
                logger.info("Log IPC: PTT_STOP received")
                asyncio.create_task(_handle_ptt_stop())
                continue
            if "[AI NPC] PTT_CANCEL" in line:
                logger.info("Log IPC: PTT_CANCEL received")
                try:
                    stt_client.cancel()
                except Exception as exc:
                    logger.warning(f"[PTT] cancel failed: {exc}")
                continue

            active_marker = "[AI NPC] ACTIVE|"
            if active_marker in line:
                try:
                    raw_active = line.split(active_marker, 1)[1]
                    data_active = json.loads(raw_active)
                    global active_npc
                    active_npc = data_active if data_active.get("npc_id") else None
                    if active_npc:
                        resolved = resolve_npc_name(
                            active_npc.get("npc_name") or "",
                            active_npc.get("extra_context") or "",
                            config.language,
                        )
                        active_npc["npc_name_resolved"] = resolved
                        if resolved != (active_npc.get("npc_name") or ""):
                            logger.info(
                                f"Log IPC: name resolved '{active_npc.get('npc_name')}' -> '{resolved}'"
                            )
                    logger.info(f"Log IPC: active NPC = {active_npc}")
                    if config.input.overlay_enabled:
                        if active_npc:
                            input_overlay.show(active_npc.get("npc_name_resolved") or active_npc.get("npc_name") or "NPC")
                        else:
                            input_overlay.hide()
                        # Note: key_monitor pause/resume is wired through the
                        # overlay visibility callback (see lifespan), not here,
                        # so Enter/Escape hides re-enable V detection even when
                        # Lua's ACTIVE broadcast hasn't caught up yet.
                except Exception as e:
                    logger.warning(f"Log IPC: failed to parse active NPC line: {e}")
                continue

            # Continuously-updated "currently aimed at" NPC. Used as a
            # fallback for push-to-talk when no chat is open yet.
            target_marker = "[AI NPC] TARGET|"
            if target_marker in line:
                try:
                    raw_target = line.split(target_marker, 1)[1]
                    data_target = json.loads(raw_target)
                    global target_npc
                    if data_target.get("id"):
                        # Map TARGET| field names to the ChatRequest-shaped
                        # dict layout used by active_npc (npc_id / npc_name /
                        # npc_class) so the PTT fallback in _on_v_hold_start
                        # can use the same code path as a real ACTIVE| broadcast.
                        # Preserve any previously-captured extra_context from
                        # a TARGET_CTX| line for the same NPC.
                        prev_ctx = ""
                        prev_resolved = ""
                        if isinstance(target_npc, dict) and target_npc.get("npc_id") == data_target["id"]:
                            prev_ctx = target_npc.get("extra_context") or ""
                            prev_resolved = target_npc.get("npc_name_resolved") or ""
                        target_npc = {
                            "npc_id": data_target.get("id", ""),
                            "npc_name": data_target.get("name", "") or "",
                            "npc_class": data_target.get("class", "") or "",
                            "extra_context": prev_ctx,
                            "recent_player_actions": data_target.get("recent_player_actions") or [],
                            "gender": data_target.get("gender"),
                        }
                        if prev_resolved:
                            target_npc["npc_name_resolved"] = prev_resolved
                    else:
                        target_npc = None
                except Exception as e:
                    logger.warning(f"Log IPC: failed to parse TARGET line: {e}")
                continue

            target_ctx_marker = "[AI NPC] TARGET_CTX|"
            if target_ctx_marker in line:
                try:
                    raw_ctx = line.split(target_ctx_marker, 1)[1]
                    # Lua replaces literal newlines in extra_context with " | "
                    # before broadcasting (so the line stays single-line); turn
                    # them back into newlines for the LLM prompt.
                    extra_context = raw_ctx.replace(" | ", "\n").strip()
                    if isinstance(target_npc, dict):
                        target_npc["extra_context"] = extra_context
                        if not target_npc.get("npc_name_resolved"):
                            target_npc["npc_name_resolved"] = resolve_npc_name(
                                target_npc.get("npc_name") or "",
                                extra_context,
                                config.language,
                            )
                except Exception as e:
                    logger.warning(f"Log IPC: failed to parse TARGET_CTX line: {e}")
                continue

            marker = "[AI NPC] REQUEST|"
            if marker not in line:
                continue
            try:
                raw = line.split(marker, 1)[1]
                data = json.loads(raw)
                req = ChatRequest(**data)
            except Exception as e:
                logger.warning(f"Log IPC: failed to parse request line: {e}")
                continue

            request_key = (req.npc_id, req.request_id)
            if request_key in handled_requests:
                continue
            handled_requests.add(request_key)

            logger.info(f"Log IPC: request #{req.request_id} from NPC '{req.npc_name}'")
            await _process_chat_request(req, source="log")


async def _handle_ptt_stop() -> None:
    """Stop the mic, transcribe, and submit the result as a chat request.

    The Lua mod writes "[AI NPC] PTT_STOP" to kcd.log when the player releases
    V after a hold. We close the InputStream, run the buffer through the
    selected STT provider, then synthesize a ChatRequest from the currently
    active NPC (same shape as the overlay path) and route it through
    ``_process_chat_request``. The transcribed text is treated as if the
    player had typed it into the overlay.
    """
    global _ptt_request_counter
    # Snapshot once: between stt_client.stop() (a blocking call dispatched
    # to a worker thread) and request build, the player's aim could move
    # off the NPC and clear target_npc. Use the NPC that was current at
    # PTT-stop time so the transcription is delivered to the right NPC.
    npc = _ptt_npc_for_request()
    npc_for_prompt = ""
    if isinstance(npc, dict):
        npc_for_prompt = npc.get("npc_name_resolved") or npc.get("npc_name") or ""

    try:
        text = await asyncio.to_thread(stt_client.stop, prompt=npc_for_prompt)
    except Exception as exc:
        logger.error(f"[PTT] transcription error: {exc}")
        return

    if not text:
        logger.info("[PTT] empty transcription — nothing to send")
        return
    if not npc:
        logger.warning(f"[PTT] no active NPC, dropping transcription: {text!r}")
        return

    raw_actions = npc.get("recent_player_actions") or []
    parsed_actions: list[PlayerActionEntry] = []
    for a in raw_actions:
        try:
            parsed_actions.append(PlayerActionEntry(**a))
        except Exception as exc:
            logger.warning(f"[PTT] skip malformed action entry {a!r}: {exc}")

    _ptt_request_counter += 1
    req = ChatRequest(
        npc_id=npc.get("npc_id", ""),
        npc_name=npc.get("npc_name", "NPC"),
        npc_class=npc.get("npc_class", ""),
        npc_location="",
        player_message=text,
        extra_context=npc.get("extra_context", "") or "",
        recent_player_actions=parsed_actions,
        npc_gender=npc.get("gender"),
        request_id=10_000_000 + _ptt_request_counter,
    )
    logger.info(
        f"[PTT] submit #{_ptt_request_counter} -> {req.npc_name}: "
        f"{req.player_message!r} (actions={len(parsed_actions)})"
    )
    await _process_chat_request(req, source="ptt")


def _overlay_submit(text: str) -> None:
    """Tk-thread callback: build a ChatRequest from the currently active NPC
    and schedule processing on the asyncio main loop. Avoids the Lua
    command.lua round-trip which proved fragile for non-ASCII payloads."""
    global _overlay_request_counter
    if not text or not text.strip():
        return
    if not active_npc:
        logger.warning("[overlay] submit ignored: no active NPC")
        return
    if _main_loop is None:
        logger.error("[overlay] submit: main loop not initialized")
        return
    _overlay_request_counter += 1
    # Forward player_action_log captured in the latest ACTIVE| broadcast so the
    # LLM gets pickpocket/hit/loot context even when the user submits from the
    # in-game overlay (which bypasses Lua's send_message path).
    raw_actions = active_npc.get("recent_player_actions") or []
    parsed_actions: list[PlayerActionEntry] = []
    for a in raw_actions:
        try:
            parsed_actions.append(PlayerActionEntry(**a))
        except Exception as exc:
            logger.warning(f"[overlay] skip malformed action entry {a!r}: {exc}")
    req = ChatRequest(
        npc_id=active_npc.get("npc_id", ""),
        npc_name=active_npc.get("npc_name", "NPC"),
        npc_class=active_npc.get("npc_class", ""),
        npc_location="",
        player_message=text.strip(),
        extra_context=active_npc.get("extra_context", "") or "",
        recent_player_actions=parsed_actions,
        npc_gender=active_npc.get("gender"),
        request_id=20_000_000 + _overlay_request_counter,
    )
    logger.info(
        f"[overlay] submit #{_overlay_request_counter} -> {req.npc_name}: "
        f"{req.player_message} (actions={len(parsed_actions)})"
    )
    try:
        asyncio.run_coroutine_threadsafe(
            _process_chat_request(req, source="overlay"), _main_loop
        )
    except Exception as e:
        logger.error(f"[overlay] schedule failed: {e}")


def format_recent_player_actions(
    actions: "list[PlayerActionEntry]",
    current_npc_name: str = "",
) -> str:
    """Render the Lua-side player_action_log as a short paragraph for the prompt.

    Output example:
        Henry's recent actions (Player Event Dispatcher):
        - 45s ago: tried to pickpocket this NPC.
        - 2m ago: stealth-killed Pavel.
        - 5m ago: looted a corpse.
    """
    if not actions:
        return ""

    EVENT_PHRASES = {
        "Pickpocketing": "tried to pickpocket",
        "StealthKill":   "stealth-killed",
        "Knockout":      "knocked out",
        "Loot":          "looted",
        "GrabCorpse":    "dragged a corpse of",
        "MercyKill":     "mercy-killed",
        "HorsePullDown": "pulled off a horse",
        "Follow":        "asked to follow",
        "Hit":           "beat up",
    }
    # Events that are hostile/criminal acts against the target NPC.
    HOSTILE_EVENTS = {"Pickpocketing", "StealthKill", "Knockout", "Loot",
                      "GrabCorpse", "MercyKill", "Hit"}

    def humanize_age(seconds: int) -> str:
        if seconds < 60:
            return f"{seconds}s ago"
        if seconds < 3600:
            return f"{seconds // 60}m ago"
        return f"{seconds // 3600}h ago"

    against_you: list[str] = []
    other: list[str] = []
    for a in actions[-10:]:  # last 10 entries max
        phrase = EVENT_PHRASES.get(a.event, a.event.lower())
        target = "you" if a.same_npc else (a.npc_name or "someone nearby")
        # Direct-object events read better without "of"
        if a.event == "GrabCorpse" and not a.same_npc:
            target = a.npc_name or "someone"
        # Hit events: annotate with severity from hp_delta.
        suffix = ""
        if a.event == "Hit" and a.hp_delta is not None:
            # KCD2 returns HP in 0..100 for humans (likely 0..1 for some animals).
            # Normalize to a 0..1 fraction so severity thresholds work uniformly.
            frac = a.hp_delta / 100.0 if a.hp_delta > 1.0 else a.hp_delta
            sev = "heavily" if frac >= 0.30 else ("hard" if frac >= 0.10 else "lightly")
            suffix = f" ({sev}, lost ~{frac*100:.0f}% of health)"
        line = f"- {humanize_age(a.seconds_ago)}: {phrase} {target}{suffix}."
        if a.same_npc and a.event in HOSTILE_EVENTS:
            against_you.append(line)
        else:
            other.append(line)

    if not against_you and not other:
        return ""

    parts: list[str] = []
    if against_you:
        parts.append(
            "IMPORTANT — Henry just committed these acts AGAINST YOU "
            "(you witnessed them and you remember; do NOT pretend they did not happen):\n"
            + "\n".join(against_you)
            + "\nYou MUST acknowledge this in your response — be angry, frightened, "
            "indignant, suspicious or wary as fits your personality. If he tries to "
            "chat as if nothing happened, call him out on it."
        )
    if other:
        parts.append(
            "Henry's other recent actions nearby (for context, not necessarily against you):\n"
            + "\n".join(other)
        )
    return "\n\n".join(parts)


def _merge_action_context(req: "ChatRequest") -> str:
    """Return extra_context augmented with recent_player_actions if any."""
    base = req.extra_context or ""
    addendum = format_recent_player_actions(
        req.recent_player_actions, current_npc_name=req.npc_name
    )
    if not addendum:
        return base
    if base and not base.endswith("\n"):
        base += "\n"
    return base + addendum


async def _process_chat_request(req: "ChatRequest", source: str = "log") -> str | None:
    """Shared LLM+TTS+resp.lua path used by log IPC, /chat and overlay submit."""
    clear_response_lua()
    merged_extra = _merge_action_context(req)
    if req.recent_player_actions:
        formatted = format_recent_player_actions(
            req.recent_player_actions, current_npc_name=req.npc_name
        )
        logger.info(
            f"[{req.npc_name}] recent_player_actions ({len(req.recent_player_actions)} entries):\n{formatted}"
        )
    system_prompt, resolved_name = build_system_prompt(
        npc_name=req.npc_name,
        npc_class=req.npc_class,
        npc_location=req.npc_location,
        language=config.language,
        extra_context=merged_extra,
    )
    conv = conversations.get_or_create(req.npc_id, resolved_name, system_prompt)
    conv.add_user_message(req.player_message)
    t_llm = time.perf_counter()
    try:
        response_text = await llm_client.generate(
            system_prompt=conv.system_prompt,
            messages=conv.get_messages(),
        )
    except Exception as e:
        logger.error(f"[{source}] LLM generate failed: {e}")
        write_response_lua(resolved_name, f"[error: {e}]", req.request_id)
        return None
    llm_ms = (time.perf_counter() - t_llm) * 1000

    conv.add_assistant_message(response_text)
    conversations.save(req.npc_id)
    logger.info(f"[{resolved_name}] Player: {req.player_message}")
    logger.info(f"[{resolved_name}] NPC: {response_text}")
    logger.info(f"[{resolved_name}] LLM gen in {llm_ms:.0f} ms, chars={len(response_text)} (source={source})")
    if config.tts.enabled:
        asyncio.create_task(tts_client.speak(response_text, req.npc_gender))
    write_response_lua(resolved_name, response_text, req.request_id)
    return response_text


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(f"KCD2 AI NPC Server starting on {config.host}:{config.port}")
    logger.info(f"Game root: {GAME_ROOT or 'NOT FOUND (game-file features disabled)'}")
    logger.info(f"Bin dir: {BIN_DIR or 'N/A'}")
    logger.info(f"kcd.log path: {KCD_LOG_PATH or 'N/A'}")
    logger.info(f"LLM: {config.llm.model} @ {config.llm.api_url}")
    logger.info(f"Language: {config.language}")
    if config.tts.engine == "edge":
        tts_voice_info = f"male={config.tts.voice}, female={config.tts.voice_female}"
    elif config.tts.engine == "elevenlabs":
        tts_voice_info = f"male={config.tts.elevenlabs_voice}, female={config.tts.elevenlabs_voice_female}"
    elif config.tts.engine == "openai":
        tts_voice_info = f"male={config.tts.openai_voice}, female={config.tts.openai_voice_female}"
    else:
        tts_voice_info = f"male={config.tts.voice}, female={config.tts.voice_female}"
    logger.info(f"TTS: {'enabled' if config.tts.enabled else 'disabled'} ({config.tts.engine} / {tts_voice_info})")
    logger.info(
        f"STT: {'enabled' if config.stt.enabled else 'disabled'} "
        f"({config.stt.provider} / {config.stt.model} / lang={config.stt.language})"
    )
    write_action_map(config.input.chat_key, config.input.end_key)
    reload_character_db()
    if config.prompt_template:
        set_prompt_template(config.prompt_template)
    if config.tts.enabled:
        try:
            tts_warmup(config.tts.volume)
            logger.info("TTS mixer warmed up")
        except Exception as e:
            logger.warning(f"TTS warmup failed: {e}")
    global _main_loop
    _main_loop = asyncio.get_running_loop()
    if config.input.overlay_enabled:
        try:
            input_overlay.set_submit_callback(_overlay_submit)
            # Pause/unpause the V-key monitor in lock-step with overlay
            # visibility. This is the single source of truth for "is the user
            # typing right now?" — covers Enter, Escape, and Lua-driven hides.
            input_overlay.set_visibility_callback(
                lambda visible: key_monitor.set_paused(visible)
            )
            input_overlay.start()
            logger.info("Input overlay started")
        except Exception as e:
            logger.warning(f"Input overlay start failed: {e}")
    # Wire the V-key monitor (smart V: tap = overlay, hold = PTT). Defined
    # at module scope so update_config can hot-restart it when chat_key or
    # hold_threshold_ms changes from the web UI.
    key_monitor.on_tap = _on_v_tap
    key_monitor.on_hold_start = _on_v_hold_start
    key_monitor.on_hold_end = _on_v_hold_end
    if config.stt.enabled:
        try:
            key_monitor.start()
        except Exception as e:
            logger.warning(f"KeyMonitor start failed: {e}")
    else:
        logger.info("KeyMonitor not started (STT disabled in config)")

    watcher_task = asyncio.create_task(file_ipc_watcher())
    yield
    watcher_task.cancel()
    try:
        key_monitor.stop()
    except Exception:
        pass
    logger.info("Server shutting down.")


app = FastAPI(title="KCD2 AI NPC", version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# --- Web UI ---

@app.get("/", include_in_schema=False)
async def index():
    return FileResponse(STATIC_DIR / "index.html")


# --- Request / Response models ---


def _lua_bool(v) -> str:
    return "true" if bool(v) else "false"


def write_response_lua(npc_name: str, response_text: str, request_id: int) -> None:
    def lua_esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n").replace("\r", "")
    hud = config.hud
    hud_prefix = (
        f"_G.__ai_npc_hud_left = {_lua_bool(hud.show_left_top)}\n"
        f"_G.__ai_npc_hud_right = {_lua_bool(hud.show_right_top)}\n"
        f"_G.__ai_npc_hud_center = {_lua_bool(hud.show_center)}\n"
    )
    content = hud_prefix + f"AI_NPC_HandleResponse('{lua_esc(npc_name)}', '{lua_esc(response_text)}', {request_id})\n"
    if RESP_LUA_PATH is not None:
        try:
            RESP_LUA_PATH.parent.mkdir(parents=True, exist_ok=True)
            RESP_LUA_PATH.write_text(content, encoding="utf-8")
        except Exception as e:
            logger.warning(f"Could not write resp.lua (Data): {e}")
    if RESP_LUA_PATH_BIN is not None:
        try:
            RESP_LUA_PATH_BIN.write_text(content, encoding="utf-8")
        except Exception as e:
            logger.warning(f"Could not write resp.lua (Bin): {e}")


def clear_response_lua() -> None:
    if RESP_LUA_PATH is not None:
        try:
            RESP_LUA_PATH.write_text("", encoding="utf-8")
        except Exception as e:
            logger.warning(f"Could not clear resp.lua (Data): {e}")
    if RESP_LUA_PATH_BIN is not None:
        try:
            RESP_LUA_PATH_BIN.write_text("", encoding="utf-8")
        except Exception as e:
            logger.warning(f"Could not clear resp.lua (Bin): {e}")


def _force_unbind_chat_key_in_game() -> None:
    """Tell the running Lua mod to drop any legacy `bind v ai_chat`.

    The Lua side (mod/ai_npc/main.lua, AI_NPC_HandleWebCommand) recognises
    "__AI_NPC_FORCE_UNBIND_V__" as a control message and runs `unbind v` in
    the engine console. We send it whenever the KeyMonitor (re)starts so the
    user does not have to restart the game or type `unbind v` manually after
    upgrading the mod from a build that bound V via CryEngine.
    """
    try:
        cmd_id = write_command_lua("__AI_NPC_FORCE_UNBIND_V__")
        logger.info(
            f"[KeyMonitor] queued __AI_NPC_FORCE_UNBIND_V__ as command_id={cmd_id}"
        )
    except Exception:
        logger.exception("Failed to queue __AI_NPC_FORCE_UNBIND_V__")


def write_command_lua(message: str) -> int:
    global web_command_id
    web_command_id += 1
    # Persist before writing command.lua so that even if the process crashes
    # between the persist and the file write, on next start we won't reuse a
    # command_id Lua might have already seen.
    _save_web_command_id(web_command_id)

    def lua_esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", " ").replace("\r", "")

    content = f"AI_NPC_HandleWebCommand('{lua_esc(message)}', {web_command_id})\n"
    if COMMAND_LUA_PATH is not None:
        COMMAND_LUA_PATH.parent.mkdir(parents=True, exist_ok=True)
        COMMAND_LUA_PATH.write_text(content, encoding="utf-8")
    return web_command_id


# ---------------------------------------------------------------------------
# KeyMonitor callbacks
# ---------------------------------------------------------------------------
# These run on the KeyMonitor thread (see server/key_monitor.py) and are wired
# up in lifespan(). They must stay short — anything async goes through the
# main asyncio loop via run_coroutine_threadsafe.

def _on_v_tap() -> None:
    """V tapped (release < threshold): open the in-game chat overlay.

    We can't `bind v ai_chat` in CryEngine because then a hold would also
    open the overlay (the engine doesn't separate press from release in this
    build). Instead the server writes a control message to command.lua which
    the Lua mod picks up on its 500ms poll and forwards to AI_NPC_Toggle().
    """
    try:
        cmd_id = write_command_lua("__AI_NPC_TAP__")
        logger.info(f"[V-tap] queued __AI_NPC_TAP__ as command_id={cmd_id}")
    except Exception:
        logger.exception("[V-tap] failed to write command.lua")


def _ptt_npc_for_request() -> dict | None:
    """Return the NPC dict the PTT pipeline should target right now.

    Prefers ``active_npc`` (set by Lua's ACTIVE| broadcast on chat open) and
    falls back to ``target_npc`` (the crosshair-aimed NPC, populated from
    TARGET| broadcasts). The fallback lets the user hold V and speak even
    when no chat is open yet — without it they had to first tap V to open
    and close the overlay so Lua would emit ACTIVE|, which is a confusing
    UX paper-cut described by the user.
    """
    if isinstance(active_npc, dict) and active_npc.get("npc_id"):
        return active_npc
    if isinstance(target_npc, dict) and target_npc.get("npc_id"):
        return target_npc
    if isinstance(ptt_locked_npc, dict) and ptt_locked_npc.get("npc_id"):
        return ptt_locked_npc
    return None


def _current_aimed_or_active_npc() -> dict | None:
    if isinstance(active_npc, dict) and active_npc.get("npc_id"):
        return active_npc
    if isinstance(target_npc, dict) and target_npc.get("npc_id"):
        return target_npc
    return None


def _lock_ptt_npc(npc: dict | None) -> None:
    global ptt_locked_npc
    if isinstance(npc, dict) and npc.get("npc_id"):
        ptt_locked_npc = dict(npc)
        logger.info(
            f"[PTT] locked voice target: "
            f"{ptt_locked_npc.get('npc_name_resolved') or ptt_locked_npc.get('npc_name')}"
        )


def _on_v_hold_start() -> None:
    """V held past threshold: start microphone capture (push-to-talk)."""
    npc = _current_aimed_or_active_npc() or ptt_locked_npc
    try:
        cmd_id = write_command_lua("__AI_NPC_PUBLISH_TARGET__")
        logger.info(f"[V-hold] queued __AI_NPC_PUBLISH_TARGET__ as command_id={cmd_id}")
    except Exception:
        logger.exception("[V-hold] failed to queue __AI_NPC_PUBLISH_TARGET__")
    current_npc = _current_aimed_or_active_npc()
    if current_npc:
        npc = current_npc
        _lock_ptt_npc(npc)
    try:
        stt_client.start()
        if npc:
            logger.info(
                f"[V-hold] STT recording started "
                f"(target='{npc.get('npc_name_resolved') or npc.get('npc_name')}', "
                f"source={'active' if npc is active_npc else 'aim'})"
            )
        else:
            logger.info("[V-hold] STT recording started (target pending)")
    except Exception:
        logger.exception("[V-hold] stt_client.start failed")


def _on_v_hold_end(duration_sec: float) -> None:
    """V released after a hold: stop mic, transcribe, submit as a chat message.

    Reuses the existing :func:`_handle_ptt_stop` coroutine (originally written
    for the now-dead Lua-side ``[AI NPC] PTT_STOP`` log marker) so the audio
    pipeline stays in one place.
    """
    logger.info(f"[V-hold-end] duration={duration_sec:.2f}s")
    if _main_loop is None:
        logger.warning("[V-hold-end] main loop not ready — discarding audio")
        try:
            stt_client.cancel()
        except Exception:
            pass
        return
    npc = _ptt_npc_for_request()
    if not npc:
        try:
            cmd_id = write_command_lua("__AI_NPC_PUBLISH_TARGET__")
            logger.info(f"[V-hold-end] queued __AI_NPC_PUBLISH_TARGET__ as command_id={cmd_id}")
        except Exception:
            logger.exception("[V-hold-end] failed to queue __AI_NPC_PUBLISH_TARGET__")
        deadline = time.monotonic() + 1.20
        while time.monotonic() < deadline:
            time.sleep(0.025)
            npc = _ptt_npc_for_request()
            if npc:
                break
    if not npc:
        # No NPC targeted — drop the audio cleanly instead of submitting nowhere.
        try:
            stt_client.cancel()
        except Exception:
            pass
        logger.info("[V-hold-end] no active or aimed NPC at release — audio dropped")
        return
    _lock_ptt_npc(npc)
    asyncio.run_coroutine_threadsafe(_handle_ptt_stop(), _main_loop)


class PlayerActionEntry(BaseModel):
    """One entry from the Lua-side player_action_log (Player Event Dispatcher).
    Captured when the player pickpockets / stealth-kills / loots / etc. an NPC."""
    event: str = Field(description="Short event name, e.g. 'Pickpocketing', 'StealthKill', 'Loot'.")
    seconds_ago: int = Field(default=0, description="How many seconds ago the action happened.")
    npc_id: str | None = Field(default=None, description="ID of the affected NPC, if resolvable.")
    npc_name: str | None = Field(default=None, description="Name of the affected NPC, if known.")
    same_npc: bool = Field(default=False, description="True if this action targeted the NPC we're now talking to.")
    # Damage-delta fields populated for synthetic "Hit" events from the Lua health-snapshot tracker.
    hp_before: float | None = Field(default=None, description="NPC health before the hit (0..1).")
    hp_after: float | None = Field(default=None, description="NPC health after the hit (0..1).")
    hp_delta: float | None = Field(default=None, description="Health drop magnitude (positive number).")


class ChatRequest(BaseModel):
    npc_id: str = Field(description="Unique NPC entity ID from the game.")
    npc_name: str = Field(default="Villager", description="NPC display name.")
    npc_class: str = Field(default="", description="NPC class/occupation.")
    npc_location: str = Field(default="", description="Current location name.")
    player_message: str = Field(description="What the player said or typed.")
    extra_context: str = Field(default="", description="Additional context (time of day, weather, etc).")
    recent_player_actions: list[PlayerActionEntry] = Field(
        default_factory=list,
        description="Recent notable player actions (pickpocket/kill/loot/...) from Player Event Dispatcher.",
    )
    npc_gender: int | None = Field(default=None, description="NPC gender code: 0=male, 1/2=female.")
    request_id: int = Field(default=0, description="Client-side request counter for resp.lua polling.")


class ChatResponse(BaseModel):
    npc_name: str
    response: str
    request_id: int = 0
    audio_url: str | None = None


class EndConversationRequest(BaseModel):
    npc_id: str


class WebChatRequest(BaseModel):
    message: str


class LLMUpdateRequest(BaseModel):
    api_url: str | None = None
    api_key: str | None = None
    model: str | None = None
    max_tokens: int | None = None
    temperature: float | None = None


class TTSUpdateRequest(BaseModel):
    enabled: bool | None = None
    engine: str | None = None
    voice: str | None = None
    voice_female: str | None = None
    elevenlabs_voice: str | None = None
    elevenlabs_voice_female: str | None = None
    elevenlabs_api_key: str | None = None
    openai_voice: str | None = None
    openai_voice_female: str | None = None
    openai_api_key: str | None = None
    volume: float | None = None


class InputUpdateRequest(BaseModel):
    chat_key: str | None = None
    end_key: str | None = None
    overlay_enabled: bool | None = None
    overlay_style: str | None = None


class HUDUpdateRequest(BaseModel):
    show_left_top: bool | None = None
    show_right_top: bool | None = None
    show_center: bool | None = None


class STTUpdateRequest(BaseModel):
    enabled: bool | None = None
    provider: str | None = None
    model: str | None = None
    language: str | None = None
    api_url: str | None = None
    api_key: str | None = None
    device: str | None = None
    compute_type: str | None = None
    input_device: int | None = None
    min_duration_ms: int | None = None
    max_duration_sec: int | None = None
    hold_threshold_ms: int | None = None


class ConfigUpdateRequest(BaseModel):
    language: str | None = None
    llm: LLMUpdateRequest | None = None
    tts: TTSUpdateRequest | None = None
    stt: STTUpdateRequest | None = None
    input: InputUpdateRequest | None = None
    hud: HUDUpdateRequest | None = None
    prompt_template: str | None = None


# --- Endpoints ---

@app.get("/health")
async def health():
    return {"status": "ok", "version": "0.1.0", "model": config.llm.model}


@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    normalized_extra = normalize_game_extra_context(req.extra_context, npc_class=req.npc_class)
    if normalized_extra:
        logger.info(f"[{req.npc_name}] Context(normalized): {normalized_extra.replace(chr(10), ' | ')}")
    merged_extra = _merge_action_context(req)
    if req.recent_player_actions:
        logger.info(
            f"[{req.npc_name}] recent_player_actions ({len(req.recent_player_actions)}): "
            + ", ".join(f"{a.event}({a.seconds_ago}s)" for a in req.recent_player_actions[-5:])
        )
    system_prompt, resolved_name = build_system_prompt(
        npc_name=req.npc_name,
        npc_class=req.npc_class,
        npc_location=req.npc_location,
        language=config.language,
        extra_context=merged_extra,
    )
    if resolved_name != req.npc_name:
        logger.info(f"[name-resolve] '{req.npc_name}' -> '{resolved_name}' (canonical from localization)")

    conv = conversations.get_or_create(req.npc_id, resolved_name, system_prompt)
    conv.add_user_message(req.player_message)

    try:
        response_text = await llm_client.generate(
            system_prompt=conv.system_prompt,
            messages=conv.get_messages(),
        )
    except Exception as e:
        logger.error(f"LLM generate failed: {e}")
        raise HTTPException(status_code=502, detail=str(e))

    conv.add_assistant_message(response_text)
    conversations.save(req.npc_id)

    logger.info(f"[{resolved_name}] Player: {req.player_message}")
    logger.info(f"[{resolved_name}] NPC: {response_text}")

    if config.tts.enabled:
        asyncio.create_task(tts_client.speak(response_text, req.npc_gender))

    write_response_lua(resolved_name, response_text, req.request_id)

    return ChatResponse(
        npc_name=resolved_name,
        response=response_text,
        request_id=req.request_id,
        audio_url=None,
    )


@app.post("/end_conversation")
async def end_conversation(req: EndConversationRequest):
    conversations.end(req.npc_id)
    return {"status": "ok"}


@app.post("/overlay/send")
async def overlay_send(req: WebChatRequest):
    """Direct chat from in-game DLL overlay. Uses last known active NPC, returns response synchronously."""
    message = req.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="empty message")
    npc = active_npc or {}
    npc_id = npc.get("npc_id") or "overlay_anon"
    npc_name = npc.get("npc_name") or "Villager"
    npc_class = npc.get("npc_class") or ""
    npc_location = npc.get("npc_location") or ""
    extra_context = npc.get("extra_context") or ""
    if extra_context:
        logger.info(f"[overlay] extra_context: {extra_context.replace(chr(10), ' | ')}")
    system_prompt, resolved_name = build_system_prompt(
        npc_name=npc_name,
        npc_class=npc_class,
        npc_location=npc_location,
        language=config.language,
        extra_context=extra_context,
    )
    conv = conversations.get_or_create(npc_id, resolved_name, system_prompt)
    conv.add_user_message(message)
    try:
        response_text = await llm_client.generate(
            system_prompt=conv.system_prompt,
            messages=conv.get_messages(),
        )
    except Exception as e:
        logger.error(f"overlay_send LLM failed: {e}")
        raise HTTPException(status_code=502, detail=str(e))
    conv.add_assistant_message(response_text)
    conversations.save(npc_id)
    logger.info(f"[overlay {resolved_name}] Player: {message}")
    logger.info(f"[overlay {resolved_name}] NPC: {response_text}")
    return {"npc_name": resolved_name, "response": response_text}


@app.get("/game_chat/status")
async def game_chat_status():
    return {"active_npc": active_npc}


@app.post("/game_chat/send")
async def game_chat_send(req: WebChatRequest):
    message = req.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="Message is empty")
    command_id = write_command_lua(message)
    return {"status": "queued", "command_id": command_id, "active_npc": active_npc}


@app.post("/reload_characters")
async def reload_characters():
    db = reload_character_db()
    return {"status": "ok", "characters_loaded": len(db)}


@app.post("/clear_history")
async def clear_history():
    """Wipe all NPC conversation memory (in-RAM + on-disk JSON files)."""
    deleted = conversations.clear_all()
    logger.info(f"[clear_history] wiped {deleted} conversation files")
    return {"status": "ok", "deleted": deleted}


@app.post("/ptt/start")
async def ptt_start():
    """Begin recording from the configured input device.

    Same effect as Lua writing "[AI NPC] PTT_START" to kcd.log — provided for
    web-UI testing and headless integration.
    """
    try:
        stt_client.start()
        return {"status": "recording"}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/ptt/stop")
async def ptt_stop():
    """Stop recording, transcribe, and (if there is an active NPC) submit
    the result as a chat request. Returns the recognized text either way."""
    npc_for_prompt = ""
    if isinstance(active_npc, dict):
        npc_for_prompt = active_npc.get("npc_name_resolved") or active_npc.get("npc_name") or ""
    try:
        text = await asyncio.to_thread(stt_client.stop, prompt=npc_for_prompt)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    if text and active_npc:
        # Reuse the same plumbing as the log-IPC PTT path: build a synthetic
        # ChatRequest from the active NPC and let _process_chat_request do
        # the rest (LLM → TTS → resp.lua).
        global _ptt_request_counter
        _ptt_request_counter += 1
        raw_actions = active_npc.get("recent_player_actions") or []
        parsed_actions: list[PlayerActionEntry] = []
        for a in raw_actions:
            try:
                parsed_actions.append(PlayerActionEntry(**a))
            except Exception:
                pass
        req = ChatRequest(
            npc_id=active_npc.get("npc_id", ""),
            npc_name=active_npc.get("npc_name", "NPC"),
            npc_class=active_npc.get("npc_class", ""),
            npc_location="",
            player_message=text,
            extra_context=active_npc.get("extra_context", "") or "",
            recent_player_actions=parsed_actions,
            npc_gender=active_npc.get("gender"),
            request_id=10_000_000 + _ptt_request_counter,
        )
        asyncio.create_task(_process_chat_request(req, source="ptt-http"))
    return {"status": "ok", "text": text}


@app.post("/ptt/cancel")
async def ptt_cancel():
    try:
        stt_client.cancel()
    except Exception:
        pass
    return {"status": "ok"}


@app.get("/stt/devices")
async def stt_devices():
    """List input-capable audio devices on the host."""
    return {"devices": stt_client.list_devices()}


@app.post("/stt/test")
async def stt_test(req: STTUpdateRequest):
    """Record ~3 seconds from the mic with the *requested* (possibly
    unsaved) STT settings and return the transcript. Web UI helper.
    """
    test_cfg = STTConfig(
        enabled=True,
        provider=req.provider or config.stt.provider,
        model=req.model or config.stt.model,
        language=req.language or config.stt.language,
        api_url=req.api_url if req.api_url is not None else config.stt.api_url,
        api_key=req.api_key if req.api_key is not None else config.stt.api_key,
        device=req.device or config.stt.device,
        compute_type=req.compute_type or config.stt.compute_type,
        input_device=req.input_device if req.input_device is not None else config.stt.input_device,
        min_duration_ms=req.min_duration_ms or config.stt.min_duration_ms,
        max_duration_sec=req.max_duration_sec or config.stt.max_duration_sec,
        hold_threshold_ms=req.hold_threshold_ms or config.stt.hold_threshold_ms,
    )
    probe = STTClient(test_cfg)
    try:
        text = await probe.test(duration_sec=3.0)
        return {"status": "ok", "text": text}
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc))


@app.post("/tts/test")
async def test_tts():
    try:
        phrase = TTSClient._TEST_PHRASES.get(config.language, TTSClient._TEST_PHRASES["en"])
        result = await tts_client.test(text=phrase)
        return {"status": "ok", "result": result}
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))


@app.post("/shutdown")
async def shutdown_server():
    threading.Timer(0.5, lambda: os._exit(0)).start()
    return {"status": "shutting_down"}


@app.post("/llm/test")
async def test_llm(req: LLMUpdateRequest):
    test_cfg = LLMConfig(
        api_url=req.api_url or config.llm.api_url,
        api_key=req.api_key or config.llm.api_key,
        model=req.model or config.llm.model,
        max_tokens=min(req.max_tokens or 120, 120),
        temperature=req.temperature if req.temperature is not None else config.llm.temperature,
    )
    test_client = LLMClient(test_cfg)
    try:
        reply = await test_client.generate(
            system_prompt=(
                "You are a medieval villager from Bohemia, year 1403. "
                "Speak naturally in 1-2 sentences. Never reply with just one word or dots."
            ),
            messages=[{"role": "user", "content": "Good day! Who are you and what do you do here?"}],
        )
        return {"status": "ok", "response": reply.strip()}
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))


@app.get("/config")
async def get_config():
    return config.model_dump()


@app.post("/config/update")
async def update_config(req: ConfigUpdateRequest):
    global config, llm_client
    data: dict = {}
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH, "r", encoding="utf-8-sig") as f:
            data = json.load(f)

    if req.language is not None:
        data["language"] = req.language
        config.language = req.language

    if req.llm is not None:
        llm_patch = req.llm.model_dump(exclude_none=True)
        data.setdefault("llm", {})
        data["llm"].update(llm_patch)
        config.llm = LLMConfig(**data["llm"])
        llm_client = LLMClient(config.llm)
        logger.info(f"LLM reloaded: {config.llm.model} @ {config.llm.api_url}")

    if req.tts is not None:
        global tts_client
        tts_patch = req.tts.model_dump(exclude_none=True)
        data.setdefault("tts", {})
        data["tts"].update(tts_patch)
        config.tts = TTSConfig(**data["tts"])
        tts_client = TTSClient(config.tts)
        logger.info(f"TTS reloaded: {config.tts.engine} / {config.tts.voice}")

    if req.stt is not None:
        global stt_client
        stt_patch = req.stt.model_dump(exclude_none=True)
        data.setdefault("stt", {})
        data["stt"].update(stt_patch)
        config.stt = STTConfig(**data["stt"])
        # Drop the old client (and its cached faster-whisper model) so the
        # new provider/model settings take effect on the next PTT press.
        try:
            stt_client.cancel()
        except Exception:
            pass
        stt_client = STTClient(config.stt)
        logger.info(
            f"STT reloaded: provider={config.stt.provider} model={config.stt.model} "
            f"lang={config.stt.language} device={config.stt.device}"
        )
        # Sync KeyMonitor enabled-state and hold threshold with the new config.
        try:
            if config.stt.enabled:
                key_monitor.update_config(threshold_ms=int(config.stt.hold_threshold_ms))
                key_monitor.start()  # idempotent if already running
            else:
                key_monitor.stop()
        except Exception:
            logger.exception("KeyMonitor reconfig failed")

    if req.input is not None:
        input_patch = req.input.model_dump(exclude_none=True)
        data.setdefault("input", {})
        prev_style = (data["input"].get("overlay_style") or config.input.overlay_style or "kcd").lower()
        data["input"].update(input_patch)
        data["input"]["chat_key"] = normalize_key(data["input"].get("chat_key"), "v")
        data["input"]["end_key"] = normalize_key(data["input"].get("end_key"), "", allow_empty=True)
        new_style_raw = (data["input"].get("overlay_style") or "kcd").lower()
        if new_style_raw not in ("kcd", "plain"):
            new_style_raw = "kcd"
        data["input"]["overlay_style"] = new_style_raw
        config.input = InputConfig(**data["input"])
        write_action_map(config.input.chat_key, config.input.end_key)
        if new_style_raw != prev_style:
            try:
                input_overlay.set_style(new_style_raw)
                logger.info(f"Overlay style live-switched: {prev_style} -> {new_style_raw}")
            except Exception as e:
                logger.warning(f"Overlay live restyle failed: {e}")
        # If the chat key changed, retarget the KeyMonitor at the new VK.
        try:
            key_monitor.update_config(chat_key=config.input.chat_key)
        except Exception:
            logger.exception("KeyMonitor chat-key update failed")

    if req.hud is not None:
        hud_patch = req.hud.model_dump(exclude_none=True)
        data.setdefault("hud", {})
        data["hud"].update(hud_patch)
        config.hud = HUDConfig(**data["hud"])
        logger.info(
            f"HUD reloaded: left={config.hud.show_left_top} "
            f"right={config.hud.show_right_top} center={config.hud.show_center}"
        )

    if req.prompt_template is not None:
        data["prompt_template"] = req.prompt_template
        config.prompt_template = req.prompt_template
        set_prompt_template(req.prompt_template)

    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

    logger.info("Configuration updated via web UI")
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=config.host, port=config.port)

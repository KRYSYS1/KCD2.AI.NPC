# -*- coding: utf-8 -*-
"""NPC beckon initiative — сервер сам решает, когда знакомый NPC зовёт игрока.

Поток:
  Lua раз в ~25 c пишет в kcd.log строку  [AI NPC] NEARBY|{"p":[px,py,pz,fx,fy,fz],
  "n":[{"i":"userdata: ...","d":5.2,"x":..,"y":..,"z":..,"g":0}, ...]}
  → main.py (file_ipc_watcher) передаёт payload сюда → мы фильтруем ЗНАКОМЫХ
  (memory/npc_relationships.json: familiarity, fear, annoyance) → кулдауны →
  вероятность → генерим короткий оклик через LLM → озвучиваем TTS (спатиализовано)
  → шлём в Lua команду жеста __AI_NPC_BECKON__:<npc_id> (command.lua).

Форс-тест (обходит знакомство/кулдауны): консольная команда ai_npc_beckon_force
пишет [AI NPC] BECKON_FORCE|{...} с тем же форматом.

Настройки — константы ниже (v1; при желании вынесем в config.json).
"""
from __future__ import annotations

import json
import logging
import random
import time
from pathlib import Path

logger = logging.getLogger("ai_npc.initiative")

MEM_DIR = Path(__file__).parent.parent / "memory"
RELATIONSHIPS_PATH = MEM_DIR / "npc_relationships.json"
STATE_PATH = MEM_DIR / "initiative_state.json"

# ── Настройки ────────────────────────────────────────────────────────────────
ENABLED = True
GLOBAL_COOLDOWN_S = 10 * 60      # не чаще одного зова в 10 мин (все NPC)
NPC_COOLDOWN_S = 45 * 60         # конкретный NPC — не чаще раза в 45 мин
CHANCE = 0.35                    # вероятность зова на один подходящий скан
FAMILIARITY_MIN = 3              # «знакомый» = общались достаточно
FEAR_MAX = 5                     # напуганный не зовёт
ANNOYANCE_MAX = 5                # раздражённый не зовёт
RADIUS_M = 8.0                   # зовём только если игрок в этом радиусе
CALL_MAX_WORDS = 8

_last_error_ts = 0.0


def _sanitize_key(npc_id: str) -> str:
    """Тот же санитайзер, что _relationship_key в main.py."""
    raw = (npc_id or "unknown_npc").strip()
    return "".join(ch if ch.isalnum() or ch in ("-", "_") else "_" for ch in raw)[:120]


def _load_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def _save_json(path: Path, data) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    except Exception as exc:
        logger.warning(f"[initiative] state save failed: {exc}")


def _vec(seq, i):
    try:
        return float(seq[i])
    except Exception:
        return 0.0


async def _speak_call(ctx: dict, npc: dict, rel: dict, payload_p) -> None:
    """Сгенерировать короткий оклик через LLM и озвучить его (спатиализовано)."""
    llm = ctx["llm"]
    tts = ctx["tts"]
    language = ctx.get("language") or "en"
    name = rel.get("npc_name") or "villager"
    fam = int(rel.get("familiarity", 0))
    mood = rel.get("last_mood") or "neutral"

    system_prompt = (
        f"You are {name}, a commoner in medieval Bohemia, 1403 (Kingdom Come: Deliverance)."
        f" You notice a traveler you have already spoken with before (familiarity {fam}, mood {mood})."
        " ROLEPLAY CONTEXT (CRITICAL): stay fully in character, medieval speech, no modern words,"
        " no AI disclaimers, no narration, no quotes."
    )
    user_msg = (
        f"Call the traveler over to talk to you. Reply with ONE short spoken line only,"
        f" at most {CALL_MAX_WORDS} words, in language: {language}."
    )
    text = ""
    try:
        text = await llm.generate(system_prompt=system_prompt, messages=[{"role": "user", "content": user_msg}])
        text = (text or "").strip().strip('"').strip()
    except Exception as exc:
        logger.warning(f"[initiative] LLM call line failed: {exc}")
    if not text:
        text = "Эй, путник! Подойди-ка сюда!" if str(language).lower().startswith("ru") else "Hey, traveler! Come here!"

    npc_pos = {"x": npc.get("x"), "y": npc.get("y"), "z": npc.get("z")}
    player_pos = {"x": _vec(payload_p, 0), "y": _vec(payload_p, 1), "z": _vec(payload_p, 2)}
    player_fwd = {"x": _vec(payload_p, 3), "y": _vec(payload_p, 4), "z": _vec(payload_p, 5)}
    try:
        await tts.speak(
            text,
            gender=npc.get("g"),
            npc_id=npc.get("i"),
            npc_name=name,
            npc_name_resolved=name,
            npc_pos=npc_pos,
            player_pos=player_pos,
            player_fwd=player_fwd,
        )
    except Exception as exc:
        logger.warning(f"[initiative] TTS failed: {exc}")
    logger.info(f"[initiative] beckon: {name} ({npc.get('i')}) says: {text}")


async def _do_beckon(ctx: dict, npc: dict, rel: dict, payload_p) -> None:
    # Жест сразу (не ждём LLM), потом голос.
    try:
        ctx["write_command"]("__AI_NPC_BECKON__:" + str(npc.get("i")))
    except Exception as exc:
        logger.warning(f"[initiative] write_command failed: {exc}")
    await _speak_call(ctx, npc, rel, payload_p)


async def on_nearby(raw: str, ctx: dict) -> None:
    """Обработка NEARBY| строки. Все проверки «редкости» здесь."""
    global _last_error_ts
    if not ctx.get("enabled", ENABLED):
        return
    try:
        payload = json.loads(raw)
        now = time.time()
        state = _load_json(STATE_PATH, {})
        if now - float(state.get("last_global", 0)) < GLOBAL_COOLDOWN_S:
            return
        rels = _load_json(RELATIONSHIPS_PATH, {})
        npc_cd = state.get("npc", {})

        eligible: list[tuple[dict, dict]] = []
        for npc in payload.get("n", []):
            try:
                if float(npc.get("d", 999)) > RADIUS_M:
                    continue
                key = _sanitize_key(str(npc.get("i", "")))
                rel = rels.get(key)
                if not isinstance(rel, dict):
                    continue
                if int(rel.get("familiarity", 0)) < FAMILIARITY_MIN:
                    continue
                if int(rel.get("fear", 0)) >= FEAR_MAX or int(rel.get("annoyance", 0)) >= ANNOYANCE_MAX:
                    continue
                if now - float(npc_cd.get(key, 0)) < NPC_COOLDOWN_S:
                    continue
                eligible.append((npc, rel))
            except Exception:
                continue

        if not eligible:
            return
        if random.random() > CHANCE:
            return

        npc, rel = random.choice(eligible)
        key = _sanitize_key(str(npc.get("i", "")))
        state["last_global"] = now
        state.setdefault("npc", {})[key] = now
        _save_json(STATE_PATH, state)

        await _do_beckon(ctx, npc, rel, payload.get("p") or [])
    except Exception as exc:
        if time.time() - _last_error_ts > 60:
            _last_error_ts = time.time()
            logger.warning(f"[initiative] on_nearby failed: {exc}")


async def on_force(raw: str, ctx: dict) -> None:
    """BECKON_FORCE| — полный флоу БЕЗ знакомства и кулдаунов (тест)."""
    try:
        payload = json.loads(raw)
        npcs = payload.get("n", [])
        if not npcs:
            return
        npc = npcs[0]
        key = _sanitize_key(str(npc.get("i", "")))
        rels = _load_json(RELATIONSHIPS_PATH, {})
        rel = rels.get(key) if isinstance(rels.get(key), dict) else {"npc_name": "villager", "familiarity": 5, "last_mood": "neutral"}
        logger.info(f"[initiative] FORCE beckon for {npc.get('i')}")
        await _do_beckon(ctx, npc, rel, payload.get("p") or [])
    except Exception as exc:
        logger.warning(f"[initiative] on_force failed: {exc}")

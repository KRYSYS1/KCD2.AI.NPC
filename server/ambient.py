"""Фоновая жизнь NPC (без обращения игрока).

Две независимые фичи, обе — на данных NEARBY|-скана и вспомогательной LLM:

1. НЕЙРОБОЛТОВНЯ NPC↔NPC (interaction.enable_npc_chatter):
   два соседних NPC изредка перекидываются короткими репликами (2-4 строки),
   каждая звучит спатиализованно с позиции своего говорящего + липсинк.

2. СОЛО-ИНИЦИАТИВА (interaction.enable_npc_solo_initiative):
   одиночный NPC сам обращается к игроку (комментарий, оклик) или кричит
   что-то другому NPC. Отдельно от beckon-инициативы (жест «поди сюда»).

Вызывается из file_ipc_watcher на каждом NEARBY|-скане (idle-тик ~25 c).
Все вызовы LLM — через ctx["llm"] (вспомогательная модель, если включена).

Анти-«заезженная пластинка» (2026-07-24):
- знакомые NPC (memory/npc_relationships.json) говорят об игроке как о
  знакомом Генрихе (имя, отношение, свежие recent_thoughts), а не как об
  анонимном «подозрительном чужаке»;
- в 60% случаев путник вообще не упоминается — болтают о своём;
- последние 8 обменов держим в памяти и запрещаем LLM повторять их темы,
  плюс подсовываем случайную затравку темы.
"""

import asyncio
import json
import logging
import random
import time
from collections import deque
from pathlib import Path

logger = logging.getLogger(__name__)

MEM_DIR = Path(__file__).parent.parent / "memory"
RELATIONSHIPS_PATH = MEM_DIR / "npc_relationships.json"

# --- Кулдауны/шансы (состояние в памяти процесса) ---------------------------
CHATTER_CHANCE = 0.30
CHATTER_COOLDOWN = 300.0          # глобально между диалогами, сек
CHATTER_PAIR_MAX_DIST = 10.0      # макс. расстояние между собеседниками, м

SOLO_CHANCE = 0.30
SOLO_COOLDOWN = 180.0             # глобально, сек
SOLO_PER_NPC_COOLDOWN = 600.0     # на конкретного NPC, сек

# Как часто болтовня вообще касается путника (если никто его не знает).
TRAVELER_MENTION_CHANCE = 0.40

# Развитие темы: шанс продолжить прошлый обмен вместо новой темы и кап
# продолжений подряд (потом принудительно свежая тема).
CHATTER_CONTINUE_CHANCE = 0.50
CHATTER_CONTINUE_MAX = 2

# Ре-энгейдж: NPC из недавнего разговора сам окликает замолчавшего игрока.
REENGAGE_AFTER_S = 60.0      # тишина после последнего обмена, сек (1 мин)
REENGAGE_MAX_DIST = 12.0     # NPC должен быть в этом радиусе, м
# Если игрок молчит и после оклика — другой NPC «отвечает за него».
REENGAGE_ANSWER_AFTER_S = 30.0

# Случайные затравки тем — чтобы LLM не сползала в одну колею.
CHATTER_TOPICS = [
    "the harvest and the fields",
    "mud, rain and the roads",
    "the priest's last sermon",
    "prices at the market",
    "ale at the tavern",
    "a neighbour's quarrel",
    "aching backs and bad teeth",
    "wolves or foxes near the pens",
    "bandits on the roads",
    "the lord's men and taxes",
    "an upcoming wedding or feast",
    "children misbehaving",
    "a strange dream or omen",
    "repairs: fences, roofs, carts",
    "fishing or hunting luck",
]

_state = {
    "ambient_last": 0.0,
    "chatter_last": 0.0,
    "solo_last": 0.0,
    "solo_per_npc": {},
    "busy": False,
}

# Последние ambient-реплики — скармливаем LLM как «не повторяй это».
_recent_chatter = deque(maxlen=8)
_recent_solo = deque(maxlen=8)

# Нить болтовни: последний обмен и сколько раз подряд его развивали.
_chatter_thread = {"last": None, "count": 0}

# Ре-энгейдж: время последнего обмена с игроком, 5 последних собеседников
# (свежий первым), метка тишины с окликом (1 оклик на период молчания),
# данные оклика (кто/что сказал) и метка «за игрока уже ответили».
_reengage = {
    "last_chat_ts": 0.0, "recent": [], "fired_for_ts": 0.0,
    "fired_at": 0.0, "fired_npc": None, "fired_name": None, "fired_text": None,
    "answered_for_ts": 0.0,
}
REENGAGE_RECENT_MAX = 5


def note_conversation(npc_id) -> None:
    """Вызывается из main.py после каждого обмена репликами с NPC."""
    nid = str(npc_id or "").strip()
    if not nid:
        return
    _reengage["last_chat_ts"] = time.time()
    rec = _reengage["recent"]
    if nid in rec:
        rec.remove(nid)
    rec.insert(0, nid)
    del rec[REENGAGE_RECENT_MAX:]


def _dist(a, b) -> float:
    dx = float(a.get("x") or 0) - float(b.get("x") or 0)
    dy = float(a.get("y") or 0) - float(b.get("y") or 0)
    return (dx * dx + dy * dy) ** 0.5


def _estimate_ms(text: str) -> float:
    """Грубая длительность озвучки: ~13 симв/с + запас."""
    return max(1.8, len(text or "") / 13.0 + 1.2)


def _gender_word(g) -> str:
    return "a woman" if int(g or 0) == 2 else "a man"


def _sanitize_key(npc_id: str) -> str:
    """Тот же санитайзер, что _relationship_key в main.py / initiative.py."""
    raw = (npc_id or "unknown_npc").strip()
    return "".join(ch if ch.isalnum() or ch in ("-", "_") else "_" for ch in raw)[:120]


def _load_relationships() -> dict:
    try:
        data = json.loads(RELATIONSHIPS_PATH.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _rel_for(rels: dict, npc: dict):
    rel = rels.get(_sanitize_key(str(npc.get("i") or "")))
    return rel if isinstance(rel, dict) and int(rel.get("familiarity", 0)) >= 1 else None


def _traveler_block(rel_a, rel_b, pname="Henry") -> str:
    """Строки про путника для промпта болтовни, с учётом знакомства."""
    known = [(1, rel_a), (2, rel_b)]
    known = [(i, r) for i, r in known if r]
    if not known:
        # Никто игрока не знает — упоминаем чужака лишь изредка.
        if random.random() < TRAVELER_MENTION_CHANCE:
            return ("- A stranger (an armed traveler) is loitering nearby; "
                    "they MAY mention him warily, or ignore him.")
        return ("- Do NOT mention the armed traveler standing nearby this time; "
                "they have already gossiped about him enough. Talk about their own matters.")
    parts = []
    thoughts = []
    for idx, rel in known:
        mood = rel.get("last_mood") or "neutral"
        parts.append(
            f"Speaker {idx} has personally spoken with him before "
            f"(familiarity {int(rel.get('familiarity', 0))}, attitude: {mood}, "
            f"trust {int(rel.get('trust', 0))}, fear {int(rel.get('fear', 0))}, "
            f"annoyance {int(rel.get('annoyance', 0))})"
        )
        rt = rel.get("recent_thoughts")
        if isinstance(rt, list):
            for t in rt[-2:]:
                thoughts.append(f"Speaker {idx} privately thinks: {t}")
    block = (
        f"- The traveler nearby is {pname} — NOT a nameless stranger to them: "
        + "; ".join(parts) + ".\n"
        "- If they mention him, they speak of him as someone they know (by name), reflecting their "
        "actual attitude and anything new they learned about him — never re-tread the old "
        "'suspicious stranger loitering' line.\n"
    )
    if thoughts:
        block += ("- Private impressions (color their words, do not quote verbatim):\n"
                  + "\n".join(f"  - {t}" for t in thoughts) + "\n")
    if random.random() >= TRAVELER_MENTION_CHANCE:
        block += f"- This time, though, they should rather talk about their own matters, not about {pname}.\n"
    return block.rstrip()


async def on_scan(nearby: dict, ctx: dict) -> None:
    """Idle-тик: решить, случится ли болтовня или соло-инициатива."""
    if _state["busy"]:
        return
    if ctx.get("chat_active"):
        return
    neighbors = nearby.get("n") or []
    p = nearby.get("p") or []
    if len(p) < 6 or not neighbors:
        return
    now = time.time()
    # Ре-энгейдж: игрок замолчал после разговора (3 мин), а недавний собеседник
    # всё ещё рядом — тот сам обращается к игроку. Один оклик на период молчания
    # (до следующего обмена репликами). Приоритетнее болтовни/соло.
    if (ctx.get("reengage_enabled", True) and _reengage["last_chat_ts"] > 0
            and now - _reengage["last_chat_ts"] >= REENGAGE_AFTER_S
            and _reengage["fired_for_ts"] != _reengage["last_chat_ts"]):
        cand = None
        for nid in _reengage["recent"]:
            for nb in neighbors:
                if str(nb.get("i") or "") == nid and float(nb.get("d") or 999) <= REENGAGE_MAX_DIST:
                    cand = nb
                    break
            if cand:
                break
        if cand:
            _reengage["fired_for_ts"] = _reengage["last_chat_ts"]
            _state["busy"] = True
            try:
                if await _do_reengage(cand, p, ctx):
                    _state["ambient_last"] = time.time()
            except Exception as exc:
                logger.warning(f"[ambient] reengage failed: {exc}")
            finally:
                _state["busy"] = False
            return
    # Акт второй: оклик был, игрок всё молчит — другой NPC «отвечает за него»
    # (один раз на период молчания).
    if (ctx.get("reengage_enabled", True)
            and _reengage["fired_for_ts"] == _reengage["last_chat_ts"]
            and _reengage["last_chat_ts"] > 0 and _reengage["fired_npc"]
            and _reengage["answered_for_ts"] != _reengage["last_chat_ts"]
            and now - float(_reengage["fired_at"] or 0.0) >= REENGAGE_ANSWER_AFTER_S):
        other = None
        for nb in neighbors:  # отсортированы по дистанции до игрока
            if str(nb.get("i") or "") != _reengage["fired_npc"] and float(nb.get("d") or 999) <= REENGAGE_MAX_DIST:
                other = nb
                break
        if other:
            _reengage["answered_for_ts"] = _reengage["last_chat_ts"]
            _state["busy"] = True
            try:
                if await _do_answer_for_player(other, p, ctx):
                    _state["ambient_last"] = time.time()
            except Exception as exc:
                logger.warning(f"[ambient] answer-for-player failed: {exc}")
            finally:
                _state["busy"] = False
            return
    # Слайдер «интенсивность фоновой жизни» (0-100, дефолт 50) — масштабирует
    # шансы и кулдауны обеих фич разом.
    v = max(0, min(100, int(ctx.get("intensity") or 50)))
    chatter_chance = 0.02 + 0.0088 * v         # 0 -> 0.02, 50 -> 0.46, 100 -> 0.90
    chatter_cd = max(30.0, 480.0 - 4.5 * v)    # 50 -> 255 c, 100 -> 30 c
    solo_chance = 0.02 + 0.0088 * v
    solo_cd = max(20.0, 300.0 - 2.8 * v)       # 50 -> 160 c, 100 -> 20 c
    # Общее затишье между ЛЮБЫМИ ambient-событиями (диалог ИЛИ оклик):
    # 0 -> 10 мин, 50 -> ~5 мин, 100 -> 30 c.
    ambient_gap = max(30.0, 600.0 - 5.7 * v)
    if now - float(_state.get("ambient_last") or 0.0) < ambient_gap:
        return
    _state["busy"] = True
    try:
        # Порядок: сначала пробуем диалог (ярче), потом соло.
        if ctx.get("chatter_enabled") and len(neighbors) >= 2:
            if now - _state["chatter_last"] >= chatter_cd and random.random() < chatter_chance:
                if await _do_chatter(neighbors, p, ctx):
                    _state["chatter_last"] = time.time()
                    _state["ambient_last"] = time.time()
                    return
        if ctx.get("solo_enabled"):
            if now - _state["solo_last"] >= solo_cd and random.random() < solo_chance:
                if await _do_solo(neighbors, p, ctx):
                    _state["solo_last"] = time.time()
                    _state["ambient_last"] = time.time()
    except Exception as exc:
        logger.warning(f"[ambient] tick failed: {exc}")
    finally:
        _state["busy"] = False


async def _do_chatter(neighbors: list, p: list, ctx: dict) -> bool:
    # Пара: ближайшие друг к другу NPC (не дальше CHATTER_PAIR_MAX_DIST).
    best = None
    for i in range(len(neighbors)):
        for j in range(i + 1, len(neighbors)):
            d = _dist(neighbors[i], neighbors[j])
            if d <= CHATTER_PAIR_MAX_DIST and (best is None or d < best[0]):
                best = (d, neighbors[i], neighbors[j])
    if not best:
        return False
    _, a, b = best
    rels = _load_relationships()
    # Режим обмена: развить прошлую нить (continue) или начать новую тему (fresh).
    cont = None
    if (_chatter_thread["last"] and _chatter_thread["count"] < CHATTER_CONTINUE_MAX
            and random.random() < CHATTER_CONTINUE_CHANCE):
        cont = _chatter_thread["last"]
    if cont:
        topic_part = (
            "Villagers around here were just discussing this:\n"
            f"  {cont}\n"
            "Write the NEXT beat of that same conversation: develop the subject further — a new detail, "
            "an opinion, a disagreement, a joke or a conclusion. Do not restart it from scratch.\n"
        )
    else:
        topic_seed = ", ".join(random.sample(CHATTER_TOPICS, 2))
        topic_part = (
            "Write a brief mundane exchange they might have: work, weather, gossip, aches, prices, church, ale, neighbours.\n"
            f"- Fresh topic suggestion for this exchange: {topic_seed} (or anything else mundane).\n"
        )
    sys_prompt = (
        "Two commoners in a village in the Kingdom of Bohemia, 1403, are chatting a few steps apart:\n"
        f"- Speaker 1: {_gender_word(a.get('g'))}\n"
        f"- Speaker 2: {_gender_word(b.get('g'))}\n"
        + topic_part +
        "- 2 to 4 lines total, each line max 14 words. Plain medieval register, no modern words, no narrator, no asterisks.\n"
        f"{_traveler_block(_rel_for(rels, a), _rel_for(rels, b), ctx.get('player_name') or 'Henry')}\n"
        f"- Language: {ctx.get('language') or 'ru'}.\n"
        'Respond ONLY with JSON: {"lines":[{"s":1,"t":"..."},{"s":2,"t":"..."}]} where s is the speaker number.'
    )
    pdesc = str(ctx.get("player_desc") or "").strip()
    if pdesc:
        sys_prompt += f"\nHow locals see the traveler: {pdesc}."
    if _recent_chatter:
        if cont:
            sys_prompt += (
                "\nLines already spoken in this area — do NOT repeat their wording, move the talk forward:\n"
                + "\n".join(f"- {t}" for t in _recent_chatter)
            )
        else:
            sys_prompt += (
                "\nRecently overheard exchanges in this area — do NOT repeat their topics or phrasing, pick something different:\n"
                + "\n".join(f"- {t}" for t in _recent_chatter)
            )
    if ctx.get("world"):
        sys_prompt += "\n" + str(ctx.get("world"))
    if ctx.get("style"):
        sys_prompt += "\nSpeech style of locals in this world (match it):\n" + str(ctx.get("style"))
    llm = ctx["llm"]
    raw = await llm.generate(system_prompt=sys_prompt, messages=[{"role": "user", "content": "Begin."}])
    try:
        start = raw.index("{")
        end = raw.rindex("}") + 1
        lines = json.loads(raw[start:end]).get("lines") or []
    except Exception:
        logger.info(f"[ambient] chatter: unparseable LLM output, skip: {raw[:120]!r}")
        return False
    lines = [l for l in lines if isinstance(l, dict) and str(l.get("t") or "").strip()][:4]
    if len(lines) < 2:
        return False
    joined = " / ".join(str(l.get("t")).strip() for l in lines)[:200]
    _recent_chatter.append(joined)
    # Обновляем нить: продолжение наращивает счётчик, новая тема сбрасывает.
    _chatter_thread["count"] = (_chatter_thread["count"] + 1) if cont else 0
    _chatter_thread["last"] = joined
    player_pos = {"x": p[0], "y": p[1], "z": p[2]}
    player_fwd = {"x": p[3], "y": p[4], "z": p[5]}
    speakers = {1: a, 2: b}
    logger.info(f"[ambient] chatter {a.get('i')} <-> {b.get('i')}: {len(lines)} lines ({'continue' if cont else 'fresh'})")
    tts = ctx["tts"]
    for line in lines:
        npc = speakers.get(int(line.get("s") or 1)) or a
        text = str(line.get("t")).strip()
        npc_pos = {"x": npc.get("x") or 0, "y": npc.get("y") or 0, "z": npc.get("z") or 0}
        try:
            await tts.speak(text, int(npc.get("g") or 0), str(npc.get("i")), "chatter", "chatter",
                            npc_pos, player_pos, player_fwd)
        except Exception as exc:
            logger.warning(f"[ambient] chatter line failed: {exc}")
            return True
        await asyncio.sleep(_estimate_ms(text))
        if ctx.get("chat_active_fn") and ctx["chat_active_fn"]():
            return True  # игрок начал разговор — замолкаем
    return True


async def _do_reengage(npc: dict, p: list, ctx: dict) -> bool:
    """NPC из недавнего разговора окликает замолчавшего игрока (1 короткая реплика)."""
    rels = _load_relationships()
    rel = rels.get(_sanitize_key(str(npc.get("i") or "")))
    rel = rel if isinstance(rel, dict) else {}
    name = rel.get("npc_name") or "villager"
    mood = rel.get("last_mood") or "neutral"
    fam = int(rel.get("familiarity", 0))
    sys_prompt = (
        f"You are {name}, {_gender_word(npc.get('g'))}, a commoner in the Kingdom of Bohemia, 1403.\n"
        f"You spoke with the traveler {ctx.get('player_name') or 'Henry'} only minutes ago (familiarity {fam}, your attitude: {mood}), "
        "but he has fallen silent and still lingers nearby, saying nothing.\n"
        "Address him again yourself: ONE short spoken line — nudge him, ask what he broods about, "
        "pick the talk back up, or tease him for standing there mute. Max 14 words. "
        "Plain medieval register, no modern words, no narrator, no asterisks, no quotes.\n"
        f"Language: {ctx.get('language') or 'ru'}.\n"
    )
    pdesc = str(ctx.get("player_desc") or "").strip()
    if pdesc:
        sys_prompt += f"How you and the locals see him: {pdesc}.\n"
    rt = rel.get("recent_thoughts")
    if isinstance(rt, list) and rt:
        sys_prompt += ("Your recent private thoughts about him (color your words, do not quote them): "
                       + "; ".join(str(t) for t in rt[-2:]) + "\n")
    if ctx.get("world"):
        sys_prompt += str(ctx.get("world")) + "\n"
    if ctx.get("style"):
        sys_prompt += "Speech style of locals in this world (match it):\n" + str(ctx.get("style")) + "\n"
    llm = ctx["llm"]
    text = ""
    try:
        text = await llm.generate(system_prompt=sys_prompt, messages=[{"role": "user", "content": "Now."}])
        text = (text or "").strip().strip('"').strip()
    except Exception as exc:
        logger.warning(f"[ambient] reengage LLM failed: {exc}")
        return False
    if not text or len(text) > 200:
        return False
    npc_pos = {"x": npc.get("x") or 0, "y": npc.get("y") or 0, "z": npc.get("z") or 0}
    player_pos = {"x": p[0], "y": p[1], "z": p[2]}
    player_fwd = {"x": p[3], "y": p[4], "z": p[5]}
    logger.info(f"[ambient] reengage {name} ({npc.get('i')}): {text}")
    # Запоминаем оклик — если игрок продолжит молчать, другой NPC «ответит за него».
    _reengage["fired_at"] = time.time()
    _reengage["fired_npc"] = str(npc.get("i") or "")
    _reengage["fired_name"] = name
    _reengage["fired_text"] = text
    try:
        await ctx["tts"].speak(text, int(npc.get("g") or 0), str(npc.get("i")),
                               name, name, npc_pos, player_pos, player_fwd)
    except Exception as exc:
        logger.warning(f"[ambient] reengage TTS failed: {exc}")
    return True


async def _do_answer_for_player(npc: dict, p: list, ctx: dict) -> bool:
    """Игрок промолчал и оклик — другой NPC отвечает за него (шутка/заступничество)."""
    rels = _load_relationships()
    rel = rels.get(_sanitize_key(str(npc.get("i") or "")))
    rel = rel if isinstance(rel, dict) else {}
    caller = _reengage.get("fired_name") or "a villager"
    called = _reengage.get("fired_text") or ""
    sys_prompt = (
        f"You are {_gender_word(npc.get('g'))}, a commoner in the Kingdom of Bohemia, 1403.\n"
        f"A minute ago {caller} called out to the traveler standing nearby: \"{called}\"\n"
        "The traveler just keeps standing there, silent as a stone, answering nothing.\n"
        f"Speak ONE short line about it — answer {caller} in the traveler's stead: tell them to leave "
        "him be, joke that he is mute or moonstruck, or guess aloud what occupies him. Max 14 words. "
        "Plain medieval register, no modern words, no narrator, no asterisks, no quotes.\n"
        f"Language: {ctx.get('language') or 'ru'}.\n"
    )
    pdesc = str(ctx.get("player_desc") or "").strip()
    if pdesc:
        sys_prompt += f"How locals see this traveler: {pdesc}.\n"
    if int(rel.get("familiarity", 0)) >= 1:
        mood = rel.get("last_mood") or "neutral"
        sys_prompt += (
            f"You yourself have spoken with this traveler before (familiarity "
            f"{int(rel.get('familiarity', 0))}, your attitude: {mood}) — let it color your line.\n"
        )
    if ctx.get("world"):
        sys_prompt += str(ctx.get("world")) + "\n"
    if ctx.get("style"):
        sys_prompt += "Speech style of locals in this world (match it):\n" + str(ctx.get("style")) + "\n"
    llm = ctx["llm"]
    text = ""
    try:
        text = await llm.generate(system_prompt=sys_prompt, messages=[{"role": "user", "content": "Now."}])
        text = (text or "").strip().strip('"').strip()
    except Exception as exc:
        logger.warning(f"[ambient] answer-for-player LLM failed: {exc}")
        return False
    if not text or len(text) > 200:
        return False
    npc_pos = {"x": npc.get("x") or 0, "y": npc.get("y") or 0, "z": npc.get("z") or 0}
    player_pos = {"x": p[0], "y": p[1], "z": p[2]}
    player_fwd = {"x": p[3], "y": p[4], "z": p[5]}
    logger.info(f"[ambient] answer-for-player {npc.get('i')} (re: {caller}): {text}")
    try:
        await ctx["tts"].speak(text, int(npc.get("g") or 0), str(npc.get("i")),
                               "ambient", "ambient", npc_pos, player_pos, player_fwd)
    except Exception as exc:
        logger.warning(f"[ambient] answer-for-player TTS failed: {exc}")
    return True


async def _do_solo(neighbors: list, p: list, ctx: dict) -> bool:
    now = time.time()
    candidate = None
    for nb in neighbors:  # отсортированы по дистанции до игрока
        nb_id = str(nb.get("i") or "")
        if not nb_id:
            continue
        if now - float(_state["solo_per_npc"].get(nb_id) or 0.0) < SOLO_PER_NPC_COOLDOWN:
            continue
        candidate = nb
        break
    if not candidate:
        return False
    other = next((nb for nb in neighbors if nb is not candidate), None)
    other_txt = (
        f"There is also another local ({_gender_word(other.get('g'))}) nearby they could shout to."
        if other else "No other locals are within earshot."
    )
    rel = _rel_for(_load_relationships(), candidate)
    if rel:
        mood = rel.get("last_mood") or "neutral"
        traveler_txt = (
            f"A traveler you KNOW — {ctx.get('player_name') or 'Henry'} — is standing about {float(candidate.get('d') or 3):.0f} meters away, "
            f"not talking to anyone. You have spoken with him before (familiarity "
            f"{int(rel.get('familiarity', 0))}, your attitude: {mood}). If you address him, address him "
            "as someone you know — by name, with your actual attitude — not as a suspicious stranger."
        )
        rt = rel.get("recent_thoughts")
        if isinstance(rt, list) and rt:
            traveler_txt += " Your recent private thoughts about him (do not quote verbatim): " + "; ".join(
                str(t) for t in rt[-2:]
            )
    else:
        traveler_txt = (
            f"An armed traveler is standing about {float(candidate.get('d') or 3):.0f} meters away, "
            "not talking to anyone."
        )
    sys_prompt = (
        f"You are {_gender_word(candidate.get('g'))}, a commoner in the Kingdom of Bohemia, 1403, going about your business.\n"
        f"{traveler_txt}\n"
        f"{other_txt}\n"
        "If (and only if) it feels natural, say ONE unprompted line: address the traveler (greeting, remark, warning, plea) "
        "OR shout something to the other local. Max 14 words. Plain medieval register, no narrator, no asterisks.\n"
        f"Language: {ctx.get('language') or 'ru'}.\n"
        'Respond ONLY with JSON: {"target":"player"|"npc","t":"..."} or exactly SILENCE.'
    )
    pdesc = str(ctx.get("player_desc") or "").strip()
    if pdesc:
        sys_prompt += f"\nHow locals see this traveler: {pdesc}.\n"
    if _recent_solo:
        sys_prompt += (
            "\nLines already shouted around here recently — do NOT repeat them or their topic:\n"
            + "\n".join(f"- {t}" for t in _recent_solo)
        )
    if ctx.get("world"):
        sys_prompt += "\n" + str(ctx.get("world"))
    if ctx.get("style"):
        sys_prompt += "\nSpeech style of locals in this world (match it):\n" + str(ctx.get("style"))
    llm = ctx["llm"]
    raw = await llm.generate(system_prompt=sys_prompt, messages=[{"role": "user", "content": "Now."}])
    if not raw or "SILENCE" in raw.upper():
        return False
    try:
        start = raw.index("{")
        end = raw.rindex("}") + 1
        obj = json.loads(raw[start:end])
        text = str(obj.get("t") or "").strip()
    except Exception:
        return False
    if not text or len(text) > 200:
        return False
    _state["solo_per_npc"][str(candidate.get("i"))] = time.time()
    _recent_solo.append(text[:200])
    npc_pos = {"x": candidate.get("x") or 0, "y": candidate.get("y") or 0, "z": candidate.get("z") or 0}
    player_pos = {"x": p[0], "y": p[1], "z": p[2]}
    player_fwd = {"x": p[3], "y": p[4], "z": p[5]}
    logger.info(f"[ambient] solo {candidate.get('i')} -> {obj.get('target')}: {text}")
    try:
        await ctx["tts"].speak(text, int(candidate.get("g") or 0), str(candidate.get("i")),
                               "ambient", "ambient", npc_pos, player_pos, player_fwd)
    except Exception as exc:
        logger.warning(f"[ambient] solo failed: {exc}")
    return True

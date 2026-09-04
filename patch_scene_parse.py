#!/usr/bin/env python3
"""Fix NPC speech leaking raw JSON ('system words' at start/end of replies).

Root cause: the chat model started returning JSON with real line breaks inside
string values (and/or stray unescaped quotes). Strict json.loads fails on that,
and the whole raw JSON blob became the NPC's speech (subtitles + TTS).
The patch makes _parse_scene_response tolerant:
  1) json.loads strict -> json.loads strict=False (allows newlines in strings);
  2) regex salvage of keys (tolerates even unescaped quotes in speech);
  3) last resort: strip the {"speech":"..."} wrapper by hand.
Well-formed JSON behaves EXACTLY as before.

Usage:
  cd C:/Users/kolan/Desktop/projects/github/kcd2-ai-npc
  python patch_scene_parse.py
(or: python patch_scene_parse.py <path to server/main.py>)

The script backs up server/main.py.bak_parsefix and syntax-checks the result.
Afterwards: restart the server and delete server/memory/conversations/*.json
(they contain replies polluted with JSON, otherwise the model keeps imitating).
"""
import re
import shutil
import sys
import py_compile
from pathlib import Path

NEW_BLOCK = r'''
_SCENE_KEY_AFTER_RE = re.compile(
    r'(?<!\\)"\s*,\s*"(mood|intent|suggested_action|item_name|item_count|trade_price|speech|say|response)"\s*:'
)


def _salvage_json_string_value(candidate: str, key: str) -> str:
    """Вытянуть значение строкового ключа, когда json.loads не справился.

    Терпит реальные переносы строк внутри значения и шальные неэкранированные
    кавычки в речи (некоторые модели печатают JSON именно так).
    """
    m = re.search(r'"' + re.escape(key) + r'"\s*:\s*"', candidate)
    if not m:
        return ""
    rest = candidate[m.end():]
    end = _SCENE_KEY_AFTER_RE.search(rest)
    if end is not None:
        raw = rest[:end.start()]
    else:
        m2 = re.match(r"((?:[^\"\\]|\\.)*)\"", rest)
        raw = m2.group(1) if m2 else ""
    try:
        return str(json.loads('"' + raw + '"', strict=False))
    except Exception:
        return (
            raw.replace("\\\\", "\\")
            .replace('\\"', '"')
            .replace("\\n", "\n")
            .replace("\\t", "\t")
            .replace("\\r", "\r")
        )


def _salvage_json_number_value(candidate: str, key: str) -> int | None:
    """Вытянуть числовой ключ (trade_price / item_count) без json.loads."""
    m = re.search(r'"' + re.escape(key) + r'"\s*:\s*"?(-?\d+(?:\.\d+)?)"?', candidate)
    if not m:
        return None
    try:
        return int(float(m.group(1)))
    except Exception:
        return None


def _salvage_scene_object(candidate: str) -> dict:
    """Собрать scene-словарь регулярками, когда JSON не парсится вообще."""
    out: dict = {}
    speech = (
        _salvage_json_string_value(candidate, "speech")
        or _salvage_json_string_value(candidate, "say")
        or _salvage_json_string_value(candidate, "response")
    )
    if speech:
        out["speech"] = speech
    for key in ("mood", "intent", "suggested_action", "item_name"):
        value = _salvage_json_string_value(candidate, key)
        if value:
            out[key] = value
    for key in ("trade_price", "item_count"):
        value = _salvage_json_number_value(candidate, key)
        if value is not None:
            out[key] = str(value)
    return out


def _looks_like_json_blob(speech: str) -> bool:
    """True, если в речь утёк сырой JSON (системные слова в начале/конце)."""
    t = (speech or "").lstrip()
    return t.startswith("{") and ('"speech"' in t[:200] or '"mood"' in t[:600])


def _strip_json_wrapper(speech: str) -> str:
    """Последний рубеж: срезать обёртку {"speech":" ... "} вручную."""
    t = (speech or "").strip()
    t = re.sub(r'^\{\s*"(?:speech|say|response)"\s*:\s*"', "", t, count=1)
    t = re.sub(
        r'",\s*"(?:mood|intent|suggested_action|item_name|item_count|trade_price)"\s*:.*?\}\s*$',
        "",
        t,
        count=1,
        flags=re.DOTALL,
    )
    t = re.sub(r'"\s*\}\s*$', "", t, count=1)
    try:
        return str(json.loads('"' + t + '"', strict=False))
    except Exception:
        return t.replace('\\"', '"').replace("\\n", "\n")


def _parse_scene_response(raw_text: str) -> dict[str, str]:
    # 2026-09-04: hardened — модели вроде Mistral печатают JSON с реальными
    # переносами строк внутри значений и шальными кавычками; строгий
    # json.loads на таком падает и сырой JSON утекал в речь/субтитры/TTS.
    # Теперь: strict -> non-strict -> regex-salvage -> strip wrapper.
    text = (raw_text or "").strip()
    scene = {
        "speech": text,
        "mood": "neutral",
        "intent": "continue",
        "suggested_action": "none",
    }
    if not text:
        return scene
    candidate = text
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, flags=re.IGNORECASE | re.DOTALL)
    if fenced:
        candidate = fenced.group(1).strip()
    elif "{" in text and "}" in text:
        candidate = text[text.find("{"): text.rfind("}") + 1].strip()
    if not candidate.startswith("{"):
        return scene
    data = None
    try:
        data = json.loads(candidate)
    except Exception:
        data = None
    if not isinstance(data, dict):
        try:
            data = json.loads(candidate, strict=False)
        except Exception:
            data = None
    if not isinstance(data, dict):
        data = _salvage_scene_object(candidate)
        if data:
            logger.info(f"[scene_parse] salvaged keys via regex: {sorted(data.keys())}")
    if not isinstance(data, dict):
        return scene
    speech = str(data.get("speech") or data.get("say") or data.get("response") or "").strip()
    if speech:
        scene["speech"] = speech
    for key in ("mood", "intent", "suggested_action"):
        value = str(data.get(key) or "").strip().lower()
        if value:
            scene[key] = value[:80]
    item_name = str(data.get("item_name") or "").strip()
    if item_name:
        scene["item_name"] = item_name[:200]
    try:
        item_count = int(float(str(data.get("item_count") or 1)))
    except Exception:
        item_count = 1
    scene["item_count"] = str(max(1, min(20, item_count)))
    try:
        trade_price = int(float(str(data.get("trade_price") or 0)))
    except Exception:
        trade_price = 0
    scene["trade_price"] = str(max(0, min(1000000, trade_price)))
    if _looks_like_json_blob(scene["speech"]):
        fixed = _salvage_json_string_value(candidate, "speech") or _strip_json_wrapper(scene["speech"])
        if not fixed or _looks_like_json_blob(fixed):
            fixed = _strip_json_wrapper(scene["speech"])
        if fixed:
            logger.info("[scene_parse] stripped leaked JSON wrapper from speech")
            scene["speech"] = fixed
    return scene
'''


def find_target(explicit=None):
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else None
    here = Path(__file__).resolve().parent
    for cand in (Path.cwd() / "server" / "main.py",
                 here / "server" / "main.py",
                 here / "main.py"):
        if cand.is_file():
            return cand
    return None


def main():
    explicit = sys.argv[1] if len(sys.argv) > 1 else None
    target = find_target(explicit)
    if target is None:
        print("server/main.py NOT FOUND. Run from the repo root")
        print("(C:/Users/kolan/Desktop/projects/github/kcd2-ai-npc)")
        print("or pass the path: python patch_scene_parse.py <path>")
        sys.exit(1)
    print("Target:", target)
    raw = target.read_bytes()
    nl = "\r\n" if b"\r\n" in raw[:8000] else "\n"
    text = raw.decode("utf-8-sig")
    if "_salvage_scene_object" in text:
        print("Already patched (_salvage_scene_object present). Nothing to do.")
        sys.exit(0)
    pat = re.compile(r"^def _parse_scene_response\(.*?\n(?=^def |\Z)",
                     re.MULTILINE | re.DOTALL)
    found = pat.findall(text)
    if len(found) != 1:
        print("REFUSED: found %d occurrences of def _parse_scene_response (need 1)." % len(found))
        print("File untouched. Show this message to the mod developer.")
        sys.exit(2)
    block = NEW_BLOCK.replace("\n", nl)
    if "__NEW" + "_BLOCK__" in block:
        print("REFUSED: patch block was not injected (placeholder left).")
        sys.exit(3)
    block = block.strip("\r\n") + nl * 2
    new_text = pat.sub(lambda _: block, text, count=1)
    backup = target.with_name("main.py.bak_parsefix")
    shutil.copyfile(target, backup)
    print("Backup:", backup)
    target.write_bytes(new_text.encode("utf-8"))
    py_compile.compile(str(target), doraise=True)
    print("OK: function replaced, syntax verified (py_compile).")
    print("Next: restart the server, delete server/memory/conversations/*.json")


if __name__ == "__main__":
    main()

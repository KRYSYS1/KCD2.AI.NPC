"""Loads NPC display names from KCD2's text_ui_soul.xml localization tables.

The game stores rows like:
    <Row><Cell>char_667_uiName</Cell><Cell>Mutt</Cell><Cell>Барбос</Cell></Row>

We expose two lookup dicts (ru/en) keyed by the soul name id (column 1).
"""

from __future__ import annotations

import re
from pathlib import Path

DATA_DIR = Path(__file__).parent / "data"
RU_FILE = DATA_DIR / "text_ui_soul_ru.xml"
EN_FILE = DATA_DIR / "text_ui_soul_en.xml"

_ROW_RE = re.compile(
    r"<Row>\s*<Cell>([^<]*)</Cell>\s*<Cell>([^<]*)</Cell>\s*<Cell>([^<]*)</Cell>",
    re.DOTALL,
)


def _load_table(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8", errors="replace")
    out: dict[str, str] = {}
    for m in _ROW_RE.finditer(text):
        key, en, ru = m.group(1).strip(), m.group(2).strip(), m.group(3).strip()
        if not key:
            continue
        # The third column is the localized text (russian here). Some rows have
        # only EN content; in that case fall back to EN. This file already comes
        # from the russian pak, so col 3 is russian.
        chosen = ru if ru else en
        if chosen:
            out[key] = chosen
    return out


_ru: dict[str, str] | None = None
_en: dict[str, str] | None = None


def get_ru() -> dict[str, str]:
    global _ru
    if _ru is None:
        _ru = _load_table(RU_FILE)
    return _ru


def get_en() -> dict[str, str]:
    global _en
    if _en is None:
        # text_ui_soul_en.xml may have only two columns (EN). Reuse the same
        # parser; if the second cell holds the english text and third is empty,
        # _load_table will pick it. For the english pak the third column likely
        # equals the english text anyway.
        _en = _load_table(EN_FILE)
    return _en


def lookup(soul_key: str, language: str = "ru") -> str | None:
    """Resolve a soul/UI name key to its localized display name."""
    if not soul_key:
        return None
    soul_key = soul_key.strip().lstrip("@")
    if not soul_key:
        return None
    table = get_ru() if language.lower().startswith("ru") else get_en()
    return table.get(soul_key)


if __name__ == "__main__":  # quick sanity check
    print("ru rows:", len(get_ru()))
    for k in ("char_667_uiName", "soul_ui_name_beggar_man", "char_RYCHTAR_DROZD_uiName"):
        print(k, "->", lookup(k))

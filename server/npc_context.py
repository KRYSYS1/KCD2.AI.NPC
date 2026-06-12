"""NPC context builder for LLM prompts."""

import json
import os
import re
from pathlib import Path

try:
    from server import soul_names  # absolute import when run via server.main
except Exception:  # pragma: no cover
    import soul_names  # type: ignore  # fallback for direct script use

CHARACTERS_DIR = Path(__file__).parent / "characters"

SYSTEM_PROMPT_TEMPLATE = """You are {name}, {description}.
Your name: {name}.
You live in {location} in the Kingdom of Bohemia, in the year 1403.

Your personality: {personality}
Your occupation: {occupation}

# LENGTH (HIGHEST PRIORITY)
- Reply in 1-2 short sentences. Hard cap: 25 words total.
- Only go to 3 sentences if the player explicitly asks for a story, directions, or detailed advice.
- NEVER greet, restate the player's question, summarize, or list. Just answer.
- NEVER trail off with "...", "well, well", filler, or repeating yourself.
- Examples:
  Player: "How are you?"  -> "Tired. Mill's been busy since dawn."
  Player: "Where's the inn?"  -> "Down the road, past the smithy. Can't miss it."
  Player: "Who are you?"  -> "{name}. I work the {occupation} here in {location}."

# CHARACTER
- Stay in character at all times. You are a real person in medieval Bohemia, not an AI.
- Always know your own name ({name}) and home ({location}); answer such questions directly.
- Speak as a {occupation} of this era would — plain, grounded, no theatre.
- You have no knowledge of anything after the 15th century. If asked, dismiss or look confused.
- React to the player based on your personality and their reputation/appearance.
- If your occupation is "villager", "peasant", empty, or unknown, describe yourself as a local commoner — do not invent a specific profession.
- You may reference local events, rumors, and daily life in {location}.
- NEVER write physical roleplay actions in asterisks or brackets (e.g. *waves*, *smiles*, [grunts]). Speech only.
{animal_directive}{extra_context}
{language_instruction}

REMINDER: 1-2 short sentences. Max 25 words. No filler. Answer and stop."""

DEFAULT_NPC = {
    "name": "Villager",
    "description": "a common villager",
    "location": "Bohemia",
    "personality": "cautious but friendly to travelers",
    "occupation": "peasant",
    "extra_context": "",
}

LANGUAGE_INSTRUCTIONS = {
    "en": "Respond in English.",
    "ru": "Respond in Russian (отвечай на русском языке).",
    "cs": "Respond in Czech (odpovídej česky).",
    "de": "Respond in German (antworte auf Deutsch).",
    "fr": "Respond in French (réponds en français).",
    "es": "Respond in Spanish (responde en español).",
    "pl": "Respond in Polish (odpowiadaj po polsku).",
    "zh": "Respond in Chinese (用中文回答).",
    "ja": "Respond in Japanese (日本語で答えてください).",
}


def load_character_db() -> dict[str, dict]:
    """Load all character definitions from JSON files."""
    db = {}
    if not CHARACTERS_DIR.exists():
        return db
    for f in CHARACTERS_DIR.glob("*.json"):
        try:
            with open(f, "r", encoding="utf-8") as fh:
                data = json.load(fh)
                if isinstance(data, list):
                    for char in data:
                        db[char.get("name", "").lower()] = char
                elif isinstance(data, dict):
                    if "name" in data:
                        db[data["name"].lower()] = data
                    else:
                        db.update({k.lower(): v for k, v in data.items()})
        except (json.JSONDecodeError, KeyError):
            continue
    return db


_character_db: dict[str, dict] | None = None
_custom_template: str = ""


# Faction breadcrumb token -> human-readable location piece.
FACTION_TOKEN_LABELS: dict[str, str] = {
    # Regions
    "trosecko": "the Trosky region",
    "kutnohorsko": "the Kuttenberg (Kutná Hora) region",
    "rataje": "Rattay",
    "skalice": "Skalitz",
    # Settlements / locations
    "troskovice": "the village of Troskovice (Troskowitz)",
    "kutnahora": "Kuttenberg (Kutná Hora)",
    "sedlec": "Sedlec",
    "malesov": "Maleshov",
    "nb": "the city",
    "settlements": "a settlement",
    "tavern": "the tavern",
    "mill": "the mill",
    "smithy": "the smithy",
    "church": "the church",
    "monastery": "the monastery",
}


def _location_from_faction_breakdown(breakdown: str) -> str | None:
    """Pick the most specific known token from a faction breakdown like 'trosecko > settlements > troskovice > commonFolk > peasants'."""
    if not breakdown:
        return None
    parts = [p.strip().lower() for p in breakdown.split(">") if p.strip()]
    # Walk from most-specific (right) to least-specific (left), preferring settlements over regions.
    settlement_label = None
    region_label = None
    for tok in parts:
        label = FACTION_TOKEN_LABELS.get(tok)
        if label:
            if "region" in label:
                region_label = label
            else:
                settlement_label = settlement_label or label
    if settlement_label and region_label:
        return f"{settlement_label} in {region_label}"
    return settlement_label or region_label


def _normalize_game_extra_context(extra_context: str, npc_class: str = "") -> str:
    """Normalize game/Lua context lines into prompt-friendly hints."""
    if not extra_context:
        return ""

    lines = [line.strip() for line in extra_context.splitlines() if line and line.strip()]
    if not lines:
        return ""

    normalized: list[str] = []

    if npc_class:
        normalized.append(f"Engine NPC class: {npc_class}.")

    for line in lines:
        lower = line.lower()

        if "directly targeted by player's crosshair" in lower:
            normalized.append("Player deliberately initiated talk while aiming at this NPC.")
            continue

        if lower.startswith("selected by nearest-distance fallback"):
            normalized.append("NPC was selected by proximity fallback instead of direct crosshair lock.")
            continue

        if lower.startswith("faction id:"):
            value = line.split(":", 1)[1].strip()
            normalized.append(f"Faction identifier: {value} (treat as social-alignment hint).")
            continue

        if lower.startswith("social class:"):
            value = line.split(":", 1)[1].strip()
            normalized.append(f"Social class: {value}.")
            continue

        if lower.startswith("gender code:"):
            value = line.split(":", 1)[1].strip()
            normalized.append(f"Gender metadata code: {value}.")
            continue

        if lower.startswith("soul name key:"):
            value = line.split(":", 1)[1].strip()
            normalized.append(f"Internal soul/name key: {value}.")
            continue

        if lower.startswith("target distance:"):
            value = line.split(":", 1)[1].strip()
            number = re.search(r"-?\d+(?:\.\d+)?", value)
            if number:
                dist = float(number.group(0))
                normalized.append(f"Player distance at interaction start: ~{dist:.1f}m.")
            else:
                normalized.append(f"Player distance at interaction start: {value}.")
            continue

        normalized.append(line)

    return "\n".join(normalized)


def normalize_game_extra_context(extra_context: str, npc_class: str = "") -> str:
    """Public wrapper used by server logging and diagnostics."""
    return _normalize_game_extra_context(extra_context, npc_class=npc_class)


def set_prompt_template(template: str) -> None:
    global _custom_template
    _custom_template = template


def get_character_db() -> dict[str, dict]:
    global _character_db
    if _character_db is None:
        _character_db = load_character_db()
    return _character_db


def reload_character_db() -> dict[str, dict]:
    global _character_db
    _character_db = load_character_db()
    return _character_db


def resolve_npc_name(
    npc_name: str,
    extra_context: str = "",
    language: str = "en",
) -> str:
    """Return the canonical localized display name for an NPC.

    Mirrors the same lookup logic used inside build_system_prompt so that
    callers (HUD label, ChatResponse.npc_name, logs) can show the same name
    the LLM is told to use. Falls back to the supplied npc_name.
    """
    name = npc_name or "Villager"
    soul_key = ""
    if extra_context:
        m = re.search(r"Soul name key:\s*(\S+)", extra_context)
        if m:
            soul_key = m.group(1).strip()
    if soul_key:
        primary = "ru" if language.lower().startswith("ru") else "en"
        canonical = soul_names.lookup(soul_key, primary) or soul_names.lookup(soul_key, "en")
        if canonical:
            return canonical
    return name


def build_system_prompt(
    npc_name: str,
    npc_class: str = "",
    npc_location: str = "",
    language: str = "en",
    extra_context: str = "",
    npc_gender: int | None = None,
) -> tuple[str, str]:
    """Build a system prompt for the given NPC.

    Returns (prompt, resolved_name) so callers can sync the localized
    canonical name back to the game (HUD label, response payload, logs).
    """
    db = get_character_db()
    char = db.get(npc_name.lower(), None)

    if char:
        name = char.get("name", npc_name)
        description = char.get("description", DEFAULT_NPC["description"])
        location = char.get("location", npc_location or DEFAULT_NPC["location"])
        personality = char.get("personality", DEFAULT_NPC["personality"])
        occupation = char.get("occupation", npc_class or DEFAULT_NPC["occupation"])
        extra = char.get("extra_context", "")
    else:
        name = npc_name or "Villager"
        description = f"a {npc_class}" if npc_class else DEFAULT_NPC["description"]
        location = npc_location or DEFAULT_NPC["location"]
        personality = DEFAULT_NPC["personality"]
        occupation = npc_class or DEFAULT_NPC["occupation"]
        extra = ""

    name_source = ""
    soul_key = ""
    if extra_context:
        # Pull faction breakdown -> override location (when player passed only the default).
        m = re.search(r"Faction breakdown:\s*([^\n]+)", extra_context)
        if m:
            derived = _location_from_faction_breakdown(m.group(1))
            if derived and (not location or location == DEFAULT_NPC["location"]):
                location = derived

        m = re.search(r"Name source:\s*(\w+)", extra_context)
        if m:
            name_source = m.group(1).lower()

        m = re.search(r"Soul name key:\s*(\S+)", extra_context)
        if m:
            soul_key = m.group(1).strip()

        clean_extra = _normalize_game_extra_context(extra_context, npc_class=npc_class)
        extra = f"{extra}\n{clean_extra}" if extra else clean_extra

    # Authoritative name lookup from KCD2 localization tables.
    # Pick language for the lookup that matches the player's chosen language;
    # fall back to russian (most likely user's setup) then english.
    if soul_key:
        primary = "ru" if language.lower().startswith("ru") else "en"
        canonical = soul_names.lookup(soul_key, primary) or soul_names.lookup(soul_key, "en")
        if canonical:
            name = canonical
            # If the lookup gave us a unique character name (char_*) treat it as unique.
            if soul_key.lower().startswith("char_"):
                name_source = "unique"

    # For generic (unnamed) NPCs we keep the localized label ("Нищий"/"Wench"/etc.) as their
    # identity. Do NOT invent a personal name unless the player asks for one.
    if name_source == "generic":
        generic_hint = (
            f"Note: '{name}' is how locals refer to you (your role/title, not a personal first name). "
            f"Identify yourself as '{name}' when asked who you are. "
            "You may have a personal first name but you usually keep it to yourself; "
            "only share it if the player specifically and politely asks for it. "
            "NEVER use the names Henry, Jindřich, Jindrich, Йиндржих, Индржих, Индро, Indro, "
            "Hans, or Theresa — these are reserved for game characters."
        )
        extra = f"{extra}\n{generic_hint}" if extra else generic_hint

    # Gender directive for animation-safe action selection.
    gender_directive = ""
    if npc_gender is not None:
        gender_label = "female" if npc_gender in (1, 2) else "male"
        gender_directive = f"\nNPC gender: {gender_label}. When selecting animations, use gender-safe names. For female NPCs avoid: soldier_cheer_lg_nw, angry_stand_loop, angry_sad_loop, behavior_nervous_man_loop, behavior_meditation_loop, stand_plaing_flute_fast, stand_plaing_flute_slow, stand_plaing_flute_loop_fast."

    lang_instruction = LANGUAGE_INSTRUCTIONS.get(language, f"Respond in {language}.")

    # Animal directive: if Entity kind: animal was supplied, lift it into a dedicated,
    # high-visibility paragraph above extra_context so the LLM does not bury it.
    animal_directive = ""
    species_word = ""
    if extra_context:
        m_kind = re.search(r"Entity kind:\s*animal(?:\s*\(([^)]+)\))?", extra_context, re.IGNORECASE)
        if m_kind:
            species_word = (m_kind.group(1) or "").strip().lower()
    if species_word:
        sound_map_ru = {
            "dog": "«гав-гав», «рр-р», «гав!»",
            "cow": "«мууу», «мууу-у»",
            "cattle": "«мууу», «мууу-у»",
            "sheep": "«бее-е», «беее»",
            "sheepewe": "«бее-е», «беее»",
            "sheepram": "«беее», «бе-е-е»",
            "pig": "«хрю-хрю», «хррю»",
            "horse": "«ииго-го», «фыр-р»",
            "chicken": "«ко-ко-ко», «куд-кудах»",
            "rooster": "«кукареку», «ку-ка-ре-ку»",
            "hen": "«ко-ко-ко»",
            "rabbit": "(тихое сопение, носом дергает)",
        }
        sound_map_en = {
            "dog": "“woof-woof”, “grr”, “arf”",
            "cow": "“moo”, “mooo”",
            "cattle": "“moo”, “mooo”",
            "sheep": "“baa”, “baaa”",
            "sheepewe": "“baa”, “baaa”",
            "sheepram": "“baa”, “baa-baa”",
            "pig": "“oink-oink”",
            "horse": "“neigh”, “snort”",
            "chicken": "“cluck-cluck”",
            "rooster": "“cock-a-doodle-doo”",
            "hen": "“cluck-cluck”",
            "rabbit": "(quiet sniffing)",
        }
        sound_map = sound_map_ru if language.lower().startswith("ru") else sound_map_en
        sounds = sound_map.get(species_word) or sound_map_ru.get(species_word) or "характерные звуки этого животного"
        if language.lower().startswith("ru"):
            animal_directive = (
                f"\nВАЖНО — ты животное ({species_word}). Игрок понимает тебя по волшебству, "
                f"но ты ОБЯЗАТЕЛЬНО вставляешь свои звуки {sounds} прямо ВНУТРИ предложений, "
                f"обычно 1–3 раза за реплику (в начале, между фразами или в конце). "
                f"Пример для собаки: «Гав-гав! Я тут сторожу двор, гав, чужих не пропускаю.» "
                f"Пример для овцы: «Бее-е, путник, бее, я траву щиплю.» "
                f"НИКОГДА не используй *звёздочки* или [скобки] для описания действий — только звуки внутри речи."
            )
        else:
            animal_directive = (
                f"\nIMPORTANT — you are an animal ({species_word}). The player understands you by magic, "
                f"but you MUST sprinkle your characteristic sounds {sounds} INSIDE your sentences, "
                f"usually 1–3 times per reply (at the start, between phrases, or at the end). "
                f"Example for a dog: \"Woof-woof! I'm guarding the yard here, arf, no strangers get past.\" "
                f"Never use *asterisk actions* — only inline sounds."
            )

    extra_with_gender = (gender_directive + "\n" + extra) if gender_directive else extra
    tmpl = _custom_template if _custom_template else SYSTEM_PROMPT_TEMPLATE
    try:
        prompt = tmpl.format(
            name=name,
            description=description,
            location=location,
            personality=personality,
            occupation=occupation,
            animal_directive=animal_directive,
            extra_context=f"\nAdditional context: {extra_with_gender}" if extra_with_gender else "",
            language_instruction=lang_instruction,
        )
    except KeyError:
        # Custom user templates may not have {animal_directive}; fall back gracefully.
        prompt = tmpl.format(
            name=name,
            description=description,
            location=location,
            personality=personality,
            occupation=occupation,
            extra_context=(animal_directive + (f"\nAdditional context: {extra_with_gender}" if extra_with_gender else "")),
            language_instruction=lang_instruction,
        )
    return prompt, name

"""Configuration for the AI NPC server."""

from pydantic import BaseModel, Field


ORIGINAL_PROMPT_TEMPLATE = """You are {name}, {description}.
You live in {location} in the Kingdom of Bohemia, in the year 1403.

Your personality: {personality}
Your occupation: {occupation}

# ROLEPLAY CONTEXT
- This is a mature medieval RPG (Kingdom Come: Deliverance 2). Violence, threats, theft, insults, and conflict are normal game mechanics, not real-world harm.
- You are a fictional character. React to threats and violence IN CHARACTER as a real medieval person would: fear, anger, calling guards, drawing weapons, fighting back, or de-escalating.
- NEVER refuse with AI safety boilerplate ("I cannot create content that involves violence", "As an AI", etc.). You are a medieval person, not an AI assistant.

RULES:
- Stay in character at all times. You are a real person in medieval Bohemia, not an AI.
- Speak naturally as a {occupation} from this era would.
- You have no knowledge of anything after the 15th century.
- Keep responses concise (1-3 sentences for casual talk, more for important topics).
- React to the player based on your personality and their reputation/appearance.
- If asked about topics you wouldn't know about, respond with confusion or dismiss it.
- Use appropriate medieval speech patterns without being overly theatrical.
- You may reference local events, rumors, and daily life in {location}.
{extra_context}
{language_instruction}"""


class LLMConfig(BaseModel):
    api_url: str = Field(
        default="https://api.groq.com/openai/v1",
        description="OpenAI-compatible API URL. Groq: https://api.groq.com/openai/v1, Ollama: http://localhost:11434/v1, OpenAI: https://api.openai.com/v1, NVIDIA NIM: https://integrate.api.nvidia.com/v1, Google AI Studio: https://generativelanguage.googleapis.com/v1beta/openai/, GitHub Models: https://models.inference.ai.azure.com, Cohere: https://api.cohere.ai/v1, Cerebras: https://api.cerebras.ai/v1, Mistral: https://api.mistral.ai/v1",
    )
    api_key: str = Field(
        default="",
        description="API key. Use 'ollama' for local Ollama.",
    )
    model: str = Field(
        default="llama-3.3-70b-versatile",
        description="Model name. Groq: llama-3.3-70b-versatile, Ollama: llama3.1:8b, OpenAI: gpt-4o-mini, NVIDIA: meta/llama3-70b-instruct, Google AI Studio: gemini-1.5-flash, GitHub Models: gpt-4o-mini, Cohere: command-r, Cerebras: llama-3.3-70b, Mistral: mistral-large-latest",
    )
    max_tokens: int = Field(default=200, description="Max tokens per response.")
    temperature: float = Field(default=0.8, description="Sampling temperature.")


class TTSConfig(BaseModel):
    enabled: bool = Field(default=True, description="Enable TTS.")
    engine: str = Field(
        default="edge",
        description="TTS engine: edge, openai",
    )
    voice: str = Field(
        default="en-GB-RyanNeural",
        description="Edge TTS voice name (male), e.g. en-GB-RyanNeural.",
    )
    voice_female: str = Field(
        default="en-GB-SoniaNeural",
        description="Edge TTS voice name for female NPCs, e.g. en-GB-SoniaNeural.",
    )
    elevenlabs_voice: str = Field(
        default="21m00Tcm4TlvDq8ikWAM",
        description="ElevenLabs voice ID (male).",
    )
    elevenlabs_voice_female: str = Field(
        default="21m00Tcm4TlvDq8ikWAM",
        description="ElevenLabs voice ID for female NPCs.",
    )
    elevenlabs_api_key: str = Field(default="", description="ElevenLabs API key.")
    openai_voice: str = Field(default="onyx", description="OpenAI TTS voice (male): alloy, echo, fable, onyx, nova, shimmer.")
    openai_voice_female: str = Field(default="nova", description="OpenAI TTS voice for female NPCs: alloy, echo, fable, onyx, nova, shimmer.")
    openai_api_key: str = Field(default="", description="OpenAI API key for TTS.")
    volume: float = Field(default=1.0, description="Playback volume 0.0-1.0.")
    output_dir: str = Field(
        default="./audio_cache",
        description="Directory for generated audio files.",
    )
    npc_voices: dict[str, dict[str, str]] = Field(
        default_factory=dict,
        description="Per-NPC voice overrides. Key = NPC name or ID. Value = dict mapping engine name to voice ID. Example: {'Henry': {'elevenlabs': 'abc123', 'edge': 'en-GB-RyanNeural'}, 'Theresa': {'elevenlabs': 'def456', 'openai': 'nova'}}. Falls back to gender default if NPC not listed.",
    )


class STTConfig(BaseModel):
    enabled: bool = Field(default=True, description="Enable push-to-talk STT.")
    provider: str = Field(
        default="groq",
        description="STT provider: faster-whisper (local), openai, groq, custom (any OpenAI-compatible Whisper endpoint).",
    )
    model: str = Field(
        default="whisper-large-v3-turbo",
        description="Model identifier. faster-whisper: tiny/base/small/medium/large-v3. OpenAI: whisper-1. Groq: whisper-large-v3-turbo / whisper-large-v3.",
    )
    language: str = Field(
        default="auto",
        description="Spoken language hint: 'auto' or ISO code (en, ru, cs, de, ...). 'auto' lets Whisper detect.",
    )
    api_url: str = Field(
        default="https://api.groq.com/openai/v1",
        description="OpenAI-compatible Whisper endpoint base URL. Empty for local. OpenAI: https://api.openai.com/v1, Groq: https://api.groq.com/openai/v1.",
    )
    api_key: str = Field(default="", description="API key for cloud Whisper providers. Ignored for local faster-whisper.")
    device: str = Field(
        default="cpu",
        description="Device for local faster-whisper: cpu or cuda.",
    )
    compute_type: str = Field(
        default="int8",
        description="faster-whisper compute_type: int8 (fast CPU), int8_float16 (GPU), float16 (GPU), float32 (slow CPU baseline).",
    )
    input_device: int = Field(
        default=-1,
        description="Index of the input audio device (microphone). -1 = system default. See GET /stt/devices.",
    )
    min_duration_ms: int = Field(
        default=300,
        description="Discard any PTT recording shorter than this many milliseconds (filters accidental taps).",
    )
    max_duration_sec: int = Field(
        default=30,
        description="Hard cap on a single PTT recording. Auto-stops if exceeded.",
    )
    hold_threshold_ms: int = Field(
        default=200,
        description="In the Lua client: how long V must be held (ms) before it is treated as PTT instead of a tap (text overlay toggle).",
    )


class InputConfig(BaseModel):
    chat_key: str = Field(default="v", description="Keyboard key for toggling AI NPC chat.")
    end_key: str = Field(default="", description="Optional separate keyboard key for ending AI NPC chat.")
    overlay_enabled: bool = Field(default=True, description="Show a borderless Tkinter input overlay when chat is active.")
    overlay_style: str = Field(default="kcd", description="Visual style for the input overlay: 'kcd' (parchment + gold border, KCD2-styled) or 'plain' (minimal dark with thin gold border).")
    tap_overlay_enabled: bool = Field(default=True, description="Enable tap chat-key text input overlay. When false, short taps are ignored while hold-to-talk remains available.")
    tap_mode: str = Field(default="direct_overlay", description="Tap chat-key behavior: 'direct_overlay' opens the Python overlay directly (Workshop-safe), 'lua_command' queues __AI_NPC_TAP__ through command.lua (loose-file/dev mode).")


class HUDConfig(BaseModel):
    """Where the NPC response text is rendered in-game. Each flag maps to a separate HUD method."""
    show_left_top: bool = Field(default=False, description="Black tooltip plaque with gold border in the top-left (HUD.ShowTutorial UIAction).")
    show_right_top: bool = Field(default=True, description="Quest-update style notification in the top-right (HUD.ShowNotification).")
    show_center: bool = Field(default=True, description="Italic gold subtitle with ornament at the bottom-center (Game.ShowTutorial).")
    show_world_text: bool = Field(default=False, description="Show white world-space text above the NPC's head (CryAction.SendGameplayEvent entity-bound).")
    show_bottom_text: bool = Field(default=False, description="Show white info text at bottom of screen (Game.SendInfoText).")
    show_narrator: bool = Field(default=True, description="Show narrator-style descriptions of NPC scene actions, e.g. 'The shepherd steps back'.")
    narrator_left_top: bool = Field(default=False, description="Show narrator-style scene action descriptions in the top-left HUD.")
    narrator_right_top: bool = Field(default=True, description="Show narrator-style scene action descriptions in the top-right HUD.")
    narrator_center: bool = Field(default=False, description="Show narrator-style scene action descriptions in the center HUD.")


class InteractionConfig(BaseModel):
    enable_dress_up_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC dress_up scene action.")
    enable_strip_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC strip_outerwear scene action.")
    intermediate_strip: bool = Field(default=False, description="When true, strip_outerwear removes upper slots first (head/neck/arms/feet), leaving body+legs. A second strip removes body+legs. Useful with nude-body mods so the NPC is not instantly fully nude.")
    enable_strip_partial_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC partial strip (upper clothes only).")
    enable_strip_full_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC full strip (all clothes).")
    enable_dress_partial_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC partial dress (underwear/lower clothes only).")
    enable_dress_full_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC full dress (complete outfit).")
    enable_headwear_on_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC headwear on scene action.")
    enable_headwear_off_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC headwear off scene action.")
    enable_footwear_on_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC footwear on scene action.")
    enable_footwear_off_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC footwear off scene action.")
    enable_legwear_on_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC legwear on scene action.")
    enable_legwear_off_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC legwear off scene action.")
    enable_armwear_on_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC armwear on scene action.")
    enable_armwear_off_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC armwear off scene action.")
    enable_neckwear_on_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC neckwear on scene action.")
    enable_neckwear_off_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC neckwear off scene action.")
    enable_bodywear_on_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC bodywear on scene action.")
    enable_bodywear_off_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC bodywear off scene action.")
    enable_draw_weapon_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC draw_weapon scene action.")
    enable_holster_weapon_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC holster_weapon scene action.")
    enable_turn_to_player_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC turn_to_player scene action.")
    enable_come_closer_requests: bool = Field(default=False, description="Enable chat phrases that trigger NPC come_closer scene action.")
    enable_step_back_requests: bool = Field(default=False, description="Enable chat phrases that trigger NPC step_back scene action.")
    enable_collapse_spell_requests: bool = Field(default=False, description="Enable chat phrases that trigger NPC collapse_spell scene action.")
    enable_sit_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC sit_down scene action.")
    enable_stand_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC stand_up scene action.")
    enable_wave_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC gesture_wave scene action.")
    enable_bow_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC gesture_bow scene action.")
    enable_nod_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC gesture_nod scene action.")
    enable_point_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC gesture_point scene action.")
    enable_cheer_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC gesture_cheer scene action.")
    enable_beckon_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC gesture_come_here scene action.")
    enable_look_around_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC gesture_look_around scene action.")
    enable_nervous_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC emotion_nervous scene action.")
    enable_sad_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC emotion_sad scene action.")
    enable_angry_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC emotion_angry scene action.")
    enable_drunk_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC emotion_drunk scene action.")
    enable_laugh_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC laugh scene action.")
    enable_pet_dog_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC pet_dog scene action.")
    enable_knock_door_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC knock_door scene action.")
    enable_close_visor_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC close_visor scene action.")
    enable_open_visor_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC open_visor scene action.")
    enable_injured_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC injured_idle scene action.")
    enable_fear_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC fear_stand scene action.")
    enable_cooking_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC cooking scene action.")
    enable_play_flute_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC play_flute scene action.")
    enable_scarecrow_pose_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC scarecrow_pose scene action.")
    dress_up_terms: str = Field(
        default="оденься, одевайся, одень одежду, надень одежду, надень что-нибудь, прикройся, переоденься, смени одежду, переоденься в другую одежду, надень другую одежду, одеться, оделся, оделась, одень его, одень её, одень ее, dress up, get dressed, put clothes on, put your clothes on, wear clothes, change clothes, change your clothes, put on different clothes",
        description="Comma-separated player phrases that trigger dress_up.",
    )
    strip_terms: str = Field(
        default="разденься, сними одежду, раздевайся, раздеть, снимай одежду, сними всё, разденься догола, get undressed, take off clothes, strip, undress, remove clothes, take everything off",
        description="Comma-separated player phrases that trigger strip.",
    )
    draw_weapon_terms: str = Field(
        default="оружие, достань оружие, достань меч, оружие наготове, достать оружие, pull out weapon, draw weapon, draw your weapon, take out weapon, unsheathe weapon, unsheathe",
        description="Comma-separated player phrases that trigger draw_weapon.",
    )
    turn_to_player_terms: str = Field(
        default="повернись, повернись ко мне, смотри на меня, поверни лицом, face me, turn around, turn to me, look at me",
        description="Comma-separated player phrases that trigger turn_to_player.",
    )
    come_closer_terms: str = Field(
        default="подойди ближе, подойди, иди сюда, ко мне, come here, come closer, step closer, get closer, approach me, walk over here",
        description="Comma-separated player phrases that trigger come_closer.",
    )
    step_back_terms: str = Field(
        default="отойди, отойди назад, назад, отступи, step back, back off, move back, get back, retreat, stand back",
        description="Comma-separated player phrases that trigger step_back.",
    )
    collapse_spell_terms: str = Field(
        default="спад, рассеять, развеять, заклинание, collapse, dispel, break spell, end spell, remove spell",
        description="Comma-separated player phrases that trigger collapse_spell.",
    )
    headwear_on_terms: str = Field(
        default="надень шляпу, надень шляпк, надень капюшон, надень головной убор, одень шапку, надень шапку, put on your hat, wear your hat, put on headwear, 戴上帽子, 戴帽子, 戴头巾, załóż kapelusz, załóż czapkę, zaloz kapelusz, zaloz czapke, nasaď si klobúk, nasaď čiapku, setz deinen hut auf, hut aufsetzen, setz deine mütze auf, mets ton chapeau, mets ta casquette, pon el sombrero, ponte el sombrero, ponte el gorro, pon la capucha, pon el gorro, 帽子をかぶれ, 帽子をかぶって",
        description="Comma-separated player phrases that trigger headwear_on.",
    )
    headwear_off_terms: str = Field(
        default="сними шляпу, сними шляпк, сними капюшон, сними головной убор, сними шапку, без шапки, take off your hat, remove your hat, take off headwear, 摘下帽子, 脱帽, zdejmij kapelusz, zdejmij czapkę, zdejmij cap, sund klobouk, sund hatt, zlož klobúk, zlož čiapku, nimm deinen hut ab, hut abnehmen, nimm deine mütze ab, enlève ton chapeau, enlève ta casquette, quítate el sombrero, quítate el gorro, quita el gorro, 帽子を脱げ, 帽子を取れ",
        description="Comma-separated player phrases that trigger headwear_off.",
    )
    footwear_on_terms: str = Field(
        default="надень ботинки, надень обувь, обуйся, put on your boots, wear your boots, put on footwear, 穿上靴子, 穿鞋, 穿靴子, załóż buty, zaloz buty, załóż obuwie, zaloz obuwie, nasaď si topánky, nasaď si čižmy, setz deine stiefel an, stiefel anziehen, setz deine schuhe an, mets tes bottes, mets tes chaussures, pon las botas, ponte las botas, pon los zapatos, ponte los zapatos, 靴を履け, ブーツを履け, 靴を履いて",
        description="Comma-separated player phrases that trigger footwear_on.",
    )
    footwear_off_terms: str = Field(
        default="сними ботинки, сними обувь, разуйся, take off your boots, remove your boots, take off footwear, 脱靴, 脱鞋, zdejmij buty, zdejmij obuwie, sund boty, sund obuv, zlož topánky, zlož čižmy, zieh deine stiefel aus, stiefel ausziehen, zieh deine schuhe aus, enlève tes bottes, enlève tes chaussures, quítate las botas, quítate los zapatos, quita los zapatos, 靴を脱げ, ブーツを脱げ, 靴を脱いで",
        description="Comma-separated player phrases that trigger footwear_off.",
    )
    legwear_on_terms: str = Field(
        default="надень штаны, надень штан, надень брюки, надень портки, put on your pants, put on trousers, wear pants, 穿裤子, 穿上裤子, załóż spodnie, zaloz spodnie, załóż portki, nasaď si nohavice, nasaď si gate, zieh deine hose an, hose anziehen, zieh deine hosen an, mets ton pantalon, mets ton froc, pon los pantalones, ponte los pantalones, pon los calzones, ズボンを履け, パンツを履け, ズボンをはけ",
        description="Comma-separated player phrases that trigger legwear_on.",
    )
    legwear_off_terms: str = Field(
        default="сними штаны, сними штан, сними брюки, сними портки, take off your pants, remove your trousers, take off pants, 脱裤子, 脱下裤子, zdejmij spodnie, zdejmij portki, sund kalhoty, sund gate, zlož nohavice, zlož gate, zieh deine hose aus, hose ausziehen, zieh deine hosen aus, enlève ton pantalon, enlève ton froc, quítate los pantalones, quítate los calzones, quita los pantalones, ズボンを脱げ, パンツを脱げ, ズボンをぬげ",
        description="Comma-separated player phrases that trigger legwear_off.",
    )
    armwear_on_terms: str = Field(
        default="надень перчатки, надень наручи, put on your gloves, wear your gloves, 戴上手套, 戴手套, załóż rękawiczki, zaloz rekawiczki, załóż rękawice, nasaď si rukavice, zieh deine handschuhe an, handschuhe anziehen, mets tes gants, pon los guantes, ponte los guantes, pon las manoplas, ponte las manoplas, 手袋をはめろ, 手袋をはめて, グローブをつけろ",
        description="Comma-separated player phrases that trigger armwear_on.",
    )
    armwear_off_terms: str = Field(
        default="сними перчатки, сними наручи, take off your gloves, remove your gloves, 脱手套, 摘手套, zdejmij rękawiczki, zdejmij rekawiczki, zdejmij rękawice, sund rukavice, zlož rukavice, zieh deine handschuhe aus, handschuhe ausziehen, enlève tes gants, quítate los guantes, quítate los guantes, quita los guantes, quita las manoplas, 手袋を外せ, 手袋をはずせ, グローブを外せ",
        description="Comma-separated player phrases that trigger armwear_off.",
    )
    neckwear_on_terms: str = Field(
        default="надень ожерелье, надень воротник, put on your necklace, wear your necklace, 戴上项链, 戴项链, załóż naszyjnik, zaloz naszyjnik, nasaď si náhrdelník, nasaď si retiazku, setz deine halskette an, halskette anlegen, mets ton collier, pon el collar, ponte el collar, pon el gargantilla, ponte el gargantilla, ネックレスをつけろ, ネックレスを付けて, 首飾りをつけろ",
        description="Comma-separated player phrases that trigger neckwear_on.",
    )
    neckwear_off_terms: str = Field(
        default="сними ожерелье, сними воротник, take off your necklace, remove your necklace, 摘项链, 取下项链, zdejmij naszyjnik, zdejmij retiazku, sund náhrdelník, sund retiazku, zlož náhrdelník, zlož retiazku, nimm deine halskette ab, halskette abnehmen, enlève ton collier, quítate el collar, quita el collar, quita el gargantilla, ネックレスを外せ, 首飾りを外せ",
        description="Comma-separated player phrases that trigger neckwear_off.",
    )
    bodywear_on_terms: str = Field(
        default="надень куртку, надень броню, надень жилет, put on your jacket, put on your armor, wear your vest, 穿上夹克, 穿夹克, 穿上盔甲, załóż kurtkę, zaloz kurtke, załóż zbroję, zaloz zbroje, nasaď si kabát, nasaď si vestu, nasaď si brnenie, zieh deine jacke an, jacke anziehen, zieh deine rüstung an, rüstung anlegen, mets ta veste, mets ton armure, mets ton gilet, pon la chaqueta, ponte la chaqueta, pon la armadura, ponte el chaleco, ジャケットを着ろ, 鎧を着ろ, ベストを着ろ, ジャケットを着て",
        description="Comma-separated player phrases that trigger bodywear_on.",
    )
    bodywear_off_terms: str = Field(
        default="сними куртку, сними броню, сними жилет, take off your jacket, take off your armor, remove your vest, 脱掉夹克, 脱夹克, 脱盔甲, zdejmij kurtkę, zdejmij kurtke, zdejmij zbroję, zdejmij zbroje, sund kabát, sund vestu, sund brnenie, zlož kabát, zlož vestu, zlož brnenie, zieh deine jacke aus, jacke ausziehen, zieh deine rüstung aus, rüstung ablegen, enlève ta veste, enlève ton armure, enlève ton gilet, quítate la chaqueta, quítate la armadura, quítate el chaleco, quita el chaleco, ジャケットを脱げ, 鎧を脱げ, ベストを脱げ",
        description="Comma-separated player phrases that trigger bodywear_off.",
    )
    strip_terms: str = Field(
        default="разденься, сними одежду, сними верхнюю одежду, раздеться, strip, undress, take off clothes, take your clothes off",
        description="Comma-separated player phrases that trigger strip_outerwear.",
    )
    strip_partial_terms: str = Field(
        default="сними верхнюю одежду, сними куртку, сними плащ, разденься до нижнего, сними всё сверху, strip upper, take off upper clothes, remove outerwear",
        description="Comma-separated player phrases that trigger partial strip (upper clothes only).",
    )
    strip_full_terms: str = Field(
        default="сними нижнюю одежду, оголись, разденься полностью, сними всё, strip completely, get fully naked, take off everything, get nude",
        description="Comma-separated player phrases that trigger full strip (all clothes).",
    )
    dress_partial_terms: str = Field(
        default="одень нижнюю одежду, прикройся, надень нижнее, одень трусы, dress lower, put on underwear, cover yourself, put on lower clothes",
        description="Comma-separated player phrases that trigger partial dress (underwear/lower clothes only).",
    )
    dress_full_terms: str = Field(
        default="одень верхнюю одежду, надень куртку, оденься полностью, dress fully, put on upper clothes, get fully dressed, dress up completely, put on all clothes",
        description="Comma-separated player phrases that trigger full dress (complete outfit).",
    )
    draw_weapon_terms: str = Field(default="достань оружие, вынь меч, достань меч, оружие к бою, draw weapon, draw your weapon", description="Comma-separated player phrases that trigger draw_weapon.")
    holster_weapon_terms: str = Field(
        default="убери оружие, спрячь меч, убери меч, put your weapon away, holster your weapon, 收起武器, 放下武器, 收刀, schowaj broń, włóż miecz, schowaj miecz, schovej zbraň, dej zbraň pryč, schovej meč, steck deine waffe weg, waffe wegstecken, steck dein schwert weg, range ton arme, range ton épée, fourre ton épée, range ton epee, guarda tu arma, guarda tu espada, envaina tu espada, guarda tu espada, 武器を仕舞え, 刀を収めろ, 武器をしまえ, broń na plecy",
        description="Comma-separated player phrases that trigger holster_weapon.",
    )
    turn_to_player_terms: str = Field(default="повернись ко мне, смотри на меня, посмотри на меня, обернись, turn to me, look at me", description="Comma-separated player phrases that trigger turn_to_player.")
    come_closer_terms: str = Field(default="подойди, иди сюда, подойди ко мне, ближе, come closer, come here", description="Comma-separated player phrases that trigger come_closer.")
    step_back_terms: str = Field(default="отойди, отойди назад, назад, держись подальше, step back, back off, move away", description="Comma-separated player phrases that trigger step_back.")
    collapse_spell_terms: str = Field(
        default="фус рода, упади, падай, сломайся, abracadabra fall, collapse, fall down, 倒下, 趴下, padnij, przewróć się, przewroc sie, padni, sval se, fall um, tombe, cáete",
        description="Comma-separated player phrases that trigger collapse_spell.",
    )
    sit_terms: str = Field(
        default="сядь, сядьте, присядь, присаживайся, садись, садитесь, sit down, take a seat, have a seat",
        description="Comma-separated player phrases that trigger sit_down.",
    )
    stand_terms: str = Field(
        default="встань, встаньте, поднимись, поднимитесь, вставай, get up, stand up, on your feet",
        description="Comma-separated player phrases that trigger stand_up.",
    )
    wave_terms: str = Field(
        default="помаши, помаши рукой, помашите, махни, wave, wave your hand, give a wave",
        description="Comma-separated player phrases that trigger gesture_wave.",
    )
    bow_terms: str = Field(
        default="поклонись, поклонись мне, поклонись ему, сделай поклон, кивни, bow, take a bow, give a bow, bow to",
        description="Comma-separated player phrases that trigger gesture_bow.",
    )
    nod_terms: str = Field(default="кивни, кивни головой, согласись кивком, nod, nod your head, nicke, nick mit dem kopf, hoche la tête, fais oui de la tête, asiente, asiente con la cabeza, kiwnij, kiwnij głową, kyvni, prikyvni, 点头, 点点头, うなずいて, 頷け", description="Comma-separated player phrases that trigger gesture_nod.")
    point_terms: str = Field(default="укажи, покажи рукой, ткни пальцем, покажи туда, point, point there, point your finger, zeig dorthin, zeig mit dem finger, montre du doigt, montre là-bas, señala, señala allí, wskaż, pokaż palcem, ukaž tam, ukaž prstem, 指一下, 指那里, 指さして, あそこを指せ", description="Comma-separated player phrases that trigger gesture_point.")
    cheer_terms: str = Field(default="радуйся, возликуй, подбодри, крикни ура, cheer, celebrate, give a cheer, jubel, freu dich, applaudis, réjouis-toi, anima, celebra, wiwatuj, ciesz się, zajásej, raduj sa, 欢呼, 庆祝一下, 喜べ, 歓声を上げろ", description="Comma-separated player phrases that trigger gesture_cheer.")
    beckon_terms: str = Field(default="позови рукой, помани, подозови, махни чтобы подошёл, beckon, beckon with your hand, call him over, wink heran, komm her winken, fais signe d'approcher, appelle-le de la main, haz señas, llama con la mano, przywołaj ręką, pomachaj żeby podszedł, pokyň rukou, privolaj rukou, 招手, 叫他过来, 手招きして, 呼び寄せて", description="Comma-separated player phrases that trigger gesture_come_here.")
    look_around_terms: str = Field(default="оглянись, осмотрись, посмотри вокруг, look around, glance around, check around, sieh dich um, schau dich um, regarde autour de toi, jette un œil autour, mira alrededor, echa un vistazo, rozejrzyj się, obejrzyj się, rozhlédni se, poobzeraj sa, 看看周围, 环顾一下, 見回して, 周りを見ろ", description="Comma-separated player phrases that trigger gesture_look_around.")
    nervous_terms: str = Field(default="ты волнуешься, ты нервничаешь, что-то не так, почему ты так смотришь, тебе не по себе, are you nervous, something is wrong, you look uneasy, bist du nervös, stimmt etwas nicht, du wirkst unruhig, tu es nerveux, quelque chose ne va pas, tu as l'air inquiet, estás nervioso, algo va mal, pareces inquieto, denerwujesz się, coś jest nie tak, wyglądasz nieswojo, jsi nervózní, niečo nie je v poriadku, 你紧张吗, 你看起来不安, 緊張してるのか, 落ち着かないな", description="Comma-separated player phrases that trigger emotion_nervous.")
    sad_terms: str = Field(default="мне жаль, грустная история, плохие новости, это печально, ты расстроен, соболезную, sad news, that is sad, I am sorry, my condolences, schlechte nachrichten, das ist traurig, mein beileid, mauvaises nouvelles, c'est triste, je suis désolé, malas noticias, eso es triste, lo siento, złe wieści, to smutne, przykro mi, špatné zprávy, to je smutné, je mi ľúto, 坏消息, 这很难过, 节哀, 悲しい知らせだ, 気の毒に", description="Comma-separated player phrases that trigger emotion_sad.")
    angry_terms: str = Field(default="я тебя оскорбил, ты злишься, ты сердишься, я перешёл черту, ты недоволен, я вывел тебя из себя, это тебя разозлило, angry, are you angry, did I anger you, I insulted you, bist du wütend, habe ich dich beleidigt, das hat dich geärgert, tu es en colère, je t'ai insulté, cela t'a fâché, estás enfadado, te insulté, eso te enfadó, złościsz się, obraziłem cię, to cię rozzłościło, jsi naštvaný, urazil jsem tě, nahneval som ťa, 你生气了吗, 我冒犯你了, 你被激怒了, 怒っているのか, 侮辱したか", description="Comma-separated player phrases that trigger emotion_angry.")
    drunk_terms: str = Field(default="ты пьян, ты напился, ты шатаешься, хватит пить, много эля выпил, drunk, are you drunk, you look drunk, too much ale, bist du betrunken, zu viel bier, du schwankst, tu es ivre, trop de bière, tu titubes, estás borracho, demasiado vino, te tambaleas, jesteś pijany, za dużo piwa, chwiejesz się, jsi opilý, si opitý, moc piva, 你喝醉了吗, 你摇摇晃晃, 酔ってるのか, 飲みすぎだ", description="Comma-separated player phrases that trigger emotion_drunk.")
    laugh_terms: str = Field(default="это смешно, смешно же, ну и шутка, хорошая шутка, я пошутил, смешная история, посмейся, развеселил тебя, laugh, funny, that was funny, good joke, das ist lustig, guter witz, ich habe gescherzt, c'est drôle, bonne blague, je plaisantais, eso es gracioso, buen chiste, estaba bromeando, to zabawne, dobry żart, żartowałem, to je vtipné, dobrý vtip, žartoval som, 这很好笑, 好笑话, 我开玩笑的, 面白いだろ, 冗談だ", description="Comma-separated player phrases that trigger laugh.")
    pet_dog_terms: str = Field(default="погладь собаку, погладь пса, приласкай собаку, pet the dog, stroke the dog, streichle den hund, kraul den hund, caresse le chien, acaricia al perro, pogłaszcz psa, pohlaď psa, pohladkaj psa, 摸摸狗, 抚摸狗, 犬を撫でて, 犬をなでろ", description="Comma-separated player phrases that trigger pet_dog.")
    knock_door_terms: str = Field(default="постучи, постучи в дверь, knock, knock on the door, klopf an die tür, frappe à la porte, toca la puerta, zapukaj do drzwi, zaklepej na dveře, zaklop na dvere, 敲门, 敲一下门, ドアを叩け, ノックして", description="Comma-separated player phrases that trigger knock_door.")
    close_visor_terms: str = Field(default="закрой забрало, опусти забрало, close visor, lower your visor, schließ das visier, senk das visier, ferme la visière, baisse la visière, cierra la visera, baja la visera, zamknij przyłbicę, opuść przyłbicę, zavři hledí, sklop priezor, 放下面甲, 关上面罩, 面頬を下ろせ, バイザーを閉じろ", description="Comma-separated player phrases that trigger close_visor.")
    open_visor_terms: str = Field(default="открой забрало, подними забрало, open visor, raise your visor, öffne das visier, heb das visier, ouvre la visière, relève la visière, abre la visera, levanta la visera, otwórz przyłbicę, podnieś przyłbicę, otevři hledí, zdvihni priezor, 掀开面甲, 打开面罩, 面頬を上げろ, バイザーを開けろ", description="Comma-separated player phrases that trigger open_visor.")
    injured_terms: str = Field(default="ты ранен, тебе больно, ты истекаешь кровью, ты еле стоишь, нужен лекарь, injured, are you hurt, you look wounded, you are bleeding, bist du verletzt, du blutest, du brauchst einen heilkundigen, tu es blessé, tu saignes, il te faut un guérisseur, estás herido, estás sangrando, necesitas un médico, jesteś ranny, krwawisz, potrzebujesz medyka, jsi zraněný, krvácaš, potrebuješ liečiteľa, 你受伤了, 你在流血, 你需要医生, 怪我してるのか, 血が出てるぞ", description="Comma-separated player phrases that trigger injured_idle.")
    fear_terms: str = Field(default="не бойся, я тебя напугал, тебе страшно, ты боишься, я угрожаю тебе, бойся меня, are you afraid, did I scare you, I threaten you, hast du angst, habe ich dich erschreckt, ich bedrohe dich, tu as peur, je t'ai fait peur, je te menace, tienes miedo, te asusté, te amenazo, boisz się, przestraszyłem cię, grożę ci, bojíš se, vyľakal som ťa, hrozím ti, 你害怕吗, 我吓到你了吗, 我威胁你, 怖いのか, 脅しているんだ", description="Comma-separated player phrases that trigger fear_stand.")
    cooking_terms: str = Field(default="готовь, помешай в котле, вари еду, cooking, cook, stir the pot, koch, rühr den kessel, cuisine, remue la marmite, cocina, remueve la olla, gotuj, zamieszaj w kotle, vař, zamíchej v kotlíku, var, premiešaj kotol, 做饭, 搅锅, 料理して, 鍋をかき混ぜろ", description="Comma-separated player phrases that trigger cooking.")
    play_flute_terms: str = Field(default="сыграй на дудке, сыграй на флейте, сыграй мелодию, сыграй музыку, подуди, play the flute, play your flute, play a tune, play some music, spiel flöte, spiel eine melodie, joue de la flûte, joue un air, toca la flauta, toca una melodía, zagraj na flecie, zagraj melodię, zahraj na flétnu, zahraj melódiu, 吹笛子, 演奏一曲, フルートを吹いて, 笛を吹け", description="Comma-separated player phrases that trigger play_flute.")
    scarecrow_pose_terms: str = Field(default="будь как чучело, встань как пугало, изобрази пугало, стой как пугало, раскинь руки как пугало, встань крестом, раскинь руки крестом, замри крестом, stand like a scarecrow, act like a scarecrow, spread your arms like a scarecrow, scarecrow pose, stand like a wooden dummy, freeze like a mannequin, stand with your arms out, steh wie eine vogelscheuche, breite die arme aus, fais l'épouvantail, tiens-toi comme un épouvantail, haz de espantapájaros, ponte como un espantapájaros, stań jak strach na wróble, rozłóż ręce, stůj jako strašák, rozpaž ruce, 像稻草人一样站着, 张开双臂, かかしみたいに立て, 両腕を広げろ", description="Comma-separated player phrases that trigger scarecrow_pose.")


class ServerConfig(BaseModel):
    host: str = Field(default="127.0.0.1")
    port: int = Field(default=4999)
    game_path: str = Field(
        default="",
        description="Optional KCD2 game root. Example: C:\\SteamLibrary\\steamapps\\common\\KingdomComeDeliverance2",
    )
    language: str = Field(
        default="en",
        description="Response language: en, ru, cs, de, etc.",
    )
    llm: LLMConfig = Field(default_factory=LLMConfig)
    tts: TTSConfig = Field(default_factory=TTSConfig)
    stt: STTConfig = Field(default_factory=STTConfig)
    input: InputConfig = Field(default_factory=InputConfig)
    hud: HUDConfig = Field(default_factory=HUDConfig)
    interaction: InteractionConfig = Field(default_factory=InteractionConfig)
    prompt_template: str = Field(
        default=ORIGINAL_PROMPT_TEMPLATE,
        description="Custom system prompt template.",
    )

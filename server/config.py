"""Configuration for the AI NPC server."""

from pydantic import BaseModel, Field


ORIGINAL_PROMPT_TEMPLATE = """You are {name}, {description}.
You live in {location} in the Kingdom of Bohemia, in the year 1403.

Your personality: {personality}
Your occupation: {occupation}

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
        description="OpenAI-compatible API URL. Groq: https://api.groq.com/openai/v1, Ollama: http://localhost:11434/v1, OpenAI: https://api.openai.com/v1",
    )
    api_key: str = Field(
        default="",
        description="API key. Use 'ollama' for local Ollama.",
    )
    model: str = Field(
        default="llama-3.3-70b-versatile",
        description="Model name. Groq: llama-3.3-70b-versatile, Ollama: llama3.1:8b, OpenAI: gpt-4o-mini",
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
    show_narrator: bool = Field(default=True, description="Show narrator-style descriptions of NPC scene actions, e.g. 'The shepherd steps back'.")
    narrator_left_top: bool = Field(default=False, description="Show narrator-style scene action descriptions in the top-left HUD.")
    narrator_right_top: bool = Field(default=True, description="Show narrator-style scene action descriptions in the top-right HUD.")
    narrator_center: bool = Field(default=False, description="Show narrator-style scene action descriptions in the center HUD.")


class InteractionConfig(BaseModel):
    enable_dress_up_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC dress_up scene action.")
    enable_strip_requests: bool = Field(default=True, description="Enable chat phrases that trigger NPC strip_outerwear scene action.")
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
    dress_up_terms: str = Field(
        default="оденься, одевайся, одень одежду, надень одежду, надень что-нибудь, прикройся, переоденься, смени одежду, переоденься в другую одежду, надень другую одежду, одеться, оделся, оделась, одень его, одень её, одень ее, dress up, get dressed, put clothes on, put your clothes on, wear clothes, change clothes, change your clothes, put on different clothes",
        description="Comma-separated player phrases that trigger dress_up.",
    )
    headwear_on_terms: str = Field(
        default="надень шляпу, надень шляпк, надень капюшон, надень головной убор, одень шапку, надень шапку, put on your hat, wear your hat, put on headwear",
        description="Comma-separated player phrases that trigger headwear_on.",
    )
    headwear_off_terms: str = Field(
        default="сними шляпу, сними шляпк, сними капюшон, сними головной убор, сними шапку, без шапки, take off your hat, remove your hat, take off headwear",
        description="Comma-separated player phrases that trigger headwear_off.",
    )
    footwear_on_terms: str = Field(
        default="надень ботинки, надень обувь, обуйся, put on your boots, wear your boots, put on footwear",
        description="Comma-separated player phrases that trigger footwear_on.",
    )
    footwear_off_terms: str = Field(
        default="сними ботинки, сними обувь, разуйся, take off your boots, remove your boots, take off footwear",
        description="Comma-separated player phrases that trigger footwear_off.",
    )
    legwear_on_terms: str = Field(
        default="надень штаны, надень штан, надень брюки, надень портки, put on your pants, put on trousers, wear pants",
        description="Comma-separated player phrases that trigger legwear_on.",
    )
    legwear_off_terms: str = Field(
        default="сними штаны, сними штан, сними брюки, сними портки, take off your pants, remove your trousers, take off pants",
        description="Comma-separated player phrases that trigger legwear_off.",
    )
    armwear_on_terms: str = Field(
        default="надень перчатки, надень наручи, put on your gloves, wear your gloves",
        description="Comma-separated player phrases that trigger armwear_on.",
    )
    armwear_off_terms: str = Field(
        default="сними перчатки, сними наручи, take off your gloves, remove your gloves",
        description="Comma-separated player phrases that trigger armwear_off.",
    )
    neckwear_on_terms: str = Field(
        default="надень ожерелье, надень воротник, put on your necklace, wear your necklace",
        description="Comma-separated player phrases that trigger neckwear_on.",
    )
    neckwear_off_terms: str = Field(
        default="сними ожерелье, сними воротник, take off your necklace, remove your necklace",
        description="Comma-separated player phrases that trigger neckwear_off.",
    )
    bodywear_on_terms: str = Field(
        default="надень куртку, надень броню, надень жилет, put on your jacket, put on your armor, wear your vest",
        description="Comma-separated player phrases that trigger bodywear_on.",
    )
    bodywear_off_terms: str = Field(
        default="сними куртку, сними броню, сними жилет, take off your jacket, take off your armor, remove your vest",
        description="Comma-separated player phrases that trigger bodywear_off.",
    )
    strip_terms: str = Field(
        default="разденься, сними одежду, сними верхнюю одежду, раздеться, strip, undress, take off clothes, take your clothes off",
        description="Comma-separated player phrases that trigger strip_outerwear.",
    )
    draw_weapon_terms: str = Field(default="достань оружие, вынь меч, достань меч, оружие к бою, draw weapon, draw your weapon", description="Comma-separated player phrases that trigger draw_weapon.")
    holster_weapon_terms: str = Field(default="убери оружие, спрячь меч, убери меч, put your weapon away, holster your weapon", description="Comma-separated player phrases that trigger holster_weapon.")
    turn_to_player_terms: str = Field(default="повернись ко мне, смотри на меня, посмотри на меня, обернись, turn to me, look at me", description="Comma-separated player phrases that trigger turn_to_player.")
    come_closer_terms: str = Field(default="подойди, иди сюда, подойди ко мне, ближе, come closer, come here", description="Comma-separated player phrases that trigger come_closer.")
    step_back_terms: str = Field(default="отойди, отойди назад, назад, держись подальше, step back, back off, move away", description="Comma-separated player phrases that trigger step_back.")
    collapse_spell_terms: str = Field(default="фус рода, упади, падай, сломайся, abracadabra fall, collapse, fall down", description="Comma-separated player phrases that trigger collapse_spell.")


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

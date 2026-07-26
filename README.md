# KCD2 AI NPC — AI-Powered Dialogue for Kingdom Come: Deliverance II

Talk to **any NPC** in Kingdom Come: Deliverance II using AI-generated dialogue with voice input/output. The mod uses a local Python server with an LLM to generate contextual, in-character responses, with TTS and STT support. NPCs also live a background life — chatting with each other, reacting to the world, and initiating conversations with you.

[![Steam Workshop](https://img.shields.io/badge/Steam-Workshop-blue?logo=steam)](https://steamcommunity.com/sharedfiles/filedetails/?id=3729594101)

## How It Works

```
Player holds V near NPC → Lua mod detects NPC → HTTP request →
→ Python server (STT → LLM → TTS) →
→ Response text + audio → In-game HUD + audio output

Background life (server-initiated):
→ Server polls nearby NPCs via Lua scan (NEARBY|) →
→ Lightweight LLM generates chatter/solo/re-engage lines →
→ Spatial TTS + lip sync + face emotion → Lua commands back to game
```

**Architecture:**
- **In-game mod** (Lua) — runs inside KCD2, handles UI, NPC detection, and HUD display
- **External server** (Python/FastAPI) — runs locally, handles LLM requests, TTS, and STT

## Features

### Core Dialogue
- Chat with any NPC using voice (push-to-talk) or text input
- LLM generates in-character medieval responses
- **TTS** — NPCs speak aloud (Edge TTS, ElevenLabs, OpenAI TTS)
- **STT** — talk with microphone (Groq Whisper, faster-whisper, OpenAI Whisper)
- Per-NPC conversation memory with automatic context compression
- Multi-language support (en, ru, cs, de, fr, es, pl, zh, ja)
- Web UI for configuration at `http://127.0.0.1:4999`
- Supports Groq, OpenAI, Ollama, and any OpenAI-compatible API
- Custom player name (roleplay as someone other than Henry)

### Background NPC Life
- **NPC-to-NPC chatter** — nearby NPCs hold spontaneous conversations with each other
- **Solo initiative** — NPCs call out to you or other NPCs on their own
- **Re-engage** — if you walk away and stay silent, an NPC calls you back
- **Beckon** — a familiar NPC waves you over to talk (gesture + voice)
- **Interjections** — bystanders comment on your conversation as you pass by
- NPC dialogue adapts to time of day and weather
- NPC internal thoughts (mixed into dialogue context for richer responses)
- Adjustable intensity sliders for chatter and interjections

### Movement & Animation
- NPCs walk toward/away from you using animation (no teleportation)
- **Lip sync** — NPCs move their lips during speech
- **Facial emotions** — expression changes with dialogue mood (friendly, angry, suspicious, afraid, etc.)
- Scene actions: come closer, step back, walk away, gestures, emotions, sit/stand

### Spatial Audio
- **3D voice** — volume and panning based on NPC position relative to camera
- **Real-time panning** — sound follows camera rotation during a line
- Distance attenuation and rear muffling
- Front/back and left/right positioning

### Vision (optional)
- NPC can "see" your screen when you use a trigger word ("look at...")
- Screenshot is attached to the LLM request for visual context
- Requires a vision-capable LLM model

### Web Panel
- Toggles for all features (lip sync, spatial audio, background life, vision, thoughts, interjections)
- Intensity sliders for background life and interjection frequency
- Key NPC editor (custom prompt templates per character)
- Conversation memory block (summaries, manual editing, "forget NPC")
- "Lively" prompt preset (SkyrimNet-inspired immersive roleplay)
- Player persona fields (name + description)
- Light LLM configuration (separate model for background tasks)

### Scene Actions
NPCs can perform in-game actions suggested by the LLM:
- Movement: come closer, step back, walk away
- Gestures: wave, bow, nod, point, beckon, cheer
- Emotions: angry, sad, nervous, happy, surprised
- Equipment: draw/holster weapon, strip/dress
- Posture: sit down, stand up
- Music: play flute, play lute (with instrument prop)

## Requirements

- Kingdom Come: Deliverance II (Steam or GOG, **build 15345** or newer)
- Python 3.12.10 (recommended) — see `requirements.txt`
- One of:
  - [Groq](https://groq.com/) (free tier, cloud) — recommended
  - [Ollama](https://ollama.ai/) (free, local)
  - [OpenAI API](https://platform.openai.com/) key
  - Any OpenAI-compatible API endpoint

## Quick Start

### 1. Install the Game Mod

**Option A — Steam Workshop:** Subscribe to **[AI NPC Dialogue](https://steamcommunity.com/sharedfiles/filedetails/?id=3729594101)**

**Option B — Manual install (GOG / non-Workshop):** Copy `mod/ai_npc/` into `<game_root>/mods/`. See [Manual Installation](#manual-installation-without-steam-workshop) below.

### 2. Server Setup

```bash
git clone https://github.com/KRYSYS1/KCD2.AI.NPC.git
cd kcd2-ai-npc
pip install -r requirements.txt
```

### 3. Configure

The repository already includes `config.json`. Open it and replace `YOUR_GROQ_API_KEY_HERE` with your Groq API key (free at [console.groq.com](https://console.groq.com)). You can also start the server and enter the same keys in the web UI at `http://127.0.0.1:4999`.

If the server cannot find your game automatically, set `game_path` to your KCD2 game root, for example `C:/SteamLibrary/steamapps/common/KingdomComeDeliverance2`:

```json
{
  "game_path": "",
  "language": "en",
  "llm": {
    "api_url": "https://api.groq.com/openai/v1",
    "api_key": "gsk_your_key_here",
    "model": "llama-3.3-70b-versatile"
  },
  "stt": {
    "enabled": true,
    "provider": "groq",
    "api_key": "gsk_your_key_here"
  }
}
```

Or use local Ollama (free, no key): set `llm.api_url` to `http://localhost:11434/v1` and `stt.provider` to `faster-whisper`.

### 4. Start

```bash
python run_server.py
```

Server starts on `http://127.0.0.1:4999`.

### 5. Play

- **Hold V** near any NPC to speak (push-to-talk)
- **Tap V** to open text chat
- Configure at `http://127.0.0.1:4999`

## API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/health` | GET | Server status check |
| `/chat` | POST | Send a message, get NPC response |
| `/end_conversation` | POST | End conversation with an NPC |
| `/reload_characters` | POST | Reload NPC character database |
| `/config` | GET | View current configuration |

### Example Chat Request

```bash
curl -X POST http://127.0.0.1:4999/chat \
  -H "Content-Type: application/json" \
  -d '{
    "npc_id": "npc_father_godwin",
    "npc_name": "Father Godwin",
    "npc_class": "priest",
    "npc_location": "Uzhitz",
    "player_message": "Good day, Father. Do you have any ale?"
  }'
```

## Adding Custom NPCs

Add character definitions to `server/characters/`. Each file is a JSON array:

```json
[
  {
    "name": "Custom NPC",
    "description": "a mysterious traveler from distant lands",
    "location": "Sasau",
    "personality": "secretive, knowledgeable, speaks in riddles",
    "occupation": "traveler",
    "extra_context": "Knows secrets about the ancient monastery."
  }
]
```

Then call `POST /reload_characters` or restart the server.

## Project Structure

```
kcd2-ai-npc/
├── run_server.py               # Server startup script
├── requirements.txt            # Python dependencies
├── config.json                 # Server configuration
├── server/                     # Python FastAPI server
│   ├── main.py                 # FastAPI app & endpoints
│   ├── config.py               # Configuration models
│   ├── llm_client.py           # LLM integration (primary + vision)
│   ├── tts_client.py           # TTS (Edge, ElevenLabs, OpenAI) + spatial audio
│   ├── stt_client.py           # STT (Groq, faster-whisper, OpenAI)
│   ├── key_monitor.py          # Keyboard hook for push-to-talk
│   ├── conversation.py         # Conversation history + context compression
│   ├── npc_context.py          # NPC prompt builder + player persona
│   ├── npc_initiative.py       # Beckon initiative (NPC invites player to talk)
│   ├── ambient.py              # Background NPC life (chatter, solo, re-engage)
│   ├── characters/             # NPC character database (JSON)
│   ├── vision.py               # Screenshot capture for vision LLM
│   └── static/                 # Web UI (config panel)
├── mod/ai_npc/                 # Ready-to-install mod package (copy to <game>/mods/ai_npc/)
│   ├── main.lua                # Mod entry point
│   ├── mod.cfg                 # sys_PakPriority=0 (loose files override pak)
│   ├── mod.manifest            # Mod descriptor
│   ├── npc_token_names.lua     # NPC name database
│   ├── ui_name_keys.lua        # UI localization keys
│   ├── Data/
│   │   └── ai_npc.pak          # Packed mod scripts (ZIP_STORED)
│   └── Localization/
│       ├── English_xml.pak     # English localization
│       └── Russian_xml.pak     # Russian localization
└── config.json                 # Server configuration
```

## Companion Mod (optional)

- **[Player Event Dispatcher](https://steamcommunity.com/sharedfiles/filedetails/?id=1430)** — recommended. Lets AI NPCs know about recent player actions (fighting, stealing, looting, etc.) for richer context. If installed and detected, the mod automatically uses it.

Not required — the mod works on vanilla KCD2 without any DLLs or additional loaders.

## Roadmap

- ✅ Text chat with LLM
- [x] Text chat with LLM
- [x] TTS integration (Edge, ElevenLabs, OpenAI)
- [x] STT integration (Groq, faster-whisper, OpenAI) — push-to-talk
- [x] Web UI for configuration
- [x] Steam Workshop distribution
- [x] Multi-language UI and speech support
- [x] Voice cloning for individual NPCs
- [x] NPC memory persistence (save/load)
- [x] NPC movement (walk animations)
- [x] Lip sync (facial animation layer)
- [x] Facial emotions per dialogue mood
- [x] 3D spatial audio (distance, panning, rear muffling)
- [x] Background NPC life (chatter, solo initiative, re-engage, beckon)
- [x] NPC interjections during player conversations
- [x] NPC internal thoughts
- [x] Vision (screenshots by trigger word)
- [x] Context compression for long conversations
- [x] Custom player name (roleplay beyond Henry)
- [x] Time-of-day and weather context

## Tech Stack

- **Server:** Python 3.12+, FastAPI, OpenAI SDK
- **LLM:** Groq, Ollama, OpenAI, any OpenAI-compatible API (dual-model: primary + lightweight for background tasks)
- **TTS:** Edge TTS, ElevenLabs, OpenAI TTS
- **STT:** Groq Whisper, faster-whisper, OpenAI Whisper
- **Game mod:** Lua, CryEngine HUD system, file-based IPC (kcd.log + command.lua/resp.lua)
- **Audio:** pygame mixer with spatial volume/panning, low-pass distance filtering

## Manual Installation (without Steam Workshop)

> Works on GOG, Epic, and Steam. Requires KCD2 **build 153645 or newer**.

1. Find your KCD2 game root — the folder where `Bin/Win64MasterMasterGogPGO/KingdomCome.exe` (GOG) or `Bin/Win64MasterMasterSteamPGO/KingdomCome.exe` (Steam) is located.

2. Copy `mod/ai_npc/` into `<game_root>/mods/`:

```
<game_root>/mods/ai_npc/
├── main.lua
├── mod.cfg
├── mod.manifest
├── npc_token_names.lua
├── ui_name_keys.lua
├── Data/
│   └── ai_npc.pak
└── Localization/
    ├── English_xml.pak
    └── Russian_xml.pak
```

3. Launch KCD2 — the mod is loaded automatically (no additional DLLs or dependencies needed).

**Note:** For Steam users, it's recommended to use [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3729594101).

## License

MIT

## Credits

- [Warhorse Studios](https://warhorsestudios.cz/) for Kingdom Come: Deliverance II
- Inspired by SkyrimNet

# KCD2 AI NPC — AI-Powered Dialogue for Kingdom Come: Deliverance II

Talk to **any NPC** in Kingdom Come: Deliverance II using AI-generated dialogue with voice input/output. The mod uses a local Python server with an LLM to generate contextual, in-character responses, with TTS and STT support.

[![Steam Workshop](https://img.shields.io/badge/Steam-Workshop-blue?logo=steam)](https://steamcommunity.com/sharedfiles/filedetails/?id=3729594101)

## How It Works

```
Player holds V near NPC → Lua mod detects NPC → HTTP request →
→ Python server (STT → LLM → TTS) →
→ Response text + audio → In-game HUD + audio output
```

**Architecture:**
- **In-game mod** (Lua) — runs inside KCD2, handles UI, NPC detection, and HUD display
- **External server** (Python/FastAPI) — runs locally, handles LLM requests, TTS, and STT

## Features

- Chat with any NPC using voice (push-to-talk) or text input
- LLM generates in-character medieval responses
- **TTS** — NPCs speak aloud (Edge TTS, ElevenLabs, OpenAI TTS)
- **STT** — talk with microphone (Groq Whisper, faster-whisper, OpenAI Whisper)
- Per-NPC conversation memory
- Multi-language support (en, ru, cs, de, fr, es, pl, zh, ja)
- Web UI for configuration at `http://127.0.0.1:4999`
- Supports Groq, OpenAI, Ollama, and any OpenAI-compatible API

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
│   ├── llm_client.py           # LLM integration
│   ├── tts_client.py           # TTS (Edge, ElevenLabs, OpenAI)
│   ├── stt_client.py           # STT (Groq, faster-whisper, OpenAI)
│   ├── key_monitor.py          # Keyboard hook for push-to-talk
│   ├── conversation.py         # Conversation history manager
│   ├── npc_context.py          # NPC prompt builder
│   └── static/                 # Web UI (config panel)
├── mod/ai_npc/                 # Ready-to-install mod package (copy to <game>/mods/ai_npc/)
│   ├── main.lua                # Mod entry point
│   ├── mod.cfg                 # ReturnOfModding config
│   ├── mod.manifest            # Mod descriptor
│   ├── npc_token_names.lua     # NPC name database
│   ├── ui_name_keys.lua        # UI localization keys
│   ├── Data/
│   │   └── ai_npc.pak          # Packed mod scripts (ZIP_STORED)
│   └── Localization/
│       ├── English_xml.pak     # English localization
│       └── Russian_xml.pak     # Russian localization
└── build/                      # Pre-packaging source files (Lua scripts, XML, config)
    ├── Data/
    │   ├── Scripts/ai_npc/     # Lua scripts, command.lua
    │   ├── Libs/Config/        # Action map (V key binding)
    │   └── Scripts/Utils/      # Bootstrap script
    ├── Localization/           # Localization XML source
    ├── mods/ai_npc/            # mod.cfg, mod.manifest
    └── scripts/mods/           # ai_npc.lua bootstrap
```

## Roadmap

- [x] Text chat with LLM
- [x] TTS integration (Edge, ElevenLabs, OpenAI)
- [x] STT integration (Groq, faster-whisper, OpenAI) — push-to-talk
- [x] Web UI for configuration
- [x] Steam Workshop distribution
- [x] Multi-language UI and speech support
- [x] Voice cloning for individual NPCs
- [ ] Native dialogue system integration
- [x] NPC memory persistence (save/load)
- [ ] Lip sync via CryEngine animation system

## Tech Stack

- **Server:** Python 3.12+, FastAPI, OpenAI SDK
- **LLM:** Groq, Ollama, OpenAI, any OpenAI-compatible API
- **TTS:** Edge TTS, ElevenLabs, OpenAI TTS
- **STT:** Groq Whisper, faster-whisper, OpenAI Whisper
- **Game mod:** Lua, CryEngine HUD system

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

- Inspired by SkyrimNet
- [Warhorse Studios](https://warhorsestudios.cz/) for Kingdom Come: Deliverance II
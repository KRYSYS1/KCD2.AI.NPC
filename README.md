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

### Server
- Python 3.10+
- One of:
  - [Groq](https://console.groq.com/) (free tier, cloud) — recommended
  - [Ollama](https://ollama.ai/) (free, local)
  - [OpenAI API](https://platform.openai.com/) key
  - Any OpenAI-compatible API endpoint

### Game Mod
- Kingdom Come: Deliverance II (Steam, GOG, Epic)

## Quick Start

### 1. Install the Game Mod

**Option A — Steam Workshop:** Subscribe to **[AI NPC Dialogue](https://steamcommunity.com/sharedfiles/filedetails/?id=3729594101)**

**Option B — Manual install:** Copy the contents of `game_files/` into your KCD2 game root. See [Manual Installation](#manual-installation-without-steam-workshop) below.

### 2. Server Setup

```bash
git clone https://github.com/KRYSYS1/KCD2.AI.NPC.git
cd kcd2-ai-npc
pip install -r requirements.txt
```

### 3. Configure

The repository already includes `config.json`. Open it and replace `YOUR_GROQ_API_KEY_HERE` with your Groq API key (free at [console.groq.com](https://console.groq.com)). You can also start the server and enter the same keys in the web UI at `http://127.0.0.1:4999`.

If the server cannot find your game automatically, set `game_path` to your KCD2 game root, for example `C:\SteamLibrary\steamapps\common\KingdomComeDeliverance2`:

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
├── mod/                        # KCD2 Lua mod
│   └── ai_npc/
│       ├── main.lua            # Mod entry point
│       ├── npc_token_names.lua # NPC name database
│       └── ui_name_keys.lua    # UI localization keys
├── game_files/                 # Mod files — copy into KCD2 game root for manual install
│   ├── scripts/
│   │   └── mods/
│   │       └── ai_npc.lua      # Bootstrap script
│   ├── Data/
│   │   ├── Scripts/ai_npc/     # Lua mod scripts
│   │   └── Libs/Config/        # Action map (V key binding)
│   └── Localization/           # UI text (en, ru)
```

## Roadmap

- [x] Text chat with LLM
- [x] TTS integration (Edge, ElevenLabs, OpenAI)
- [x] STT integration (Groq, faster-whisper, OpenAI) — push-to-talk
- [x] Web UI for configuration
- [x] Steam Workshop distribution
- [x] Multi-language UI and speech support
- [ ] Voice cloning for individual NPCs
- [ ] Native dialogue system integration
- [ ] NPC memory persistence (save/load)
- [ ] Lip sync via CryEngine animation system

## Tech Stack

- **Server:** Python 3.10+, FastAPI, OpenAI SDK
- **LLM:** Groq, Ollama, OpenAI, any OpenAI-compatible API
- **TTS:** Edge TTS, ElevenLabs, OpenAI TTS
- **STT:** Groq Whisper, faster-whisper, OpenAI Whisper
- **Game mod:** Lua, CryEngine HUD system

## Manual Installation (without Steam Workshop)

Copy the contents of `game_files/` into your KCD2 game root (the folder containing `Bin\`):

```
Kingdom Come Deliverance II\          ← game root (e.g. E:\Games\Kingdom Come Deliverance II)
├── Bin\Win64MasterMasterGogPGO\
│   ├── KingdomCome.exe               ← game executable
│   ├── version.dll                   ← add DLL (modified KCD2ModLoader by xiaoxiao921)
│   └── plugins\ai_npc\               ← add folder
│       ├── main.lua
│       └── manifest.json
├── Bin\Win64MasterMasterSteamPGO\
│   ├── KingdomCome.exe               ← game executable
│   ├── version.dll                   ← add DLL (same build as GOG package)
│   └── plugins\ai_npc\               ← add folder
│       ├── main.lua
│       └── manifest.json
├── scripts\
│   └── mods\
│       └── ai_npc.lua                ← add file
├── Data\\
|   ├── Scripts\\
|   |   ├── ai_npc\\                   <- add folder
|   |   |   ├── main.lua
|   |   |   ├── command.lua
|   |   |   ├── npc_token_names.lua
|   |   |   └── ui_name_keys.lua
|   |   └── Utils\\
|   |       └── ai_npc_init.lua        <- Lua bootstrap used by manual installs
|   └── Libs\\Config\\
|       └── ai_npc_actions.xml        <- add file
├── Localization\\                     <- add folder (merge)
|   ├── text__ai_npc.xml
|   ├── English_xml\\
|   |   └── text__ai_npc.xml
|   └── Russian_xml\\
|       └── text__ai_npc.xml
└── mods\\ai_npc\\                      <- add folder
    ├── mod.cfg
    ├── mod.manifest
    └── Localization\\
        ├── English_xml.pak
        └── Russian_xml.pak
```

**One-command install:**

Run this from the extracted repository folder:

```bat
python install_mod.py "C:\SteamLibrary\steamapps\common\KingdomComeDeliverance2"
python install_mod.py "D:\Program Files (x86)\Steam\steamapps\common\KingdomComeDeliverance2"
```

GOG examples:

```bat
python install_mod.py "E:\Games\Kingdom Come Deliverance II"
python install_mod.py "C:\GOG Games\KingdomComeDeliverance2"
```

The installer copies everything from `game_files\` into the game root automatically.

**Manual copy steps:**
1. Find your game root — the folder where `Bin\Win64MasterMasterGogPGO\KingdomCome.exe` (GOG) or `Bin\Win64MasterMasterSteamPGO\KingdomCome.exe` (Steam) is located
2. Copy everything from `game_files\` into the game root, merging folders when prompted
3. The mod loads automatically on next launch

The repository ships both `Win64MasterMasterGogPGO` and `Win64MasterMasterSteamPGO` so manual installs work for either storefront without renaming folders by hand.

**One-command uninstall:**

Remove installed game mod files from Steam/GOG game folder:

```bat
python uninstall_mod.py "C:\SteamLibrary\steamapps\common\KingdomComeDeliverance2"
python uninstall_mod.py "D:\Program Files (x86)\Steam\steamapps\common\KingdomComeDeliverance2"
python uninstall_mod.py "C:\GOG Games\KingdomComeDeliverance2"
```

Skip the confirmation prompt if needed:

```bat
python uninstall_mod.py "C:\SteamLibrary\steamapps\common\KingdomComeDeliverance2" --yes
```

**Remove Python dependencies:**

If you installed dependencies globally and want to remove them:

```bat
pip uninstall -r requirements.txt -y
```

If you used a virtual environment, just delete the virtual environment folder instead.

## License

MIT

## Credits

- Inspired by SkyrimNet
- [Warhorse Studios](https://warhorsestudios.cz/) for Kingdom Come: Deliverance II

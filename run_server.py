#!/usr/bin/env python3
"""Startup script for the KCD2 AI NPC server."""

import uvicorn
from server.config import ServerConfig
from server.main import config

if __name__ == "__main__":
    print("=" * 50)
    print("  KCD2 AI NPC Server")
    print("=" * 50)
    print(f"  LLM:      {config.llm.model}")
    print(f"  API:      {config.llm.api_url}")
    print(f"  Language:  {config.language}")
    print(f"  TTS:       {'ON' if config.tts.enabled else 'OFF'} ({config.tts.engine})")
    print(f"  STT:       {'ON' if config.stt.enabled else 'OFF'}")
    print("=" * 50)
    print(f"  Starting on http://{config.host}:{config.port}")
    print("=" * 50)
    uvicorn.run(
        "server.main:app",
        host=config.host,
        port=config.port,
        reload=False,
    )

#!/usr/bin/env python3
"""Startup script for the KCD2 AI NPC server."""

import uvicorn
from server.config import ServerConfig
from server.main import config

try:
    from rich.console import Console
    from pyfiglet import figlet_format
    RICH = True
except ImportError:
    RICH = False

def print_banner():
    if not RICH:
        print("=" * 50)
        print("  KCD2 AI NPC Server")
        print("=" * 50)
        print(f"  LLM:       {config.llm.model}")
        print(f"  API:       {config.llm.api_url}")
        print(f"  Language:  {config.language}")
        print(f"  TTS:       {'ON' if config.tts.enabled else 'OFF'} ({config.tts.engine})")
        print(f"  STT:       {'ON' if config.stt.enabled else 'OFF'}")
        print("=" * 50)
        print(f"  Starting on http://{config.host}:{config.port}")
        print("=" * 50)
        return

    console = Console()

    art = figlet_format("KCD2  AI  NPC", font="slant")
    console.print(f"[bold yellow]{art}[/]")

    tts_status = f"[green]ON[/green]  ({config.tts.engine})" if config.tts.enabled else "[red]OFF[/red]"
    stt_status = "[green]ON[/green]" if config.stt.enabled else "[red]OFF[/red]"

    console.print(f"  [dim]LLM      [/dim] [cyan]{config.llm.model}[/cyan]")
    console.print(f"  [dim]API      [/dim] [cyan]{config.llm.api_url}[/cyan]")
    console.print(f"  [dim]Language [/dim] {config.language.upper()}")
    console.print(f"  [dim]TTS      [/dim] {tts_status}")
    console.print(f"  [dim]STT      [/dim] {stt_status}")
    console.print(f"  [dim]URL      [/dim] [bold green]http://{config.host}:{config.port}[/bold green]")
    console.print()
    console.print("[dim]Starting uvicorn...[/dim]\n")


if __name__ == "__main__":
    print_banner()
    uvicorn.run(
        "server.main:app",
        host=config.host,
        port=config.port,
        reload=False,
    )

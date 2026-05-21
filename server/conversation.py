"""Conversation manager — tracks per-NPC dialogue history."""

import json
import time
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Conversation:
    npc_name: str
    system_prompt: str
    messages: list[dict[str, str]] = field(default_factory=list)
    created_at: float = field(default_factory=time.time)
    last_active: float = field(default_factory=time.time)

    def add_user_message(self, text: str) -> None:
        self.messages.append({"role": "user", "content": text})
        self.last_active = time.time()

    def add_assistant_message(self, text: str) -> None:
        self.messages.append({"role": "assistant", "content": text})
        self.last_active = time.time()

    def get_messages(self, max_history: int = 20) -> list[dict[str, str]]:
        """Return the last N messages for context window management."""
        return self.messages[-max_history:]

    def is_expired(self, timeout: float = 600.0) -> bool:
        return (time.time() - self.last_active) > timeout


class ConversationManager:
    def __init__(self, max_history: int = 20, timeout: float = 600.0, storage_dir: str = "memory/conversations"):
        self._conversations: dict[str, Conversation] = {}
        self._max_history = max_history
        self._timeout = timeout
        self._storage_dir = Path(storage_dir)
        self._storage_dir.mkdir(parents=True, exist_ok=True)

    def get_or_create(self, npc_id: str, npc_name: str, system_prompt: str) -> Conversation:
        self._cleanup()
        if npc_id in self._conversations:
            conv = self._conversations[npc_id]
            conv.system_prompt = system_prompt
            return conv
        conv = self._load(npc_id, npc_name, system_prompt)
        self._conversations[npc_id] = conv
        return conv

    def end(self, npc_id: str) -> None:
        if npc_id in self._conversations:
            self._save(npc_id, self._conversations[npc_id])
        self._conversations.pop(npc_id, None)

    def save(self, npc_id: str) -> None:
        if npc_id in self._conversations:
            self._save(npc_id, self._conversations[npc_id])

    def end_all(self) -> None:
        for npc_id, conv in self._conversations.items():
            self._save(npc_id, conv)
        self._conversations.clear()

    def clear_all(self) -> int:
        """Drop all in-memory conversations AND wipe persisted history. Returns # files deleted."""
        self._conversations.clear()
        deleted = 0
        if self._storage_dir.exists():
            for path in self._storage_dir.glob("*.json"):
                try:
                    path.unlink()
                    deleted += 1
                except OSError:
                    pass
        return deleted

    def _cleanup(self) -> None:
        expired = [k for k, v in self._conversations.items() if v.is_expired(self._timeout)]
        for k in expired:
            self._save(k, self._conversations[k])
            del self._conversations[k]

    def _path_for(self, npc_id: str) -> Path:
        safe = "".join(ch if ch.isalnum() or ch in ("-", "_") else "_" for ch in npc_id)[:120]
        return self._storage_dir / f"{safe}.json"

    def _load(self, npc_id: str, npc_name: str, system_prompt: str) -> Conversation:
        path = self._path_for(npc_id)
        if not path.exists():
            return Conversation(npc_name=npc_name, system_prompt=system_prompt)
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            messages = data.get("messages", [])
            if not isinstance(messages, list):
                messages = []
            return Conversation(
                npc_name=data.get("npc_name", npc_name),
                system_prompt=system_prompt,
                messages=messages[-self._max_history:],
                created_at=float(data.get("created_at", time.time())),
                last_active=float(data.get("last_active", time.time())),
            )
        except Exception:
            return Conversation(npc_name=npc_name, system_prompt=system_prompt)

    def _save(self, npc_id: str, conv: Conversation) -> None:
        path = self._path_for(npc_id)
        data = {
            "npc_id": npc_id,
            "npc_name": conv.npc_name,
            "created_at": conv.created_at,
            "last_active": conv.last_active,
            "messages": conv.messages[-self._max_history:],
        }
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

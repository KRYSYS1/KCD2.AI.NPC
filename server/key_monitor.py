"""Server-side V-key monitor for the smart-V (push-to-talk) flow.

CryEngine's "+" / "-" console-bind prefix that would normally give us
separate press / release callbacks fires both events on key-down in the
current KCD2 build (see mod/ai_npc/main.lua docstring on the Push-to-talk
section). To keep the smart-V design — *tap* opens the text overlay,
*hold* records the microphone — we side-step the engine entirely and
poll the keyboard via Win32 ``GetAsyncKeyState`` from a Python thread.

Overview of the state machine handled by :class:`KeyMonitor`:

* press  → store ``press_at`` timestamp.
* still pressed at ``threshold_ms``  → call ``on_hold_start`` (start mic).
* release before threshold           → call ``on_tap``        (open overlay).
* release after  threshold            → call ``on_hold_end``   (stop+submit).

Callbacks may be invoked from a background thread; main.py wraps any async
work via ``asyncio.run_coroutine_threadsafe``.

The implementation is Windows-only (KCD2 is Windows-only); on other
platforms ``start()`` becomes a no-op.
"""
from __future__ import annotations

import logging
import sys
import threading
import time
from typing import Callable, Optional

logger = logging.getLogger(__name__)

# Mapping from the chat_key strings the user can configure (single character
# or function key) to Windows virtual-key codes. Covers the common cases —
# extend as needed.
_VK_MAP: dict[str, int] = {
    **{c: 0x30 + i for i, c in enumerate("0123456789")},  # 0..9
    **{c: 0x41 + (ord(c) - ord("a")) for c in "abcdefghijklmnopqrstuvwxyz"},
    "space": 0x20,
    "tab": 0x09,
    "enter": 0x0D,
    "f1": 0x70, "f2": 0x71, "f3": 0x72, "f4": 0x73, "f5": 0x74,
    "f6": 0x75, "f7": 0x76, "f8": 0x77, "f9": 0x78, "f10": 0x79,
    "f11": 0x7A, "f12": 0x7B,
}


def _resolve_vk(key: str) -> Optional[int]:
    if not key:
        return None
    return _VK_MAP.get(key.strip().lower())


class KeyMonitor:
    """Background thread that detects tap / hold transitions on a single key.

    Parameters
    ----------
    chat_key:
        The key bound to the AI-NPC chat (defaults to "v"). The monitor only
        reacts to this exact key; if the configured key isn't in :data:`_VK_MAP`
        the monitor logs a warning and stays idle.
    threshold_ms:
        Hold threshold separating taps from holds.
    poll_interval_ms:
        How often we sample the key state. Lower = lower latency but more CPU.
        25 ms gives ~40 Hz sampling, well below the ``threshold_ms`` floor of
        100 ms while staying invisible CPU-wise.
    on_tap, on_hold_start, on_hold_end:
        Callbacks invoked on the corresponding state transitions. They run
        on the monitor's own thread; keep them lightweight or hand off to an
        executor / asyncio loop.
    """

    def __init__(
        self,
        chat_key: str = "v",
        threshold_ms: int = 200,
        poll_interval_ms: int = 25,
        on_tap: Optional[Callable[[], None]] = None,
        on_hold_start: Optional[Callable[[], None]] = None,
        on_hold_end: Optional[Callable[[float], None]] = None,
    ) -> None:
        self._chat_key = chat_key
        self._threshold_ms = max(50, int(threshold_ms))
        self._poll_interval_ms = max(5, int(poll_interval_ms))
        self.on_tap = on_tap
        self.on_hold_start = on_hold_start
        self.on_hold_end = on_hold_end

        self._stop_evt = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._user32 = None
        self._vk: Optional[int] = None
        # When ``_paused`` is True the worker thread keeps spinning but does
        # not look at the keyboard. main.py sets this while the text overlay
        # is open so the player can type words containing the configured key
        # ("vvvv" in the entry) without the tap/hold callbacks firing.
        self._paused: bool = False

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------
    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        if not sys.platform.startswith("win"):
            logger.warning("KeyMonitor: non-Windows platform — disabled")
            return
        try:
            import ctypes
            self._user32 = ctypes.windll.user32  # type: ignore[attr-defined]
        except Exception as exc:
            logger.error(f"KeyMonitor: failed to load user32: {exc}")
            return
        self._vk = _resolve_vk(self._chat_key)
        if self._vk is None:
            logger.warning(
                f"KeyMonitor: unsupported chat_key={self._chat_key!r} — "
                f"key monitor will stay idle (add to _VK_MAP if needed)"
            )
            return
        self._stop_evt.clear()
        self._thread = threading.Thread(
            target=self._run, daemon=True, name="key-monitor"
        )
        self._thread.start()
        logger.info(
            f"KeyMonitor started: key={self._chat_key!r} (VK=0x{self._vk:02X}) "
            f"threshold={self._threshold_ms}ms poll={self._poll_interval_ms}ms"
        )

    def stop(self) -> None:
        self._stop_evt.set()
        t = self._thread
        if t and t.is_alive():
            t.join(timeout=1.0)
        self._thread = None
        logger.info("KeyMonitor stopped")

    def set_paused(self, paused: bool) -> None:
        """Temporarily ignore the V key without tearing down the worker.

        main.py flips this on whenever the in-game text overlay is shown so
        the user can include the configured chat key in their typed message
        without triggering tap / hold callbacks. The state machine in
        :meth:`_run` resets its press tracker when transitioning into the
        paused state so a still-held key on resume is treated as a fresh
        press.
        """
        if self._paused == bool(paused):
            return
        self._paused = bool(paused)
        logger.info(f"KeyMonitor: paused={self._paused}")

    def update_config(
        self,
        chat_key: Optional[str] = None,
        threshold_ms: Optional[int] = None,
    ) -> None:
        """Hot-restart the monitor when the user changes chat_key / threshold
        in the web UI. Cheaper than recreating the whole object — same
        callbacks stay wired up.
        """
        restart = False
        if chat_key is not None and chat_key != self._chat_key:
            self._chat_key = chat_key
            restart = True
        if threshold_ms is not None and int(threshold_ms) != self._threshold_ms:
            self._threshold_ms = max(50, int(threshold_ms))
            # Threshold change doesn't require an OS-level restart, but a
            # bounce keeps the state machine clean.
            restart = True
        if restart:
            logger.info(
                f"KeyMonitor: reconfiguring "
                f"key={self._chat_key} threshold={self._threshold_ms}ms"
            )
            self.stop()
            self.start()

    # ------------------------------------------------------------------
    # Worker
    # ------------------------------------------------------------------
    def _is_pressed(self) -> bool:
        # GetAsyncKeyState returns a SHORT where the high bit (0x8000) is set
        # when the key is currently down. We don't care about the "since last
        # call" low bit — we maintain our own edge tracking with `was_down`.
        # Cast through ctypes.c_short so the sign bit is preserved on the
        # 0x8000 mask.
        try:
            v = self._user32.GetAsyncKeyState(self._vk)  # type: ignore[union-attr]
        except Exception as exc:
            logger.debug(f"GetAsyncKeyState failed: {exc}")
            return False
        # Some Python ctypes returns int, some short — normalize.
        return bool(v & 0x8000)

    def _run(self) -> None:
        was_down = False
        press_at: Optional[float] = None
        hold_started = False
        threshold_s = self._threshold_ms / 1000.0
        poll_s = self._poll_interval_ms / 1000.0

        while not self._stop_evt.is_set():
            # While paused (text overlay open) skip all detection and
            # forget any in-progress press so the user can type words
            # containing the chat key. When the pause is lifted we re-arm
            # from a clean slate.
            if self._paused:
                if was_down or press_at is not None or hold_started:
                    was_down = False
                    press_at = None
                    hold_started = False
                self._stop_evt.wait(timeout=poll_s)
                continue

            now_down = self._is_pressed()
            now = time.monotonic()

            # ---------- rising edge: key just pressed ----------
            if now_down and not was_down:
                press_at = now
                hold_started = False

            # ---------- still pressed: maybe promote to hold ----------
            elif now_down and was_down and not hold_started and press_at is not None:
                if (now - press_at) >= threshold_s:
                    hold_started = True
                    self._safe_call(self.on_hold_start, "on_hold_start")

            # ---------- falling edge: key just released ----------
            elif (not now_down) and was_down:
                duration = (now - press_at) if press_at is not None else 0.0
                if hold_started:
                    self._safe_call_arg(self.on_hold_end, duration, "on_hold_end")
                else:
                    # Sub-threshold press — treat as tap.
                    self._safe_call(self.on_tap, "on_tap")
                press_at = None
                hold_started = False

            was_down = now_down
            self._stop_evt.wait(timeout=poll_s)

    @staticmethod
    def _safe_call(cb: Optional[Callable[[], None]], name: str) -> None:
        if cb is None:
            return
        try:
            cb()
        except Exception:
            logger.exception(f"KeyMonitor callback {name} raised")

    @staticmethod
    def _safe_call_arg(cb: Optional[Callable[[float], None]], arg: float, name: str) -> None:
        if cb is None:
            return
        try:
            cb(arg)
        except Exception:
            logger.exception(f"KeyMonitor callback {name} raised")

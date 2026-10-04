"""Server-side V-key monitor for the smart-V (push-to-talk) flow.

CryEngine's "+" / "-" console-bind prefix that would normally give us
separate press / release callbacks fires both events on key-down in the
current KCD2 build (see mod/ai_npc/main.lua docstring on the Push-to-talk
section). To keep the smart-V design — *tap* opens the text overlay,
*hold* records the microphone — we side-step the engine entirely and
monitor the keyboard ourselves.

Overview of the state machine handled by :class:`KeyMonitor`:

* press  → store ``press_at`` timestamp.
* still pressed at ``threshold_ms``  → call ``on_hold_start`` (start mic).
* release before threshold           → call ``on_tap``        (open overlay).
* release after  threshold            → call ``on_hold_end``   (stop+submit).

Callbacks may be invoked from a background thread; main.py wraps any async
work via ``asyncio.run_coroutine_threadsafe``.

Backends (tried in order):

1. **Win32 ``GetAsyncKeyState``** (primary on Windows) — polls the keyboard
   from a daemon thread. No extra dependencies.
2. **pynput** (fallback on Linux/X11, also works on Windows) — event-driven
   ``keyboard.Listener`` with ``on_press`` / ``on_release`` callbacks.
   Requires the optional ``pynput`` package (``pip install pynput``).
   On Wayland, global keyboard capture is blocked by the compositor's
   security model — pynput will fail to start and ``start()`` returns
   ``False`` so the Lua console-toggle fallback takes over.

When neither backend can start, ``start()`` returns ``False`` and the caller
notifies the Lua mod via ``__AI_NPC_KEYMON_OFFLINE__`` so V still works for
text chat through the legacy console-toggle path (voice/PTT unavailable).
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


# ---------------------------------------------------------------------------
# XInput (gamepad) support
# ---------------------------------------------------------------------------
# Gamepad chat button, polled server-side through XInput and OR-ed into the
# same tap/hold state machine as the keyboard key. The game still sees the
# raw button press — players should pick a button they don't use in combat.

XINPUT_BUTTONS: dict[str, int] = {
    "a": 0x1000, "b": 0x2000, "x": 0x4000, "y": 0x8000,
    "lb": 0x0100, "rb": 0x0200,
    "back": 0x0020, "start": 0x0010,
    "lstick": 0x0040, "rstick": 0x0080,
    "dpad_up": 0x0001, "dpad_down": 0x0002, "dpad_left": 0x0004, "dpad_right": 0x0008,
}


def normalize_pad_button(value: str, allow_empty: bool = True) -> str:
    """Validate a gamepad button name from the web panel. Empty = disabled."""
    name = (value or "").strip().lower()
    if not name:
        return "" if allow_empty else ""
    return name if name in XINPUT_BUTTONS else ""


_XINPUT_STATE = None  # ctypes Structure class, lazily built


def _load_xinput():
    """Return (XInputGetState callable, state type) or None. Windows only."""
    global _XINPUT_STATE
    if not sys.platform.startswith("win"):
        return None
    try:
        import ctypes
        last_exc = None
        for dll_name in ("xinput1_4", "xinput1_3", "xinput9_1_0"):
            try:
                xinput = ctypes.WinDLL(dll_name)
                break
            except OSError as exc:
                last_exc = exc
        else:
            logger.warning(f"KeyMonitor: no xinput dll found ({last_exc})")
            return None
        if _XINPUT_STATE is None:
            class _Gamepad(ctypes.Structure):
                _fields_ = [
                    ("wButtons", ctypes.c_ushort),
                    ("bLeftTrigger", ctypes.c_ubyte),
                    ("bRightTrigger", ctypes.c_ubyte),
                    ("sThumbLX", ctypes.c_short),
                    ("sThumbLY", ctypes.c_short),
                    ("sThumbRX", ctypes.c_short),
                    ("sThumbRY", ctypes.c_short),
                ]

            class _State(ctypes.Structure):
                _fields_ = [("dwPacketNumber", ctypes.c_ulong), ("Gamepad", _Gamepad)]

            _XINPUT_STATE = _State
        get_state = xinput.XInputGetState
        get_state.restype = ctypes.c_ulong  # ERROR_SUCCESS / ERROR_DEVICE_NOT_CONNECTED
        get_state.argtypes = [ctypes.c_ulong, ctypes.POINTER(_XINPUT_STATE)]
        return get_state
    except Exception as exc:
        logger.warning(f"KeyMonitor: xinput load failed: {exc}")
        return None


# ---------------------------------------------------------------------------
# pygame / SDL2 game-controller fallback
# ---------------------------------------------------------------------------
# XInput only sees Xbox-style devices. DualShock 4 / DualSense connected
# without Steam Input (or DS4Windows) are invisible to it. SDL2 (already a
# dependency via pygame) talks to Sony pads natively through its hidapi
# driver and exposes them through the standard game-controller layout, so
# the button mapping below is layout-independent.

# SDL_GameControllerButton enum values (stable across SDL2): cross→0, circle→1,
# square→2, triangle→3, etc. pygame._sdl2.controller exposes no named constants.
_PAD_GC_BUTTONS: dict[str, int] = {
    "a": 0, "b": 1, "x": 2, "y": 3,
    "back": 4, "start": 6,
    "lstick": 7, "rstick": 8,
    "lb": 9, "rb": 10,
    "dpad_up": 11, "dpad_down": 12, "dpad_left": 13, "dpad_right": 14,
}


def _load_pygame_controller():
    """Return the pygame._sdl2.controller module (initialized) or None."""
    try:
        import pygame
        from pygame._sdl2 import controller as sdl_controller
        sdl_controller.init()
        return sdl_controller
    except Exception as exc:
        logger.info(f"KeyMonitor: pygame game-controller API unavailable ({exc})")
        return None


def _pynput_key_matches(key_obj, chat_key: str) -> bool:
    """Check whether a pynput KeyCode / Key object matches the configured key.

    pynput represents character keys as ``KeyCode(char='v')`` and special
    keys as ``Key.space``, ``Key.enter``, etc. Function keys arrive as
    ``KeyCode(char=None, vk=70)`` on Windows or ``Key.f1`` on Linux.
    """
    if key_obj is None:
        return False
    target = chat_key.strip().lower()
    # Character key (most common: "v", "a", etc.)
    char = getattr(key_obj, "char", None)
    if char is not None:
        return char.lower() == target
    # Special keys via pynput.keyboard.Key enum
    from pynput import keyboard  # type: ignore[import-not-found]
    special_map = {
        "space": keyboard.Key.space,
        "tab": keyboard.Key.tab,
        "enter": keyboard.Key.enter,
    }
    if target in special_map and key_obj == special_map[target]:
        return True
    # Function keys — pynput uses Key.f1 .. Key.f12 on Linux, KeyCode(vk=NN)
    # on Windows. Check both forms.
    if target.startswith("f") and target[1:].isdigit():
        fn_num = int(target[1:])
        if 1 <= fn_num <= 12:
            try:
                fn_key = getattr(keyboard.Key, f"f{fn_num}")
                if key_obj == fn_key:
                    return True
            except AttributeError:
                pass
    return False


class KeyMonitor:
    """Background monitor that detects tap / hold transitions on a single key.

    Parameters
    ----------
    chat_key:
        The key bound to the AI-NPC chat (defaults to "v"). The monitor only
        reacts to this exact key; if the configured key isn't recognised
        the monitor logs a warning and stays idle.
    threshold_ms:
        Hold threshold separating taps from holds.
    poll_interval_ms:
        How often we sample the key state (Win32 polling backend only).
        Lower = lower latency but more CPU.  25 ms gives ~40 Hz sampling,
        well below the ``threshold_ms`` floor of 100 ms while staying
        invisible CPU-wise.
    on_tap, on_hold_start, on_hold_end:
        Callbacks invoked on the corresponding state transitions. They run
        on the monitor's own thread; keep them lightweight or hand off to
        an executor / asyncio loop.
    """

    def __init__(
        self,
        chat_key: str = "v",
        threshold_ms: int = 200,
        poll_interval_ms: int = 25,
        pad_button: str = "",
        on_tap: Optional[Callable[[], None]] = None,
        on_hold_start: Optional[Callable[[], None]] = None,
        on_hold_end: Optional[Callable[[float], None]] = None,
    ) -> None:
        self._chat_key = chat_key
        self._pad_button = normalize_pad_button(pad_button)
        self._threshold_ms = max(50, int(threshold_ms))
        self._poll_interval_ms = max(5, int(poll_interval_ms))
        self.on_tap = on_tap
        self.on_hold_start = on_hold_start
        self.on_hold_end = on_hold_end

        self._stop_evt = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._user32 = None
        self._vk: Optional[int] = None
        self._xinput = None  # XInputGetState callable (None = gamepad disabled/unavailable)
        self._xinput_state = None  # reusable XINPUT_STATE buffer
        self._sdl_ctrl = None  # pygame._sdl2.controller module (Sony pads fallback)
        self._ctrl = None  # cached sdl_controller.Controller(0)
        self._listener = None  # pynput listener (Linux/X11 fallback)
        self._hold_timer: Optional[threading.Timer] = None
        self._backend = ""  # "win32", "pynput", or ""
        # When ``_paused`` is True the worker thread keeps spinning but does
        # not look at the keyboard. main.py sets this while the text overlay
        # is open so the player can type words containing the configured key
        # ("vvvv" in the entry) without the tap/hold callbacks firing.
        self._paused: bool = False

        # Shared state machine state — used by both the polling loop and the
        # event-driven pynput callbacks. Guarded by _sm_lock so concurrent
        # on_press / on_release invocations don't race.
        self._sm_lock = threading.Lock()
        self._sm_was_down = False
        self._sm_press_at: Optional[float] = None
        self._sm_hold_started = False

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------
    def start(self) -> bool:
        """Start the key monitor thread.

        Returns ``True`` if the monitor is running (either already alive or
        just started), ``False`` if it could not start (non-Windows platform
        without pynput, user32 load failure, unsupported chat key, or pynput
        unavailable / blocked by the compositor).  The caller uses the
        return value to decide whether to notify the Lua mod that the
        server-side tap/hold pipeline is unavailable so it can fall back to
        the legacy console-driven toggle.
        """
        if self._thread and self._thread.is_alive():
            return True
        if self._listener is not None:
            return True

        # Backend 1: Win32 GetAsyncKeyState (Windows, no deps)
        if self._try_start_win32():
            return True

        # Backend 2: pynput (Linux/X11, also Windows fallback)
        if self._try_start_pynput():
            return True

        return False

    def _try_start_win32(self) -> bool:
        """Attempt to start the Win32 polling backend. Returns True on success.

        Starts when at least one input source resolves: the keyboard chat key
        (virtual-key code) and/or the configured gamepad button (XInput).
        """
        if not sys.platform.startswith("win"):
            return False
        try:
            import ctypes
            self._user32 = ctypes.windll.user32  # type: ignore[attr-defined]
        except Exception as exc:
            logger.error(f"KeyMonitor: failed to load user32: {exc}")
            return False
        self._vk = _resolve_vk(self._chat_key)
        if self._pad_button:
            self._xinput = _load_xinput()
            if self._xinput is None:
                logger.warning(
                    f"KeyMonitor: pad_button={self._pad_button!r} configured but XInput "
                    f"is unavailable — gamepad input disabled, keyboard-only mode"
                )
            self._sdl_ctrl = _load_pygame_controller()
            if self._sdl_ctrl is None and self._xinput is None:
                logger.warning(
                    f"KeyMonitor: pad_button={self._pad_button!r} configured but neither "
                    f"XInput nor pygame/SDL2 gamepads are available — gamepad disabled"
                )
        if self._vk is None and (not self._pad_button or (self._xinput is None and self._sdl_ctrl is None)):
            logger.warning(
                f"KeyMonitor: unsupported chat_key={self._chat_key!r} and no working "
                f"gamepad button — key monitor will stay idle (add to _VK_MAP if needed)"
            )
            self._user32 = None
            return False
        self._stop_evt.clear()
        self._backend = "win32"
        self._thread = threading.Thread(
            target=self._run_poll, daemon=True, name="key-monitor-win32"
        )
        self._thread.start()
        vk_part = f"key={self._chat_key!r} (VK=0x{self._vk:02X})" if self._vk is not None else "no keyboard key"
        pad_part = "pad=off"
        if self._pad_button:
            if self._xinput is not None and self._sdl_ctrl is not None:
                pad_part = f"pad={self._pad_button!r} (xinput+sdl)"
            elif self._xinput is not None:
                pad_part = f"pad={self._pad_button!r} (xinput)"
            elif self._sdl_ctrl is not None:
                pad_part = f"pad={self._pad_button!r} (sdl)"
            else:
                pad_part = f"pad={self._pad_button!r} (unavailable)"
        logger.info(
            f"KeyMonitor started (win32): {vk_part} {pad_part} "
            f"threshold={self._threshold_ms}ms poll={self._poll_interval_ms}ms"
        )
        return True

    def _try_start_pynput(self) -> bool:
        """Attempt to start the pynput event-driven backend. Returns True on success."""
        try:
            from pynput import keyboard  # type: ignore[import-not-found]
        except ImportError:
            logger.info("KeyMonitor: pynput not installed — Linux/voice support unavailable (pip install pynput)")
            return False
        except Exception as exc:
            logger.warning(f"KeyMonitor: pynput import failed: {exc}")
            return False

        # pynput can match any key via its listener, so we don't need a VK map.
        # But we still log the configured key for diagnostics.
        self._stop_evt.clear()
        self._backend = "pynput"

        # We run the pynput Listener on its own daemon thread. The Listener
        # itself spawns a thread internally, but we wrap it so is_running()
        # and stop() work uniformly across backends.
        def _on_press(key_obj):
            if self._stop_evt.is_set():
                return
            if self._paused:
                return
            if not _pynput_key_matches(key_obj, self._chat_key):
                return
            self._handle_press()

        def _on_release(key_obj):
            if self._stop_evt.is_set():
                return
            if self._paused:
                return
            if not _pynput_key_matches(key_obj, self._chat_key):
                return
            self._handle_release()

        try:
            self._listener = keyboard.Listener(on_press=_on_press, on_release=_on_release)
            self._listener.start()
        except Exception as exc:
            logger.warning(f"KeyMonitor: pynput listener failed to start: {exc}")
            self._listener = None
            self._backend = ""
            return False

        logger.info(
            f"KeyMonitor started (pynput): key={self._chat_key!r} "
            f"threshold={self._threshold_ms}ms"
        )
        return True

    def stop(self) -> None:
        self._stop_evt.set()
        self._cancel_hold_timer()
        # Stop pynput listener first (it owns its own thread).
        if self._listener is not None:
            try:
                self._listener.stop()
            except Exception:
                pass
            self._listener = None
        t = self._thread
        if t and t.is_alive():
            t.join(timeout=1.0)
        self._thread = None
        self._backend = ""
        logger.info("KeyMonitor stopped")

    def is_running(self) -> bool:
        """Return True if the monitor is currently active."""
        if self._listener is not None:
            # pynput Listener.is_alive() checks its internal thread.
            try:
                if self._listener.is_alive():
                    return True
            except Exception:
                pass
        return bool(self._thread and self._thread.is_alive())

    def set_paused(self, paused: bool) -> None:
        """Temporarily ignore the V key without tearing down the worker.

        main.py flips this on whenever the in-game text overlay is shown so
        the user can include the configured chat key in their typed message
        without triggering tap / hold callbacks. The state machine resets
        its press tracker when transitioning into the paused state so a
        still-held key on resume is treated as a fresh press.
        """
        if self._paused == bool(paused):
            return
        self._paused = bool(paused)
        if self._paused:
            with self._sm_lock:
                self._sm_was_down = False
                self._sm_press_at = None
                self._sm_hold_started = False
        logger.info(f"KeyMonitor: paused={self._paused}")

    def update_config(
        self,
        chat_key: Optional[str] = None,
        threshold_ms: Optional[int] = None,
        pad_button: Optional[str] = None,
    ) -> None:
        """Hot-restart the monitor when the user changes chat_key / pad_button
        / threshold in the web UI. Cheaper than recreating the whole object —
        same callbacks stay wired up.
        """
        restart = False
        if chat_key is not None and chat_key != self._chat_key:
            self._chat_key = chat_key
            restart = True
        if pad_button is not None:
            pad_button = normalize_pad_button(pad_button)
            if pad_button != self._pad_button:
                self._pad_button = pad_button
                restart = True
        if threshold_ms is not None and int(threshold_ms) != self._threshold_ms:
            self._threshold_ms = max(50, int(threshold_ms))
            # Threshold change doesn't require an OS-level restart, but a
            # bounce keeps the state machine clean.
            restart = True
        if restart:
            logger.info(
                f"KeyMonitor: reconfiguring "
                f"key={self._chat_key} pad={self._pad_button or 'off'} threshold={self._threshold_ms}ms"
            )
            self.stop()
            self.start()

    # ------------------------------------------------------------------
    # State machine (shared by both backends)
    # ------------------------------------------------------------------
    def _handle_press(self) -> None:
        """Rising edge: key just pressed."""
        with self._sm_lock:
            if self._sm_was_down:
                return  # already down — ignore repeats
            self._sm_was_down = True
            self._sm_press_at = time.monotonic()
            self._sm_hold_started = False
        # For event-driven backends (pynput) there is no polling loop to
        # promote a hold, so schedule a one-shot timer.
        if self._backend == "pynput":
            self._schedule_hold_timer()

    def _schedule_hold_timer(self) -> None:
        """Schedule a one-shot timer that fires on_hold_start after the hold
        threshold. Only used by the pynput backend (the Win32 polling loop
        checks hold promotion on every tick instead).
        """
        self._cancel_hold_timer()
        threshold_s = self._threshold_ms / 1000.0
        t = threading.Timer(threshold_s, self._on_hold_timer_fire)
        t.daemon = True
        t.name = "key-monitor-hold"
        self._hold_timer = t
        t.start()

    def _cancel_hold_timer(self) -> None:
        t = self._hold_timer
        if t is not None:
            t.cancel()
            self._hold_timer = None

    def _on_hold_timer_fire(self) -> None:
        """Called by the hold timer (pynput backend only)."""
        with self._sm_lock:
            if not self._sm_was_down or self._sm_hold_started:
                return
            self._sm_hold_started = True
        self._safe_call(self.on_hold_start, "on_hold_start")

    def _handle_release(self) -> None:
        """Falling edge: key just released."""
        self._cancel_hold_timer()
        with self._sm_lock:
            if not self._sm_was_down:
                return  # spurious release without press
            duration = (time.monotonic() - self._sm_press_at) if self._sm_press_at else 0.0
            hold = self._sm_hold_started
            self._sm_was_down = False
            self._sm_press_at = None
            self._sm_hold_started = False
        if hold:
            self._safe_call_arg(self.on_hold_end, duration, "on_hold_end")
        else:
            self._safe_call(self.on_tap, "on_tap")

    def _check_hold_promotion(self) -> None:
        """Poll-based hold promotion: if the key is still down past the
        threshold, fire on_hold_start. Called from the polling loop only;
        pynput fires on_hold_start from a timer instead.
        """
        with self._sm_lock:
            if not self._sm_was_down or self._sm_hold_started or self._sm_press_at is None:
                return
            if (time.monotonic() - self._sm_press_at) >= (self._threshold_ms / 1000.0):
                self._sm_hold_started = True
                hold = True
            else:
                hold = False
        if hold:
            self._safe_call(self.on_hold_start, "on_hold_start")

    # ------------------------------------------------------------------
    # Worker (Win32 polling backend)
    # ------------------------------------------------------------------
    def _is_pad_pressed(self) -> bool:
        """Poll the configured gamepad button. XInput (controllers 0-3) first;
        if no XInput device is connected, fall back to pygame/SDL2, which sees
        DualShock 4 / DualSense natively."""
        mask = XINPUT_BUTTONS.get(self._pad_button)
        if self._xinput is not None and mask is not None:
            any_connected = False
            for idx in range(4):
                state = self._xinput_state
                if state is None:
                    self._xinput_state = state = _XINPUT_STATE()
                try:
                    if self._xinput(idx, state) != 0:  # 0 = ERROR_SUCCESS
                        continue  # controller not connected
                except Exception as exc:
                    logger.debug(f"XInputGetState failed: {exc}")
                    return False
                any_connected = True
                if state.Gamepad.wButtons & mask:
                    return True
            if any_connected:
                return False
        return self._is_pad_pressed_sdl()

    def _is_pad_pressed_sdl(self) -> bool:
        if self._sdl_ctrl is None or not self._pad_button:
            return False
        try:
            if self._sdl_ctrl.get_count() == 0:
                self._ctrl = None
                return False
            if self._ctrl is None:
                self._ctrl = self._sdl_ctrl.Controller(0)
            btn_id = _PAD_GC_BUTTONS.get(self._pad_button)
            if btn_id is None:
                return False
            return bool(self._ctrl.get_button(btn_id))
        except Exception as exc:
            # Pad likely disconnected mid-poll — drop the cached handle.
            self._ctrl = None
            logger.debug(f"SDL controller poll failed: {exc}")
            return False

    def _is_pressed(self) -> bool:
        # Keyboard: GetAsyncKeyState returns a SHORT where the high bit
        # (0x8000) is set when the key is currently down. Gamepad: XInput
        # wButtons bitmask. Either source feeds the same tap/hold machine —
        # we don't care about the "since last call" low bit — we maintain our
        # own edge tracking.
        if self._vk is not None:
            try:
                v = self._user32.GetAsyncKeyState(self._vk)  # type: ignore[union-attr]
            except Exception as exc:
                logger.debug(f"GetAsyncKeyState failed: {exc}")
                v = 0
            if v & 0x8000:
                return True
        return self._is_pad_pressed()

    def _run_poll(self) -> None:
        """Win32 polling loop — samples GetAsyncKeyState at poll_interval_ms."""
        poll_s = self._poll_interval_ms / 1000.0

        while not self._stop_evt.is_set():
            # While paused (text overlay open) skip all detection.
            if self._paused:
                with self._sm_lock:
                    if self._sm_was_down or self._sm_press_at is not None:
                        self._sm_was_down = False
                        self._sm_press_at = None
                        self._sm_hold_started = False
                self._stop_evt.wait(timeout=poll_s)
                continue

            now_down = self._is_pressed()

            # ---------- rising edge ----------
            if now_down and not self._sm_was_down:
                source = "pad" if self._is_pad_pressed() else "keyboard"
                logger.info(f"[input] press detected (source={source}, key={self._chat_key!r}, pad={self._pad_button!r})")
                self._handle_press()

            # ---------- still pressed: maybe promote to hold ----------
            elif now_down and self._sm_was_down:
                self._check_hold_promotion()

            # ---------- falling edge ----------
            elif (not now_down) and self._sm_was_down:
                self._handle_release()

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

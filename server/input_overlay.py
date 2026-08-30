"""Tkinter-based borderless input overlay for KCD2 AI NPC.

Pops a small always-on-top text entry near the bottom of the screen when an
NPC chat session becomes active. Enter submits the message, Esc cancels.

The overlay runs Tkinter in its own thread; public methods schedule actions
on that thread via root.after().
"""

from __future__ import annotations

import logging
import threading
from typing import Callable, Optional

logger = logging.getLogger(__name__)


class InputOverlay:
    def __init__(self, style: str = "kcd") -> None:
        self._submit_cb: Optional[Callable[[str], None]] = None
        # Invoked with True when the overlay becomes visible and False when it
        # hides (including the user pressing Enter/Escape). server/main.py uses
        # this to pause the global V-key monitor so the player can type words
        # containing the chat key without triggering tap/hold callbacks.
        self._visibility_cb: Optional[Callable[[bool], None]] = None
        self._root = None
        self._entry = None
        self._label = None
        self._thread: Optional[threading.Thread] = None
        self._ready = threading.Event()
        self._visible = False
        self._keep_open_after_submit = False
        self._user_close_cb: Optional[Callable[[], None]] = None
        self._style = (style or "kcd").lower()
        self._game_hwnd = None
        if self._style not in ("kcd", "plain"):
            self._style = "kcd"

    # ------------------------------------------------------------------
    # Public API (thread-safe; schedules on the tk thread).
    # ------------------------------------------------------------------
    def set_submit_callback(self, cb: Callable[[str], None]) -> None:
        self._submit_cb = cb

    def set_keep_open(self, flag: bool) -> None:
        """Не прятать окно после Enter (спящий механизм, сейчас не включается)."""
        self._keep_open_after_submit = bool(flag)

    def set_user_close_callback(self, cb: Callable[[], None]) -> None:
        """Колбэк на закрытие окна ИГРОКОМ (Enter — с текстом или пустой,
        Escape). Не дёргается на программные hide(). main.py вешает сюда
        авто-END для tap_mode=lua_command_autoend."""
        self._user_close_cb = cb

    def set_visibility_callback(self, cb: Callable[[bool], None]) -> None:
        """Register a callback fired every time the overlay shows/hides.

        Called on the Tk thread; callees must keep it cheap (no I/O, no
        blocking). main.py uses it to gate the server-side V-key monitor.
        """
        self._visibility_cb = cb

    def _notify_visibility(self, visible: bool) -> None:
        cb = self._visibility_cb
        if cb is None:
            return
        try:
            cb(visible)
        except Exception:
            logger.exception("Overlay visibility callback raised")

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._run, daemon=True, name="overlay-tk")
        self._thread.start()
        # Wait briefly for tk to come up so callers can show() immediately.
        self._ready.wait(timeout=2.0)

    def show(self, npc_name: str) -> None:
        if not self._ready.is_set():
            return
        try:
            self._root.after(0, lambda: self._show_impl(npc_name))
        except Exception as e:
            logger.warning(f"Overlay show schedule failed: {e}")

    def hide(self) -> None:
        if not self._ready.is_set():
            return
        try:
            self._root.after(0, self._hide_impl)
        except Exception as e:
            logger.warning(f"Overlay hide schedule failed: {e}")

    def set_style(self, style: str) -> None:
        new_style = (style or "kcd").lower()
        if new_style not in ("kcd", "plain"):
            new_style = "kcd"
        if new_style == self._style:
            return
        self._style = new_style
        if not self._ready.is_set():
            return
        try:
            self._root.after(0, self._restyle_impl)
        except Exception as e:
            logger.warning(f"Overlay restyle schedule failed: {e}")

    # ------------------------------------------------------------------
    # Tk thread internals
    # ------------------------------------------------------------------
    def _run(self) -> None:
        try:
            import tkinter as tk
            from tkinter import font as tkfont
        except Exception as e:
            logger.error(f"Tkinter not available: {e}")
            return
        try:
            self._root = tk.Tk()
            self._root.withdraw()
            self._root.overrideredirect(True)
            self._root.attributes("-topmost", True)
            if self._style == "kcd":
                self._build_ui_kcd(tk, tkfont)
            else:
                self._build_ui_plain(tk)
            logger.info(f"Overlay style: {self._style}")
            self._ready.set()
            self._root.mainloop()
        except Exception as e:
            logger.error(f"Overlay tk loop crashed: {e}")
        finally:
            self._ready.clear()

    # ------------------------------------------------------------------
    # Style: 'kcd' — parchment + double gold border, serif fonts.
    # ------------------------------------------------------------------
    def _build_ui_kcd(self, tk, tkfont) -> None:
        self._root.attributes("-alpha", 0.95)

        COL_GOLD       = "#c9a14a"
        COL_GOLD_DIM   = "#7a5b2b"
        COL_PARCHMENT  = "#1a130d"
        COL_BG_DEEP    = "#0c0905"
        COL_TEXT       = "#f1deb0"
        COL_NPC_NAME   = "#d4af55"
        COL_PROMPT     = "#8a6f3b"

        self._root.configure(bg=COL_BG_DEEP)

        installed = set(tkfont.families())
        def pick_font(candidates: list[str], default: str) -> str:
            for c in candidates:
                if c in installed:
                    return c
            return default
        font_label_family = pick_font(
            ["Cinzel", "Trajan Pro", "Trajan Pro 3", "IM FELL English",
             "Cormorant Garamond", "Palatino Linotype", "Book Antiqua",
             "Constantia", "Georgia"],
            "Georgia",
        )
        font_entry_family = pick_font(
            ["Cinzel", "Palatino Linotype", "Book Antiqua", "Constantia",
             "Cambria", "Georgia"],
            "Georgia",
        )

        outer = tk.Frame(self._root, bg=COL_BG_DEEP, bd=0)
        outer.pack(fill="both", expand=True, padx=6, pady=6)

        border_gold = tk.Frame(outer, bg=COL_GOLD, bd=0)
        border_gold.pack(fill="both", expand=True)

        border_inner = tk.Frame(border_gold, bg=COL_GOLD_DIM, bd=0)
        border_inner.pack(fill="both", expand=True, padx=2, pady=2)

        inner = tk.Frame(border_inner, bg=COL_PARCHMENT, bd=0)
        inner.pack(fill="both", expand=True, padx=1, pady=1)

        top = tk.Frame(inner, bg=COL_PARCHMENT)
        top.pack(fill="x", padx=18, pady=(10, 0))

        self._label = tk.Label(
            top, text="", bg=COL_PARCHMENT, fg=COL_NPC_NAME,
            font=(font_label_family, 13, "italic"), anchor="w",
        )
        self._label.pack(fill="x", anchor="w")

        sep = tk.Frame(inner, bg=COL_GOLD_DIM, height=1)
        sep.pack(fill="x", padx=18, pady=(4, 8))

        row = tk.Frame(inner, bg=COL_PARCHMENT)
        row.pack(fill="x", padx=18, pady=(0, 14))

        prompt = tk.Label(
            row, text="\u25B8", bg=COL_PARCHMENT, fg=COL_PROMPT,
            font=(font_entry_family, 16),
        )
        prompt.pack(side="left", padx=(0, 8))

        self._entry = tk.Entry(
            row, bg=COL_PARCHMENT, fg=COL_TEXT,
            insertbackground=COL_TEXT, insertwidth=2,
            relief="flat", font=(font_entry_family, 15),
            bd=0, highlightthickness=0,
        )
        self._entry.pack(side="left", fill="x", expand=True, ipady=6)
        self._entry.bind("<Return>", self._on_enter)
        self._entry.bind("<Escape>", self._on_escape)

        logger.info(f"Overlay fonts: label='{font_label_family}', entry='{font_entry_family}'")

    # ------------------------------------------------------------------
    # Style: 'plain' — minimal dark with thin gold border (original look).
    # ------------------------------------------------------------------
    def _build_ui_plain(self, tk) -> None:
        self._root.attributes("-alpha", 0.92)
        self._root.configure(bg="#0a0a0a")

        frame = tk.Frame(self._root, bg="#0a0a0a", bd=0,
                         highlightthickness=2, highlightbackground="#c9a86a")
        frame.pack(fill="both", expand=True, padx=0, pady=0)

        self._label = tk.Label(
            frame, text="", bg="#0a0a0a", fg="#c9a86a",
            font=("Georgia", 11, "italic"),
            anchor="w", padx=12, pady=4,
        )
        self._label.pack(fill="x")

        self._entry = tk.Entry(
            frame, bg="#101010", fg="#f0e6d2",
            insertbackground="#f0e6d2", relief="flat",
            font=("Georgia", 14), bd=0,
        )
        self._entry.pack(fill="x", padx=12, pady=(0, 10), ipady=8)
        self._entry.bind("<Return>", self._on_enter)
        self._entry.bind("<Escape>", self._on_escape)

    def _restyle_impl(self) -> None:
        if not self._root:
            return
        try:
            import tkinter as tk
            from tkinter import font as tkfont
        except Exception as e:
            logger.error(f"Restyle: tkinter import failed: {e}")
            return
        try:
            was_visible = self._visible
            for w in list(self._root.winfo_children()):
                w.destroy()
            self._label = None
            self._entry = None
            if self._style == "kcd":
                self._build_ui_kcd(tk, tkfont)
            else:
                self._build_ui_plain(tk)
            logger.info(f"Overlay restyled to: {self._style}")
            if was_visible and self._label is not None:
                # Re-apply current label text (NPC name) and re-show.
                self._show_impl(self._label.cget("text").strip() or "NPC")
        except Exception as e:
            logger.error(f"Overlay restyle failed: {e}")

    def _show_impl(self, npc_name: str) -> None:
        if not self._root:
            return
        try:
            if self._style == "kcd":
                width, height = 760, 120
                y_frac = 0.74
                label_text = npc_name
            else:
                width, height = 720, 90
                y_frac = 0.78
                label_text = f"  {npc_name}"
            sw = self._root.winfo_screenwidth()
            sh = self._root.winfo_screenheight()
            x = (sw - width) // 2
            y = int(sh * y_frac)
            self._root.geometry(f"{width}x{height}+{x}+{y}")
            self._label.configure(text=label_text)
            self._entry.delete(0, "end")
            self._root.deiconify()
            self._root.lift()
            self._root.attributes("-topmost", True)
            self._entry.focus_force()
            self._steal_foreground()
            self._entry.focus_set()
            self._block_game_input()
            was_visible = self._visible
            self._visible = True
            if not was_visible:
                self._notify_visibility(True)
        except Exception as e:
            logger.warning(f"Overlay show failed: {e}")

    def _steal_foreground(self) -> None:
        """Force-steal foreground focus from the current app (the game).

        Windows refuses SetForegroundWindow from a background process unless
        we attach our input thread to the current foreground thread first.
        """
        try:
            import ctypes
            from ctypes import wintypes
            user32 = ctypes.windll.user32
            kernel32 = ctypes.windll.kernel32

            # Tk's toplevel HWND is exposed via wm_frame() as a hex string.
            try:
                hwnd = int(self._root.wm_frame(), 16)
            except Exception:
                hwnd = int(self._root.winfo_id())

            user32.GetWindowThreadProcessId.restype = wintypes.DWORD
            user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
            user32.AttachThreadInput.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.BOOL]
            user32.SetForegroundWindow.argtypes = [wintypes.HWND]
            user32.BringWindowToTop.argtypes = [wintypes.HWND]
            user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]

            fg_hwnd = user32.GetForegroundWindow()
            fg_thread = user32.GetWindowThreadProcessId(fg_hwnd, None)
            cur_thread = kernel32.GetCurrentThreadId()

            if fg_thread and fg_thread != cur_thread:
                user32.AttachThreadInput(fg_thread, cur_thread, True)
                try:
                    user32.ShowWindow(hwnd, 5)  # SW_SHOW
                    user32.BringWindowToTop(hwnd)
                    user32.SetForegroundWindow(hwnd)
                finally:
                    user32.AttachThreadInput(fg_thread, cur_thread, False)
            else:
                user32.SetForegroundWindow(hwnd)
        except Exception as e:
            logger.debug(f"Steal foreground failed: {e}")

    def _hide_impl(self, return_focus: bool = True) -> None:
        if not self._root:
            return
        try:
            was_visible = self._visible
            self._unblock_game_input()
            self._root.withdraw()
            self._visible = False
            if return_focus:
                self._return_focus_to_game()
            if was_visible:
                self._notify_visibility(False)
        except Exception as e:
            logger.warning(f"Overlay hide failed: {e}")

    def _on_enter(self, _event) -> None:
        try:
            text = self._entry.get().strip()
        except Exception:
            text = ""
        if self._keep_open_after_submit and text:
            # Режим «окно остаётся»: очистить поле, отправить, не прятаться.
            try:
                self._entry.delete(0, "end")
            except Exception:
                pass
            if self._submit_cb:
                try:
                    self._submit_cb(text)
                except Exception as e:
                    logger.error(f"Overlay submit callback failed: {e}")
            return "break"
        self._hide_impl(return_focus=False)
        if text and self._submit_cb:
            try:
                self._submit_cb(text)
            except Exception as e:
                logger.error(f"Overlay submit callback failed: {e}")
        self._fire_user_close()
        if self._root:
            self._root.after(180, self._return_focus_to_game)
        return "break"

    def _fire_user_close(self) -> None:
        if self._user_close_cb:
            try:
                self._user_close_cb()
            except Exception as e:
                logger.error(f"Overlay user-close callback failed: {e}")

    def _on_escape(self, _event) -> str:
        self._hide_impl(return_focus=False)
        self._fire_user_close()
        if self._root:
            self._root.after(180, self._return_focus_to_game)
        return "break"

    @staticmethod
    def _find_game_hwnd():
        """Find the KCD2 main window HWND (top-level, visible)."""
        try:
            import ctypes
            from ctypes import wintypes
            user32 = ctypes.windll.user32
            EnumWindows = user32.EnumWindows
            GetWindowTextW = user32.GetWindowTextW
            IsWindowVisible = user32.IsWindowVisible

            target_titles = (
                "kingdomcomedeliverance2",
                "kingdom come deliverance ii",
                "kingdom come: deliverance ii",
            )
            found = [0]
            EnumWindowsProc = ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)

            def _cb(hwnd, _lparam):
                if not IsWindowVisible(hwnd):
                    return True
                buf = ctypes.create_unicode_buffer(256)
                GetWindowTextW(hwnd, buf, 256)
                title = buf.value.lower()
                if any(t in title for t in target_titles):
                    found[0] = hwnd
                    return False
                return True

            EnumWindows(EnumWindowsProc(_cb), 0)
            return found[0] or None
        except Exception:
            return None

    def _block_game_input(self) -> None:
        """While the overlay is focused, disable the game window so its
        keystrokes don't leak through (DirectInput/CryEngine read the physical
        keyboard regardless of Tk focus). Re-enabled on hide."""
        if self._game_hwnd is not None:
            return
        try:
            import ctypes
            from ctypes import wintypes
            user32 = ctypes.windll.user32
            hwnd = self._find_game_hwnd()
            if not hwnd:
                return
            user32.EnableWindow.argtypes = [wintypes.HWND, wintypes.BOOL]
            user32.EnableWindow(hwnd, False)
            self._game_hwnd = hwnd
            logger.info(f"Game window input blocked (hwnd={hwnd})")
        except Exception as e:
            logger.debug(f"Block game input failed: {e}")

    def _unblock_game_input(self) -> None:
        if not self._game_hwnd:
            return
        try:
            import ctypes
            from ctypes import wintypes
            user32 = ctypes.windll.user32
            user32.EnableWindow.argtypes = [wintypes.HWND, wintypes.BOOL]
            user32.EnableWindow(self._game_hwnd, True)
            logger.info(f"Game window input re-enabled (hwnd={self._game_hwnd})")
        except Exception as e:
            logger.debug(f"Unblock game input failed: {e}")
        finally:
            self._game_hwnd = None

    @staticmethod
    def _return_focus_to_game() -> None:
        """Best-effort: bring KCD2 window back to foreground on Windows."""
        try:
            import ctypes
            from ctypes import wintypes
            user32 = ctypes.windll.user32
            SetForegroundWindow = user32.SetForegroundWindow
            hwnd = InputOverlay._find_game_hwnd()
            if hwnd:
                SetForegroundWindow(hwnd)
        except Exception as e:
            logger.debug(f"Return focus to game failed: {e}")

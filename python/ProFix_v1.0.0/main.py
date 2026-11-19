"""ProFix - Slow PC Doctor v1.0 Entry Point."""

import ctypes
import sys


def enable_windows_dpi_awareness():
    if sys.platform != "win32":
        return
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except Exception:
            pass


if __name__ == "__main__":
    enable_windows_dpi_awareness()
    from ui.main_window import ProFixApp
    app = ProFixApp()
    app.mainloop()

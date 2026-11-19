"""Safe 1-Click Fix, Graceful App Close (WM_CLOSE), Reversible Windows Tweaks & Full Undo."""

import base64
import ctypes
import datetime
import json
import os
import subprocess
import sys
from pathlib import Path

if sys.platform == "win32":
    import winreg
else:
    winreg = None

CREATE_NO_WINDOW = 0x08000000
RESTORE_DIR = Path(os.environ.get("LOCALAPPDATA", ".")) / "ProFix"
RESTORE_FILE = RESTORE_DIR / "ProFix_Restore.json"
APPROVED_RUN_PATH = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
PERSONALIZE_PATH = r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
STORAGE_SENSE_PATH = r"Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
BALANCED_POWER_GUID = "381b4222-f694-41f0-9685-ff5bb260df2e"


def _load_or_init_restore() -> dict:
    RESTORE_DIR.mkdir(parents=True, exist_ok=True)
    if RESTORE_FILE.exists():
        try:
            return json.loads(RESTORE_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {
        "timestamp": datetime.datetime.now().isoformat(timespec="seconds"),
        "startup_backups": [],
        "tweak_backups": {},
    }


def _save_restore(data: dict):
    RESTORE_DIR.mkdir(parents=True, exist_ok=True)
    data["timestamp"] = datetime.datetime.now().isoformat(timespec="seconds")
    RESTORE_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")


def _disable_startup_app_safely(app_name: str) -> dict:
    """Uses native Windows Task Manager StartupApproved\Run toggle (no Run key deletion)."""
    backup = {"name": app_name, "existed": False, "prev_bytes_b64": None}
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, APPROVED_RUN_PATH) as key:
        try:
            prev_val, _ = winreg.QueryValueEx(key, app_name)
            backup["existed"] = True
            backup["prev_bytes_b64"] = base64.b64encode(prev_val).decode("ascii")
        except FileNotFoundError:
            pass
        disabled_bytes = bytes([0x03] + [0x00] * 11)
        winreg.SetValueEx(key, app_name, 0, winreg.REG_BINARY, disabled_bytes)
    return backup


def close_app_gently(pids: list[int]) -> dict:
    """
    Sends standard WM_CLOSE to visible windows belonging to pids (like clicking X).
    Never calls TerminateProcess / taskkill /F so unsaved user work stays safe.
    """
    if sys.platform != "win32":
        return {"ok": False, "sent": 0, "message": "Windows-only action."}

    WM_CLOSE = 0x0010
    pid_set = set(pids)
    sent_count = 0

    EnumWindowsProc = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    user32 = ctypes.windll.user32

    def callback(hwnd, _lparam):
        nonlocal sent_count
        if user32.IsWindowVisible(hwnd):
            lpdw_pid = ctypes.c_ulong()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(lpdw_pid))
            if lpdw_pid.value in pid_set:
                user32.PostMessageW(hwnd, WM_CLOSE, 0, 0)
                sent_count += 1
        return True

    user32.EnumWindows(EnumWindowsProc(callback), 0)
    if sent_count > 0:
        return {"ok": True, "sent": sent_count, "message": f"Sent gentle close signal to {sent_count} window(s)."}
    return {"ok": False, "sent": 0, "message": "No visible window found (tray/service app). Use Startup pause or exit from system tray."}


def apply_safe_tweak(tweak_id: str, enable: bool, current_state: dict) -> dict:
    """Applies a single reversible Windows speed tweak and records Undo backup."""
    if sys.platform != "win32" or not winreg:
        return {"ok": False, "message": "Windows-only setting."}

    restore = _load_or_init_restore()

    try:
        if tweak_id == "power_balanced":
            prev_guid = current_state.get("power_plan_guid")
            if prev_guid and "power_plan_guid" not in restore["tweak_backups"]:
                restore["tweak_backups"]["power_plan_guid"] = prev_guid
            proc = subprocess.run(
                ["powercfg", "/setactive", BALANCED_POWER_GUID],
                capture_output=True, text=True, timeout=5, creationflags=CREATE_NO_WINDOW
            )
            if proc.returncode == 0:
                _save_restore(restore)
                return {"ok": True, "message": "Power Plan switched to Balanced (reversible in Restore & Logs)."}
            return {"ok": False, "message": "Could not switch Power Plan."}

        if tweak_id == "transparency":
            new_val = 1 if enable else 0
            if "transparency" not in restore["tweak_backups"]:
                restore["tweak_backups"]["transparency"] = 1 if current_state.get("transparency_enabled", True) else 0
            with winreg.CreateKey(winreg.HKEY_CURRENT_USER, PERSONALIZE_PATH) as k:
                winreg.SetValueEx(k, "EnableTransparency", 0, winreg.REG_DWORD, new_val)
            _save_restore(restore)
            label = "enabled" if enable else "disabled for smoother UI"
            return {"ok": True, "message": f"Window transparency {label}."}

        if tweak_id == "storage_sense":
            new_val = 1 if enable else 0
            if "storage_sense" not in restore["tweak_backups"]:
                restore["tweak_backups"]["storage_sense"] = 1 if current_state.get("storage_sense_enabled", False) else 0
            with winreg.CreateKey(winreg.HKEY_CURRENT_USER, STORAGE_SENSE_PATH) as k:
                winreg.SetValueEx(k, "01", 0, winreg.REG_DWORD, new_val)
            _save_restore(restore)
            label = "enabled" if enable else "disabled"
            return {"ok": True, "message": f"Windows Storage Sense {label}."}
    except OSError as exc:
        return {"ok": False, "message": f"Setting update skipped: {exc}"}

    return {"ok": False, "message": "Unknown tweak."}


def apply_safe_fixes(
    clean_junk_files: list[str] | None = None,
    disable_startups: list[str] | None = None,
    empty_recycle_bin: bool = False,
    flush_dns: bool = False,
) -> dict:
    """Executes only user-approved safe fixes and updates ProFix_Restore.json."""
    result = {
        "timestamp": datetime.datetime.now().isoformat(timespec="seconds"),
        "junk_freed_gb": 0.0,
        "junk_deleted_count": 0,
        "junk_locked_skipped": 0,
        "startups_disabled": [],
        "recycle_bin_emptied": False,
        "dns_flushed": False,
    }
    restore = _load_or_init_restore()

    # 1. Clean 24h+ Safe Junk (skip locked files safely)
    if clean_junk_files:
        freed_bytes = 0
        for fpath in clean_junk_files:
            try:
                size = os.path.getsize(fpath)
                os.remove(fpath)
                freed_bytes += size
                result["junk_deleted_count"] += 1
            except OSError:
                result["junk_locked_skipped"] += 1
        result["junk_freed_gb"] = round(freed_bytes / (1024 ** 3), 2)

    # 2. Pause selected Startup Apps with Backup
    if disable_startups and winreg:
        existing_names = {b["name"].lower() for b in restore["startup_backups"]}
        for app_name in disable_startups:
            try:
                bkp = _disable_startup_app_safely(app_name)
                if app_name.lower() not in existing_names:
                    restore["startup_backups"].append(bkp)
                    existing_names.add(app_name.lower())
                result["startups_disabled"].append(app_name)
            except OSError:
                continue

    # 3. Empty Recycle Bin (Native Shell API)
    if empty_recycle_bin and sys.platform == "win32":
        flags = 0x00000001 | 0x00000002 | 0x00000004  # NOCONFIRM | NOPROGRESS | NOSOUND
        res = ctypes.windll.shell32.SHEmptyRecycleBinW(None, None, flags)
        result["recycle_bin_emptied"] = (res == 0)

    # 4. Flush Local DNS Cache
    if flush_dns and sys.platform == "win32":
        proc = subprocess.run(
            ["ipconfig", "/flushdns"],
            capture_output=True, text=True, timeout=5, creationflags=CREATE_NO_WINDOW
        )
        result["dns_flushed"] = (proc.returncode == 0)

    if restore["startup_backups"] or restore["tweak_backups"]:
        _save_restore(restore)

    return result


def undo_last_fix() -> dict:
    """Restores startup apps AND Windows speed tweaks from ProFix_Restore.json."""
    if not RESTORE_FILE.exists():
        return {"ok": False, "message": "No restore snapshot found.", "restored": 0, "failed": 0}
    if not winreg:
        return {"ok": False, "message": "Windows-only action.", "restored": 0, "failed": 0}

    data = json.loads(RESTORE_FILE.read_text(encoding="utf-8"))
    restored, failed = 0, 0

    # Restore Startup Apps
    if data.get("startup_backups"):
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, APPROVED_RUN_PATH) as key:
            for item in data["startup_backups"]:
                try:
                    if item.get("existed") and item.get("prev_bytes_b64"):
                        raw = base64.b64decode(item["prev_bytes_b64"])
                        winreg.SetValueEx(key, item["name"], 0, winreg.REG_BINARY, raw)
                    else:
                        enabled_bytes = bytes([0x02] + [0x00] * 11)
                        winreg.SetValueEx(key, item["name"], 0, winreg.REG_BINARY, enabled_bytes)
                    restored += 1
                except OSError:
                    failed += 1

    # Restore Windows Tweaks
    tweaks = data.get("tweak_backups", {})
    if "power_plan_guid" in tweaks:
        try:
            subprocess.run(
                ["powercfg", "/setactive", tweaks["power_plan_guid"]],
                capture_output=True, text=True, timeout=5, creationflags=CREATE_NO_WINDOW
            )
            restored += 1
        except Exception:
            failed += 1

    if "transparency" in tweaks:
        try:
            with winreg.CreateKey(winreg.HKEY_CURRENT_USER, PERSONALIZE_PATH) as k:
                winreg.SetValueEx(k, "EnableTransparency", 0, winreg.REG_DWORD, int(tweaks["transparency"]))
            restored += 1
        except OSError:
            failed += 1

    if "storage_sense" in tweaks:
        try:
            with winreg.CreateKey(winreg.HKEY_CURRENT_USER, STORAGE_SENSE_PATH) as k:
                winreg.SetValueEx(k, "01", 0, winreg.REG_DWORD, int(tweaks["storage_sense"]))
            restored += 1
        except OSError:
            failed += 1

    if failed == 0:
        RESTORE_FILE.unlink(missing_ok=True)

    msg = (
        f"Restore complete — {restored} setting(s) restored to original state."
        if failed == 0
        else f"Restored {restored} item(s); {failed} item(s) could not be reverted."
    )
    return {"ok": True, "restored": restored, "failed": failed, "message": msg}

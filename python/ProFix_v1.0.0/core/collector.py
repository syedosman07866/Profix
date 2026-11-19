"""Read-only Windows Diagnostics, Background App Grouper, Safe Tweaks & Hardware Probe."""

import ctypes
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from collections import defaultdict
from pathlib import Path
import psutil

if sys.platform == "win32":
    import winreg
else:
    winreg = None

CREATE_NO_WINDOW = 0x08000000
TWENTY_FOUR_HOURS = 24 * 3600

PROTECTED_PROCESS_NAMES = {
    "system", "registry", "smss.exe", "csrss.exe", "wininit.exe", "services.exe",
    "lsass.exe", "svchost.exe", "fontdrvhost.exe", "dwm.exe", "winlogon.exe",
    "explorer.exe", "sihost.exe", "taskhostw.exe", "ctfmon.exe", "runtimebroker.exe",
    "searchhost.exe", "startmenuexperiencehost.exe", "shellexperiencehost.exe",
    "textinputhost.exe", "msmpeng.exe", "securityhealthservice.exe", "securityhealthsystray.exe",
    "nissrv.exe", "audiodg.exe", "spoolsv.exe", "conhost.exe", "dllhost.exe",
    "wmiprvse.exe", "memory compression", "idle", "python.exe", "pythonw.exe",
    "profix_v1.0.0.exe", "profix.exe", "applicationframehost.exe", "lockapp.exe",
    "widgets.exe", "phoneexperiencehost.exe", "smartscreen.exe", "dashost.exe",
}

CAUTION_KEYWORDS = ("onedrive", "teams", "dropbox", "googledrive", "vpn", "outlook", "zoom")


def is_admin() -> bool:
    if sys.platform != "win32":
        return False
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def get_c_drive_space() -> tuple[float, float]:
    target = "C:\\" if sys.platform == "win32" else "/"
    usage = psutil.disk_usage(target)
    free_gb = round(usage.free / (1024 ** 3), 2)
    free_pct = round((usage.free / usage.total) * 100, 1)
    return free_gb, free_pct


def scan_top_user_folders(max_folders: int = 5) -> list[dict]:
    """Quick read-only size check of common large user folders (capped to stay fast)."""
    home = Path.home()
    candidates = [
        ("Downloads", home / "Downloads"),
        ("Videos", home / "Videos"),
        ("Desktop", home / "Desktop"),
        ("Documents", home / "Documents"),
        ("Pictures", home / "Pictures"),
        ("AppData Local Temp", Path(tempfile.gettempdir())),
    ]
    results = []
    for label, path in candidates:
        if not path.exists():
            continue
        total_b = 0
        scanned = 0
        try:
            for root, _, fnames in os.walk(path):
                for fn in fnames:
                    scanned += 1
                    if scanned > 6000:
                        break
                    try:
                        total_b += os.path.getsize(os.path.join(root, fn))
                    except OSError:
                        continue
                if scanned > 6000:
                    break
        except OSError:
            continue
        gb = round(total_b / (1024 ** 3), 2)
        if gb >= 0.1:
            results.append({"name": label, "path": str(path), "gb": gb})
    results.sort(key=lambda x: x["gb"], reverse=True)
    return results[:max_folders]


def get_averaged_cpu_ram(samples: int = 4, interval: float = 0.75) -> tuple[float, float]:
    """Samples CPU and RAM over ~3 seconds to avoid launch spikes."""
    psutil.cpu_percent(interval=None)
    cpu_readings, ram_readings = [], []
    for _ in range(samples):
        time.sleep(interval)
        cpu_readings.append(psutil.cpu_percent(interval=None))
        ram_readings.append(psutil.virtual_memory().percent)
    return round(sum(cpu_readings) / len(cpu_readings), 1), round(sum(ram_readings) / len(ram_readings), 1)


def get_uptime_days() -> float:
    if sys.platform == "win32":
        ms = ctypes.windll.kernel32.GetTickCount64()
        return round(ms / 86_400_000.0, 2)
    return round((time.time() - psutil.boot_time()) / 86400.0, 2)


def get_safe_junk_targets() -> list[Path]:
    targets = [Path(tempfile.gettempdir())]
    if sys.platform == "win32":
        win_temp = Path(os.environ.get("WINDIR", "C:\\Windows")) / "Temp"
        wer_archive = Path(os.environ.get("ProgramData", "C:\\ProgramData")) / "Microsoft\\Windows\\WER\\ReportArchive"
        for p in (win_temp, wer_archive):
            if p.exists() and p not in targets:
                targets.append(p)
    return targets


def scan_safe_junk() -> dict:
    """Read-only scan of temp files strictly older than 24 hours."""
    cutoff = time.time() - TWENTY_FOUR_HOURS
    total_bytes = 0
    file_paths = []
    skipped_recent = 0

    for folder in get_safe_junk_targets():
        try:
            for root, _, files in os.walk(folder):
                for name in files:
                    fpath = os.path.join(root, name)
                    try:
                        st = os.stat(fpath)
                        if st.st_mtime < cutoff and st.st_ctime < cutoff:
                            total_bytes += st.st_size
                            file_paths.append(fpath)
                        else:
                            skipped_recent += 1
                    except OSError:
                        continue
        except OSError:
            continue

    return {
        "junk_gb": round(total_bytes / (1024 ** 3), 2),
        "file_count": len(file_paths),
        "skipped_recent": skipped_recent,
        "files": file_paths,
    }


def get_enabled_startup_apps() -> list[dict]:
    """Reads HKCU Run entries and checks native Windows Task Manager StartupApproved state."""
    if not winreg:
        return []
    run_path = r"Software\Microsoft\Windows\CurrentVersion\Run"
    approved_path = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    apps = []

    approved_map = {}
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, approved_path) as akey:
            i = 0
            while True:
                name, val, _ = winreg.EnumValue(akey, i)
                approved_map[name.lower()] = val
                i += 1
    except OSError:
        pass

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, run_path) as rkey:
            i = 0
            while True:
                name, cmd, _ = winreg.EnumValue(rkey, i)
                low_cmd = str(cmd).lower()
                if "windows defender" in low_cmd or "securityhealth" in low_cmd:
                    i += 1
                    continue

                raw_state = approved_map.get(name.lower())
                is_enabled = True if (raw_state is None or raw_state[0] in (2, 6)) else False

                if is_enabled:
                    safety = "caution" if any(k in name.lower() or k in low_cmd for k in CAUTION_KEYWORDS) else "safe"
                    apps.append({
                        "name": name,
                        "command": cmd,
                        "safety": safety,
                        "hive": "HKCU",
                    })
                i += 1
    except OSError:
        pass

    return apps


def get_grouped_background_apps(limit: int = 12) -> list[dict]:
    """
    Groups non-system user processes by executable name.
    Protects core Windows/security processes from ever appearing in the user list.
    """
    win_dir = os.environ.get("WINDIR", "C:\\Windows").lower()
    groups = defaultdict(lambda: {"pids": [], "ram_mb": 0.0, "exe": ""})

    for proc in psutil.process_iter(["pid", "name", "exe", "memory_info"]):
        try:
            info = proc.info
            pname = (info.get("name") or "").strip()
            low_name = pname.lower()
            exe_path = (info.get("exe") or "").lower()
            if not pname or low_name in PROTECTED_PROCESS_NAMES:
                continue
            # Hide core Windows System32 / WinSxS binaries
            if exe_path.startswith(win_dir + "\\system32") or exe_path.startswith(win_dir + "\\syswow64"):
                continue

            mem = info.get("memory_info")
            ram_mb = (mem.rss / (1024 ** 2)) if mem else 0.0
            display = pname[:-4] if low_name.endswith(".exe") else pname
            key = display.lower()
            groups[key]["display_name"] = display
            groups[key]["pids"].append(info["pid"])
            groups[key]["ram_mb"] += ram_mb
            if not groups[key]["exe"] and exe_path:
                groups[key]["exe"] = exe_path
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            continue

    items = []
    for key, g in groups.items():
        if g["ram_mb"] < 15.0:
            continue
        safety = "caution" if any(k in key for k in CAUTION_KEYWORDS) else "safe"
        items.append({
            "name": g["display_name"],
            "process_count": len(g["pids"]),
            "pids": g["pids"],
            "ram_mb": round(g["ram_mb"], 1),
            "safety": safety,
        })

    items.sort(key=lambda x: x["ram_mb"], reverse=True)
    return items[:limit]


def check_pending_restart() -> bool:
    if not winreg:
        return False
    checks = [
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"),
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"),
    ]
    for hive, path in checks:
        try:
            with winreg.OpenKey(hive, path):
                return True
        except OSError:
            continue
    return False


def get_recycle_bin_gb() -> float:
    if sys.platform != "win32":
        return 0.0

    class SHQUERYRBINFO(ctypes.Structure):
        _fields_ = [
            ("cbSize", ctypes.c_ulong),
            ("i64Size", ctypes.c_longlong),
            ("i64NumItems", ctypes.c_longlong),
        ]

    info = SHQUERYRBINFO()
    info.cbSize = ctypes.sizeof(SHQUERYRBINFO)
    res = ctypes.windll.shell32.SHQueryRecycleBinW(None, ctypes.byref(info))
    if res == 0:
        return round(info.i64Size / (1024 ** 3), 2)
    return 0.0


def measure_dns_ms() -> int | None:
    try:
        t0 = time.perf_counter()
        socket.getaddrinfo("cloudflare.com", 443)
        return int((time.perf_counter() - t0) * 1000)
    except OSError:
        return None


def inspect_safe_windows_tweaks() -> dict:
    """Read-only check of native, reversible Windows performance settings."""
    state = {
        "power_plan_guid": None,
        "power_plan_name": "Balanced",
        "is_power_saver": False,
        "transparency_enabled": True,
        "storage_sense_enabled": False,
    }
    if sys.platform != "win32" or not winreg:
        return state

    # 1. Active Power Plan
    try:
        proc = subprocess.run(
            ["powercfg", "/getactivescheme"],
            capture_output=True, text=True, timeout=4, creationflags=CREATE_NO_WINDOW
        )
        out = proc.stdout.strip()
        if "GUID:" in out:
            parts = out.split("GUID:")[1].strip().split()
            if parts:
                state["power_plan_guid"] = parts[0].strip()
            if "(" in out and ")" in out:
                state["power_plan_name"] = out[out.find("(") + 1:out.rfind(")")]
            if "power saver" in out.lower() or "a1841308-3541-4fab-bc81-f71556f20b4a" in out.lower():
                state["is_power_saver"] = True
    except Exception:
        pass

    # 2. Transparency Effects (HKCU Personalize)
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as k:
            val, _ = winreg.QueryValueEx(k, "EnableTransparency")
            state["transparency_enabled"] = bool(val)
    except OSError:
        pass

    # 3. Storage Sense (HKCU StoragePolicy)
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy") as k:
            val, _ = winreg.QueryValueEx(k, "01")
            state["storage_sense_enabled"] = bool(val)
    except OSError:
        pass

    return state


def probe_hardware() -> dict:
    """Single read-only PowerShell CIM probe with clean non-admin fallback."""
    fallback = {
        "os_drive_type": "Unknown",
        "smart_ok": True,
        "smart_verified": False,
        "total_ram_gb": round(psutil.virtual_memory().total / (1024 ** 3)),
        "ram_slots_used": None,
        "ram_slots_total": None,
        "cpu_name": "Windows Processor",
        "cpu_threads": psutil.cpu_count(logical=True) or 4,
        "battery_health_pct": None,
    }
    if sys.platform != "win32":
        return fallback

    ps_script = r"""
    $ErrorActionPreference = 'SilentlyContinue'
    $osPart = Get-Partition -DriveLetter C | Select-Object -First 1
    $disk = if ($osPart) { Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $osPart.DiskNumber } | Select-Object -First 1 }
    $mem = Get-CimInstance Win32_PhysicalMemory
    $arr = Get-CimInstance Win32_PhysicalMemoryArray | Select-Object -First 1
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $batStatic = Get-CimInstance -Namespace root/WMI -ClassName BatteryStaticData | Select-Object -First 1
    $batFull   = Get-CimInstance -Namespace root/WMI -ClassName BatteryFullChargedCapacity | Select-Object -First 1
    $batPct = $null
    if ($batStatic -and $batFull -and $batStatic.DesignedCapacity -gt 0) {
      $batPct = [math]::Min(100, [math]::Round(($batFull.FullChargedCapacity / $batStatic.DesignedCapacity) * 100))
    }
    @{
      mediaType = if ($disk) { "$($disk.MediaType)" } else { "Unknown" }
      busType   = if ($disk) { "$($disk.BusType)" } else { "Unknown" }
      health    = if ($disk) { "$($disk.HealthStatus)" } else { "Unknown" }
      slotsUsed = ($mem | Measure-Object).Count
      slotsTot  = if ($arr) { [int]$arr.MemoryDevices } else { $null }
      cpuName   = if ($cpu) { $cpu.Name.Trim() } else { "Unknown CPU" }
      batPct    = $batPct
    } | ConvertTo-Json -Compress
    """

    try:
        proc = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps_script],
            capture_output=True, text=True, timeout=7, creationflags=CREATE_NO_WINDOW
        )
        if proc.returncode == 0 and proc.stdout.strip():
            data = json.loads(proc.stdout.strip())
            media = str(data.get("mediaType", "Unknown")).upper()
            bus = str(data.get("busType", "")).upper()
            if "NVME" in bus:
                fallback["os_drive_type"] = "NVME"
            elif "SSD" in media:
                fallback["os_drive_type"] = "SSD"
            elif "HDD" in media:
                fallback["os_drive_type"] = "HDD"

            health = str(data.get("health", "Unknown")).lower()
            if health in ("healthy", "warning", "unhealthy"):
                fallback["smart_verified"] = True
                fallback["smart_ok"] = (health == "healthy")

            if data.get("slotsUsed"):
                fallback["ram_slots_used"] = int(data["slotsUsed"])
            if data.get("slotsTot"):
                fallback["ram_slots_total"] = int(data["slotsTot"])
            if data.get("cpuName"):
                fallback["cpu_name"] = data["cpuName"]
            if data.get("batPct") is not None:
                fallback["battery_health_pct"] = int(data["batPct"])
    except Exception:
        pass

    return fallback


def run_full_diagnosis(progress_cb=None) -> dict:
    """Runs all 7 checks, background app grouper, tweaks check, and hardware probe."""
    def step(idx):
        if progress_cb:
            progress_cb(idx)

    step(0)
    c_free_gb, c_free_pct = get_c_drive_space()
    top_folders = scan_top_user_folders()

    step(1)
    startup_apps = get_enabled_startup_apps()
    bg_apps = get_grouped_background_apps()

    step(2)
    cpu_avg, ram_avg = get_averaged_cpu_ram()
    uptime_days = get_uptime_days()

    step(3)
    junk_info = scan_safe_junk()

    step(4)
    pending_restart = check_pending_restart()

    step(5)
    rb_gb = get_recycle_bin_gb()
    dns_ms = measure_dns_ms()

    step(6)
    tweaks = inspect_safe_windows_tweaks()

    step(7)
    hw = probe_hardware()

    return {
        "is_admin": is_admin(),
        "c_free_gb": c_free_gb,
        "c_free_pct": c_free_pct,
        "top_folders": top_folders,
        "ram_used_pct": ram_avg,
        "startup_count": len(startup_apps),
        "startup_apps": startup_apps,
        "background_apps": bg_apps,
        "cpu_avg_pct": cpu_avg,
        "uptime_days": uptime_days,
        "junk_gb": junk_info["junk_gb"],
        "junk_files": junk_info["files"],
        "junk_skipped_recent": junk_info["skipped_recent"],
        "pending_restart": pending_restart,
        "updates_available": False,
        "recycle_bin_gb": rb_gb,
        "dns_ms": dns_ms,
        "tweaks": tweaks,
        **hw,
    }

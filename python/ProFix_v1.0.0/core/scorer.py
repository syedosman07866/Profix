"""ProFix 75/25 Health Score Engine (Software 75 + Hardware 25)."""


def calculate_health_score(m: dict) -> dict:
    """
    Calculates 0-100 PC Health Score from raw diagnostic metrics.
    Returns overall score, grade, 75/25 breakdown, cap reason, and instant fixable gain.
    """
    scores = {}

    # 1. C: Drive Free Space (Max 20)
    gb, pct = float(m.get("c_free_gb", 0)), float(m.get("c_free_pct", 0))
    if gb >= 40 or pct >= 20:
        scores["c_drive"] = 20
    elif gb >= 25 or pct >= 15:
        scores["c_drive"] = 15
    elif gb >= 15 or pct >= 10:
        scores["c_drive"] = 10
    elif gb >= 5 or pct >= 5:
        scores["c_drive"] = 5
    else:
        scores["c_drive"] = 0

    # 2. RAM Pressure - 3s average % (Max 15)
    ram_pct = float(m.get("ram_used_pct", 0))
    scores["ram_pressure"] = (
        15 if ram_pct < 65 else 10 if ram_pct < 80 else 5 if ram_pct < 90 else 0
    )

    # 3. Startup Apps - enabled non-MS count (Max 12)
    st = int(m.get("startup_count", 0))
    scores["startup"] = 12 if st <= 3 else 8 if st <= 6 else 4 if st <= 10 else 0

    # 4. CPU (3s avg) + Uptime days (Max 5 + 5 = 10)
    cpu = float(m.get("cpu_avg_pct", 0))
    cpu_pts = 5 if cpu < 40 else 3 if cpu < 70 else 1 if cpu < 85 else 0
    up = float(m.get("uptime_days", 0))
    up_pts = 5 if up < 3 else 3 if up < 7 else 1 if up < 14 else 0
    scores["cpu_uptime"] = cpu_pts + up_pts

    # 5. Safe Junk Files >24h in GB (Max 8)
    junk = float(m.get("junk_gb", 0))
    scores["junk"] = 8 if junk < 0.5 else 6 if junk < 2.0 else 3 if junk < 5.0 else 0

    # 6. Windows Update / Pending Restart (Max 6)
    if m.get("pending_restart"):
        scores["updates"] = 0
    elif m.get("updates_available"):
        scores["updates"] = 4
    else:
        scores["updates"] = 6

    # 7. Recycle Bin GB + DNS Latency ms (Max 2 + 2 = 4)
    rb = float(m.get("recycle_bin_gb", 0))
    rb_pts = 2 if rb < 0.5 else 1 if rb <= 2.0 else 0
    dns = m.get("dns_ms")
    dns_pts = 0 if (dns is None or dns < 0) else 2 if dns < 50 else 1 if dns <= 150 else 0
    scores["recycle_dns"] = rb_pts + dns_pts
    scores["recycle_only"] = rb_pts
    scores["dns_only"] = dns_pts

    # --- PART B: HARDWARE (Max 25) ---
    # 8. OS Drive Type (Max 12)
    drive_map = {"SSD": 12, "NVME": 12, "HDD": 0}
    drive_type = str(m.get("os_drive_type", "Unknown")).upper()
    scores["hw_drive"] = drive_map.get(drive_type, 7)

    # 9. Total Physical RAM GB (Max 8)
    tot_ram = float(m.get("total_ram_gb", 8))
    scores["hw_ram"] = 8 if tot_ram >= 16 else 5 if tot_ram >= 8 else 0

    # 10. SMART + CPU Threads / Battery Health (Max 5)
    smart_ok = bool(m.get("smart_ok", True))
    cpu_threads = int(m.get("cpu_threads", 4))
    bat_pct = m.get("battery_health_pct")
    if not smart_ok:
        scores["hw_health"] = 0
    elif cpu_threads < 4 or (bat_pct is not None and bat_pct < 60):
        scores["hw_health"] = 2
    else:
        scores["hw_health"] = 5

    software_keys = [
        "c_drive", "ram_pressure", "startup", "cpu_uptime", "junk", "updates", "recycle_dns"
    ]
    hardware_keys = ["hw_drive", "hw_ram", "hw_health"]

    software_score = sum(scores[k] for k in software_keys)
    hardware_score = sum(scores[k] for k in hardware_keys)
    total = software_score + hardware_score

    # Critical Safety Override Caps
    cap_reason = None
    if not smart_ok and total > 39:
        total = 39
        cap_reason = "Urgent: Disk SMART health warning detected — back up your data immediately."
    elif gb < 2.0 and total > 44:
        total = 44
        cap_reason = "Critical: C: drive has under 2 GB free — free space immediately."

    grade = (
        "Excellent" if total >= 85 else
        "Good" if total >= 65 else
        "Fair" if total >= 45 else
        "Poor"
    )

    instant_fixable = (
        (8 - scores["junk"])
        + (2 - rb_pts)
        + (2 - dns_pts)
        + (12 - scores["startup"])
    )

    return {
        "total_score": total,
        "grade": grade,
        "software_score": software_score,   # /75
        "hardware_score": hardware_score,   # /25
        "instant_fixable_pts": instant_fixable,
        "cap_reason": cap_reason,
        "breakdown": scores,
    }

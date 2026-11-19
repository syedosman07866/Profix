"""Automated verification suite for ProFix Health Score & Report Engine."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.scorer import calculate_health_score
from core.reporter import build_txt_report


def run_tests():
    # 1. Slow Office PC (HDD + 8 GB RAM)
    slow_pc = {
        "c_free_gb": 12.0, "c_free_pct": 4.8, "ram_used_pct": 85.0,
        "startup_count": 9, "cpu_avg_pct": 35.0, "uptime_days": 11.0,
        "junk_gb": 3.8, "pending_restart": True, "updates_available": False,
        "recycle_bin_gb": 1.5, "dns_ms": 22,
        "os_drive_type": "HDD", "total_ram_gb": 8, "smart_ok": True,
        "cpu_threads": 8, "battery_health_pct": None,
        "cpu_name": "Intel Core i5-1035G1", "ram_slots_used": 1, "ram_slots_total": 2,
    }
    s1 = calculate_health_score(slow_pc)
    assert s1["software_score"] == 26, f"Expected 26, got {s1['software_score']}"
    assert s1["hardware_score"] == 10, f"Expected 10, got {s1['hardware_score']}"
    assert s1["total_score"] == 36 and s1["grade"] == "Poor", s1

    # 2. Right After 1-Click Safe Fix
    post_fix = {**slow_pc, "c_free_gb": 17.3, "c_free_pct": 6.9, "startup_count": 3, "junk_gb": 0.1, "recycle_bin_gb": 0.0}
    s2 = calculate_health_score(post_fix)
    assert s2["total_score"] == 55 and s2["grade"] == "Fair", s2

    # 3. After Manual Restart
    post_restart = {**post_fix, "ram_used_pct": 60.0, "uptime_days": 0.1, "pending_restart": False}
    s3 = calculate_health_score(post_restart)
    assert s3["total_score"] == 75 and s3["grade"] == "Good", s3

    # 4. After SSD Upgrade
    ssd_pc = {**post_restart, "os_drive_type": "NVME"}
    s4 = calculate_health_score(ssd_pc)
    assert s4["total_score"] == 87 and s4["grade"] == "Excellent", s4

    # 5. Critical SMART Failure Override Cap (<= 39)
    smart_fail = {**ssd_pc, "smart_ok": False}
    s5 = calculate_health_score(smart_fail)
    assert s5["total_score"] == 39 and s5["grade"] == "Poor" and s5["cap_reason"], s5

    # 6. Critical < 2 GB C: Drive Override Cap (<= 44)
    low_disk = {**ssd_pc, "c_free_gb": 1.4, "c_free_pct": 0.6}
    s6 = calculate_health_score(low_disk)
    assert s6["total_score"] == 44 and s6["grade"] == "Poor" and s6["cap_reason"], s6

    # 7. Report Formatting Verification
    txt = build_txt_report(slow_pc, s1, post_fix, s2, {
        "junk_freed_gb": 3.7, "junk_locked_skipped": 4,
        "recycle_bin_emptied": True, "startups_disabled": ["Spotify", "Steam"], "dns_flushed": True,
    })
    assert "36/100 (Poor)  --->  55/100 (Fair)  [+19 pts]" in txt

    print("ALL 7 PROFIX VERIFICATION TESTS PASSED!")


if __name__ == "__main__":
    run_tests()

"""Before vs. After Diagnostic Report Generator (TXT & single-file HTML)."""

import datetime
import html
import platform
from pathlib import Path


def _default_report_dir() -> Path:
    desktop = Path.home() / "Desktop"
    return desktop if desktop.exists() else Path.home()


def build_txt_report(
    before_metrics: dict,
    before_score: dict,
    after_metrics: dict | None = None,
    after_score: dict | None = None,
    fix_result: dict | None = None,
) -> str:
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    host = platform.node() or "Windows-PC"
    os_ver = f"{platform.system()} {platform.release()}"
    slots = (
        f"{before_metrics['ram_slots_used']}/{before_metrics['ram_slots_total']} slots"
        if before_metrics.get("ram_slots_total")
        else "slots N/A"
    )
    smart = "SMART OK" if before_metrics.get("smart_ok", True) else "SMART WARNING"

    lines = [
        "=" * 64,
        "  PROFIX - SLOW PC DOCTOR v1.0 | DIAGNOSTIC & FIX REPORT",
        "=" * 64,
        f"Generated : {now}",
        f"Device    : {host} | {os_ver}",
        f"Hardware  : {before_metrics['cpu_name']} ({before_metrics['cpu_threads']}T)",
        f"            {before_metrics['total_ram_gb']} GB RAM ({slots}) | {before_metrics['os_drive_type']} ({smart})",
        "Mode      : Safe Mode (No Registry Cleanup | No Process Kills | 24h Temp Guard)",
        "",
        "-" * 64,
        "  HEALTH SCORE SUMMARY",
        "-" * 64,
    ]

    if after_score:
        delta = after_score["total_score"] - before_score["total_score"]
        sign = "+" if delta >= 0 else ""
        lines.extend([
            f"Overall Score      : {before_score['total_score']}/100 ({before_score['grade']})  --->  {after_score['total_score']}/100 ({after_score['grade']})  [{sign}{delta} pts]",
            f"  System Health    : {before_score['software_score']}/75  --->  {after_score['software_score']}/75",
            f"  Hardware Ready   : {before_score['hardware_score']}/25  --->  {after_score['hardware_score']}/25",
        ])
    else:
        lines.extend([
            f"Overall Score      : {before_score['total_score']}/100 ({before_score['grade']})",
            f"  System Health    : {before_score['software_score']}/75",
            f"  Hardware Ready   : {before_score['hardware_score']}/25",
        ])

    if fix_result:
        lines.extend(["", "-" * 64, "  SAFE FIXES APPLIED (REVERSIBLE)", "-" * 64])
        lines.append(
            f"[OK] Safe Junk Cleaned   : {fix_result['junk_freed_gb']} GB freed "
            f"({fix_result['junk_locked_skipped']} locked/in-use skipped)"
        )
        if fix_result.get("recycle_bin_emptied"):
            lines.append("[OK] Recycle Bin Emptied : Completed")
        if fix_result.get("startups_disabled"):
            apps = ", ".join(fix_result["startups_disabled"])
            lines.append(f"[OK] Startup Apps Paused : {len(fix_result['startups_disabled'])} ({apps})")
        if fix_result.get("dns_flushed"):
            lines.append("[OK] DNS Cache Flushed   : Completed")

    cur_m = after_metrics or before_metrics
    recs = []
    if cur_m.get("pending_restart") or cur_m.get("uptime_days", 0) >= 3:
        recs.append(f"[SOFTWARE] Restart Windows via Start Menu (current uptime: {cur_m.get('uptime_days', 0)}d).")
    if str(cur_m.get("os_drive_type", "")).upper() == "HDD":
        recs.append("[HARDWARE | HIGH] Upgrade C: drive from HDD to SSD (+12 pts hardware readiness).")
    if cur_m.get("total_ram_gb", 16) < 16:
        recs.append(f"[HARDWARE | MEDIUM] Consider upgrading RAM from {cur_m['total_ram_gb']} GB to 16 GB.")
    if not cur_m.get("smart_ok", True):
        recs.append("[CRITICAL] Drive SMART warning detected — back up personal data immediately!")

    if recs:
        lines.extend(["", "-" * 64, "  NEXT RECOMMENDED ACTIONS", "-" * 64])
        for idx, rec in enumerate(recs, 1):
            lines.append(f"{idx}. {rec}")

    lines.extend([
        "",
        "=" * 64,
        "  Undo Anytime: Open ProFix -> Restore & Logs -> Undo Last Fix",
        "=" * 64,
    ])
    return "\n".join(lines)


def export_report(
    before_metrics: dict,
    before_score: dict,
    after_metrics: dict | None = None,
    after_score: dict | None = None,
    fix_result: dict | None = None,
    fmt: str = "txt",
    output_dir: Path | None = None,
) -> Path:
    stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M")
    out_dir = output_dir or _default_report_dir()
    txt_body = build_txt_report(before_metrics, before_score, after_metrics, after_score, fix_result)

    if fmt == "html":
        out_path = out_dir / f"ProFix_Report_{stamp}.html"
        escaped = html.escape(txt_body)
        html_doc = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>ProFix Report</title>
<style>
  body {{ background:#0F1218; color:#F1F5F9; font-family:'Segoe UI',sans-serif; padding:32px; }}
  .card {{ max-width:780px; margin:auto; background:#171C26; border:1px solid #283142; border-radius:12px; padding:24px; }}
  pre {{ font-family:Consolas,monospace; font-size:13px; line-height:1.55; white-space:pre-wrap; margin:0; }}
</style></head><body><div class="card"><pre>{escaped}</pre></div></body></html>"""
        out_path.write_text(html_doc, encoding="utf-8")
        return out_path

    out_path = out_dir / f"ProFix_Report_{stamp}.txt"
    out_path.write_text(txt_body, encoding="utf-8")
    return out_path

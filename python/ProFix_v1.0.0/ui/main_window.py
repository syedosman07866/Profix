"""ProFix - Slow PC Doctor v1.0 | 3-Zone Fluent Desktop UI (CustomTkinter)."""

import ctypes
import json
import os
import sys
import threading
import tkinter as tk
from pathlib import Path
import customtkinter as ctk

from core.collector import run_full_diagnosis
from core.fixer import (
    RESTORE_FILE,
    apply_safe_fixes,
    apply_safe_tweak,
    close_app_gently,
    undo_last_fix,
)
from core.reporter import export_report
from core.scorer import calculate_health_score


def resource_path(relative: str) -> Path:
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
    return base / relative


class RadialGauge(tk.Canvas):
    """Lightweight native Canvas radial score ring (zero matplotlib/chart bloat)."""

    def __init__(self, master, size=144, **kwargs):
        super().__init__(master, width=size, height=size, highlightthickness=0, bd=0, **kwargs)
        self.size = size

    def render(self, score: int, grade: str, bg: str, track: str, ring: str, text_fg: str, muted_fg: str):
        self.configure(bg=bg)
        self.delete("all")
        pad = 12
        s = self.size
        self.create_oval(pad, pad, s - pad, s - pad, outline=track, width=10)
        extent = -(max(0, min(100, score)) / 100.0) * 359.9
        if score > 0:
            self.create_arc(pad, pad, s - pad, s - pad, start=90, extent=extent, style="arc", outline=ring, width=10)
        self.create_text(s / 2, s / 2 - 10, text=str(score), fill=text_fg, font=("Segoe UI", 30, "bold"))
        self.create_text(s / 2, s / 2 + 22, text=grade.upper(), fill=muted_fg, font=("Segoe UI", 9, "bold"))


class ProFixApp(ctk.CTk):
    def __init__(self):
        super().__init__()
        self.theme_cfg = json.loads(resource_path("config/theme.json").read_text(encoding="utf-8"))
        self.strings = json.loads(resource_path("config/strings.json").read_text(encoding="utf-8"))

        self.mode = "dark"
        ctk.set_appearance_mode("dark")

        self.title(f"{self.strings['app_name']} v{self.strings['version']}")
        self.geometry("1080x700")
        self.minsize(940, 620)

        self.metrics: dict | None = None
        self.score_data: dict | None = None
        self.before_metrics: dict | None = None
        self.before_score: dict | None = None
        self.last_fix_result: dict | None = None
        self.active_tab = "overview"
        self.busy = False

        self.fix_vars = {
            "junk": tk.BooleanVar(value=True),
            "startup": tk.BooleanVar(value=True),
            "recycle_dns": tk.BooleanVar(value=True),
        }
        self.startup_checks: dict[str, tk.BooleanVar] = {}

        self._build_shell()
        self.bind("<F5>", lambda _e: self.start_scan())
        self.bind("<Control-r>", lambda _e: self.start_scan())
        self.bind("<Control-z>", lambda _e: self.switch_tab("restore"))
        self.after(180, self.start_scan)

    @property
    def pal(self) -> dict:
        return self.theme_cfg[self.mode]

    def _grade_color(self, grade: str) -> str:
        return {
            "Excellent": self.pal["status_excellent"],
            "Good": self.pal["status_good"],
            "Fair": self.pal["status_fair"],
            "Poor": self.pal["status_poor"],
        }.get(grade, self.pal["accent_primary"])

    # ---------------- SHELL LAYOUT ----------------
    def _build_shell(self):
        self.configure(fg_color=self.pal["bg_canvas"])
        self.grid_columnconfigure(1, weight=1)
        self.grid_rowconfigure(1, weight=1)

        # Left Navigation Rail
        self.nav_rail = ctk.CTkFrame(
            self, width=215, corner_radius=0,
            fg_color=self.pal["bg_surface"], border_width=1, border_color=self.pal["border_subtle"]
        )
        self.nav_rail.grid(row=0, column=0, rowspan=3, sticky="nsew")
        self.nav_rail.grid_propagate(False)

        self.brand_lbl = ctk.CTkLabel(self.nav_rail, text="ProFix", font=("Segoe UI", 22, "bold"), text_color=self.pal["text_primary"])
        self.brand_lbl.pack(anchor="w", padx=20, pady=(20, 0))
        self.sub_lbl = ctk.CTkLabel(self.nav_rail, text="Slow PC Doctor v1.0", font=("Segoe UI", 12), text_color=self.pal["text_muted"])
        self.sub_lbl.pack(anchor="w", padx=20, pady=(0, 20))

        self.nav_buttons = {}
        nav_items = [
            ("overview", "Overview"),
            ("apps", "Startup & Apps"),
            ("hardware", "Hardware Advisor"),
            ("tweaks", "Safe Tweaks"),
            ("restore", "Restore & Logs"),
        ]
        for key, label in nav_items:
            btn = ctk.CTkButton(
                self.nav_rail, text=f"  {label}", anchor="w", height=38, corner_radius=8,
                font=("Segoe UI", 13, "bold"), fg_color="transparent",
                text_color=self.pal["text_muted"], hover_color=self.pal["bg_elevated"],
                command=lambda k=key: self.switch_tab(k),
            )
            btn.pack(fill="x", padx=12, pady=3)
            self.nav_buttons[key] = btn

        self.theme_btn = ctk.CTkButton(
            self.nav_rail, text="Switch to Light Mode", height=32, corner_radius=8,
            font=("Segoe UI", 12), fg_color=self.pal["bg_elevated"],
            text_color=self.pal["text_primary"], hover_color=self.pal["border_subtle"],
            command=self.toggle_theme,
        )
        self.theme_btn.pack(side="bottom", fill="x", padx=14, pady=16)

        # Top Context Bar
        self.top_bar = ctk.CTkFrame(self, height=54, corner_radius=0, fg_color=self.pal["bg_canvas"])
        self.top_bar.grid(row=0, column=1, sticky="ew", padx=20, pady=(12, 4))
        self.top_bar.grid_columnconfigure(0, weight=1)

        self.hw_pill = ctk.CTkLabel(
            self.top_bar, text="Detecting hardware...", font=("Segoe UI", 12),
            fg_color=self.pal["bg_surface"], text_color=self.pal["text_muted"],
            corner_radius=14, padx=12, pady=5,
        )
        self.hw_pill.grid(row=0, column=0, sticky="w")

        right_bar = ctk.CTkFrame(self.top_bar, fg_color="transparent")
        right_bar.grid(row=0, column=1, sticky="e")

        self.priv_pill = ctk.CTkButton(
            right_bar, text="Standard Mode", height=28, corner_radius=14,
            font=("Segoe UI", 11, "bold"), fg_color=self.pal["bg_surface"],
            text_color=self.pal["text_muted"], hover_color=self.pal["bg_elevated"],
            command=self._relaunch_as_admin,
        )
        self.priv_pill.pack(side="left", padx=(0, 10))

        self.rescan_btn = ctk.CTkButton(
            right_bar, text="Re-Scan (F5)", width=112, height=32, corner_radius=8,
            font=("Segoe UI", 12, "bold"), fg_color=self.pal["bg_elevated"],
            text_color=self.pal["text_primary"], hover_color=self.pal["border_subtle"],
            command=self.start_scan,
        )
        self.rescan_btn.pack(side="left")

        # Scrollable Workspace
        self.workspace = ctk.CTkScrollableFrame(self, fg_color=self.pal["bg_canvas"], corner_radius=0)
        self.workspace.grid(row=1, column=1, sticky="nsew", padx=20, pady=(4, 8))
        self.workspace.grid_columnconfigure(0, weight=1)

        # Bottom Toast / Trust Bar
        self.toast_bar = ctk.CTkLabel(
            self, text=f"  {self.strings['trust_banner']}", anchor="w", height=30,
            font=("Segoe UI", 11), fg_color=self.pal["bg_surface"], text_color=self.pal["text_muted"],
        )
        self.toast_bar.grid(row=2, column=1, sticky="ew")

        self._highlight_nav()

    def _highlight_nav(self):
        for key, btn in self.nav_buttons.items():
            active = (key == self.active_tab)
            btn.configure(
                fg_color=self.pal["bg_elevated"] if active else "transparent",
                text_color=self.pal["text_primary"] if active else self.pal["text_muted"],
                hover_color=self.pal["bg_elevated"],
            )

    def switch_tab(self, tab_key: str):
        self.active_tab = tab_key
        self._highlight_nav()
        self.render_workspace()

    def toggle_theme(self):
        self.mode = "light" if self.mode == "dark" else "dark"
        ctk.set_appearance_mode(self.mode)
        self.configure(fg_color=self.pal["bg_canvas"])
        self.nav_rail.configure(fg_color=self.pal["bg_surface"], border_color=self.pal["border_subtle"])
        self.brand_lbl.configure(text_color=self.pal["text_primary"])
        self.sub_lbl.configure(text_color=self.pal["text_muted"])
        self.top_bar.configure(fg_color=self.pal["bg_canvas"])
        self.workspace.configure(fg_color=self.pal["bg_canvas"])
        self.hw_pill.configure(fg_color=self.pal["bg_surface"], text_color=self.pal["text_muted"])
        self.priv_pill.configure(fg_color=self.pal["bg_surface"], hover_color=self.pal["bg_elevated"])
        self.rescan_btn.configure(
            fg_color=self.pal["bg_elevated"], text_color=self.pal["text_primary"], hover_color=self.pal["border_subtle"]
        )
        self.toast_bar.configure(fg_color=self.pal["bg_surface"], text_color=self.pal["text_muted"])
        self.theme_btn.configure(
            text="Switch to Dark Mode" if self.mode == "light" else "Switch to Light Mode",
            fg_color=self.pal["bg_elevated"], text_color=self.pal["text_primary"], hover_color=self.pal["border_subtle"],
        )
        self._highlight_nav()
        self.render_workspace()

    def show_toast(self, msg: str, color: str | None = None):
        self.toast_bar.configure(text=f"  {msg}", text_color=color or self.pal["text_primary"])

    def _relaunch_as_admin(self):
        if sys.platform != "win32" or (self.metrics and self.metrics.get("is_admin")):
            return
        try:
            script = os.path.abspath(sys.argv[0])
            params = "" if getattr(sys, "frozen", False) else f'"{script}"'
            ctypes.windll.shell32.ShellExecuteW(None, "runas", sys.executable, params, None, 1)
            self.destroy()
        except Exception:
            self.show_toast("Admin elevation cancelled — continuing safely in Standard Mode.")

    # ---------------- WORKERS ----------------
    def start_scan(self, is_post_fix: bool = False):
        if self.busy:
            return
        self.busy = True
        self.rescan_btn.configure(state="disabled")
        self._render_scanning_view()

        def worker():
            def on_step(idx):
                steps = self.strings["scan_steps"]
                msg = steps[idx] if idx < len(steps) else "Finishing..."
                self.after(0, lambda: self._update_scan_progress((idx + 1) / len(steps), msg))

            metrics = run_full_diagnosis(progress_cb=on_step)
            score = calculate_health_score(metrics)
            self.after(0, lambda: self._on_scan_complete(metrics, score, is_post_fix))

        threading.Thread(target=worker, daemon=True).start()

    def _render_scanning_view(self):
        for w in self.workspace.winfo_children():
            w.destroy()
        card = ctk.CTkFrame(
            self.workspace, fg_color=self.pal["bg_surface"], corner_radius=12,
            border_width=1, border_color=self.pal["border_subtle"]
        )
        card.grid(row=0, column=0, sticky="ew", pady=40, padx=10)
        ctk.CTkLabel(card, text="Diagnosing Your PC...", font=("Segoe UI", 20, "bold"), text_color=self.pal["text_primary"]).pack(pady=(28, 8))
        self.scan_status_lbl = ctk.CTkLabel(card, text=self.strings["scan_steps"][0], font=("Segoe UI", 13), text_color=self.pal["text_muted"])
        self.scan_status_lbl.pack(pady=(0, 16))
        self.scan_bar = ctk.CTkProgressBar(card, width=420, height=10, progress_color=self.pal["accent_primary"])
        self.scan_bar.set(0.08)
        self.scan_bar.pack(pady=(0, 30))

    def _update_scan_progress(self, val: float, msg: str):
        if hasattr(self, "scan_bar") and self.scan_bar.winfo_exists():
            self.scan_bar.set(val)
            self.scan_status_lbl.configure(text=msg)

    def _on_scan_complete(self, metrics: dict, score: dict, is_post_fix: bool):
        self.busy = False
        self.rescan_btn.configure(state="normal")
        self.metrics = metrics
        self.score_data = score

        if not is_post_fix or self.before_metrics is None:
            self.before_metrics = metrics
            self.before_score = score

        self.startup_checks = {
            app["name"]: tk.BooleanVar(value=(app["safety"] == "safe"))
            for app in metrics["startup_apps"]
        }

        # Auto-select fix checkboxes only when actionable
        self.fix_vars["junk"].set(metrics["junk_gb"] >= 0.05)
        self.fix_vars["startup"].set(any(v.get() for v in self.startup_checks.values()))
        self.fix_vars["recycle_dns"].set(metrics["recycle_bin_gb"] >= 0.05 or (metrics["dns_ms"] is not None and metrics["dns_ms"] >= 50))

        cpu_short = metrics["cpu_name"].split("@")[0].replace("(R)", "").replace("(TM)", "").strip()[:26]
        self.hw_pill.configure(text=f"{cpu_short}  •  {metrics['total_ram_gb']} GB RAM  •  {metrics['os_drive_type']}")
        if metrics["is_admin"]:
            self.priv_pill.configure(text="Admin Active", text_color=self.pal["status_excellent"], state="disabled")
        else:
            self.priv_pill.configure(text="Standard Mode (Elevate)", text_color=self.pal["status_fair"], state="normal")

        if is_post_fix and self.before_score:
            delta = score["total_score"] - self.before_score["total_score"]
            self.show_toast(
                f"Done! Health Score: {self.before_score['total_score']} -> {score['total_score']} (+{max(0, delta)} pts).",
                self.pal["status_excellent"],
            )
        else:
            self.show_toast(self.strings["trust_banner"], self.pal["text_muted"])

        self.render_workspace()

    def run_one_click_fix(self):
        if self.busy or not self.metrics:
            return
        self.busy = True
        self.show_toast("Applying selected safe fixes and saving Undo snapshot...", self.pal["accent_primary"])

        clean_files = self.metrics["junk_files"] if self.fix_vars["junk"].get() else None
        selected_startups = [n for n, v in self.startup_checks.items() if v.get()] if self.fix_vars["startup"].get() else None
        empty_bin = self.fix_vars["recycle_dns"].get() and self.metrics["recycle_bin_gb"] > 0
        flush_dns = self.fix_vars["recycle_dns"].get()

        def worker():
            res = apply_safe_fixes(
                clean_junk_files=clean_files,
                disable_startups=selected_startups,
                empty_recycle_bin=empty_bin,
                flush_dns=flush_dns,
            )
            self.after(0, lambda: self._after_fix(res))

        threading.Thread(target=worker, daemon=True).start()

    def _after_fix(self, fix_result: dict):
        self.last_fix_result = fix_result
        self.busy = False
        self.start_scan(is_post_fix=True)

    def _handle_gentle_close(self, app_name: str, pids: list[int]):
        res = close_app_gently(pids)
        self.show_toast(f"{app_name}: {res['message']}", self.pal["status_excellent"] if res["ok"] else self.pal["status_fair"])

    def _handle_tweak(self, tweak_id: str, enable: bool):
        if not self.metrics:
            return
        res = apply_safe_tweak(tweak_id, enable, self.metrics["tweaks"])
        self.show_toast(res["message"], self.pal["status_excellent"] if res["ok"] else self.pal["status_fair"])
        if res["ok"]:
            self.start_scan(is_post_fix=True)

    def trigger_undo(self):
        res = undo_last_fix()
        self.show_toast(res["message"], self.pal["status_excellent"] if res["ok"] else self.pal["status_fair"])
        if res["ok"]:
            self.start_scan()

    def trigger_export(self, fmt: str = "txt"):
        if not self.before_metrics or not self.before_score:
            return
        path = export_report(
            self.before_metrics, self.before_score,
            self.metrics if self.last_fix_result else None,
            self.score_data if self.last_fix_result else None,
            self.last_fix_result, fmt=fmt,
        )
        self.show_toast(f"Report saved to {path}", self.pal["status_excellent"])

    # ---------------- TAB RENDERERS ----------------
    def render_workspace(self):
        for w in self.workspace.winfo_children():
            w.destroy()
        if not self.metrics or not self.score_data:
            return
        {
            "overview": self._render_overview,
            "apps": self._render_apps_tab,
            "hardware": self._render_hardware_tab,
            "tweaks": self._render_tweaks_tab,
            "restore": self._render_restore_tab,
        }[self.active_tab]()

    def _render_overview(self):
        m, s = self.metrics, self.score_data
        grade_color = self._grade_color(s["grade"])

        hero = ctk.CTkFrame(
            self.workspace, fg_color=self.pal["bg_surface"], corner_radius=12,
            border_width=1, border_color=self.pal["border_subtle"]
        )
        hero.grid(row=0, column=0, sticky="ew", pady=(0, 14))
        hero.grid_columnconfigure(1, weight=1)

        gauge = RadialGauge(hero, size=144)
        gauge.grid(row=0, column=0, padx=22, pady=18)
        gauge.render(s["total_score"], s["grade"], self.pal["bg_surface"], self.pal["bg_elevated"], grade_color, self.pal["text_primary"], self.pal["text_muted"])

        info = ctk.CTkFrame(hero, fg_color="transparent")
        info.grid(row=0, column=1, sticky="nsew", padx=(0, 22), pady=18)

        verdict = self.strings["verdicts"][s["grade"]]
        headline = s["cap_reason"] or verdict["headline"]
        ctk.CTkLabel(info, text=headline, font=("Segoe UI", 18, "bold"), text_color=self.pal["text_primary"], anchor="w").pack(fill="x")
        ctk.CTkLabel(info, text=verdict["subtitle"], font=("Segoe UI", 13), text_color=self.pal["text_muted"], anchor="w").pack(fill="x", pady=(2, 12))

        bars = ctk.CTkFrame(info, fg_color="transparent")
        bars.pack(fill="x", pady=(0, 12))
        bars.grid_columnconfigure((0, 1), weight=1)
        for col, (lbl, val, mx) in enumerate([
            (f"System Health: {s['software_score']}/75", s["software_score"], 75),
            (f"Hardware Readiness: {s['hardware_score']}/25", s["hardware_score"], 25),
        ]):
            box = ctk.CTkFrame(bars, fg_color="transparent")
            box.grid(row=0, column=col, sticky="ew", padx=(0 if col == 0 else 14, 0))
            ctk.CTkLabel(box, text=lbl, font=("Segoe UI", 12, "bold"), text_color=self.pal["text_muted"], anchor="w").pack(fill="x")
            pb = ctk.CTkProgressBar(box, height=8, fg_color=self.pal["bg_elevated"], progress_color=self.pal["accent_primary"] if col == 0 else self.pal["status_good"])
            pb.set(val / mx)
            pb.pack(fill="x", pady=(4, 0))

        cta_row = ctk.CTkFrame(info, fg_color="transparent")
        cta_row.pack(fill="x")
        self.cta_btn = ctk.CTkButton(cta_row, height=38, corner_radius=8, font=("Segoe UI", 13, "bold"), command=self.run_one_click_fix)
        self.cta_btn.pack(side="left")

        if self.last_fix_result:
            ctk.CTkButton(
                cta_row, text="Export Report", height=38, corner_radius=8, font=("Segoe UI", 12, "bold"),
                fg_color=self.pal["bg_elevated"], text_color=self.pal["text_primary"],
                hover_color=self.pal["border_subtle"], command=lambda: self.trigger_export("txt"),
            ).pack(side="left", padx=(10, 0))

        self._refresh_cta_label()

        ctk.CTkLabel(self.workspace, text="Diagnostic Checks (7)", font=("Segoe UI", 15, "bold"), text_color=self.pal["text_primary"]).grid(row=1, column=0, sticky="w", pady=(2, 8))

        b = s["breakdown"]
        top_folder_note = ""
        if m.get("top_folders"):
            top = m["top_folders"][0]
            top_folder_note = f" Largest user folder: {top['name']} ({top['gb']} GB)."

        rows = [
            ("Safe Junk Files (24h+)", f"{m['junk_gb']} GB cleanable ({m['junk_skipped_recent']} recent kept)", b["junk"], 8, "junk",
             "Targets User Temp, Windows Temp, and WER reports strictly older than 24 hours. Active/locked files are safely skipped."),
            ("Startup Apps", f"{m['startup_count']} non-Microsoft apps enabled at login", b["startup"], 12, "startup",
             "Pauses selected startup apps via native Windows StartupApproved flag with full 1-click Undo backup. Customize selections in Startup & Apps."),
            ("Recycle Bin & DNS", f"{m['recycle_bin_gb']} GB bin  •  DNS {m['dns_ms']} ms" if m["dns_ms"] is not None else f"{m['recycle_bin_gb']} GB bin  •  Offline", b["recycle_dns"], 4, "recycle_dns",
             "Empties Windows Recycle Bin and runs standard 'ipconfig /flushdns' to clear stale DNS entries."),
            ("C: Drive Free Space", f"{m['c_free_gb']} GB free ({m['c_free_pct']}%)", b["c_drive"], 20, None,
             f"Windows stays smooth with 20%+ or 40 GB+ free on C:.{top_folder_note}"),
            ("RAM Pressure (3s avg)", f"{m['ram_used_pct']}% of {m['total_ram_gb']} GB in use", b["ram_pressure"], 15, None,
             "Close heavy background apps gently from the Startup & Apps tab or restart Windows to clear cached memory."),
            ("CPU Load & Uptime", f"{m['cpu_avg_pct']}% CPU  •  Up {m['uptime_days']} days", b["cpu_uptime"], 10, None,
             "Windows Fast Startup keeps uptime running across Shut Down. Use Start -> Restart for a full clean kernel reset."),
            ("Windows Update / Restart", "Pending Restart active" if m["pending_restart"] else "No pending restart", b["updates"], 6, None,
             "Pending updates keep background installers busy until you restart Windows manually."),
        ]
        rows.sort(key=lambda r: r[2] / r[3])

        for idx, (title, metric, pts, max_pts, fix_key, detail) in enumerate(rows, start=2):
            self._build_check_row(idx, title, metric, pts, max_pts, fix_key, detail)

    def _refresh_cta_label(self):
        if not hasattr(self, "cta_btn") or not self.metrics or not self.score_data:
            return
        m, b = self.metrics, self.score_data["breakdown"]
        count, gb, pts = 0, 0.0, 0

        if self.fix_vars["junk"].get() and m["junk_gb"] >= 0.05:
            count += 1; gb += m["junk_gb"]; pts += (8 - b["junk"])
        safe_st = [n for n, v in self.startup_checks.items() if v.get()]
        if self.fix_vars["startup"].get() and safe_st:
            count += 1; pts += (12 - b["startup"])
        if self.fix_vars["recycle_dns"].get():
            count += 1; gb += m["recycle_bin_gb"]; pts += (4 - b["recycle_dns"])

        if count == 0 and self.score_data["total_score"] >= 85:
            self.cta_btn.configure(text=self.strings["cta"]["healthy"], state="disabled", fg_color=self.pal["status_excellent"])
        elif count == 0:
            self.cta_btn.configure(text=self.strings["cta"]["none_selected"], state="disabled", fg_color=self.pal["bg_elevated"])
        elif gb >= 0.1:
            txt = self.strings["cta"]["fix_with_space"].format(count=count, gb=gb, pts=pts)
            self.cta_btn.configure(text=txt, state="normal", fg_color=self.pal["accent_primary"])
        else:
            txt = self.strings["cta"]["fix_no_space"].format(count=count, pts=pts)
            self.cta_btn.configure(text=txt, state="normal", fg_color=self.pal["accent_primary"])

    def _build_check_row(self, grid_row: int, title: str, metric: str, pts: int, max_pts: int, fix_key: str | None, detail: str):
        ratio = pts / max_pts
        dot_col = self.pal["status_excellent"] if ratio >= 0.75 else self.pal["status_fair"] if ratio >= 0.4 else self.pal["status_poor"]

        card = ctk.CTkFrame(
            self.workspace, fg_color=self.pal["bg_surface"], corner_radius=10,
            border_width=1, border_color=self.pal["border_subtle"]
        )
        card.grid(row=grid_row, column=0, sticky="ew", pady=4)
        card.grid_columnconfigure(0, weight=1)

        top = ctk.CTkFrame(card, fg_color="transparent")
        top.grid(row=0, column=0, sticky="ew", padx=14, pady=10)
        top.grid_columnconfigure(1, weight=1)

        ctk.CTkLabel(top, text="●", font=("Segoe UI", 14), text_color=dot_col, width=18).grid(row=0, column=0, padx=(0, 8))
        ctk.CTkLabel(top, text=title, font=("Segoe UI", 13, "bold"), text_color=self.pal["text_primary"], anchor="w").grid(row=0, column=1, sticky="w")
        ctk.CTkLabel(top, text=metric, font=("Segoe UI", 12), text_color=self.pal["text_muted"]).grid(row=0, column=2, padx=14)
        ctk.CTkLabel(top, text=f"{pts}/{max_pts} pts", font=("Segoe UI", 11, "bold"), fg_color=self.pal["bg_elevated"], text_color=dot_col, corner_radius=10, padx=8, pady=2).grid(row=0, column=3, padx=(0, 10))

        if fix_key:
            ctk.CTkCheckBox(
                top, text="Fix", width=54, checkbox_width=18, checkbox_height=18,
                font=("Segoe UI", 12), variable=self.fix_vars[fix_key], command=self._refresh_cta_label
            ).grid(row=0, column=4)

        drawer = ctk.CTkLabel(card, text=detail, font=("Segoe UI", 12), text_color=self.pal["text_muted"], anchor="w", wraplength=760, justify="left")
        state = {"open": False}

        def toggle_drawer():
            state["open"] = not state["open"]
            if state["open"]:
                drawer.grid(row=1, column=0, sticky="ew", padx=36, pady=(0, 10))
            else:
                drawer.grid_forget()

        ctk.CTkButton(top, text="▾", width=26, height=26, fg_color="transparent", text_color=self.pal["text_muted"], hover_color=self.pal["bg_elevated"], command=toggle_drawer).grid(row=0, column=5, padx=(4, 0))

    def _render_apps_tab(self):
        row_idx = 0
        ctk.CTkLabel(self.workspace, text="Startup Apps (Auto-Launch at Login)", font=("Segoe UI", 17, "bold"), text_color=self.pal["text_primary"]).grid(row=row_idx, column=0, sticky="w", pady=(0, 4))
        row_idx += 1
        ctk.CTkLabel(self.workspace, text="Checked apps will be paused when you click 1-Click Fix (backed up for Undo). Windows security apps are protected.", font=("Segoe UI", 12), text_color=self.pal["text_muted"]).grid(row=row_idx, column=0, sticky="w", pady=(0, 10))
        row_idx += 1

        apps = self.metrics["startup_apps"]
        if not apps:
            ctk.CTkLabel(self.workspace, text="No non-Microsoft startup apps currently enabled.", font=("Segoe UI", 13), text_color=self.pal["status_excellent"]).grid(row=row_idx, column=0, sticky="w", pady=(0, 14))
            row_idx += 1
        else:
            for app in apps:
                card = ctk.CTkFrame(self.workspace, fg_color=self.pal["bg_surface"], corner_radius=10, border_width=1, border_color=self.pal["border_subtle"])
                card.grid(row=row_idx, column=0, sticky="ew", pady=3)
                card.grid_columnconfigure(0, weight=1)
                is_safe = app["safety"] == "safe"
                ctk.CTkCheckBox(card, text=app["name"], font=("Segoe UI", 13, "bold"), variable=self.startup_checks[app["name"]]).grid(row=0, column=0, sticky="w", padx=14, pady=10)
                ctk.CTkLabel(
                    card, text="SAFE TO PAUSE" if is_safe else "USE WITH CAUTION",
                    font=("Segoe UI", 10, "bold"), fg_color=self.pal["bg_elevated"],
                    text_color=self.pal["status_excellent"] if is_safe else self.pal["status_fair"],
                    corner_radius=10, padx=8, pady=3
                ).grid(row=0, column=1, padx=14)
                row_idx += 1

        # Background Running Apps Section
        ctk.CTkLabel(self.workspace, text="Background Running Apps (You Decide ON/OFF)", font=("Segoe UI", 17, "bold"), text_color=self.pal["text_primary"]).grid(row=row_idx, column=0, sticky="w", pady=(18, 4))
        row_idx += 1
        ctk.CTkLabel(self.workspace, text="Grouped non-system apps using 15+ MB RAM. 'Close Gently' sends a normal window close signal (never force-kills).", font=("Segoe UI", 12), text_color=self.pal["text_muted"]).grid(row=row_idx, column=0, sticky="w", pady=(0, 10))
        row_idx += 1

        bg_apps = self.metrics.get("background_apps", [])
        if not bg_apps:
            ctk.CTkLabel(self.workspace, text="No heavy background user apps detected right now.", font=("Segoe UI", 13), text_color=self.pal["text_muted"]).grid(row=row_idx, column=0, sticky="w")
            return

        for bg in bg_apps:
            card = ctk.CTkFrame(self.workspace, fg_color=self.pal["bg_surface"], corner_radius=10, border_width=1, border_color=self.pal["border_subtle"])
            card.grid(row=row_idx, column=0, sticky="ew", pady=3)
            card.grid_columnconfigure(0, weight=1)

            ram_txt = f"{bg['ram_mb']/1024:.2f} GB" if bg["ram_mb"] >= 1024 else f"{bg['ram_mb']:.0f} MB"
            ctk.CTkLabel(card, text=f"{bg['name']}  ({bg['process_count']} proc)", font=("Segoe UI", 13, "bold"), text_color=self.pal["text_primary"]).grid(row=0, column=0, sticky="w", padx=14, pady=10)
            ctk.CTkLabel(card, text=f"{ram_txt} RAM", font=("Segoe UI", 12), text_color=self.pal["text_muted"]).grid(row=0, column=1, padx=12)
            ctk.CTkButton(
                card, text="Close Gently", width=106, height=28, corner_radius=8,
                font=("Segoe UI", 11, "bold"), fg_color=self.pal["bg_elevated"],
                text_color=self.pal["text_primary"], hover_color=self.pal["border_subtle"],
                command=lambda n=bg["name"], p=bg["pids"]: self._handle_gentle_close(n, p),
            ).grid(row=0, column=2, padx=14)
            row_idx += 1

    def _render_hardware_tab(self):
        m = self.metrics
        ctk.CTkLabel(self.workspace, text="Hardware Readiness & Upgrade Advisor", font=("Segoe UI", 18, "bold"), text_color=self.pal["text_primary"]).grid(row=0, column=0, sticky="w", pady=(0, 6))
        if not m["is_admin"]:
            ctk.CTkLabel(self.workspace, text=self.strings["non_admin_notice"], font=("Segoe UI", 12), text_color=self.pal["status_fair"]).grid(row=1, column=0, sticky="w", pady=(0, 12))

        cards = []
        if not m["smart_ok"]:
            cards.append(("CRITICAL ALERT", self.pal["status_poor"], "Disk SMART Failure Predicted", "Your drive reported a health warning. Back up personal files to an external drive or cloud right away."))
        if m["os_drive_type"] == "HDD":
            cards.append(("HIGH IMPACT (+12 pts)", self.pal["status_poor"], "OS Drive is a Mechanical HDD", "Upgrading C: to an SSD typically makes boot and app launches 4x-5x faster."))
        elif m["os_drive_type"] in ("SSD", "NVME"):
            cards.append(("OPTIMAL", self.pal["status_excellent"], f"Fast {m['os_drive_type']} Boot Drive", "No storage hardware upgrade needed."))
        else:
            cards.append(("INFO", self.pal["status_good"], "Boot Drive Type Unverified", "Run as Administrator to verify whether C: is an SSD or HDD."))

        if m["total_ram_gb"] < 16:
            slot_msg = ""
            if m["ram_slots_total"] and m["ram_slots_used"] and m["ram_slots_used"] < m["ram_slots_total"]:
                slot_msg = f" ({m['ram_slots_total'] - m['ram_slots_used']} open RAM slot available!)"
            cards.append(("MEDIUM IMPACT (+3 pts)", self.pal["status_fair"], f"{m['total_ram_gb']} GB Total RAM", f"Upgrading to 16 GB reduces browser and multitasking lag{slot_msg}."))
        else:
            cards.append(("OPTIMAL", self.pal["status_excellent"], f"{m['total_ram_gb']} GB RAM Installed", "Sufficient memory for smooth everyday Windows multitasking."))

        if m.get("battery_health_pct") is not None:
            bp = m["battery_health_pct"]
            col = self.pal["status_fair"] if bp < 60 else self.pal["status_excellent"]
            cards.append(("BATTERY HEALTH", col, f"Laptop Battery Capacity: {bp}%", "Severe battery wear (<60%) can trigger power throttling on battery."))

        for idx, (pill, col, title, desc) in enumerate(cards, start=2):
            c = ctk.CTkFrame(self.workspace, fg_color=self.pal["bg_surface"], corner_radius=12, border_width=1, border_color=self.pal["border_subtle"])
            c.grid(row=idx, column=0, sticky="ew", pady=5)
            ctk.CTkLabel(c, text=pill, font=("Segoe UI", 10, "bold"), fg_color=self.pal["bg_elevated"], text_color=col, corner_radius=10, padx=8, pady=3).pack(anchor="w", padx=16, pady=(12, 4))
            ctk.CTkLabel(c, text=title, font=("Segoe UI", 15, "bold"), text_color=self.pal["text_primary"]).pack(anchor="w", padx=16)
            ctk.CTkLabel(c, text=desc, font=("Segoe UI", 12), text_color=self.pal["text_muted"], wraplength=760, justify="left").pack(anchor="w", padx=16, pady=(2, 12))

    def _render_tweaks_tab(self):
        tw = self.metrics["tweaks"]
        ctk.CTkLabel(self.workspace, text="Safe Windows Speed Tweaks (100% Reversible)", font=("Segoe UI", 18, "bold"), text_color=self.pal["text_primary"]).grid(row=0, column=0, sticky="w", pady=(0, 6))
        ctk.CTkLabel(self.workspace, text="Native Windows settings only — no risky debloater scripts. Every change is backed up for 1-Click Undo.", font=("Segoe UI", 12), text_color=self.pal["text_muted"]).grid(row=1, column=0, sticky="w", pady=(0, 12))

        tweak_rows = [
            (
                "Power Plan Optimization",
                f"Active plan: {tw['power_plan_name']}. Power Saver throttles CPU responsiveness.",
                "Switch to Balanced" if tw["is_power_saver"] else "Balanced Active",
                tw["is_power_saver"],
                lambda: self._handle_tweak("power_balanced", True),
            ),
            (
                "Window Transparency Effects",
                "Turning off blur/transparency speeds up UI on 4-8 GB RAM systems while keeping sharp fonts.",
                "Turn Off for Speed" if tw["transparency_enabled"] else "Turn On Transparency",
                True,
                lambda: self._handle_tweak("transparency", not tw["transparency_enabled"]),
            ),
            (
                "Windows Storage Sense",
                "Lets Windows automatically clear old temp files periodically in the background.",
                "Disable Storage Sense" if tw["storage_sense_enabled"] else "Enable Storage Sense",
                True,
                lambda: self._handle_tweak("storage_sense", not tw["storage_sense_enabled"]),
            ),
        ]

        for idx, (title, desc, btn_txt, enabled, cmd) in enumerate(tweak_rows, start=2):
            c = ctk.CTkFrame(self.workspace, fg_color=self.pal["bg_surface"], corner_radius=12, border_width=1, border_color=self.pal["border_subtle"])
            c.grid(row=idx, column=0, sticky="ew", pady=5)
            c.grid_columnconfigure(0, weight=1)
            ctk.CTkLabel(c, text=title, font=("Segoe UI", 14, "bold"), text_color=self.pal["text_primary"]).grid(row=0, column=0, sticky="w", padx=16, pady=(12, 2))
            ctk.CTkLabel(c, text=desc, font=("Segoe UI", 12), text_color=self.pal["text_muted"]).grid(row=1, column=0, sticky="w", padx=16, pady=(0, 12))
            ctk.CTkButton(
                c, text=btn_txt, height=32, corner_radius=8, font=("Segoe UI", 12, "bold"),
                state="normal" if enabled else "disabled",
                fg_color=self.pal["accent_primary"] if enabled else self.pal["bg_elevated"],
                command=cmd,
            ).grid(row=0, column=1, rowspan=2, padx=16)

    def _render_restore_tab(self):
        ctk.CTkLabel(self.workspace, text="Restore Point & Diagnostic Reports", font=("Segoe UI", 18, "bold"), text_color=self.pal["text_primary"]).grid(row=0, column=0, sticky="w", pady=(0, 12))

        card = ctk.CTkFrame(self.workspace, fg_color=self.pal["bg_surface"], corner_radius=12, border_width=1, border_color=self.pal["border_subtle"])
        card.grid(row=1, column=0, sticky="ew", pady=6)

        has_backup = RESTORE_FILE.exists()
        status_txt = f"Restore snapshot ready: {RESTORE_FILE}" if has_backup else "No reversible changes made yet. Every fix or tweak saves a restore snapshot here automatically."
        ctk.CTkLabel(card, text="1-Click Undo Last Fix", font=("Segoe UI", 15, "bold"), text_color=self.pal["text_primary"]).pack(anchor="w", padx=16, pady=(14, 2))
        ctk.CTkLabel(card, text=status_txt, font=("Segoe UI", 12), text_color=self.pal["text_muted"]).pack(anchor="w", padx=16, pady=(0, 14))

        btn_row = ctk.CTkFrame(card, fg_color="transparent")
        btn_row.pack(anchor="w", padx=16, pady=(0, 16))
        ctk.CTkButton(
            btn_row, text="Undo Last Fix", state="normal" if has_backup else "disabled",
            fg_color=self.pal["status_fair"], text_color="#0F172A", font=("Segoe UI", 12, "bold"),
            command=self.trigger_undo,
        ).pack(side="left", padx=(0, 10))
        ctk.CTkButton(
            btn_row, text="Export TXT Report", fg_color=self.pal["accent_primary"],
            font=("Segoe UI", 12, "bold"), command=lambda: self.trigger_export("txt"),
        ).pack(side="left", padx=(0, 10))
        ctk.CTkButton(
            btn_row, text="Export HTML Report", fg_color=self.pal["bg_elevated"],
            text_color=self.pal["text_primary"], font=("Segoe UI", 12, "bold"),
            command=lambda: self.trigger_export("html"),
        ).pack(side="left")

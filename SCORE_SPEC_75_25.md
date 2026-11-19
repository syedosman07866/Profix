# ProFix Health Score — 75/25 Split Architecture (adopted 19 Nov 2026, Syed's spec)

## Why
Honesty vs satisfaction: hardware penalty too high → Fix still leaves score low, user thinks tool is useless. Hardware ignored → 4 GB RAM + HDD laptop shows 98/100 after cleanup, fake. Solution: Overall Score 0-100, with two sub-bars underneath: System Health (x/75) + Hardware Health (y/25).

## UI
- Big Overall Score + grade badge.
- Below it: System Health progress bar (x/75), Hardware Health progress bar (y/25).
- Diagnose screen also shows: "1-Click Fix se +X points turant badhenge" (instant_fixable_pts).

## Part A — Software & System (max 75)
1. C: Drive Free Space (20 pts, dual rule GB OR %) — 20: 40 GB+ or 20%+ · 15: 25-39 GB or 15-19.9% · 10: 15-24 GB or 10-14.9% · 5: 5-14 GB or 5-9.9% · 0: <5 GB AND <5%
2. RAM Pressure, 3-sec average (15) — 15: <65% used · 10: 65-79% · 5: 80-89% · 0: 90%+
3. Startup Apps, enabled non-Microsoft only (12) — 12: 0-3 · 8: 4-6 · 4: 7-10 · 0: 11+
4. CPU + Uptime (5+5=10) — CPU 5-sec avg: 5 (<40%) · 3 (40-69%) · 1 (70-84%) · 0 (85%+). Uptime: 5 (<3d) · 3 (3-6d) · 1 (7-13d) · 0 (14+d)
5. Junk / Temp, 24h+ safe files (8) — 8: <500 MB · 6: 500 MB-1.9 GB · 3: 2-4.9 GB · 0: 5 GB+
6. Windows Update / Pending Restart (6) — 6: no pending reboot · 4: updates pending, no reboot needed yet · 0: pending restart flag active
7. Recycle Bin + DNS (2+2=4) — Recycle Bin: 2 (<500 MB) · 1 (500 MB-2 GB) · 0 (2 GB+). DNS: 2 (<50 ms) · 1 (50-150 ms) · 0 (timeout/fail, None/-1)

## Part B — Hardware Bottlenecks (max 25, all read-only WMI/CIM)
8. OS Boot Drive C: (12) — 12: NVMe / SATA SSD · 7: Unknown / VM / eMMC · 0: Mechanical HDD (MSFT_PhysicalDisk MediaType)
9. Total Physical RAM (8) — 8: 16 GB+ · 5: 8-15 GB · 0: <8 GB
10. Disk SMART + CPU/Battery (5) — 5: SMART OK + 4+ CPU threads + Battery 60%+ (if laptop) · 2: dual-core CPU or Battery <60% · 0: SMART Warning / Failing (MSStorageDriver_FailurePredictStatus)

## Critical Safety Overrides (hard caps, applied AFTER total)
- SMART Failing / Predict Failure: final = min(score, 39) → Poor + red alert "Hard drive failure risk detected — backup data first!"
- C: Critically Full (<2 GB free): final = min(score, 44) → Poor, Windows pagefile/updates fail risk.

## Grades
- 85-100 Excellent (Green) — "PC healthy hai — koi major bottleneck nahi."
- 65-84 Good (Teal/Blue) — "Smooth chal raha hai, minor cleanup se aur tez hoga."
- 45-64 Fair (Amber) — "Noticeable slowdown hai — 1-Click Fix recommend hai."
- 0-44 Poor (Red) — "Heavy bottleneck ya critical issue — immediate action chahiye."

## Instant fixable points
instant_fixable = (8 - junk_pts) + (2 - recycle_pts) + (2 - dns_pts) + (12 - startup_pts)

## Reference example (Syed's test case)
HDD + 8 GB RAM, C: 12 GB free (4.8%), 9 startup, 85% RAM, 35% CPU, 11d uptime, 3.8 GB junk, Pending Restart ON, 1.5 GB Recycle Bin, DNS OK.
- Before Fix: 26/75 + 10/25 = 36 Poor
- Right after 1-Click Fix (5.3 GB freed, 6 startup off): 45/75 + 10/25 = 55 Fair (+19, prompt "Restart to unlock +20 more pts")
- After manual Restart (uptime 0d, reboot clear, RAM 60%): 65/75 + 10/25 = 75 Good. Note: "Hardware cap: SSD lagane par score 87 Excellent ho jayega."

## Engineering rules
- CPU & RAM: NO 1-second snapshot (ProFix itself spikes CPU on launch). Wait 1 sec after scan starts, then take 3-5 sec average.
- Non-admin fallback: if MSFT_PhysicalDisk / SMART cannot be read without admin, do NOT crash or 0 — use Unknown (7 pts) + SMART Unchecked (5 pts) + note "Run as Administrator for full hardware diagnostics."
- Python reference function calculate_health_score(m) from Syed's message is the authoritative logic — port it exactly to C# and PowerShell, same tiers, same caps, same grade bands.

## Status
- Spec adopted 19 Nov 2026. **IMPLEMENTED 19 Nov 2026 in ProFix v1.0.0** — ported exactly to `ProFix.ps1` (`Get-HealthScore`) and `dotnet/Program.cs` (`CalculateHealthScore`), exe rebuilt (SHA-256 f9e1ea31ca7e72261550cff07983da18cb4349136f63533903ab726a0b63bc5c). Reference example verified by hand: 36 Poor → 55 Fair → 75 Good; caps 39 (SMART) and 44 (C: <2 GB) verified. One deliberate deviation: the SMART cap applies only when SMART was actually checked AND failing (see BUILD_REPORT — the spec Python's `if not m["smart_ok"]` would cap every non-admin PC at 39). Hardware collection for scoring is v1.0 (read-only); full Upgrade Advisor UI stays v1.1.

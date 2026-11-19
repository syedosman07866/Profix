# ProFix — Python version (Syed's build)

This folder holds Syed's Python implementation of ProFix v1.0.0
(CustomTkinter UI + `psutil`), in `ProFix_v1.0.0/`.

It does the same job as the C# / PowerShell version in the repo root:
7 diagnostics, 75/25 Health Score, safe 1-Click Fix, Undo via
`ProFix_Restore.json`, Before vs After report (TXT + HTML) — plus the
v1.1/v1.2 extras already built in (background-app grouper with gentle
WM_CLOSE, safe Windows tweaks, top-folders X-Ray).

Known differences from the C# version (19 Nov 2026, checked by Muse):
- Junk scan covers Temp + Windows Temp + WER only — **no browser caches yet**.
- No real Windows System Restore Point — "Restore" here is the Undo
  snapshot (`ProFix_Restore.json`) only.
- Startup apps are paused with the Task Manager method (StartupApproved
  flag), not by deleting the Run value.

## Build the .exe

**Option A — GitHub Actions (no Python needed on your PC):**
Actions tab → "Build ProFix Python exe (Windows)" → Run workflow.
The finished `ProFix_v1.0.0.exe` + `SHA256SUMS.txt` appear as an
artifact on the run page.

**Option B — on your own Windows PC:**
Double-click `ProFix_v1.0.0/build_release.bat` (needs Python + internet).
Output: `ProFix_v1.0.0/dist/ProFix_v1.0.0.exe`.

**Dev run:** `ProFix_v1.0.0/run_dev.bat` (runs the 7 unit tests, then the UI).

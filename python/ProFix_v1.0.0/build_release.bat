@echo off
echo === Building ProFix - Slow PC Doctor v1.0.0 ===

if exist .build_venv rmdir /s /q .build_venv
python -m venv .build_venv
call .build_venv\Scripts\activate.bat

pip install --upgrade pip
pip install -r requirements.txt pyinstaller

pyinstaller --noconfirm --clean --onefile --windowed --noupx ^
  --name "ProFix_v1.0.0" ^
  --add-data "config;config" ^
  --collect-data customtkinter ^
  --exclude-module matplotlib ^
  --exclude-module numpy ^
  --exclude-module pandas ^
  --exclude-module scipy ^
  --exclude-module PySide6 ^
  --exclude-module PyQt6 ^
  --exclude-module unittest ^
  --exclude-module pydoc ^
  --exclude-module doctest ^
  main.py

echo.
echo === Generating SHA-256 Checksum ===
certutil -hashfile dist\ProFix_v1.0.0.exe SHA256 > dist\SHA256SUMS.txt
type dist\SHA256SUMS.txt

echo.
echo Build complete! Test dist\ProFix_v1.0.0.exe in Standard & Admin modes before release.
pause

@echo off
REM ProFix v1.0.0 - launcher
REM Licensed under the MIT License. Copyright (c) 2026 Syed Osman (PRO SUPPORT).
REM Double-click this file. It starts ProFix.ps1, with admin rights if possible.

cd /d "%~dp0"

REM 1. The script must sit next to this launcher.
if not exist "%~dp0ProFix.ps1" (
    echo ProFix.ps1 not found in this folder.
    echo Copy ProFix.ps1 next to Run-ProFix.bat and try again.
    echo.
    pause
    exit /b 1
)

REM 2. Already admin? Run directly.
net session >nul 2>&1
if %errorlevel% equ 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ProFix.ps1"
    goto :done
)

REM 3. Not admin - ask Windows for elevation. If the user says No on the
REM    UAC prompt (or elevation is unavailable), fall back to running
REM    without admin: Restore Point stays off, the rest works.
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0ProFix.ps1' -Wait"
if %errorlevel% neq 0 (
    echo.
    echo Admin was declined or unavailable - running without admin rights.
    echo System Restore Point will be disabled.
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ProFix.ps1"
)

:done
echo.
echo ProFix closed. Press any key to close this window.
pause >nul

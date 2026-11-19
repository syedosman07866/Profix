@echo off
title ProFix - Slow PC Doctor v1.0 (Dev Test)
if not exist .venv (
    echo Creating clean virtual environment...
    python -m venv .venv
)
call .venv\Scripts\activate.bat
pip install -q -r requirements.txt
echo Running unit tests...
python tests\test_scorer.py
echo Launching ProFix UI...
python main.py
pause

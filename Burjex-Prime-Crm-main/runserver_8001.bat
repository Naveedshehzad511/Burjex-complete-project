@echo off
cd /d "%~dp0"
if exist "venv\Scripts\activate.bat" (
  call venv\Scripts\activate.bat
) else if exist ".venv\Scripts\activate.bat" (
  call .venv\Scripts\activate.bat
) else (
  echo No virtual environment found.
  pause
  exit /b 1
)
echo Port 8001 — use if 8000 is busy: http://127.0.0.1:8001/
python manage.py runserver 127.0.0.1:8001
pause

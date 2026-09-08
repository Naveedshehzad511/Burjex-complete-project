@echo off
cd /d "%~dp0"
if exist "venv\Scripts\activate.bat" (
  call venv\Scripts\activate.bat
) else if exist ".venv\Scripts\activate.bat" (
  call .venv\Scripts\activate.bat
)
REM Bind 0.0.0.0 so Android emulator (10.0.2.2) and physical devices on LAN can connect.
echo Starting Django at http://0.0.0.0:8000/  (emulator: http://10.0.2.2:8000/)
python manage.py runserver 0.0.0.0:8000
pause

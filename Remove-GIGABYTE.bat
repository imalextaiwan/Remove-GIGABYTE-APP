@echo off
rem One-click removal of all GIGABYTE software. Double-click to run (asks for admin via UAC).
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Remove-GigabyteApps.ps1"
echo.
pause

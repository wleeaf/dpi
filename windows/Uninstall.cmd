@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0dpi.ps1" -Command uninstall -Elevate
pause

@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
echo [AutoRunAndPush] Starting...
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%AutoRunAndPush.ps1"
endlocal
pause

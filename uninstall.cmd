@echo off
chcp 65001 >nul
setlocal
echo === 豆包额度球 卸载 ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
echo.
pause

@echo off
chcp 65001 >nul
setlocal
echo === 豆包额度球 一键安装 ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause

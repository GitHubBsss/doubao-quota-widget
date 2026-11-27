@echo off
chcp 65001 >nul
echo 正在后台检查额度球，请等 3 秒...
start "" "%SystemRoot%\System32\wscript.exe" "%~dp0start-daemon.vbs"
timeout /t 3 >nul

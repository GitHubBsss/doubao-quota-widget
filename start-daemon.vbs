' 静默启动守护进程：wscript 是 GUI 子系统，不产生控制台窗口
' 用法：wscript.exe start-daemon.vbs
Dim sh, fso, base, ps
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
ps = """" & sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"""
ps = ps & " -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & base & "\doubao-widget-daemon.ps1"""
sh.Run ps, 0, False

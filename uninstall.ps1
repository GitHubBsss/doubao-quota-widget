# uninstall.ps1 —— 卸载：停守护、取消自启、还原快捷方式、移除挂件
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = 9222

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }

Say '停止挂件守护进程…'
$lock = Join-Path $here 'daemon.lock'
if (Test-Path -LiteralPath $lock) {
    $pidTxt = (Get-Content -LiteralPath $lock -Raw -ErrorAction SilentlyContinue).Trim()
    if ($pidTxt -match '^\d+$') {
        $p = Get-Process -Id ([int]$pidTxt) -ErrorAction SilentlyContinue
        if ($p) { $p | Stop-Process -Force; Say '  已停止' } else { Say '  进程已不在' }
    }
}

Say '取消开机自启…'
if (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DoubaoWidget' -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DoubaoWidget' -Force
    Say '  已删除 HKCU Run: DoubaoWidget'
} else {
    Say '  本来就没注册'
}

Say '还原快捷方式…'
$sh = New-Object -ComObject WScript.Shell
$links = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) '豆包.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) '豆包.lnk')
)
foreach ($l in $links) {
    $bak = $l + '.bak'
    if (Test-Path -LiteralPath $bak) {
        Copy-Item -LiteralPath $bak -Destination $l -Force
        Say ('  已还原：' + (Split-Path $l -Leaf))
    } else {
        try {
            $sc = $sh.CreateShortcut($l)
            $args = ([string]$sc.Arguments) -replace '\s*--remote-debugging-port=\d+', ''
            $sc.Arguments = $args.Trim()
            $sc.Save()
            Say ('  已去掉参数：' + (Split-Path $l -Leaf))
        } catch { }
    }
}

Say '移除页面里的挂件…'
try {
    $list = Invoke-WebRequest -Uri "http://127.0.0.1:$port/json/list" -UseBasicParsing -TimeoutSec 3 | Select-Object -ExpandProperty Content | ConvertFrom-Json
    $chat = $list | Where-Object { $_.type -eq 'page' -and $_.url -match 'doubao-chat/chat' } | Select-Object -First 1
    if ($chat) {
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ws.ConnectAsync([Uri]$chat.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(5000)
        $msg = '{"id":1,"method":"Runtime.evaluate","params":{"expression":"var e=document.getElementById(''dbx-root'');if(e)e.remove();1","returnByValue":true}}'
        $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
        $ws.SendAsync($bytes, [Net.WebSockets.WebSocketMessageType]::Text, $false, [Threading.CancellationToken]::None).Wait(5000)
        Start-Sleep -Milliseconds 500
        try { $ws.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'bye', [Threading.CancellationToken]::None).Wait(2000) } catch { }
        Say '  已清除'
    } else {
        Say '  当前没有打开的聊天窗口，跳过'
    }
} catch {
    Say '  豆包没在运行或端口没开，跳过（重启后挂件自然不再出现）'
}

Say ''
Say '卸载完成。运行时数据（data.json / daemon.log / quota-history.json 等）仍在本目录，可自行删除。' 'Green'

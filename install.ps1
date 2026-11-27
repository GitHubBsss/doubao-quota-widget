# install.ps1 —— 一键安装：定位豆包、改快捷方式带调试端口、注册自启、拉起守护进程
# 用法：双击 install.cmd，或在 PowerShell 里执行 powershell -ExecutionPolicy Bypass -File install.ps1

param(
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = 9222
$portUrl = "http://127.0.0.1:$port/json/version"

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }

function Test-DebugPort {
    try { $null = Invoke-WebRequest -Uri $portUrl -UseBasicParsing -TimeoutSec 2; return $true } catch { return $false }
}

function Find-DoubaoExe {
    $p = Get-Process -Name Doubao -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
    if ($p -and (Test-Path -LiteralPath $p.Path)) { return $p.Path }

    $sh = New-Object -ComObject WScript.Shell
    $links = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) '豆包.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) '豆包.lnk')
    )
    foreach ($l in $links) {
        if (Test-Path -LiteralPath $l) {
            try {
                $t = $sh.CreateShortcut($l).TargetPath
                if ($t -and (Test-Path -LiteralPath $t)) { return $t }
            } catch { }
        }
    }

    $cands = @('D:\Soft\Doubao\app\Doubao.exe')
    if ($env:ProgramFiles) { $cands += (Join-Path $env:ProgramFiles 'Doubao\app\Doubao.exe') }
    if (${env:ProgramFiles(x86)}) { $cands += (Join-Path ${env:ProgramFiles(x86)} 'Doubao\app\Doubao.exe') }
    if ($env:LOCALAPPDATA) {
        $cands += (Join-Path $env:LOCALAPPDATA 'Doubao\app\Doubao.exe')
        $cands += (Join-Path $env:LOCALAPPDATA 'Programs\Doubao\app\Doubao.exe')
    }
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }

    $un = @()
    foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall')) {
        $un += Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        } | Where-Object { $_.DisplayName -match '豆包|Doubao' }
    }
    foreach ($u in $un) {
        if ($u.DisplayIcon) {
            $i = ($u.DisplayIcon -split ',')[0].Trim('"')
            if (Test-Path -LiteralPath $i) { return $i }
        }
        if ($u.InstallLocation) {
            $guess = Join-Path $u.InstallLocation 'app\Doubao.exe'
            if (Test-Path -LiteralPath $guess) { return $guess }
        }
    }
    return $null
}

function Set-DoubaoShortcut([string]$exe) {
    $sh = New-Object -ComObject WScript.Shell
    $links = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) '豆包.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) '豆包.lnk')
    )
    $changed = @()
    foreach ($l in $links) {
        if (-not (Test-Path -LiteralPath $l)) { continue }
        try {
            $sc = $sh.CreateShortcut($l)
            $bak = $l + '.bak'
            if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $l -Destination $bak }
            $args = [string]$sc.Arguments
            if ($args -notmatch '--remote-debugging-port') {
                $args = ($args + ' --remote-debugging-port=' + $port).Trim()
            }
            $sc.TargetPath = $exe
            $sc.Arguments = $args
            $sc.Save()
            $changed += $l
        } catch {
            Say ("快捷方式处理失败：" + $l + " -> " + $_.Exception.Message) 'Yellow'
        }
    }
    return $changed
}

function Test-WidgetFresh {
    # 守护每 30 秒会写一行 updated/injected；90 秒内有这类日志，说明挂件在页面里且数据在刷新
    $log = Join-Path $here 'daemon.log'
    if (-not (Test-Path -LiteralPath $log)) { return $false }
    $lines = Get-Content -LiteralPath $log -Tail 12 -ErrorAction SilentlyContinue
    foreach ($ln in $lines) {
        if ($ln -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
            $t = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
            if (((Get-Date) - $t).TotalSeconds -lt 90 -and $ln -match '(injected|updated) ->') { return $true }
        }
    }
    return $false
}

# ---- 1. 找豆包 ----
Say '[1/4] 定位豆包客户端…'
$exe = Find-DoubaoExe
if (-not $exe) {
    Say '没找到 Doubao.exe。请先安装豆包客户端，或把本脚本放到能自动识别的位置后重试。' 'Red'
    exit 1
}
Say ("  " + $exe)

# ---- 2. 改快捷方式 ----
Say '[2/4] 给快捷方式加上调试端口参数…'
$changed = Set-DoubaoShortcut $exe
if ($changed.Count -gt 0) { Say ("  已处理：" + ($changed -join '、')) } else { Say '  没有找到桌面/开始菜单快捷方式，跳过' 'Yellow' }

# ---- 3. 需要时重启豆包 ----
Say '[3/4] 检查调试端口…'
if (Test-DebugPort) {
    Say '  端口已就绪，无需重启'
} else {
    $procs = @(Get-Process -Name Doubao -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0 -and -not $NoRestart) {
        Say '  豆包正在运行但没开调试端口，正在为你重启…'
        foreach ($p in $procs) { $null = $p.CloseMainWindow() }
        Start-Sleep -Seconds 6
        $still = @(Get-Process -Name Doubao -ErrorAction SilentlyContinue)
        if ($still.Count -gt 0) { $still | Stop-Process -Force; Start-Sleep -Seconds 2 }
    }
    if (-not $NoRestart) {
        Start-Process -FilePath $exe -ArgumentList ('--remote-debugging-port=' + $port)
        $ok = $false
        for ($i = 0; $i -lt 30; $i++) { if (Test-DebugPort) { $ok = $true; break }; Start-Sleep -Seconds 1 }
        if (-not $ok) {
            Say '  调试端口没起来，可能被安全软件拦截或被已有实例接管。关掉所有豆包窗口后重新运行本脚本。' 'Red'
            exit 1
        }
        Say '  端口已就绪'
    } else {
        Say '  已跳过重启（-NoRestart）。请手动关闭并重新打开豆包后再运行一次。' 'Yellow'
        exit 1
    }
}

# ---- 4. 注册自启并拉起守护 ----
Say '[4/4] 注册开机自启并启动挂件守护…'
$vbs = Join-Path $here 'start-daemon.vbs'
if (-not (Test-Path -LiteralPath $vbs)) { Say ('缺少 start-daemon.vbs：' + $vbs) 'Red'; exit 1 }
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-ItemProperty -Path $runKey -Name 'DoubaoWidget' -Value ('"{0}" "{1}"' -f $wscript, $vbs) -PropertyType String -Force | Out-Null
Say '  已写入 HKCU Run: DoubaoWidget'

$lock = Join-Path $here 'daemon.lock'
$running = $false
if (Test-Path -LiteralPath $lock) {
    $pidTxt = (Get-Content -LiteralPath $lock -Raw -ErrorAction SilentlyContinue).Trim()
    if ($pidTxt -match '^\d+$' -and (Get-Process -Id ([int]$pidTxt) -ErrorAction SilentlyContinue)) { $running = $true }
}
if (-not $running) {
    $null = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('"{0}" "{1}"' -f $wscript, $vbs) }
    Say '  守护进程已拉起（无窗口）'
} else {
    Say '  守护进程已在运行'
}

$log = Join-Path $here 'daemon.log'
$injected = $false
for ($i = 0; $i -lt 20; $i++) {
    if (Test-WidgetFresh) { $injected = $true; break }
    Start-Sleep -Seconds 1
}
if ($injected) { Say '  挂件已注入，看窗口右侧的额度球' 'Green' }
else { Say ('  还没看到注入成功，稍等几秒；若一直没有，看日志：' + $log) 'Yellow' }

Say ''
Say '完成。之后打开豆包，额度球会自动出现；按住球拖动可换位置，双击打开额度管理页。' 'Green'
Say ('日志：' + $log)

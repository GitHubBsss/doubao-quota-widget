<#
  豆包额度挂件 · 命令行
  用法: powershell -ExecutionPolicy Bypass -File widget.ps1 <命令>

  status    查看状态（版本 / 进程 / 额度 / 是否暂停）
  pause     暂停采样（挂件保留，数据不再刷新）
  resume    恢复采样
  refresh   立即刷新一次额度
  export    导出 quota-history.csv
  report    生成并打开 dashboard.html 用量报表（同时更新 weekly-report.md）
  open      打开程序目录
  restart   重启守护进程（改代码后用）
  update    从 GitHub 拉取最新版本并重启
  quit      退出守护进程（挂件随之消失）
#>
param([Parameter(Position = 0)][string]$Action = 'status')

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$lockF   = Join-Path $here 'daemon.lock'
$pauseF  = Join-Path $here 'daemon.pause'
$cmdF    = Join-Path $here 'command.txt'
$dataF   = Join-Path $here 'data.json'
$csvF    = Join-Path $here 'quota-history.csv'
$dashF   = Join-Path $here 'dashboard.html'
$reportF = Join-Path $here 'weekly-report.md'
$vbs     = Join-Path $here 'start-daemon.vbs'

function Get-DaemonPid {
    if (-not (Test-Path -LiteralPath $lockF)) { return 0 }
    $raw = (Get-Content -LiteralPath $lockF -Raw -ErrorAction SilentlyContinue).Trim()
    if ($raw -notmatch '^\d+$') { return 0 }
    $proc = Get-Process -Id ([int]$raw) -ErrorAction SilentlyContinue
    if ($proc) { return [int]$raw }
    return 0
}

function Send-Cmd([string]$cmd) {
    if (-not (Get-DaemonPid)) { Write-Host '守护进程未运行，先执行 restart' ; return $false }
    Set-Content -LiteralPath $cmdF -Value $cmd -Encoding ascii
    Start-Sleep -Milliseconds 900
    return $true
}

function Stop-Daemon {
    $p = Get-DaemonPid
    if ($p) {
        Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 600
        Write-Host "已停止守护进程 (pid=$p)"
    } else {
        Write-Host '守护进程本来就没运行'
    }
    Remove-Item -LiteralPath $lockF -Force -ErrorAction SilentlyContinue
}

function Start-Daemon {
    if (-not (Test-Path -LiteralPath $vbs)) { Write-Host '缺少 start-daemon.vbs，无法启动'; return $false }
    Start-Process -FilePath "$env:SystemRoot\System32\wscript.exe" -ArgumentList $vbs
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 300
        $p = Get-DaemonPid
        if ($p) { Write-Host "守护进程已启动 (pid=$p)"; return $true }
    }
    Write-Host '启动超时，请查看 daemon.log'
    return $false
}

function Test-StagedUpdate([string]$dir) {
    $js = Join-Path $dir 'widget.js'
    $daemon = Join-Path $dir 'doubao-widget-daemon.ps1'
    $cli = Join-Path $dir 'widget.ps1'
    if (-not (Test-Path -LiteralPath $js) -or -not (Test-Path -LiteralPath $daemon)) {
        Write-Host '更新包缺少 widget.js / doubao-widget-daemon.ps1'
        return $false
    }
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        & $node.Source --check $js 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host 'widget.js 语法校验失败'; return $false }
    }
    foreach ($ps in @($daemon, $cli)) {
        if (-not (Test-Path -LiteralPath $ps)) { continue }
        $txt = [IO.File]::ReadAllText($ps)
        $errs = $null
        $null = [System.Management.Automation.PSParser]::Tokenize($txt, [ref]$errs)
        if ($errs -and $errs.Count -gt 0) {
            Write-Host ('脚本语法校验失败: ' + (Split-Path $ps -Leaf))
            return $false
        }
    }
    return $true
}

switch ($Action.Trim().ToLower()) {
    'status' {
        $p = Get-DaemonPid
        Write-Host ('守护进程: ' + $(if ($p) { "运行中 (pid=$p)" } else { '未运行' }))
        if (Test-Path -LiteralPath $pauseF) { Write-Host '采样状态: 已暂停' } else { Write-Host '采样状态: 运行中' }
        if (Test-Path -LiteralPath $dataF) {
            $d = $null
            for ($i = 0; $i -lt 4; $i++) {
                try { $d = [IO.File]::ReadAllText($dataF, [Text.Encoding]::UTF8) | ConvertFrom-Json; break } catch { Start-Sleep -Milliseconds 150 }
            }
            if ($d) {
                Write-Host ('版本: ' + $d.ver)
                Write-Host ('额度: ' + $d.badge)
                foreach ($r in @($d.rows)) { Write-Host ('  ' + $r[0] + ': ' + $r[1]) }
                $t = Get-Item -LiteralPath $dataF
                Write-Host ('数据更新时间: ' + $t.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
            } else { Write-Host 'data.json 解析失败' }
        }
        if (Test-Path -LiteralPath $reportF) { Write-Host ('周报: ' + $reportF) }
        if (Test-Path -LiteralPath $dashF) { Write-Host ('报表: ' + $dashF) }
    }
    'pause' {
        Set-Content -LiteralPath $pauseF -Value '1' -Encoding ascii
        [void](Send-Cmd 'pause')
        Write-Host '已暂停采样'
    }
    'resume' {
        Remove-Item -LiteralPath $pauseF -Force -ErrorAction SilentlyContinue
        [void](Send-Cmd 'resume')
        Write-Host '已恢复采样'
    }
    'refresh' {
        if (Send-Cmd 'refresh') { Write-Host '已触发刷新' }
    }
    'export' {
        if (Send-Cmd 'export') { Write-Host ('已导出: ' + $csvF) }
    }
    'report' {
        $before = [datetime]::MinValue
        if (Test-Path -LiteralPath $dashF) { $before = (Get-Item -LiteralPath $dashF).LastWriteTime }
        if (Send-Cmd 'report') {
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 200
                if ((Test-Path -LiteralPath $dashF) -and (Get-Item -LiteralPath $dashF).LastWriteTime -gt $before) { break }
            }
            if (Test-Path -LiteralPath $dashF) {
                Start-Process -FilePath $dashF
                Write-Host ('报表: ' + $dashF)
                Write-Host ('周报: ' + $reportF)
            } else { Write-Host '报表生成失败，请查看 daemon.log' }
        }
    }
    'open' {
        Start-Process -FilePath 'explorer.exe' -ArgumentList $here
    }
    'restart' {
        Stop-Daemon
        $null = Start-Daemon
    }
    'update' {
        Write-Host '从 GitHub 拉取最新版本...'
        $url = 'https://codeload.github.com/GitHubBsss/doubao-quota-widget/zip/refs/heads/main'
        $stamp = Get-Date -Format 'yyyyMMddHHmmss'
        $tmpZip = Join-Path $env:TEMP ('dbx-update-' + $stamp + '.zip')
        $tmpDir = Join-Path $env:TEMP ('dbx-update-' + $stamp)
        try {
            Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing -TimeoutSec 60
        } catch {
            Write-Host ('下载失败: ' + $_.Exception.Message)
            break
        }
        Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir -Force
        $src = Get-ChildItem -LiteralPath $tmpDir -Directory | Select-Object -First 1
        if (-not $src) { Write-Host '压缩包结构异常'; break }

        # 先在临时目录校验，通过后再动现有文件
        if (-not (Test-StagedUpdate $src.FullName)) {
            Write-Host '更新包校验失败，已保留当前版本'
            Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            break
        }

        $files = @('widget.js', 'doubao-widget-daemon.ps1', 'widget.ps1', 'start-daemon.vbs', 'install.ps1', 'install.cmd', 'uninstall.ps1', 'uninstall.cmd', 'README.md', 'config.example.json', 'version.json')
        $backupDir = Join-Path $here ('backup-' + $stamp)
        New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
        foreach ($f in $files) {
            $cur = Join-Path $here $f
            if (Test-Path -LiteralPath $cur) { Copy-Item -LiteralPath $cur -Destination (Join-Path $backupDir $f) -Force }
        }
        foreach ($f in $files) {
            $from = Join-Path $src.FullName $f
            if (Test-Path -LiteralPath $from) {
                Copy-Item -LiteralPath $from -Destination (Join-Path $here $f) -Force
                Write-Host ('更新 ' + $f)
            }
        }
        Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

        Stop-Daemon
        $ok = Start-Daemon
        if (-not $ok) {
            Write-Host '新版本启动失败，正在回滚...'
            foreach ($f in $files) {
                $bak = Join-Path $backupDir $f
                if (Test-Path -LiteralPath $bak) { Copy-Item -LiteralPath $bak -Destination (Join-Path $here $f) -Force }
            }
            $null = Start-Daemon
            Write-Host ('已回滚，备份在 ' + $backupDir)
            break
        }
        Write-Host '更新完成'
    }
    'quit' {
        if (Send-Cmd 'quit') {
            Start-Sleep -Milliseconds 1200
            if (-not (Get-DaemonPid)) { Write-Host '守护进程已退出' } else { Write-Host '退出超时，可执行 restart 后再试' }
        }
    }
    default {
        Write-Host ('未知命令: ' + $Action)
        Write-Host '可用: status / pause / resume / refresh / export / report / open / restart / update / quit'
    }
}

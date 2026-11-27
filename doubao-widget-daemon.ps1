# doubao-widget-daemon.ps1 —— 豆包悬浮额度球守护进程
# 1) 轮询 CDP(127.0.0.1:9222)，给主聊天窗口注入悬浮球；DOM 丢失（刷新/切会话）自动重注
# 2) 定时拉真实额度（走 doubao.com 常驻 iframe 上下文，自带登录态），原地更新面板数据
# 3) 记录额度采样，算出今日累计消耗并画成细折线
# 依赖：豆包带 --remote-debugging-port=9222 启动

$ErrorActionPreference = 'Stop'
$here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$widgetF     = Join-Path $here 'widget.js'
$dataF       = Join-Path $here 'data.json'
$historyF    = Join-Path $here 'quota-history.json'
$dailyF      = Join-Path $here 'daily-usage.json'
$csvF        = Join-Path $here 'quota-history.csv'
$logF        = Join-Path $here 'daemon.log'
$lockF       = Join-Path $here 'daemon.lock'
$posF        = Join-Path $here 'widget-pos.json'
$pauseF      = Join-Path $here 'daemon.pause'
$cmdF        = Join-Path $here 'command.txt'
$dashF       = Join-Path $here 'dashboard.html'
$reportF     = Join-Path $here 'weekly-report.md'
$CdpList     = 'http://127.0.0.1:9222/json/list'
$PollMs      = 2500
$QuotaSec    = 30      # 额度刷新间隔（秒）
$MaxSamples  = 2880    # 历史采样上限（30 秒一次 = 24 小时）
$OpenUrl     = 'https://www.doubao.com/member/quota-management?locale=zh&platform=desktop'

# ---------- 单实例保护 ----------
if (Test-Path -LiteralPath $lockF) {
    $old = (Get-Content -LiteralPath $lockF -Raw -ErrorAction SilentlyContinue).Trim()
    if ($old -match '^\d+$' -and (Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue)) {
        exit
    }
}
Set-Content -LiteralPath $lockF -Value $PID -Encoding ascii

# ---------- 日志 ----------
function Write-Log([string]$msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try {
        if ((Test-Path -LiteralPath $logF) -and (Get-Item -LiteralPath $logF).Length -gt 1MB) {
            [IO.File]::WriteAllText($logF, '')
        }
        Add-Content -LiteralPath $logF -Value $line -Encoding utf8
    } catch { }
}

# ---------- CDP 客户端 ----------
$script:SendSeq = 0
$script:Sessions = @{}   # targetId -> @{ ws; stamp }

function Connect-Cdp([string]$url) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $t = $ws.ConnectAsync([Uri]$url, [Threading.CancellationToken]::None)
    if (-not $t.Wait(4000)) { throw 'connect timeout' }
    return $ws
}

function Send-Cdp($ws, [string]$method, $params) {
    $script:SendSeq++
    $id = $script:SendSeq
    $json = @{ id = $id; method = $method; params = $params } | ConvertTo-Json -Depth 12 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
                  [Threading.CancellationToken]::None).Wait(5000) | Out-Null

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $buf = New-Object byte[] 65536
        $ms  = New-Object System.IO.MemoryStream
        do {
            $rt = $ws.ReceiveAsync((New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$buf)),
                                   [Threading.CancellationToken]::None)
            if (-not $rt.Wait(6000)) { throw 'recv timeout' }
            $r = $rt.Result
            if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'ws closed' }
            $ms.Write($buf, 0, $r.Count)
        } while (-not $r.EndOfMessage)

        $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        $obj  = $text | ConvertFrom-Json
        if ($obj.id -eq $id) { return $obj }
    }
    throw 'response timeout'
}

function Eval-InPage($ws, [string]$expr, [bool]$await = $false) {
    $p = @{ expression = $expr; returnByValue = $true }
    if ($await) { $p.awaitPromise = $true }
    $res = Send-Cdp $ws 'Runtime.evaluate' $p
    if ($res.error) { throw ('cdp error: ' + ($res.error | ConvertTo-Json -Compress)) }
    return $res
}

# ---------- 真实额度抓取 ----------
# aid 优先取 config.json / 环境变量；都没有时从页面 localStorage 的 client_device_info.appId 自动识别
$script:Aid = ''
$script:Scale = 1.0
$script:AlertPct = 20
$script:ConfigQuiet = ''
$cfgF = Join-Path $here 'config.json'
if (Test-Path -LiteralPath $cfgF) {
    try {
        $cfg = Get-Content -LiteralPath $cfgF -Raw | ConvertFrom-Json
        if ($cfg.aid) { $script:Aid = [string]$cfg.aid }
        if ($null -ne $cfg.scale) { $script:Scale = [double]$cfg.scale }
        if ($null -ne $cfg.alert_pct) { $script:AlertPct = [double]$cfg.alert_pct }
        if ($cfg.quiet_hours) { $script:ConfigQuiet = [string]$cfg.quiet_hours }
    } catch { }
}
if (-not $script:Aid -and $env:DOUBAO_AID) { $script:Aid = [string]$env:DOUBAO_AID }

$QuotaBase = 'https://www.doubao.com/alice/commerce/sale/subscription/overview/?aid=__AID__&device_platform=web&doubao_device_platform=web&language=zh&region=CN&sys_region=CN&samantha_web=1&web_platform=desktop&use-olympus-account=1&pc_version=2.38.12'

function Resolve-Aid($list) {
    $t = $list | Where-Object { $_.type -eq 'page' -and $_.url -match 'doubao-chat/chat' } | Select-Object -First 1
    if (-not $t) { return '' }
    $ws = Connect-Cdp $t.webSocketDebuggerUrl
    try {
        $r = Eval-InPage $ws "try{JSON.parse(localStorage.getItem('client_device_info')).appId}catch(e){''}"
        if ($r.result -and $r.result.result) { return [string]$r.result.result.value }
        return ''
    } finally {
        try { $ws.Dispose() } catch { }
    }
}

$QuotaExpr = @'
(async () => {
  try {
    const r = await fetch('__API__', {
      method: 'POST',
      credentials: 'include',
      headers: { 'content-type': 'application/json' },
      body: '{"product_line":"membership"}'
    });
    return await r.text();
  } catch (e) { return 'ERR:' + e.message; }
})()
'@

function Format-Amount([string]$s) {
    $n = [double]($s -replace ',', '')
    if ($n -ge 1000) { return ('{0:0.0}k' -f ($n / 1000)) }
    return ('{0:0}' -f $n)
}

# 窗口重置倒计时：end_time 是毫秒时间戳
function Format-Reset([string]$endTime) {
    if (-not $endTime) { return '—' }
    try {
        $end = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$endTime).ToLocalTime()
        $left = $end - [DateTimeOffset]::Now
        if ($left.TotalMinutes -le 0) { return '已到期' }
        if ($left.TotalHours -lt 1) { return ('剩 {0:0} 分钟' -f $left.TotalMinutes) }
        if ($left.TotalHours -lt 48) { return ('剩 {0:0.0} 小时' -f $left.TotalHours) }
        return ('剩 {0:0.0} 天' -f $left.TotalDays)
    } catch { return '—' }
}

function Get-QuotaMetrics($list) {
    $ctx = $list | Where-Object { $_.url -match '^https://www\.doubao\.com/' } | Select-Object -First 1
    if (-not $ctx) { throw 'no doubao.com context' }

    $ws = Connect-Cdp $ctx.webSocketDebuggerUrl
    try {
        if (-not $script:Aid) {
            try {
                $script:Aid = Resolve-Aid $list
                if ($script:Aid) { Write-Log ('aid -> ' + $script:Aid) }
            } catch { }
        }
        if (-not $script:Aid) { throw 'aid 未识别（可从 config.json 或 DOUBAO_AID 指定）' }

        $api  = $QuotaBase.Replace('__AID__', $script:Aid)
        $expr = $QuotaExpr.Replace('__API__', $api)
        $res  = Eval-InPage $ws $expr $true
        $raw  = $res.result.result.value
        if (-not $raw) { throw 'empty quota response' }
        if ($raw -like 'ERR:*') { throw $raw }
        $q = $raw | ConvertFrom-Json

        $remainStr = [string]$q.data.quota_balance_overview.total_remaining_amount

        # 当前计费窗口（免费号也有一档）
        $wl = $null
        try { $wl = $q.data.incentive_quota_section.window_limit_groups[0].window_limits[0] } catch { }
        $usedNum = 0.0; $totalNum = 0.0; $usedPct = 0.0; $expiry = '—'
        if ($wl) {
            $usedNum  = [double](([string]$wl.used_amount -replace ',', ''))
            $totalNum = [double](([string]$wl.total_amount -replace ',', ''))
            $usedPct  = [double]$wl.used_percent
            $expiry   = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$wl.end_time).ToLocalTime().ToString('MM-dd HH:mm')
        }

        # 5 小时 / 周 / 月 窗口（有权益才存在；免费号为空）
        $windows = @()
        try {
            foreach ($g in @($q.data.window_limit_section.window_limit_groups)) {
                if (-not $g) { continue }
                foreach ($w in @($g.window_limits)) {
                    if (-not $w) { continue }
                    $t = [string]$w.window_type
                    $label = switch ($t) {
                        'H5' { '5 小时额度' }
                        'D7' { '本周额度' }
                        'M1' { '本月额度' }
                        default { '窗口额度' }
                    }
                    $windows += [pscustomobject]@{
                        Type  = $t
                        Label = $label
                        Pct   = [math]::Round(100 - [double]$w.used_percent, 0)
                        Reset = (Format-Reset ([string]$w.end_time))
                    }
                }
            }
        } catch { }

        # 环形表：外圈放周额度、内圈放 5 小时额度（顺序固定，颜色才好对应）；都没有就用整体剩余比例
        $rings = @()
        if ($windows.Count -gt 0) {
            $rings = @($windows | Where-Object { $_.Type -eq 'D7' })
            $rings += @($windows | Where-Object { $_.Type -eq 'H5' })
            if ($rings.Count -eq 0) { $rings = @($windows) }
        }
        if ($rings.Count -eq 0) {
            $pctRemain = if ($totalNum -gt 0) { 100 - (100 * $usedNum / $totalNum) } else { 100 }
            $rings = @([pscustomobject]@{ Pct = [math]::Round($pctRemain, 0); Type = 'all' })
        }
        if ($rings.Count -gt 2) { $rings = @($rings | Select-Object -First 2) }

        $remainPct = if ($totalNum -gt 0) { [math]::Round(100 - (100 * $usedNum / $totalNum), 1) } else { 100 }

        return [pscustomobject]@{
            Badge     = Format-Amount $remainStr
            RemainStr = $remainStr
            RemainNum = [double]($remainStr -replace ',', '')
            Used      = $usedNum
            Total     = $totalNum
            Pct       = $usedPct
            RemainPct = $remainPct
            Expiry    = $expiry
            Count     = $q.data.incentive_quota_section.entitlement_count
            Member    = if ($q.data.member_info.hasActiveSubscription) { '订阅中' } else { '免费版' }
            Rings     = $rings
            Windows   = $windows
        }
    } finally {
        try { $ws.Dispose() } catch { }
    }
}

# ---------- 历史采样与今日趋势 ----------
$script:History = @()
if (Test-Path -LiteralPath $historyF) {
    try {
        $h = Get-Content -LiteralPath $historyF -Raw -Encoding utf8 | ConvertFrom-Json
        $script:History = @($h)
    } catch { $script:History = @() }
}

function Add-Sample([double]$used, [double]$remain) {
    $nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $script:History = @($script:History) + [pscustomobject]@{ t = [int64]$nowMs; u = [int]$used; r = [int]$remain }
    if ($script:History.Count -gt $MaxSamples) {
        $script:History = @($script:History | Select-Object -Last $MaxSamples)
    }
    try {
        $json = @($script:History) | ConvertTo-Json -Compress -Depth 4
        [IO.File]::WriteAllText($historyF, $json, (New-Object Text.UTF8Encoding($false)))
    } catch { }
    Add-DailyDelta $used
}

function Get-TodayTrend {
    if (-not $script:History -or $script:History.Count -eq 0) {
        return @{ Points = @(); Consumed = 0 }
    }

    $now       = Get-Date
    $offsetMs  = ($now - $now.Date).TotalMilliseconds
    $midnightMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $offsetMs

    $baseUsed = $null
    foreach ($s in $script:History) {
        if ([int64]$s.t -lt [int64]$midnightMs) { $baseUsed = [double]$s.u } else { break }
    }

    $prev = $baseUsed
    $total = 0
    $cum = New-Object System.Collections.ArrayList

    foreach ($s in $script:History) {
        if ([int64]$s.t -lt [int64]$midnightMs) { continue }
        $u = [double]$s.u
        if ($null -eq $prev) { $prev = $u }
        $d = $u - $prev
        if ($d -gt 0) { $total += $d }
        $null = $cum.Add([int]$total)
        $prev = $u
    }

    if ($cum.Count -eq 0) { return @{ Points = @(); Consumed = 0 } }

    # 降采样到最多 48 个点，保留末点
    $pts = @($cum)
    if ($pts.Count -gt 48) {
        $step = [Math]::Ceiling($pts.Count / 48.0)
        $out = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $pts.Count; $i += $step) { $null = $out.Add($pts[$i]) }
        if ($out.Count -gt 0 -and $out[$out.Count - 1] -ne $pts[$pts.Count - 1]) {
            $null = $out.Add($pts[$pts.Count - 1])
        }
        $pts = @($out)
    }
    if ($pts.Count -lt 2) { $pts = @(0, $pts[0]) }

    return @{ Points = $pts; Consumed = $total }
}

# ---------- 近 7 天每日消耗（按本地自然日切分，只累计正向增量） ----------
function Get-DailyBuckets([int]$Days = 7) {
    $today = (Get-Date).Date
    $out = @()
    for ($i = $Days - 1; $i -ge 0; $i--) {
        $day = $today.AddDays(-$i)
        $startMs = ([DateTimeOffset]$day).ToUnixTimeMilliseconds()
        $endMs   = ([DateTimeOffset]$day.AddDays(1)).ToUnixTimeMilliseconds()

        $key = $day.ToString('yyyy-MM-dd')
        $sum = 0.0
        if ($script:Daily -and $script:Daily.ContainsKey($key)) {
            # 长期口径：用每日累计（历史采样只保留 24 小时）
            $sum = [double]$script:Daily[$key]
        } else {
            $prev = $null
            foreach ($s in $script:History) {
                if ([int64]$s.t -lt [int64]$startMs) { $prev = [double]$s.u } else { break }
            }
            foreach ($s in $script:History) {
                $t = [int64]$s.t
                if ($t -lt $startMs) { continue }
                if ($t -ge $endMs) { break }
                $u = [double]$s.u
                if ($null -eq $prev) { $prev = $u }
                $d = $u - $prev
                if ($d -gt 0) { $sum += $d }
                $prev = $u
            }
        }

        $out += [pscustomobject]@{ d = $day.ToString('MM-dd'); v = [int][math]::Round($sum) }
    }
    return $out
}

# ---------- 每日累计（跨重启保留，供 7/30 天统计与报表） ----------
$script:Daily = @{}
$script:DailyLast = $null
if (Test-Path -LiteralPath $dailyF) {
    try {
        $o = Get-Content -LiteralPath $dailyF -Raw -Encoding utf8 | ConvertFrom-Json
        if ($o.days) {
            foreach ($p in $o.days.PSObject.Properties) { $script:Daily[$p.Name] = [double]$p.Value }
        }
        if ($null -ne $o.last) { $script:DailyLast = [double]$o.last }
    } catch { }
}

function Save-Daily {
    try {
        $obj = @{ days = $script:Daily; last = $script:DailyLast }
        [IO.File]::WriteAllText($dailyF, ($obj | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Add-DailyDelta([double]$used) {
    $day = (Get-Date).ToString('yyyy-MM-dd')
    if ($null -ne $script:DailyLast) {
        $d = $used - [double]$script:DailyLast
        if ($d -gt 0) {
            if (-not $script:Daily.ContainsKey($day)) { $script:Daily[$day] = 0.0 }
            $script:Daily[$day] = [double]$script:Daily[$day] + $d
        }
    }
    $script:DailyLast = $used
    Save-Daily
}

function Initialize-Daily {
    $day = (Get-Date).ToString('yyyy-MM-dd')
    if ($null -eq $script:DailyLast -and $script:History.Count -gt 0) {
        $script:DailyLast = [double]$script:History[$script:History.Count - 1].u
    }
    if (-not $script:Daily.ContainsKey($day)) {
        # 首跑时用今天的历史采样回算，避免当天消耗显示为 0
        $firstU = $null
        $lastU = $null
        foreach ($s in $script:History) {
            $d = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$s.t).ToLocalTime().ToString('yyyy-MM-dd')
            if ($d -eq $day) {
                if ($null -eq $firstU) { $firstU = [double]$s.u }
                $lastU = [double]$s.u
            }
        }
        $seed = 0.0
        if ($null -ne $firstU -and $null -ne $lastU -and $lastU -gt $firstU) { $seed = $lastU - $firstU }
        $script:Daily[$day] = $seed
        $script:Consumed = $seed
        Save-Daily
    }
}

function Get-UsageStats {
    $d30 = @(Get-DailyBuckets 30)
    $d7  = @(Get-DailyBuckets 7)

    $t30 = 0.0; foreach ($x in $d30) { $t30 += [double]$x.v }
    $t7  = 0.0; foreach ($x in $d7)  { $t7  += [double]$x.v }

    $active = @($script:Daily.Keys | Where-Object { $_ -ge (Get-Date).AddDays(-30).ToString('yyyy-MM-dd') }).Count
    $avg = if ($active -gt 0) { $t30 / $active } else { 0 }

    $peak = $d30 | Sort-Object v -Descending | Select-Object -First 1

    # 近 24 小时按小时分布（判断自己什么时候最费额度）
    $hours = New-Object int[] 24
    $prev = $null; $prevDay = ''
    foreach ($s in $script:History) {
        $dt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$s.t).ToLocalTime()
        $day = $dt.ToString('yyyy-MM-dd')
        if ($day -ne $prevDay) { $prev = [double]$s.u; $prevDay = $day }
        else {
            $delta = [double]$s.u - [double]$prev
            if ($delta -gt 0) { $hours[$dt.Hour] += [int]$delta }
            $prev = [double]$s.u
        }
    }
    $busy = 0
    for ($i = 1; $i -lt 24; $i++) { if ($hours[$i] -gt $hours[$busy]) { $busy = $i } }

    return [pscustomobject]@{
        Week7    = [int][math]::Round($t7)
        Total30  = [int][math]::Round($t30)
        Avg30    = [double]$avg
        PeakDay  = if ($peak) { $peak.d } else { '' }
        PeakVal  = if ($peak) { [int]$peak.v } else { 0 }
        BusyHour = $busy
        Hours    = @($hours)
        Days30   = @($d30)
    }
}

# ---------- 导出 CSV（Excel 可直接打开：时间 / 已用 / 剩余 / 当日累计） ----------
function Export-HistoryCsv {
    try {
        $sb = New-Object System.Text.StringBuilder
        $null = $sb.AppendLine('时间,已用,剩余,当日累计')
        $day = ''
        $prev = $null
        $cum = 0.0
        foreach ($s in $script:History) {
            $dt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$s.t).ToLocalTime()
            $d = $dt.ToString('yyyy-MM-dd')
            if ($d -ne $day) { $day = $d; $cum = 0.0; $prev = $null }
            $u = [double]$s.u
            if ($null -eq $prev) { $prev = $u }
            $delta = $u - $prev
            if ($delta -gt 0) { $cum += $delta }
            $prev = $u
            $null = $sb.AppendLine(('{0},{1},{2},{3}' -f $dt.ToString('yyyy-MM-dd HH:mm:ss'), [int]$s.u, [int]$s.r, [int]$cum))
        }
        [IO.File]::WriteAllText($csvF, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    } catch { }
}

# ---------- 消耗速度与预计用完 ----------
function Get-UsageRate {
    # 优先用近 6 小时窗口的真实增量；采样跨度不足 2 小时时退回「今日累计 / 今日已过时长」，避免短样本把速度算爆
    $nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $startMs = $nowMs - 6 * 60 * 60 * 1000
    $s = @($script:History | Where-Object { [int64]$_.t -ge $startMs })

    if ($s.Count -ge 2) {
        $burned = 0.0
        $prevU = [double]$s[0].u
        foreach ($x in $s) {
            $u = [double]$x.u
            $d = $u - $prevU
            if ($d -gt 0) { $burned += $d }
            $prevU = $u
        }
        $spanMs = [int64]$s[$s.Count - 1].t - [int64]$s[0].t
        $hours = $spanMs / 3600000.0
        if ($hours -ge 2 -and $burned -gt 0) {
            return @{ Rate = $burned / $hours; Basis = '6h' }
        }
    }

    # 退回今日口径
    $now = Get-Date
    $midnightMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() - ($now - $now.Date).TotalMilliseconds
    $today = @($script:History | Where-Object { [int64]$_.t -ge [int64]$midnightMs })
    if ($today.Count -lt 2) { return @{ Rate = 0.0; Basis = '' } }

    $hoursToday = ($nowMs - [int64]$today[0].t) / 3600000.0
    if ($hoursToday -lt 0.5) { return @{ Rate = 0.0; Basis = '' } }
    return @{ Rate = ([double]$script:Consumed) / $hoursToday; Basis = 'today' }
}

function Format-Duration([double]$h) {
    if ($h -le 0) { return '' }
    if (($h * 60) -lt 60) { return ('约 {0:0} 分钟' -f ($h * 60)) }
    if ($h -lt 48) { return ('约 {0:0.0} 小时' -f $h) }
    $d = $h / 24
    if ($d -lt 365) { return ('约 {0:0.0} 天' -f $d) }
    return '超过一年'
}

# ---------- 状态 ----------
$script:DataJson = $null
$script:DataAt   = [DateTime]::MinValue
if (Test-Path -LiteralPath $dataF) {
    try { $script:DataJson = (Get-Content -LiteralPath $dataF -Raw).Trim() } catch { }
}

# 用户拖动后的悬浮球坐标（重启/重注入时沿用）
$script:Pos = $null
if (Test-Path -LiteralPath $posF) {
    try {
        $o = Get-Content -LiteralPath $posF -Raw | ConvertFrom-Json
        if ($null -ne $o.left -and $null -ne $o.top) { $script:Pos = @{ left = [int]$o.left; top = [int]$o.top } }
    } catch { }
}

# widget.js 内容变了就要强制重建 DOM（原地更新只改数据，不换结构）
$hashF = Join-Path $here 'widget.hash'
$script:WidgetHash = ''
try {
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [IO.File]::ReadAllBytes($widgetF)
    $script:WidgetHash = [BitConverter]::ToString($sha1.ComputeHash($bytes)).Replace('-', '')
} catch { $script:WidgetHash = '' }
$script:ForceRebuild = $false
try {
    $stored = ''
    if (Test-Path -LiteralPath $hashF) { $stored = (Get-Content -LiteralPath $hashF -Raw).Trim() }
    if (-not $stored -or $stored -ne $script:WidgetHash) { $script:ForceRebuild = $true }
} catch { $script:ForceRebuild = $true }

function Get-InjectExpr([string]$dataJson) {
    $w = [IO.File]::ReadAllText($widgetF)
    return '(() => { ' + $w + ' ; return dbxWidget(' + $dataJson + '); })()'
}

function Get-UpdateExpr([string]$dataJson) {
    return '(() => { if (typeof window.__dbxWidgetUpdate === "function") { return window.__dbxWidgetUpdate(' + $dataJson + '); } return false; })()'
}

# ---------- 当前模型 ----------
$ModelExpr = @'
(() => {
  try {
    var btns = Array.prototype.slice.call(document.querySelectorAll('button'));
    for (var i = 0; i < btns.length; i++) {
      var r = btns[i].getBoundingClientRect();
      var t = (btns[i].textContent || '').replace(/\s+/g, ' ').trim();
      if (r.y > window.innerHeight * 0.78 && r.x > window.innerWidth * 0.45 &&
          t.length > 1 && t.length < 40 &&
          /GLM|DeepSeek|Kimi|Qwen|Claude|GPT|豆包|自动/i.test(t)) {
        return t;
      }
    }
    return '';
  } catch (e) { return ''; }
})()
'@

$script:Metrics  = $null
$script:Trend    = @()
$script:Consumed = 0
$script:Model    = ''
$script:LastRate = 0.0

function Get-ModelParts([string]$m) {
    $name = ''; $level = ''
    if (-not $m) { return @{ Name = ''; Level = ''; Short = '' } }
    if ($m -match '(?i)\s*(极高|高|中|低)$') {
        $level = $Matches[1]
        $name = ($m -replace '(?i)\s*(极高|高|中|低)$', '').Trim()
    } else {
        $name = $m.Trim()
    }
    $short = ($name -replace '(?i)\s*(Flash|Pro|Plus|Turbo|高速|极速)', '').Trim()
    return @{ Name = $name; Level = $level; Short = $short }
}

# ---------- 版本 / 更新检查 / 低额度提醒 ----------
$script:Version    = '1.2.0'
$script:UpdateNote = ''
$script:UpdateAt   = [DateTime]::MinValue
$script:AlertLevel = ''
$script:AlertDate  = ''
$script:Week       = @()
$script:Stats      = $null
$script:Paused     = Test-Path -LiteralPath $pauseF
$script:WantQuit   = $false
$script:Quiet      = $script:ConfigQuiet
$script:CmdStamp   = [long]0

function Get-TextSha1([string]$text) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [Text.Encoding]::UTF8.GetBytes(($text -replace "`r", ''))
    return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
}

function Test-RemoteUpdate {
    if (((Get-Date) - $script:UpdateAt).TotalHours -lt 1) { return }
    $script:UpdateAt = Get-Date
    try {
        $raw = Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/GitHubBsss/doubao-quota-widget/main/doubao-widget-daemon.ps1' -UseBasicParsing -TimeoutSec 8
        if ($raw.Content -match "Version\s*=\s*'([0-9.]+)'") {
            $remote = $Matches[1]
            if ([version]$remote -gt [version]$script:Version) {
                if ($script:UpdateNote -ne ('新版 ' + $remote)) { Write-Log ('update available: ' + $remote) }
                $script:UpdateNote = '新版 ' + $remote
            } else {
                $script:UpdateNote = ''
            }
        }
    } catch {
        # 离线/限流时静默，下一次再试
    }
}

function Show-AlertBalloon([string]$text) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Warning
        $ni.Visible = $true
        $ni.BalloonTipTitle = '豆包额度提醒'
        $ni.BalloonTipText = $text
        $ni.ShowBalloonTip(6000)
        Start-Sleep -Milliseconds 700
        $ni.Dispose()
    } catch { }
}

# 静默时段，如 "22:00-08:00"
function Test-QuietHours {
    if (-not $script:Quiet) { return $false }
    try {
        if ($script:Quiet -notmatch '^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$') { return $false }
        $sh = [int]$Matches[1]; $sm = [int]$Matches[2]; $eh = [int]$Matches[3]; $em = [int]$Matches[4]
        $now = (Get-Date).TimeOfDay
        $s = New-Object TimeSpan $sh, $sm, 0
        $e = New-Object TimeSpan $eh, $em, 0
        if ($s -lt $e) { return ($now -ge $s -and $now -lt $e) }
        return ($now -ge $s -or $now -lt $e)
    } catch { return $false }
}

function XmlEsc([string]$s) {
    return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}

# 原生 Toast（失败退回托盘气泡）
function Show-Toast([string]$title, [string]$text) {
    if (Test-QuietHours) { Write-Log 'toast skipped (quiet hours)'; return }
    try {
        $aumid = 'Doubao.QuotaWidget'
        $key = "HKCU:\Software\Classes\AppUserModelId\$aumid"
        if (-not (Test-Path -LiteralPath $key)) {
            New-Item -Path $key -Force | Out-Null
            New-ItemProperty -Path $key -Name DisplayName -Value '豆包额度' -PropertyType String -Force | Out-Null
        }
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>' + (XmlEsc $title) + '</text><text>' + (XmlEsc $text) + '</text></binding></visual></toast>')
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
        Write-Log 'toast shown'
    } catch {
        Write-Log ('toast failed: ' + $_.Exception.Message)
        Show-AlertBalloon $text
    }
}

function Update-Alert($m) {
    $pct = [double]$m.RemainPct
    $text = ''
    $level = ''
    if ($pct -le 10) {
        $level = 'critical'
        $text = ('额度告急：仅剩 {0}%（约 {1} 点），预计 {2}' -f $pct, $m.RemainStr, (Format-Duration ($m.RemainNum / [math]::Max($script:LastRate, 0.001))))
    } elseif ($pct -le $script:AlertPct) {
        $level = 'warn'
        $text = ('额度偏低：剩余 {0}%（约 {1} 点）' -f $pct, $m.RemainStr)
    }

    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($level -and ($script:AlertLevel -ne $level -or $script:AlertDate -ne $today)) {
        Write-Log ('alert -> ' + $level + ' ' + $text)
        Show-Toast '豆包额度提醒' $text
    }
    $script:AlertLevel = $level
    $script:AlertDate  = $today

    if ($level) { return @{ text = $text; level = $level } }
    return $null
}

function New-DataJson {
    if (-not $script:Metrics) { return $null }
    $m = $script:Metrics
    $mp = Get-ModelParts $script:Model
    $badge = $m.Badge
    $modelText = if ($mp.Name) { $mp.Name + $(if ($mp.Level) { ' · ' + $mp.Level } else { '' }) } else { '未识别' }

    $usage = Get-UsageRate
    $script:LastRate = $usage.Rate
    $rateText = if ($usage.Rate -gt 0) {
        ('{0:0.0} 点/小时{1}' -f $usage.Rate, $(if ($usage.Basis -eq 'today') { '（近期均值）' } else { '（近 6 小时）' }))
    } else { '暂无消耗' }
    $etaText  = if ($usage.Rate -gt 0 -and $m.RemainNum -gt 0) { Format-Duration ($m.RemainNum / $usage.Rate) } else { '—' }

    $rows = New-Object System.Collections.ArrayList
    $null = $rows.Add(@('当前模型', $modelText))
    $null = $rows.Add(@('可用额度', $m.RemainStr))
    $null = $rows.Add(@('已用 / 总额', ('{0:0} / {1:0} · {2}%' -f $m.Used, $m.Total, $m.Pct)))
    $null = $rows.Add(@('今日新增消耗', ('+{0:0}' -f $script:Consumed)))
    if ($script:Stats) {
        $null = $rows.Add(@('本周消耗', ('{0} 点' -f $script:Stats.Week7)))
        $null = $rows.Add(@('近 30 天日均', ('{0:0.0} 点/天' -f $script:Stats.Avg30)))
    }
    $null = $rows.Add(@('消耗速度', $rateText))
    $null = $rows.Add(@('预计用完', $etaText))
    foreach ($w in @($m.Windows)) {
        if (-not $w) { continue }
        $null = $rows.Add(@($w.Label, ('余 {0}%  {1}' -f $w.Pct, $w.Reset)))
    }
    $null = $rows.Add(@('最近窗口归零', $m.Expiry))
    $ver = 'v' + $script:Version + $(if ($script:UpdateNote) { ' · ' + $script:UpdateNote } else { '' }) + ' · ' + (Get-Date -Format 'HH:mm')
    $null = $rows.Add(@('版本', $ver))

    # 圆环：满圈 = 总积分，亮弧 = 剩余占比；圈内写剩余积分
    $centerText = if (([string]$m.RemainStr).Length -le 5) { [string]$m.RemainStr } else { $badge }

    $ringList = @($m.Rings)
    $gaugeRings = @()
    for ($i = 0; $i -lt $ringList.Count; $i++) {
        $color = $null
        if ($ringList.Count -gt 1) {
            if ([string]$ringList[$i].Type -eq 'H5') { $color = '#7fd8ff' } else { $color = '#f5c451' }
        }
        $gaugeRings += [pscustomobject]@{ pct = [double]$ringList[$i].Pct; color = $color }
    }

    $data = @{
        badge   = $badge
        title   = '豆包额度'
        rows    = @($rows)
        trend   = @($script:Trend)
        week    = @($script:Week)
        alert   = (Update-Alert $m)
        paused  = [bool]$script:Paused
        ver     = [string]$script:Version
        openUrl = $OpenUrl
        scale   = [double]$script:Scale
        gauge   = @{ center = $centerText; rings = $gaugeRings }
    }
    if ($script:Pos) {
        $data.left = [int]$script:Pos.left
        $data.top  = [int]$script:Pos.top
    }
    return ($data | ConvertTo-Json -Depth 6 -Compress)
}

# ---------- 用量报表（HTML + Markdown 周报） ----------
function New-Dashboard {
    $st = Get-UsageStats
    $m  = $script:Metrics

    $maxD = 1.0
    foreach ($x in $st.Days30) { if ([double]$x.v -gt $maxD) { $maxD = [double]$x.v } }

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">')
    $null = $sb.AppendLine('<title>豆包额度用量报表</title><style>')
    $null = $sb.AppendLine('body{margin:0;padding:28px 32px;background:#17181b;color:#e8e8ea;font-family:-apple-system,"Segoe UI","Microsoft YaHei",sans-serif}')
    $null = $sb.AppendLine('h1{font-size:20px;margin:0 0 4px}.sub{color:#8b8b94;font-size:12px;margin-bottom:22px}')
    $null = $sb.AppendLine('.cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:26px}')
    $null = $sb.AppendLine('.card{flex:1;min-width:150px;background:#1f2023;border:1px solid rgba(255,255,255,.1);border-radius:10px;padding:14px 16px}')
    $null = $sb.AppendLine('.card .k{color:#9a9aa2;font-size:12px}.card .v{font-size:22px;font-weight:600;margin-top:6px;color:#f5c451}')
    $null = $sb.AppendLine('.sec{margin-bottom:26px}.sec h2{font-size:14px;margin:0 0 12px;color:#c9c9cf}')
    $null = $sb.AppendLine('.bars{display:flex;align-items:flex-end;gap:4px;height:130px;background:#1f2023;border:1px solid rgba(255,255,255,.08);border-radius:10px;padding:12px}')
    $null = $sb.AppendLine('.b{flex:1;display:flex;flex-direction:column;justify-content:flex-end;align-items:center;gap:4px}')
    $null = $sb.AppendLine('.b .bar{width:100%;background:#f5c451;border-radius:3px;opacity:.85}.b .d{font-size:10px;color:#8b8b94}.b .v{font-size:9px;color:#9a9aa2}')
    $null = $sb.AppendLine('.hb{flex:1;display:flex;flex-direction:column;justify-content:flex-end;align-items:center;gap:3px}')
    $null = $sb.AppendLine('.hb .bar{width:100%;background:#7fd8ff;border-radius:2px;opacity:.8}.hb .d{font-size:9px;color:#8b8b94}')
    $null = $sb.AppendLine('table{border-collapse:collapse;width:100%;font-size:12px}td,th{padding:6px 10px;border-bottom:1px solid rgba(255,255,255,.06);text-align:left}th{color:#9a9aa2;font-weight:500}')
    $null = $sb.AppendLine('</style></head><body>')

    $null = $sb.AppendLine('<h1>豆包额度用量报表</h1>')
    $null = $sb.AppendLine('<div class="sub">生成时间 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' · 数据来源：本机 30 秒采样</div>')

    $null = $sb.AppendLine('<div class="cards">')
    $cards = @(
        @('可用额度', $(if ($m) { $m.RemainStr } else { '—' })),
        @('已用 / 总额', $(if ($m) { ('{0:0} / {1:0} · {2}%' -f $m.Used, $m.Total, $m.Pct) } else { '—' })),
        @('今日消耗', ('+{0:0}' -f $script:Consumed)),
        @('本周消耗', ('{0} 点' -f $st.Week7)),
        @('近 30 天日均', ('{0:0.0} 点/天' -f $st.Avg30)),
        @('最费时段', ('{0:00}:00 前后' -f $st.BusyHour))
    )
    foreach ($c in $cards) {
        $null = $sb.AppendLine('<div class="card"><div class="k">' + $c[0] + '</div><div class="v">' + (XmlEsc ([string]$c[1])) + '</div></div>')
    }
    $null = $sb.AppendLine('</div>')

    $null = $sb.AppendLine('<div class="sec"><h2>近 30 天每日消耗</h2><div class="bars">')
    foreach ($x in $st.Days30) {
        $h = [int][math]::Max(2, [math]::Round(90 * ([double]$x.v / $maxD)))
        $null = $sb.AppendLine('<div class="b"><span class="v">' + $x.v + '</span><div class="bar" style="height:' + $h + 'px"></div><span class="d">' + $x.d + '</span></div>')
    }
    $null = $sb.AppendLine('</div></div>')

    $maxH = 1
    foreach ($v in $st.Hours) { if ($v -gt $maxH) { $maxH = $v } }
    $null = $sb.AppendLine('<div class="sec"><h2>近 24 小时时段分布</h2><div class="bars" style="height:110px">')
    for ($i = 0; $i -lt 24; $i++) {
        $h = [int][math]::Max(2, [math]::Round(70 * ([double]$st.Hours[$i] / $maxH)))
        $op = if ($i -eq $st.BusyHour) { '1' } else { '.7' }
        $null = $sb.AppendLine('<div class="hb"><div class="bar" style="height:' + $h + 'px;opacity:' + $op + '"></div><span class="d">' + $i + '</span></div>')
    }
    $null = $sb.AppendLine('</div></div>')

    $null = $sb.AppendLine('<div class="sec"><h2>概览</h2><table><tr><th>项目</th><th>数值</th></tr>')
    $rows = @(
        @('峰值日', ($(if ($st.PeakDay) { $st.PeakDay + ' · ' + $st.PeakVal + ' 点' } else { '—' }) )),
        @('消耗速度', $(if ($script:LastRate -gt 0) { ('{0:0.0} 点/小时' -f $script:LastRate) } else { '—' })),
        @('预计用完', $(if ($script:LastRate -gt 0 -and $m -and $m.RemainNum -gt 0) { Format-Duration ($m.RemainNum / $script:LastRate) } else { '—' })),
        @('数据窗口', '近 30 天（30 秒采样，历史明细保留 24 小时）')
    )
    foreach ($r in $rows) {
        $null = $sb.AppendLine('<tr><td>' + $r[0] + '</td><td>' + (XmlEsc ([string]$r[1])) + '</td></tr>')
    }
    $null = $sb.AppendLine('</table></div></body></html>')

    [IO.File]::WriteAllText($dashF, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))

    # Markdown 周报
    $md = New-Object System.Text.StringBuilder
    $null = $md.AppendLine('# 豆包额度周报 · ' + (Get-Date -Format 'yyyy-MM-dd'))
    $null = $md.AppendLine('')
    $null = $md.AppendLine('- 本周消耗：' + $st.Week7 + ' 点')
    $null = $md.AppendLine('- 近 30 天日均：' + ('{0:0.0}' -f $st.Avg30) + ' 点/天')
    $null = $md.AppendLine('- 峰值日：' + $(if ($st.PeakDay) { $st.PeakDay + '（' + $st.PeakVal + ' 点）' } else { '—' }))
    $null = $md.AppendLine('- 最费时段：' + ('{0:00}:00' -f $st.BusyHour) + ' 前后')
    $null = $md.AppendLine('- 当前速度：' + $(if ($script:LastRate -gt 0) { ('{0:0.0} 点/小时' -f $script:LastRate) } else { '—' }))
    $null = $md.AppendLine('- 预计用完：' + $(if ($script:LastRate -gt 0 -and $m -and $m.RemainNum -gt 0) { Format-Duration ($m.RemainNum / $script:LastRate) } else { '—' }))
    $null = $md.AppendLine('')
    $null = $md.AppendLine('## 每日明细')
    $null = $md.AppendLine('')
    $null = $md.AppendLine('| 日期 | 消耗（点） |')
    $null = $md.AppendLine('| --- | --- |')
    foreach ($x in $st.Days30) { $null = $md.AppendLine('| ' + $x.d + ' | ' + $x.v + ' |') }
    [IO.File]::WriteAllText($reportF, $md.ToString(), (New-Object Text.UTF8Encoding($true)))

    return $dashF
}

# ---------- 命令处理（右键菜单 / 命令行 / command.txt） ----------
function Invoke-DaemonCmd([string]$action) {
    switch ($action.Trim().ToLower()) {
        'refresh' {
            $script:DataAt = [DateTime]::MinValue
            Write-Log 'cmd -> refresh'
        }
        'pause' {
            Set-Content -LiteralPath $pauseF -Value '1' -Encoding ascii
            $script:Paused = $true
            Write-Log 'cmd -> pause'
        }
        'resume' {
            Remove-Item -LiteralPath $pauseF -Force -ErrorAction SilentlyContinue
            $script:Paused = $false
            $script:DataAt = [DateTime]::MinValue
            Write-Log 'cmd -> resume'
        }
        'export' {
            Export-HistoryCsv
            Write-Log 'cmd -> export'
            Show-Toast '豆包额度' '用量已导出到 quota-history.csv'
        }
        'report' {
            $f = New-Dashboard
            Start-Process -FilePath $f
            Write-Log ('cmd -> report ' + $f)
        }
        'open' {
            Start-Process -FilePath 'explorer.exe' -ArgumentList $here
            Write-Log 'cmd -> open folder'
        }
        'update' {
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $up = Join-Path $here 'widget.ps1'
            if (Test-Path -LiteralPath $up) {
                Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $up, 'update' -WindowStyle Hidden
                Write-Log 'cmd -> update'
                $script:WantQuit = $true
            }
        }
        'quit' {
            Write-Log 'cmd -> quit'
            $script:WantQuit = $true
        }
        default { Write-Log ('cmd -> unknown: ' + $action) }
    }

    # 暂停/恢复等状态变化后，让挂件立刻同步
    if ($script:Metrics -and -not $script:WantQuit) {
        try {
            $nj = New-DataJson
            if ($nj -and $nj -ne $script:DataJson) {
                $script:DataJson = $nj
                [IO.File]::WriteAllText($dataF, ($nj | ConvertFrom-Json | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
            }
        } catch { }
    }
}

# ---------- 主循环 ----------
Write-Log "daemon start (pid=$PID)"
Initialize-Daily
$script:Stats = Get-UsageStats

while ($true) {
    # 命令行 / 外部脚本投递的命令
    try {
        if (Test-Path -LiteralPath $cmdF) {
            $cmd = (Get-Content -LiteralPath $cmdF -Raw -ErrorAction SilentlyContinue).Trim()
            Remove-Item -LiteralPath $cmdF -Force -ErrorAction SilentlyContinue
            if ($cmd) { Invoke-DaemonCmd $cmd }
        }
    } catch { }

    if ($script:WantQuit) { break }

    # widget.js 运行中被修改也要生效
    try {
        $h = Get-TextSha1([IO.File]::ReadAllText($widgetF))
        if ($h -ne $script:WidgetHash) {
            $script:WidgetHash = $h
            $script:ForceRebuild = $true
            Write-Log 'widget.js changed -> rebuild'
        }
    } catch { }

    $list = $null
    try {
        $raw = Invoke-WebRequest -Uri $CdpList -UseBasicParsing -TimeoutSec 3
        $list = $raw.Content | ConvertFrom-Json
    } catch {
        # 豆包未启动或未带 9222 参数
        foreach ($k in @($script:Sessions.Keys)) {
            try { $script:Sessions[$k].ws.Dispose() } catch { }
            $script:Sessions.Remove($k)
        }
        Start-Sleep -Milliseconds $PollMs
        continue
    }

    # ---- 刷新额度 ----
    if (-not $script:Paused -and ((Get-Date) - $script:DataAt).TotalSeconds -ge $QuotaSec) {
        try {
            $m = Get-QuotaMetrics $list
            Add-Sample $m.Used $m.RemainNum
            $tr = Get-TodayTrend
            Test-RemoteUpdate

            $script:Metrics  = $m
            $script:Trend    = @($tr.Points)
            $script:Consumed = $tr.Consumed
            $script:Week     = @(Get-DailyBuckets 7)
            $script:Stats    = Get-UsageStats
            Export-HistoryCsv

            $json = New-DataJson
            if ($json -and $json -ne $script:DataJson) {
                $script:DataJson = $json
                try {
                    [IO.File]::WriteAllText($dataF, ($json | ConvertFrom-Json | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
                } catch { }
                Write-Log ('quota -> ' + $m.Badge + '  used=' + $m.Used + '/' + $m.Total + '  今日+' + $tr.Consumed + '  trend=' + @($tr.Points).Count + 'pt  win=' + @($m.Windows).Count + '  model=' + $script:Model)
            }
            $script:DataAt = Get-Date
        } catch {
            if (((Get-Date) - $script:DataAt).TotalSeconds -ge ($QuotaSec * 2)) {
                Write-Log ("quota error: " + $_.Exception.Message)
            }
        }
    }

    $targets = @($list | Where-Object { $_.type -eq 'page' -and $_.url -match 'doubao-chat/chat' })

    # 清理已消失的会话
    foreach ($k in @($script:Sessions.Keys)) {
        if (-not ($targets | Where-Object { $_.id -eq $k })) {
            try { $script:Sessions[$k].ws.Dispose() } catch { }
            $script:Sessions.Remove($k)
        }
    }

    if (-not $script:DataJson) { Start-Sleep -Milliseconds $PollMs; continue }

    # widget.js 改过：先清掉旧 DOM，本轮会按新代码重建
    if ($script:ForceRebuild -and $targets.Count -gt 0) {
        try {
            foreach ($t in $targets) {
                try {
                    $ws = Connect-Cdp $t.webSocketDebuggerUrl
                    $null = Send-Cdp $ws 'Runtime.enable' @{}
                    $null = Eval-InPage $ws "var e=document.getElementById('dbx-root'); if (e) e.remove(); 1"
                    try { $ws.Dispose() } catch { }
                } catch { }
            }
            Set-Content -LiteralPath $hashF -Value $script:WidgetHash -Encoding ascii -ErrorAction Stop
            Write-Log ('widget.js changed -> force rebuild (' + $script:WidgetHash.Substring(0, 8) + ')')
        } catch {
            Write-Log ('rebuild error: ' + $_.Exception.Message)
        }
        $script:ForceRebuild = $false
    }

    foreach ($t in $targets) {
        try {
            if (-not $script:Sessions.ContainsKey($t.id)) {
                $ws = Connect-Cdp $t.webSocketDebuggerUrl
                $null = Send-Cdp $ws 'Runtime.enable' @{}
                $script:Sessions[$t.id] = @{ ws = $ws; stamp = $null }
                Write-Log ("attached " + $t.id + " " + $t.url)
            }
            $sess = $script:Sessions[$t.id]
            $ws   = $sess.ws

            # 读当前模型（输入框右下角选择器）
            try {
                $mres = Eval-InPage $ws $ModelExpr
                $mtxt = ''
                if ($mres.result -and $mres.result.result) { $mtxt = [string]$mres.result.result.value }
                if ($mtxt -and $mtxt -ne $script:Model) {
                    $script:Model = $mtxt
                    $nj = New-DataJson
                    if ($nj -and $nj -ne $script:DataJson) {
                        $script:DataJson = $nj
                        Write-Log ('model -> ' + $mtxt)
                    }
                }
            } catch { }

            # 记录用户拖动后的位置（落盘，下次注入沿用）
            try {
                $pres = Eval-InPage $ws "window.__dbxPos ? JSON.stringify(window.__dbxPos) : ''"
                $ptxt = ''
                if ($pres.result -and $pres.result.result) { $ptxt = [string]$pres.result.result.value }
                if ($ptxt) {
                    $po = $ptxt | ConvertFrom-Json
                    $pl = [int]$po.left
                    $pt = [int]$po.top
                    if (-not $script:Pos -or [int]$script:Pos.left -ne $pl -or [int]$script:Pos.top -ne $pt) {
                        $script:Pos = @{ left = $pl; top = $pt }
                        try {
                            [IO.File]::WriteAllText($posF, (@{ left = $pl; top = $pt } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
                        } catch { }
                        Write-Log ('pos -> ' + $pl + ',' + $pt)
                        $nj2 = New-DataJson
                        if ($nj2) { $script:DataJson = $nj2 }
                    }
                }
            } catch { }

            # 右键菜单 / 页面内投递的命令
            try {
                $cres = Eval-InPage $ws "window.__dbxCmd ? JSON.stringify(window.__dbxCmd) : ''"
                $ctxt = ''
                if ($cres.result -and $cres.result.result) { $ctxt = [string]$cres.result.result.value }
                if ($ctxt) {
                    $null = Eval-InPage $ws "window.__dbxCmd = null; 1"
                    $co = $ctxt | ConvertFrom-Json
                    if ($co.action) { Invoke-DaemonCmd ([string]$co.action) }
                }
            } catch { }

            $chk = Eval-InPage $ws "!!document.getElementById('dbx-root')"
            $present = $false
            if ($chk.result -and $chk.result.result) { $present = [bool]$chk.result.result.value }

            if (-not $present) {
                $r2 = Eval-InPage $ws (Get-InjectExpr $script:DataJson)
                if ($r2.exceptionDetails) {
                    Write-Log ("inject exception: " + ($r2.exceptionDetails | ConvertTo-Json -Compress -Depth 6))
                } else {
                    $sess.stamp = $script:DataJson
                    Write-Log ("injected -> " + $t.id)
                }
            } elseif ($sess.stamp -ne $script:DataJson) {
                $r3 = Eval-InPage $ws (Get-UpdateExpr $script:DataJson)
                $ok = $r3.result -and $r3.result.result -and $r3.result.result.value
                if ($ok) {
                    $sess.stamp = $script:DataJson
                    Write-Log ("updated -> " + $t.id)
                } else {
                    # 更新器不在（旧版本 payload），退化为重建
                    $null = Eval-InPage $ws (Get-InjectExpr $script:DataJson)
                    $sess.stamp = $script:DataJson
                    Write-Log ("reinjected -> " + $t.id)
                }
            }
        } catch {
            Write-Log ("session error (" + $t.id + "): " + $_.Exception.Message)
            if ($script:Sessions.ContainsKey($t.id)) {
                try { $script:Sessions[$t.id].ws.Dispose() } catch { }
                $script:Sessions.Remove($t.id)
            }
        }
    }
    Start-Sleep -Milliseconds $PollMs
}

Write-Log 'daemon exit'
foreach ($k in @($script:Sessions.Keys)) {
    try { $script:Sessions[$k].ws.Dispose() } catch { }
}
try { Remove-Item -LiteralPath $lockF -Force -ErrorAction SilentlyContinue } catch { }

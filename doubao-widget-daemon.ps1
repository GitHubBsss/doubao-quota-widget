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
$logF        = Join-Path $here 'daemon.log'
$lockF       = Join-Path $here 'daemon.lock'
$posF        = Join-Path $here 'widget-pos.json'
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
# aid 是豆包账号维度参数，从同目录 config.json 或环境变量 DOUBAO_AID 读取，避免把个人账号写进代码
$Aid = $null
$cfgF = Join-Path $here 'config.json'
if (Test-Path -LiteralPath $cfgF) {
    try {
        $cfg = Get-Content -LiteralPath $cfgF -Raw | ConvertFrom-Json
        if ($cfg.aid) { $Aid = [string]$cfg.aid }
    } catch { }
}
if (-not $Aid -and $env:DOUBAO_AID) { $Aid = $env:DOUBAO_AID }
if (-not $Aid) { Write-Log 'config.json 缺少 aid，额度接口将无法查询'; $Aid = '0' }

$QuotaApi = 'https://www.doubao.com/alice/commerce/sale/subscription/overview/?aid=' + $Aid + '&device_platform=web&doubao_device_platform=web&language=zh&region=CN&sys_region=CN&samantha_web=1&web_platform=desktop&use-olympus-account=1&pc_version=2.38.12'

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

function Get-QuotaMetrics($list) {
    $ctx = $list | Where-Object { $_.url -match '^https://www\.doubao\.com/' } | Select-Object -First 1
    if (-not $ctx) { throw 'no doubao.com context' }

    $ws = Connect-Cdp $ctx.webSocketDebuggerUrl
    try {
        $expr = $QuotaExpr.Replace('__API__', $QuotaApi)
        $res  = Eval-InPage $ws $expr $true
        $raw  = $res.result.result.value
        if (-not $raw) { throw 'empty quota response' }
        if ($raw -like 'ERR:*') { throw $raw }
        $q = $raw | ConvertFrom-Json

        $remainStr = [string]$q.data.quota_balance_overview.total_remaining_amount
        $wl = $q.data.incentive_quota_section.window_limit_groups[0].window_limits[0]
        $usedNum  = [double]([string]$wl.used_amount -replace ',', '')
        $totalNum = [double]([string]$wl.total_amount -replace ',', '')

        # 环形表：优先用付费档位的窗口限额（5 小时 / 周），没有就用整体剩余比例
        $rings = @()
        try {
            foreach ($g in @($q.data.window_limit_section.window_limit_groups)) {
                if (-not $g) { continue }
                foreach ($w in @($g.window_limits)) {
                    if (-not $w) { continue }
                    $rings += [pscustomobject]@{
                        Pct  = [math]::Round(100 - [double]$w.used_percent, 0)
                        Type = [string]$w.window_type
                    }
                }
            }
        } catch { }
        if ($rings.Count -eq 0) {
            $pctRemain = if ($totalNum -gt 0) { 100 - (100 * $usedNum / $totalNum) } else { 100 }
            $rings = @([pscustomobject]@{ Pct = [math]::Round($pctRemain, 0); Type = 'all' })
        }
        if ($rings.Count -gt 2) { $rings = @($rings | Select-Object -First 2) }

        return [pscustomobject]@{
            Badge     = Format-Amount $remainStr
            RemainStr = $remainStr
            RemainNum = [double]($remainStr -replace ',', '')
            Used      = $usedNum
            Total     = $totalNum
            Pct       = $wl.used_percent
            Expiry    = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$wl.end_time).ToLocalTime().ToString('MM-dd HH:mm')
            Count     = $q.data.incentive_quota_section.entitlement_count
            Member    = if ($q.data.member_info.hasActiveSubscription) { '订阅中' } else { '免费版' }
            Rings     = $rings
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

function New-DataJson {
    if (-not $script:Metrics) { return $null }
    $m = $script:Metrics
    $mp = Get-ModelParts $script:Model
    $badge = $m.Badge
    $modelText = if ($mp.Name) { $mp.Name + $(if ($mp.Level) { ' · ' + $mp.Level } else { '' }) } else { '未识别' }

    $rows = @(
        , @('当前模型', $modelText)
        , @('可用额度', $m.RemainStr)
        , @('已用 / 总额', ('{0:0} / {1:0}   {2}%' -f $m.Used, $m.Total, $m.Pct))
        , @('今日新增消耗', ('+{0:0}' -f $script:Consumed))
        , @('最近窗口归零', $m.Expiry)
        , @('额度档位', ('{0} 档' -f $m.Count))
        , @('数据更新', (Get-Date -Format 'HH:mm'))
    )

    # 圆环：满圈 = 总积分，亮弧 = 剩余占比；圈内写剩余积分（短数字用原值，长了退回紧凑写法）
    $centerText = if (([string]$m.RemainStr).Length -le 5) { [string]$m.RemainStr } else { $badge }

    $ringList = @($m.Rings)
    $gaugeRings = @()
    for ($i = 0; $i -lt $ringList.Count; $i++) {
        $color = $null
        if ($ringList.Count -gt 1) { $color = if ($i -eq 0) { '#f5c451' } else { '#7fd8ff' } }
        $gaugeRings += [pscustomobject]@{ pct = [double]$ringList[$i].Pct; color = $color }
    }

    $data = @{
        badge   = $badge
        title   = '豆包额度'
        rows    = $rows
        trend   = @($script:Trend)
        openUrl = $OpenUrl
        gauge   = @{ center = $centerText; rings = $gaugeRings }
    }
    if ($script:Pos) {
        $data.left = [int]$script:Pos.left
        $data.top  = [int]$script:Pos.top
    }
    return ($data | ConvertTo-Json -Depth 6 -Compress)
}

# ---------- 主循环 ----------
Write-Log "daemon start (pid=$PID)"

while ($true) {
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
    if (((Get-Date) - $script:DataAt).TotalSeconds -ge $QuotaSec) {
        try {
            $m = Get-QuotaMetrics $list
            Add-Sample $m.Used $m.RemainNum
            $tr = Get-TodayTrend

            $script:Metrics  = $m
            $script:Trend    = @($tr.Points)
            $script:Consumed = $tr.Consumed

            $json = New-DataJson
            if ($json -and $json -ne $script:DataJson) {
                $script:DataJson = $json
                try {
                    [IO.File]::WriteAllText($dataF, ($json | ConvertFrom-Json | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
                } catch { }
                Write-Log ('quota -> ' + $m.Badge + '  used=' + $m.Used + '/' + $m.Total + '  今日+' + $tr.Consumed + '  trend=' + @($tr.Points).Count + 'pt  model=' + $script:Model)
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

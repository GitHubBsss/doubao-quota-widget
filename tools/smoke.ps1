param([string]$Root = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Continue'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Host ("PASS  " + $name + $(if ($detail) { "  " + $detail } else { '' })) }
    else { Write-Host ("FAIL  " + $name + $(if ($detail) { "  " + $detail } else { '' })); $script:fail++ }
}

$js = Join-Path $Root 'widget.js'
$daemon = Join-Path $Root 'doubao-widget-daemon.ps1'
$cli = Join-Path $Root 'widget.ps1'
$verFile = Join-Path $Root 'version.json'
$dataFile = Join-Path $Root 'data.json'
$csv = Join-Path $Root 'quota-history.csv'

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    & $node.Source --check $js 2>$null
    Check 'widget.js 语法' ($LASTEXITCODE -eq 0)
} else { Check 'widget.js 语法' $true 'node 未安装，跳过' }

foreach ($f in @($daemon, $cli)) {
    $errs = $null
    $null = [System.Management.Automation.PSParser]::Tokenize([IO.File]::ReadAllText($f), [ref]$errs)
    Check ((Split-Path $f -Leaf) + ' 语法') (-not $errs -or $errs.Count -eq 0)
}

if (Test-Path -LiteralPath $verFile) {
    $v = Get-Content -LiteralPath $verFile -Raw | ConvertFrom-Json
    Check 'version.json' ([bool]$v.version) ([string]$v.version)
} else { Check 'version.json' $false '缺失' }

try {
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:9222/json/version' -UseBasicParsing -TimeoutSec 3
    $b = ($r.Content | ConvertFrom-Json).Browser
    Check 'CDP 9222' ([bool]$b) ([string]$b)
} catch { Check 'CDP 9222' $false $_.Exception.Message }

if (Test-Path -LiteralPath $dataFile) {
    try {
        $d = Get-Content -LiteralPath $dataFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Check 'data.json' ($d.rows.Count -ge 8) ("ver=$($d.ver) rows=$($d.rows.Count) stale=$($d.stale)")
        if ($d.updatedAt) {
            $age = ((Get-Date) - ([datetime]$d.updatedAt)).TotalSeconds
            Check '数据新鲜度' ($age -lt 120) ("$([int]$age)s 前")
        } else { Check '数据新鲜度' $false 'updatedAt 为空' }
    } catch { Check 'data.json' $false $_.Exception.Message }
} else { Check 'data.json' $false '缺失' }

if (Test-Path -LiteralPath $csv) {
    $lines = @(Get-Content -LiteralPath $csv)
    Check 'CSV' ($lines.Count -ge 2) ("$($lines.Count) 行，末行 " + $lines[-1])
} else { Check 'CSV' $false '缺失' }

$lock = Join-Path $Root 'daemon.lock'
$pidText = if (Test-Path -LiteralPath $lock) { (Get-Content -LiteralPath $lock -Raw).Trim() } else { '' }
$alive = $pidText -match '^\d+$' -and [bool](Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue)
Check '守护进程' $alive ("pid=$pidText")

Write-Host ''
if ($fail -gt 0) { Write-Host "$fail 项失败"; exit 1 }
Write-Host '全部通过'
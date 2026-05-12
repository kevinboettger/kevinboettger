[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WaapiLog,
    [Parameter(Mandatory=$true)][string]$DebugLog,
    [Parameter(Mandatory=$true)][string]$OutPath,
    [string]$ExpectedProfile = 'Profile_1',
    [int]   $WindowMs = 3000
)

# DEBUG_VIEW_v1: cross-reference waapi.log flips with Immerse plug-in debug stream.
# - Reads WAAPI orchestrator's "set EnableImmerse=<bool>" flips with timestamps.
# - Reads DbgView's captured "[EmbodyLOG] ... Immerse_EnableImmerse inMode: <0|1>" lines.
# - For each WAAPI flip, finds the closest runtime transition within $WindowMs ms.
# - Also checks that "ProfileName set to : <ExpectedProfile>" appears at least once
#   so we know the runtime loaded the personalized HRTF (not falling back to universal).

$ErrorActionPreference = 'Continue'

function Out([string]$m) {
    Add-Content -Path $OutPath -Value $m -Encoding UTF8
    Write-Host $m
}

if (Test-Path $OutPath) { Remove-Item $OutPath -Force }
New-Item -ItemType File -Path $OutPath -Force | Out-Null

Out "===== ImmerseToggle Verification ====="
Out "  WaapiLog: $WaapiLog"
Out "  DebugLog: $DebugLog"
Out ""

if (-not (Test-Path $WaapiLog)) { Out "MISSING waapi.log"; return }
if (-not (Test-Path $DebugLog)) { Out "MISSING immerse_debug.log -- DbgView did not run or capture nothing"; return }

# Parse waapi.log flips.
# Format: [2026-05-12T03:46:06.287139-07:00] actor: BypassImmerse OK -> WAAPI EnableImmerse=false [OK]
$waapiFlips = New-Object 'System.Collections.Generic.List[object]'
foreach ($line in Get-Content $WaapiLog) {
    if ($line -match '^\[([\d\-T:\.\+]+)\].*WAAPI EnableImmerse=(true|false)\s*\[(OK|FAIL)\]') {
        try {
            $t = [DateTimeOffset]::Parse($matches[1]).LocalDateTime
        } catch { continue }
        $waapiFlips.Add([PSCustomObject]@{
            Time     = $t
            Expected = if ($matches[2] -eq 'true') { 1 } else { 0 }
            Status   = $matches[3]
        })
    }
}

# Parse DbgView log lines.
# Format: [EmbodyLOG] May_12_2026 05:54:34.797 line: 673. ___IMMERSEENGINE___ Immerse_EnableImmerse inMode: 0
$monthN = @{ Jan=1; Feb=2; Mar=3; Apr=4; May=5; Jun=6; Jul=7; Aug=8; Sep=9; Oct=10; Nov=11; Dec=12 }
$runtimeModes = New-Object 'System.Collections.Generic.List[object]'
$profileMentions = New-Object 'System.Collections.Generic.List[string]'
foreach ($line in Get-Content $DebugLog) {
    if ($line -match '\[EmbodyLOG\]\s+([A-Z][a-z]{2})\w*_(\d{1,2})_(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})\.(\d{1,3}).*Immerse_EnableImmerse\s+inMode:\s*(\d+)') {
        $mn = $monthN[$matches[1]]
        try {
            $t = [DateTime]::new([int]$matches[3], $mn, [int]$matches[2], [int]$matches[4], [int]$matches[5], [int]$matches[6], [int]($matches[7].PadRight(3,'0')))
        } catch { continue }
        $runtimeModes.Add([PSCustomObject]@{ Time = $t; InMode = [int]$matches[8] })
    }
    if ($line -match 'ProfileName set to\s*:\s*(\S+)') {
        $profileMentions.Add($matches[1])
    }
}

# Dedup runtime modes into actual transitions (the plug-in emits the same inMode
# twice per toggle, ~1ms apart -- collapse runs of identical inMode).
$runtimeTransitions = New-Object 'System.Collections.Generic.List[object]'
$lastMode = -1
foreach ($r in $runtimeModes) {
    if ($r.InMode -ne $lastMode) {
        $runtimeTransitions.Add($r)
        $lastMode = $r.InMode
    }
}

Out "  WAAPI flips:           $($waapiFlips.Count)"
Out "  Runtime inMode lines:  $($runtimeModes.Count)"
Out "  Runtime transitions:   $($runtimeTransitions.Count) (deduped)"
$uniqueProfiles = $profileMentions | Select-Object -Unique
Out "  ProfileName mentions:  $($profileMentions.Count)  unique=[$($uniqueProfiles -join ', ')]"
Out ""

# Cross-reference: for each WAAPI flip, find the nearest unused runtime transition
# within +/- $WindowMs and assert inMode matches.
$used = New-Object 'System.Collections.Generic.HashSet[int]'
$pass = 0; $fail = 0
foreach ($w in $waapiFlips) {
    $bestIdx = -1
    $bestDelta = [Math]::Abs($WindowMs) + 1
    for ($i = 0; $i -lt $runtimeTransitions.Count; $i++) {
        if ($used.Contains($i)) { continue }
        $delta = ($runtimeTransitions[$i].Time - $w.Time).TotalMilliseconds
        $abs = [Math]::Abs($delta)
        if ($abs -le $WindowMs -and $abs -lt $bestDelta) {
            $bestIdx = $i; $bestDelta = $abs
        }
    }
    if ($bestIdx -lt 0) {
        $fail++
        Out ("  FAIL  WAAPI " + $w.Time.ToString('HH:mm:ss.fff') + " ->" + $w.Expected + "  no runtime transition within " + $WindowMs + "ms")
        continue
    }
    $rt = $runtimeTransitions[$bestIdx]
    $deltaMs = [int](($rt.Time - $w.Time).TotalMilliseconds)
    $used.Add($bestIdx) | Out-Null
    if ($rt.InMode -eq $w.Expected) {
        $pass++
        Out ("  PASS  WAAPI " + $w.Time.ToString('HH:mm:ss.fff') + " ->" + $w.Expected + "   runtime inMode=" + $rt.InMode + "  lag=" + $deltaMs + "ms")
    } else {
        $fail++
        Out ("  FAIL  WAAPI " + $w.Time.ToString('HH:mm:ss.fff') + " ->" + $w.Expected + "   runtime inMode=" + $rt.InMode + "  lag=" + $deltaMs + "ms  (mismatch)")
    }
}

Out ""
$personalized = ($uniqueProfiles -contains $ExpectedProfile)
Out ("Profile check: expected='" + $ExpectedProfile + "'  loaded=" + $personalized)
Out ""
Out ("SUMMARY: " + $pass + " pass / " + $fail + " fail / total " + $waapiFlips.Count + "  profile_ok=" + $personalized)

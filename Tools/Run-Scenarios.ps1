[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ScenariosPath,
    [Parameter(Mandatory=$true)][string]$ListenerLog,
    [Parameter(Mandatory=$true)][string]$WaapiUrl,
    [Parameter(Mandatory=$true)][string]$ImmerseEffectId,
    [Parameter(Mandatory=$true)][string]$ResultsJson,
    [Parameter(Mandatory=$true)][string]$SummaryPath
)

# TIER1_SCENARIO_RUNNER_v1
# For each scenario in $ScenariosPath:
#   1. Note current size of $ListenerLog.
#   2. Call ak.wwise.core.object.setProperty on $ImmerseEffectId with the
#      scenario's property + value (boolean/string/number all supported by JSON).
#   3. Tail $ListenerLog from the noted offset and search for $expectLog regex
#      until either it matches (PASS) or $timeoutMs elapses (FAIL).
#   4. If $expectLog is absent or value is the literal "TBD", treat the scenario
#      as DISCOVERY: just snapshot what appeared in the listener log during the
#      next $captureSeconds (default 3s) and report PASS with notes.
# Exit code = number of failures (0 = all pass).

$ErrorActionPreference = 'Continue'

function Out([string]$m) { Write-Host $m }

function Invoke-Waapi([string]$Body) {
    try {
        $r = Invoke-RestMethod -Uri $WaapiUrl -Method Post -Body $Body -ContentType 'application/json' -TimeoutSec 5
        return @{ ok = $true; result = $r }
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.Response) {
            try {
                $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $msg += ' body=' + $sr.ReadToEnd()
            } catch {}
        }
        return @{ ok = $false; error = $msg }
    }
}

function Get-LogSize() {
    if (-not (Test-Path $ListenerLog)) { return 0 }
    try { return (Get-Item $ListenerLog).Length } catch { return 0 }
}

function Read-LogFrom([long]$Offset) {
    if (-not (Test-Path $ListenerLog)) { return '' }
    try {
        $fs = [System.IO.File]::Open($ListenerLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($Offset -ge $fs.Length) { return '' }
            [void]$fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
            $reader = New-Object System.IO.StreamReader($fs)
            return $reader.ReadToEnd()
        } finally { $fs.Close() }
    } catch { return '' }
}

if (-not (Test-Path $ScenariosPath)) {
    Out "ERROR: scenarios file not found: $ScenariosPath"
    exit 99
}
$scenariosObj = Get-Content -Raw $ScenariosPath | ConvertFrom-Json
$scenarios = @($scenariosObj.scenarios)
if ($scenarios.Count -eq 0) {
    Out "ERROR: no scenarios defined in $ScenariosPath"
    exit 99
}

$results = New-Object 'System.Collections.Generic.List[object]'
$pass = 0; $fail = 0; $skip = 0
$summary = New-Object 'System.Collections.Generic.List[string]'
$summary.Add("===== Tier 1 Scenario Run =====")
$summary.Add("  Scenarios:   $ScenariosPath")
$summary.Add("  ImmerseFX:   $ImmerseEffectId")
$summary.Add("  ListenerLog: $ListenerLog")
$summary.Add("")

for ($idx = 0; $idx -lt $scenarios.Count; $idx++) {
    $s = $scenarios[$idx]
    $name        = $s.name
    $prop        = $s.property
    $value       = $s.value
    $expectLog   = $s.expectLog
    $timeoutMs   = if ($s.timeoutMs) { [int]$s.timeoutMs } else { 3000 }
    $captureSec  = if ($s.captureSeconds) { [int]$s.captureSeconds } else { 3 }
    $skipMode    = $s.skip -eq $true
    $isDiscovery = ($null -eq $expectLog) -or ($value -is [string] -and $value -eq 'TBD')

    $stepIdx = "[{0,2}/{1}]" -f ($idx + 1), $scenarios.Count

    if ($skipMode) {
        Out "$stepIdx SKIP  $name"
        $skip++
        $results.Add([PSCustomObject]@{
            index   = $idx + 1
            name    = $name
            status  = 'skip'
            note    = if ($s.comment) { $s.comment } else { '' }
        })
        continue
    }

    if (-not $prop) {
        Out "$stepIdx FAIL  $name -- missing 'property' field"
        $fail++
        $results.Add([PSCustomObject]@{ index = $idx + 1; name = $name; status = 'fail'; note = 'missing property field' })
        continue
    }

    $offset = Get-LogSize
    $valueJson = $value | ConvertTo-Json -Compress
    $body = '{"uri":"ak.wwise.core.object.setProperty","args":{"object":"' + $ImmerseEffectId + '","property":"' + $prop + '","value":' + $valueJson + '},"options":{}}'
    $issuedAt = Get-Date
    $r = Invoke-Waapi $body
    if (-not $r.ok) {
        Out "$stepIdx FAIL  $name -- WAAPI setProperty failed: $($r.error)"
        $fail++
        $results.Add([PSCustomObject]@{
            index = $idx + 1; name = $name; status = 'fail'
            property = $prop; value = $value
            error = $r.error
        })
        continue
    }

    if ($isDiscovery) {
        Start-Sleep -Seconds $captureSec
        $captured = Read-LogFrom $offset
        $tailLines = ($captured -split "`r?`n") | Where-Object { $_ -and $_ -match '\[EmbodyLOG\]|___IMMERSEENGINE___|ImmerseAudio|Hpeq|Profile|Bus|Convolution' } | Select-Object -First 25
        Out "$stepIdx DISC  $name -- captured $($tailLines.Count) Immerse-related lines in ${captureSec}s"
        foreach ($l in $tailLines) { Out "         $l" }
        $pass++
        $results.Add([PSCustomObject]@{
            index = $idx + 1; name = $name; status = 'discovery'
            property = $prop; value = $value
            captured_lines = $tailLines
        })
        continue
    }

    # assertion mode: poll for $expectLog within $timeoutMs
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    $matched  = $false
    $matchedLine = $null
    $lagMs   = $null
    while ((Get-Date) -lt $deadline) {
        $chunk = Read-LogFrom $offset
        if ($chunk) {
            foreach ($line in ($chunk -split "`r?`n")) {
                if ($line -match $expectLog) {
                    $matched = $true
                    $matchedLine = $line
                    $lagMs = [int](((Get-Date) - $issuedAt).TotalMilliseconds)
                    break
                }
            }
            if ($matched) { break }
        }
        Start-Sleep -Milliseconds 100
    }

    if ($matched) {
        Out ("$stepIdx PASS  {0,-50} lag=${lagMs}ms" -f $name)
        $pass++
        $results.Add([PSCustomObject]@{
            index = $idx + 1; name = $name; status = 'pass'
            property = $prop; value = $value
            expect_log = $expectLog
            matched_line = $matchedLine
            lag_ms = $lagMs
        })
    } else {
        Out ("$stepIdx FAIL  {0,-50} no match within ${timeoutMs}ms" -f $name)
        Out "         expected: $expectLog"
        $fail++
        $results.Add([PSCustomObject]@{
            index = $idx + 1; name = $name; status = 'fail'
            property = $prop; value = $value
            expect_log = $expectLog
            timeout_ms = $timeoutMs
        })
    }
}

$summary.Add("Result: $pass pass / $fail fail / $skip skip / total $($scenarios.Count)")

@{
    schema  = 'tier1-results-v1'
    pass    = $pass
    fail    = $fail
    skip    = $skip
    total   = $scenarios.Count
    results = $results
} | ConvertTo-Json -Depth 8 | Set-Content -Path $ResultsJson -Encoding UTF8

$summary -join "`n" | Set-Content -Path $SummaryPath -Encoding UTF8
Out ''
Out ($summary -join "`n")

exit $fail

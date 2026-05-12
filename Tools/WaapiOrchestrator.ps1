[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$EditorLog,
    [Parameter(Mandatory=$true)][string]$LogPath,
    [string]$WaapiUrl          = 'http://127.0.0.1:8090/waapi',
    [string]$ImmerseEffectId   = '',
    [string]$ImmerseEffectName = 'Immerse_Audio_Renderer_(Custom)',
    [int]   $TimeoutSec        = 1800,
    [int]   $PollMs            = 200
)

# WAAPI_ORCH_v1: live EHM mirror.
# Tails the UE editor log for [ImmerseStress] EnableImmerse/BypassImmerse lines
# and flips the Immerse plug-in's EnableImmerse property over WAAPI so the
# Wwise Authoring -> UE remote connection propagates the toggle to the running
# Wwise runtime. Assumes Wwise Authoring is open with TencentRCTest.wproj loaded
# and remote-connected to the UE editor.

$ErrorActionPreference = 'Continue'

function L([string]$m) {
    $line = "[$(Get-Date -Format o)] $m"
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    Write-Host $line
}

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

function Set-WaapiProp([string]$Name, $Value) {
    $vJson = $Value | ConvertTo-Json -Compress
    $body  = '{"uri":"ak.wwise.core.object.setProperty","args":{"object":"' + $ImmerseEffectId + '","property":"' + $Name + '","value":' + $vJson + '},"options":{}}'
    $r = Invoke-Waapi $body
    if (-not $r.ok) { L "  set $Name=$Value FAILED: $($r.error)"; return $false }
    return $true
}

function Read-WaapiState() {
    $ret  = '"id","@EnableImmerse","@UserID","@ConvolutionType","@HeadphoneEq","@BusContent"'
    $body = '{"uri":"ak.wwise.core.object.get","args":{"from":{"id":["' + $ImmerseEffectId + '"]}},"options":{"return":[' + $ret + ']}}'
    $r = Invoke-Waapi $body
    if (-not $r.ok -or -not $r.result -or -not $r.result.return -or $r.result.return.Count -eq 0) { return $null }
    return $r.result.return[0]
}

function Resolve-ImmerseEffectId([string]$Name) {
    $needle = ($Name -replace '"','\"')
    $body = '{"uri":"ak.wwise.core.object.get","args":{"from":{"search":["' + $needle + '"]}},"options":{"return":["id","name","type","path"]}}'
    $r = Invoke-Waapi $body
    if (-not $r.ok -or -not $r.result -or -not $r.result.return) { return $null }
    foreach ($obj in $r.result.return) {
        if ($obj.name -eq $Name -and $obj.type -eq 'Effect') { return $obj.id }
    }
    foreach ($obj in $r.result.return) {
        if ($obj.type -eq 'Effect') { return $obj.id }
    }
    return $null
}

$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
L "WaapiOrchestrator start"
L "  EditorLog: $EditorLog"
L "  WaapiUrl:  $WaapiUrl"

if (-not $ImmerseEffectId) {
    $ImmerseEffectId = Resolve-ImmerseEffectId $ImmerseEffectName
    if (-not $ImmerseEffectId) {
        L "ERROR: could not resolve Immerse Effect ID by name '$ImmerseEffectName'. Is Wwise Authoring running with the project loaded and WAAPI on $WaapiUrl? Falling back to baseline read with no ID will fail."
    } else {
        L "  Resolved Immerse Effect ID by name '$ImmerseEffectName' -> $ImmerseEffectId"
    }
} else {
    L "  ImmerseId: $ImmerseEffectId (explicit)"
}

$base = Read-WaapiState
if ($base) {
    L ("baseline: ehm=$($base.'@EnableImmerse') uid=$($base.'@UserID') profile=$($base.'@ConvolutionType') hpeq=$($base.'@HeadphoneEq') bus=$($base.'@BusContent')")
} else {
    L "ERROR: baseline read failed -- is Wwise Authoring running with the project loaded, the Immerse FX named '$ImmerseEffectName', and WAAPI on $WaapiUrl?"
}

$startedAt = Get-Date
$lastPos   = [int64]0
$lastEhm   = $null
$flips     = 0

while (((Get-Date) - $startedAt).TotalSeconds -lt $TimeoutSec) {
    if (Test-Path $EditorLog) {
        try {
            $fs = [System.IO.File]::Open($EditorLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                if ($fs.Length -lt $lastPos) { $lastPos = 0 }
                [void]$fs.Seek($lastPos, [System.IO.SeekOrigin]::Begin)
                $reader = New-Object System.IO.StreamReader($fs)
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    if (-not $line) { continue }
                    if ($line -match '\[ImmerseStress\]\s+EnableImmerse\(.*\)\s+->\s+OK') {
                        if ($lastEhm -ne $true) {
                            $ok = Set-WaapiProp 'EnableImmerse' $true
                            L ("actor: EnableImmerse OK  -> WAAPI EnableImmerse=true  [" + ($(if($ok){'OK'}else{'FAIL'})) + "]")
                            $lastEhm = $true; $flips++
                        }
                    } elseif ($line -match '\[ImmerseStress\]\s+BypassImmerse\(.*\)\s+->\s+OK') {
                        if ($lastEhm -ne $false) {
                            $ok = Set-WaapiProp 'EnableImmerse' $false
                            L ("actor: BypassImmerse OK -> WAAPI EnableImmerse=false [" + ($(if($ok){'OK'}else{'FAIL'})) + "]")
                            $lastEhm = $false; $flips++
                        }
                    }
                }
                $lastPos = $fs.Position
            } finally {
                $fs.Close()
            }
        } catch {
            # file may be temporarily locked; retry next tick
        }
    }
    Start-Sleep -Milliseconds $PollMs
}

$final = Read-WaapiState
if ($final) {
    L ("final: ehm=$($final.'@EnableImmerse') profile=$($final.'@ConvolutionType') hpeq=$($final.'@HeadphoneEq') bus=$($final.'@BusContent')")
}
L "WaapiOrchestrator exit. ehm_flips=$flips"

[CmdletBinding()]
param(
    [string]   $WaapiUrl        = 'http://127.0.0.1:8090/waapi',
    [string]   $ImmerseEffectId = '{FC04B7CE-5A63-44EA-ABCF-4DC30BD037D4}',
    [int[]]    $Sequence        = @(0,1,0,1),
    [int]      $DelayMs         = 1500
)

# WAAPI_PROBE_v1: standalone EHM toggle probe.
# Manually exercises the SAME WAAPI call the orchestrator uses
# (ak.wwise.core.object.setProperty on @EnableImmerse) so we can A/B against
# a manually opened DbgView and confirm whether setProperty actually reaches
# the running game's sound engine.
#
# Pre-requisites for the test:
#   1. UE editor running, project loaded.
#   2. Wwise Authoring open with TencentRCTest.wproj and remote-connected to UE.
#   3. Dbgview64.exe running, click "No" if prompted to install kernel driver
#      (Win32 user-mode capture is enough). Capture > Win32 should be ON.
#      The Capture menu has no Win32-only toggle in newer DbgView -- just make
#      sure "Capture Win32" is ON and "Capture Kernel" is OFF.
#   4. AutoRunAndPush.ps1 NOT running (it would compete for DBWIN_BUFFER with
#      DbgView).
#
# Then in this PowerShell, run:
#   .\Test-WaapiEhmToggle.ps1
# Defaults perform off,on,off,on with 1.5s between each. Watch DbgView for
# "___IMMERSEENGINE___ Immerse_EnableImmerse inMode: 0/1" lines aligned with
# each flip. If they appear -> setProperty IS pushing to the runtime, our
# pipeline has a different bug. If they DON'T appear -> setProperty is purely
# authoring-side and we need a different WAAPI verb (RTPC).

$ErrorActionPreference = 'Continue'

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

function Read-Ehm() {
    $body = '{"uri":"ak.wwise.core.object.get","args":{"from":{"id":["' + $ImmerseEffectId + '"]}},"options":{"return":["id","@EnableImmerse"]}}'
    $r = Invoke-Waapi $body
    if (-not $r.ok -or -not $r.result -or -not $r.result.return -or $r.result.return.Count -eq 0) { return $null }
    return $r.result.return[0].'@EnableImmerse'
}

function Set-Ehm([bool]$Enabled) {
    $vJson = $Enabled.ToString().ToLower()
    $body  = '{"uri":"ak.wwise.core.object.setProperty","args":{"object":"' + $ImmerseEffectId + '","property":"EnableImmerse","value":' + $vJson + '},"options":{}}'
    return Invoke-Waapi $body
}

Write-Host ""
Write-Host "WAAPI EHM toggle probe"
Write-Host "  URL:       $WaapiUrl"
Write-Host "  ImmerseId: $ImmerseEffectId"
Write-Host "  Sequence:  $($Sequence -join ',')  DelayMs=$DelayMs"
Write-Host ""

$baseline = Read-Ehm
if ($null -eq $baseline) {
    Write-Host "ERROR: could not read baseline from WAAPI. Is Wwise Authoring running with the project loaded and WAAPI listening on $WaapiUrl?"
    exit 1
}
Write-Host "baseline @EnableImmerse = $baseline"
Write-Host ""

$i = 0
foreach ($v in $Sequence) {
    $i++
    $bool = ($v -ne 0)
    $r = Set-Ehm $bool
    $ts = (Get-Date).ToString('HH:mm:ss.fff')
    if ($r.ok) {
        Start-Sleep -Milliseconds 200
        $rb = Read-Ehm
        Write-Host "[$ts] flip $i -> @EnableImmerse=$bool  (readback=$rb)"
    } else {
        Write-Host "[$ts] flip $i -> FAILED: $($r.error)"
    }
    if ($i -lt $Sequence.Count) { Start-Sleep -Milliseconds $DelayMs }
}

Write-Host ""
Write-Host "Done. Check DbgView for '___IMMERSEENGINE___ Immerse_EnableImmerse inMode: N' lines."
Write-Host "If you see one per flip -> WAAPI setProperty IS reaching the runtime."
Write-Host "If you don't -> setProperty is authoring-only, we need a different verb."

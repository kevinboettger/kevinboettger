$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false
try { $PSStyle.OutputRendering = 'PlainText' } catch { }

# TIER1_WAAPI_v1: end-to-end functional test of the Immerse Audio Renderer
# driven entirely through WAAPI. No UE source patching, no build step.
# Assumes any UE C++ project with Wwise integration + an auto-playing event,
# plus a reference Wwise project + an installed Immerse Authoring plug-in.

$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir    = Split-Path -Parent $ScriptDir
# IMMERSE_UPROJECT can point at any .uproject (or a folder containing one) so
# the GUI / portable installations can target an arbitrary UE project instead
# of the one this script happens to live next to.
if ($env:IMMERSE_UPROJECT -and (Test-Path $env:IMMERSE_UPROJECT)) {
    $item = Get-Item $env:IMMERSE_UPROJECT
    if ($item.PSIsContainer) {
        $ProjectDir = $item.FullName
    } elseif ($item.Extension -eq '.uproject') {
        $ProjectDir = Split-Path -Parent $item.FullName
    }
}
$RunId         = Get-Date -Format 'yyyyMMdd-HHmmss'
$ResultsRoot   = Join-Path $ScriptDir '_results_repo'
$Owner         = 'kevinboettger'
$Repo          = 'kevinboettger'
$Branch        = 'claude/test-immerse-tier1-waapi'
$RunDirRel     = "immerse_runs/$RunId"
$RunDirAbs     = $null
$ImmerseUserId = if ($env:IMMERSE_USER_ID) { $env:IMMERSE_USER_ID } else { 'kevin_tencenttest1_emb' }

function Step($m) { Write-Host "==== $m ====" -ForegroundColor Cyan }
function Info($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GitArgs)
    $tempErr = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = & git @GitArgs 2>$tempErr
        $code   = $LASTEXITCODE
        $stderr = ''
        if (Test-Path $tempErr) { $stderr = Get-Content $tempErr -Raw -ErrorAction SilentlyContinue }
        return [PSCustomObject]@{
            ExitCode = $code
            StdOut   = ($stdout -join "`n")
            StdErr   = ($stderr -as [string])
        }
    } finally {
        Remove-Item $tempErr -ErrorAction SilentlyContinue
    }
}

$tokenFile = Join-Path $ScriptDir '.github_token'
$LocalMode = $false
if ($env:IMMERSE_LOCAL_ONLY -eq '1') {
    $LocalMode = $true
    Write-Host "    IMMERSE_LOCAL_ONLY=1 -- skipping GitHub push (local-only mode)" -ForegroundColor DarkGray
} elseif (-not (Test-Path $tokenFile)) {
    $LocalMode = $true
    Write-Host "    No .github_token found at $tokenFile -- running in local-only mode (results stay local)" -ForegroundColor DarkGray
}
if ($LocalMode) {
    $Token     = ''
    $RemoteUrl = ''
} else {
    $Token     = (Get-Content -Raw $tokenFile).Trim()
    $RemoteUrl = "https://x-access-token:$Token@github.com/$Owner/$Repo.git"
}

function Init-ResultsRepo {
    if ($LocalMode) {
        # No GitHub clone -- just ensure the local results directory exists.
        # If there's a stale clone from a previous push-mode run, leave it
        # alone (its .git stays; new local runs just write into immerse_runs/).
        if (-not (Test-Path $ResultsRoot)) {
            New-Item -ItemType Directory -Force -Path $ResultsRoot | Out-Null
        }
        return
    }
    if (Test-Path $ResultsRoot) {
        if (-not (Test-Path (Join-Path $ResultsRoot '.git'))) {
            Warn "Removing stale (non-repo) $ResultsRoot"
            Remove-Item -LiteralPath $ResultsRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path $ResultsRoot)) {
        Step "Cloning results checkout"
        $r = Invoke-Git clone --quiet --branch $Branch --single-branch $RemoteUrl $ResultsRoot
        if ($r.ExitCode -ne 0) {
            Write-Host "ERROR: git clone failed (exit $($r.ExitCode))" -ForegroundColor Red
            Write-Host $r.StdErr -ForegroundColor Red
            throw 'clone failed'
        }
    } else {
        $null = Invoke-Git -C $ResultsRoot remote set-url origin $RemoteUrl
        $null = Invoke-Git -C $ResultsRoot remote set-branches origin '*'
        $null = Invoke-Git -C $ResultsRoot fetch "origin" "+refs/heads/${Branch}:refs/remotes/origin/${Branch}"
        $null = Invoke-Git -C $ResultsRoot checkout -B $Branch "origin/$Branch"
        $null = Invoke-Git -C $ResultsRoot reset --hard "origin/$Branch"
    }
    $null = Invoke-Git -C $ResultsRoot config user.email 'immerse-bot@local'
    $null = Invoke-Git -C $ResultsRoot config user.name 'ImmerseTier1Bot'
}

function Push-To-Branch {
    param([string]$Msg)
    if ($LocalMode) { return $true }
    $null = Invoke-Git -C $ResultsRoot fetch origin $Branch
    $null = Invoke-Git -C $ResultsRoot reset --soft "origin/$Branch"
    $null = Invoke-Git -C $ResultsRoot add -A
    $diff = Invoke-Git -C $ResultsRoot diff --cached --quiet
    if ($diff.ExitCode -ne 0) {
        $commit = Invoke-Git -C $ResultsRoot commit -m $Msg
        if ($commit.ExitCode -ne 0) { Warn "commit failed: $($commit.StdErr)"; return $false }
        for ($i = 0; $i -lt 4; $i++) {
            $push = Invoke-Git -C $ResultsRoot push origin "HEAD:refs/heads/$Branch"
            if ($push.ExitCode -eq 0) { return $true }
            Warn "push retry $($i+1): $($push.StdErr)"
            Start-Sleep -Seconds ([Math]::Pow(2, $i + 1))
        }
        Warn 'push retries exhausted'
        return $false
    }
    return $true
}

function Push-Status {
    param([string]$Phase, [hashtable]$Extra)
    if (-not $script:RunDirAbs) {
        $script:RunDirAbs = Join-Path $ResultsRoot $RunDirRel
        New-Item -ItemType Directory -Force -Path $script:RunDirAbs | Out-Null
    }
    $obj = [ordered]@{
        run_id    = $RunId
        phase     = $Phase
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        host      = $env:COMPUTERNAME
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] } }
    ($obj | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $script:RunDirAbs 'status.json') -Encoding UTF8
    Push-To-Branch -Msg "$RunId : $Phase" | Out-Null
    Info ($(if ($LocalMode) { "status: $Phase (local-only)" } else { "pushed status: $Phase" }))
}

function Push-File([string]$Local, [string]$Name) {
    if (-not (Test-Path $Local)) { return }
    if (-not $script:RunDirAbs) {
        $script:RunDirAbs = Join-Path $ResultsRoot $RunDirRel
        New-Item -ItemType Directory -Force -Path $script:RunDirAbs | Out-Null
    }
    Copy-Item -LiteralPath $Local -Destination (Join-Path $script:RunDirAbs $Name) -Force
}

function Invoke-Waapi {
    param([string]$Url, [string]$Body)
    try {
        $r = Invoke-RestMethod -Uri $Url -Method Post -Body $Body -ContentType 'application/json' -TimeoutSec 5
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

try {
    Init-ResultsRepo
    Push-Status -Phase 'starting' -Extra @{ tier = 1; user_id = $ImmerseUserId }

    Step 'Locating UE engine'
    $engineRoot = $null
    foreach ($k in 'HKLM:\SOFTWARE\EpicGames\Unreal Engine\4.27','HKLM:\SOFTWARE\WOW6432Node\EpicGames\Unreal Engine\4.27') {
        if (Test-Path $k) { $engineRoot = (Get-ItemProperty $k).InstalledDirectory; if ($engineRoot) { break } }
    }
    if (-not $engineRoot) {
        foreach ($p in 'C:\Program Files\Epic Games\UE_4.27','D:\Program Files\Epic Games\UE_4.27','E:\Program Files\Epic Games\UE_4.27') {
            if (Test-Path $p) { $engineRoot = $p; break }
        }
    }
    if (-not $engineRoot) {
        Push-Status -Phase 'failed' -Extra @{ stage='locate_ue'; error='UE 4.27 not found' }
        throw 'UE 4.27 not found'
    }
    Info "Engine: $engineRoot"

    $uproject = (Get-ChildItem $ProjectDir -Filter '*.uproject' | Select-Object -First 1).FullName
    if (-not $uproject) { throw "No .uproject found in $ProjectDir" }
    Info "Uproject: $uproject"

    $editor    = Join-Path $engineRoot 'Engine\Binaries\Win64\UE4Editor.exe'
    $editorLog = Join-Path $env:TEMP "immerse_editor_$RunId.log"
    $RunDirAbs = Join-Path $ResultsRoot $RunDirRel
    New-Item -ItemType Directory -Force -Path $RunDirAbs | Out-Null

    # If this project still has the ImmerseStressTestActor compiled in from prior
    # Tier 2 builds, the actor would auto-run its plan, post 300Hz audio events,
    # and self-exit UE after ~20s. Setting IMMERSE_REMOTE_HOLD parks it (the
    # REMOTE_HOLD_v1 patch in the actor checks for this env var + go.flag).
    # We never drop go.flag, so the actor stays parked. WAAPI property changes
    # still produce listener-log lines because the plug-in's parameter callback
    # fires independently of any audio flow.
    $env:IMMERSE_REMOTE_HOLD = '1'
    $goFlagPath = Join-Path $ProjectDir 'Saved\ImmerseStress\go.flag'
    if (Test-Path $goFlagPath) { Remove-Item $goFlagPath -Force -ErrorAction SilentlyContinue }

    # listener: capture all OutputDebugString from same-user processes
    $dbgListener = $null
    $dbgLogTmp   = Join-Path $env:TEMP "immerse_dbgmonitor_$RunId.log"
    $dbgLogFinal = Join-Path $RunDirAbs 'immerse_debug.log'
    $dbgScript   = Join-Path $ScriptDir 'DebugStreamListener.ps1'
    if (Test-Path $dbgScript) {
        if (Test-Path $dbgLogTmp) { Remove-Item $dbgLogTmp -Force -ErrorAction SilentlyContinue }
        $dbgArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$dbgScript`"",
                     '-OutPath',"`"$dbgLogTmp`"",'-Seconds','1800')
        $dbgListener = Start-Process -FilePath 'powershell.exe' -ArgumentList $dbgArgs -PassThru -WindowStyle Hidden
        Info "DebugStreamListener PID: $($dbgListener.Id), log: $dbgLogTmp"
    } else {
        Warn 'DebugStreamListener.ps1 missing -- debug stream not captured'
    }

    # Wwise launch + WAAPI ready + UserID set
    $waapiUrl        = 'http://127.0.0.1:8090/waapi'
    $waapiReady      = $false
    $immerseEffectId = $null

    $wwiseExe = $env:IMMERSE_WWISE_EXE
    if (-not $wwiseExe -or -not (Test-Path $wwiseExe)) {
        $cand = @()
        foreach ($glob in @(
            'C:\Program Files (x86)\Audiokinetic\Wwise*\Authoring\x64\Release\bin\Wwise.exe',
            'C:\Program Files\Audiokinetic\Wwise*\Authoring\x64\Release\bin\Wwise.exe'
        )) { $cand += (Get-ChildItem -Path $glob -ErrorAction SilentlyContinue | ForEach-Object FullName) }
        foreach ($c in $cand) { if ($c -and (Test-Path $c)) { $wwiseExe = $c; break } }
    }
    $wproj = $env:IMMERSE_WPROJ
    if (-not $wproj -or -not (Test-Path $wproj)) {
        foreach ($p in @(
            (Join-Path $env:USERPROFILE 'OneDrive\Documents\WwiseProjects\TencentRCTest\TencentRCTest.wproj'),
            (Join-Path $env:USERPROFILE 'Documents\WwiseProjects\TencentRCTest\TencentRCTest.wproj')
        )) { if (Test-Path $p) { $wproj = $p; break } }
    }

    $wwiseProc = Get-Process -Name Wwise -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wwiseProc) {
        Info "Wwise already running (PID $($wwiseProc.Id)) -- reusing"
    } elseif ($wwiseExe -and $wproj) {
        Info "Launching Wwise: $wwiseExe"
        Info "  Project: $wproj"
        try { Start-Process -FilePath $wwiseExe -ArgumentList "`"$wproj`"" | Out-Null } catch { Warn "Failed to launch Wwise: $($_.Exception.Message)" }
    } else {
        Warn "Could not locate Wwise.exe (set IMMERSE_WWISE_EXE) and/or .wproj (set IMMERSE_WPROJ)"
    }

    Step 'Waiting for WAAPI to come up'
    $ws = Get-Date
    while (((Get-Date) - $ws).TotalSeconds -lt 60) {
        $r = Invoke-Waapi $waapiUrl '{"uri":"ak.wwise.core.getInfo","args":{},"options":{}}'
        if ($r.ok) { $waapiReady = $true; break }
        if ($r.error -match 'ak\.wwise\.locked') { Warn 'WAAPI reports modal lock in Wwise; close any open dialog' }
        Start-Sleep -Seconds 2
    }
    if (-not $waapiReady) {
        Push-Status -Phase 'failed' -Extra @{ stage='waapi_wait'; error='WAAPI unreachable in 60s' }
        throw 'WAAPI not reachable'
    }
    Info 'WAAPI ready'

    $body = '{"uri":"ak.wwise.core.object.get","args":{"from":{"search":["Immerse_Audio_Renderer_(Custom)"]}},"options":{"return":["id","name","type","path"]}}'
    $r = Invoke-Waapi $waapiUrl $body
    if ($r.ok -and $r.result -and $r.result.return) {
        foreach ($obj in $r.result.return) {
            if ($obj.type -eq 'Effect' -and $obj.name -eq 'Immerse_Audio_Renderer_(Custom)') { $immerseEffectId = $obj.id; break }
        }
        if (-not $immerseEffectId) {
            foreach ($obj in $r.result.return) { if ($obj.type -eq 'Effect') { $immerseEffectId = $obj.id; break } }
        }
    }
    if (-not $immerseEffectId) {
        Push-Status -Phase 'failed' -Extra @{ stage='resolve_immerse'; error='Immerse FX not found by name' }
        throw 'Could not resolve Immerse FX by name'
    }
    Info "Immerse FX id: $immerseEffectId"

    if ($ImmerseUserId) {
        $body = '{"uri":"ak.wwise.core.object.setProperty","args":{"object":"' + $immerseEffectId + '","property":"UserID","value":"' + ($ImmerseUserId -replace '"','\"') + '"},"options":{}}'
        $r = Invoke-Waapi $waapiUrl $body
        if ($r.ok) { Info "Set @UserID = $ImmerseUserId" } else { Warn "Failed to set @UserID: $($r.error)" }
    }
    Push-Status -Phase 'wwise_ready' -Extra @{ immerse_effect_id = $immerseEffectId }

    # UE launch (headless, -game). No actor required; the level's auto-playing event drives audio.
    $editorArgs = @(
        "`"$uproject`"",
        '/Game/ThirdPersonBP/Maps/ThirdPersonExampleMap',
        '-game','-RenderOffscreen','-unattended','-nopause','-NoSplash',
        "-abslog=$editorLog"
    )
    $editorStart = Get-Date
    $proc = Start-Process -FilePath $editor -ArgumentList $editorArgs -PassThru -WindowStyle Hidden
    Info "Editor PID: $($proc.Id), log: $editorLog"
    Push-Status -Phase 'ue_launched' -Extra @{ editor_pid = $proc.Id }

    # auto remote-connect
    Step 'Auto-connecting Wwise to UE'
    $autoConnected = $false
    $acStart = Get-Date
    while (((Get-Date) - $acStart).TotalSeconds -lt 30 -and -not $proc.HasExited) {
        $r = Invoke-Waapi $waapiUrl '{"uri":"ak.wwise.core.remote.getAvailableConsoles","args":{},"options":{}}'
        if ($r.ok -and $r.result -and $r.result.consoles) {
            # Prefer Windows consoles on localhost; fall back to whatever is there.
            # Avoid hardcoding the UE project name (e.g. 'testTP') so the same
            # launcher works for any UE project name a user might rename to.
            $cands = @($r.result.consoles)
            $candidates = @($cands | Where-Object {
                $_.platform -eq 'Windows' -and ($_.host -eq '127.0.0.1' -or $_.host -eq 'localhost')
            })
            if ($candidates.Count -eq 0) { $candidates = @($cands | Where-Object { $_.platform -eq 'Windows' }) }
            if ($candidates.Count -eq 0) { $candidates = $cands }
            if ($candidates.Count -gt 0) {
                $target = $candidates[0]
                Info "Found console: host=$($target.host) appName=$($target.appName)"
                $body = '{"uri":"ak.wwise.core.remote.connect","args":{"host":"' + $target.host + '","appName":"' + ($target.appName -replace '"','\"') + '"},"options":{}}'
                $cr = Invoke-Waapi $waapiUrl $body
                if ($cr.ok) { Info 'Wwise -> UE remote-connect successful'; $autoConnected = $true; break }
                Warn "remote.connect failed: $($cr.error)"
            }
        }
        Start-Sleep -Seconds 1
    }
    if (-not $autoConnected) {
        Warn 'Auto remote-connect timed out -- proceeding anyway (some tests may fail)'
    }

    # wait for user-load confirmation in listener log
    Step 'Waiting for personalized user-load confirmation'
    $loadOk = $false
    $lStart = Get-Date
    while (((Get-Date) - $lStart).TotalSeconds -lt 30 -and -not $proc.HasExited) {
        if (Test-Path $dbgLogTmp) {
            $content = [string]::Join("`n", (Get-Content $dbgLogTmp -Tail 800 -ErrorAction SilentlyContinue))
            $hasSetUserId = $content -match 'Immerse_SetUserId\s+inUserId'
            $hasProfile   = $content -match 'updateUserHRTFData\s+ProfileName\s+set\s+to'
            $uidMatch     = -not $ImmerseUserId -or ($content -match ('generateWebAppUrl.*userId:\s*' + [regex]::Escape($ImmerseUserId)))
            if ($hasSetUserId -and $hasProfile -and $uidMatch) { $loadOk = $true; break }
        }
        Start-Sleep -Milliseconds 500
    }
    if ($loadOk) { Info 'User-load confirmed' } else { Warn 'User-load confirmation not seen (tests may not behave as expected)' }
    Push-Status -Phase 'user_loaded' -Extra @{ user_load_ok = $loadOk; auto_connected = $autoConnected }

    # run scenarios
    Step 'Running Tier 1 scenarios'
    $scenariosPath  = Join-Path $ScriptDir 'TestScenarios.json'
    $runnerScript   = Join-Path $ScriptDir 'Run-Scenarios.ps1'
    $resultsJson    = Join-Path $RunDirAbs 'scenario_results.json'
    $summaryTxt     = Join-Path $RunDirAbs 'scenario_summary.txt'
    $scenarioOk     = $false
    if ((Test-Path $scenariosPath) -and (Test-Path $runnerScript)) {
        # Inline invocation (not 'powershell -File') so Read-Host inside the
        # runner attaches to this launcher's console (Step 5: pauseAfter).
        & "$runnerScript" `
            -ScenariosPath "$scenariosPath" -ListenerLog "$dbgLogTmp" `
            -WaapiUrl "$waapiUrl" -ImmerseEffectId "$immerseEffectId" `
            -ResultsJson "$resultsJson" -SummaryPath "$summaryTxt"
        $failCount = -1
        if (Test-Path $resultsJson) {
            try {
                $resultsObj = Get-Content -Raw $resultsJson | ConvertFrom-Json
                $failCount = [int]$resultsObj.fail
                $scenarioOk = ($failCount -eq 0)
            } catch { Warn "Could not parse scenario results: $($_.Exception.Message)" }
        }
        Info "Scenario fails: $failCount (0 = all pass)"
    } else {
        Warn 'TestScenarios.json or Run-Scenarios.ps1 missing -- skipping scenarios'
    }

    # teardown
    Step 'Stopping UE editor'
    if ($proc -and -not $proc.HasExited) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Milliseconds 1500
        Info 'Stopped UE editor'
    }

    if ($dbgListener -and -not $dbgListener.HasExited) {
        Start-Sleep -Milliseconds 1000
        try { Stop-Process -Id $dbgListener.Id -Force -ErrorAction SilentlyContinue } catch {}
        Info 'Stopped DebugStreamListener'
    }

    # IMMERSE_CLOSE_WWISE=1 from the GUI: cleanly shut down Wwise Authoring at
    # the end of the run. CloseMainWindow lets Wwise prompt to save unsaved
    # changes (it shouldn't have any since our setProperty calls live-push but
    # don't persist to the project file). If it doesn't respond within ~5s we
    # fall back to a force kill.
    if ($env:IMMERSE_CLOSE_WWISE -eq '1') {
        $wwiseAtEnd = Get-Process -Name Wwise -ErrorAction SilentlyContinue
        if ($wwiseAtEnd) {
            Step 'Closing Wwise Authoring'
            foreach ($w in $wwiseAtEnd) {
                try { [void]$w.CloseMainWindow() } catch {}
            }
            $deadline = (Get-Date).AddSeconds(5)
            while ((Get-Date) -lt $deadline) {
                $stillUp = Get-Process -Name Wwise -ErrorAction SilentlyContinue
                if (-not $stillUp) { break }
                Start-Sleep -Milliseconds 300
            }
            $stillUp = Get-Process -Name Wwise -ErrorAction SilentlyContinue
            if ($stillUp) {
                foreach ($w in $stillUp) { try { Stop-Process -Id $w.Id -Force -ErrorAction SilentlyContinue } catch {} }
                Info 'Force-killed Wwise (did not respond to CloseMainWindow in 5s)'
            } else {
                Info 'Wwise closed cleanly'
            }
        }
    }
    if (Test-Path $dbgLogTmp) {
        try { Copy-Item $dbgLogTmp $dbgLogFinal -Force } catch { Warn "Could not copy debug stream log: $($_.Exception.Message)" }
    }
    if (Test-Path $editorLog) { Push-File $editorLog 'editor.log' }

    # Generate HTML report from scenario_results.json so the GUI (or any
    # operator) has a one-file view of the run. Export the run dir to a
    # global var so the GUI can find report.html after the launcher returns.
    $reportScript = Join-Path $ScriptDir 'Generate-HtmlReport.ps1'
    $reportPath   = Join-Path $RunDirAbs 'report.html'
    if ((Test-Path $reportScript) -and (Test-Path $resultsJson)) {
        try {
            $meta = @{
                'Run ID'               = $RunId
                'Timestamp'            = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                'Host'                 = $env:COMPUTERNAME
                'User ID'              = $ImmerseUserId
                'UE project'           = $ProjectDir
                'Wwise project'        = if ($wproj) { $wproj } else { '(reused running instance)' }
                'Immerse Effect ID'    = $immerseEffectId
                'Auto remote-connect'  = $autoConnected
                'User-load confirmed'  = $loadOk
            }
            & $reportScript -ResultsJson $resultsJson -SummaryTxt $summaryTxt -OutPath $reportPath -Metadata $meta
        } catch { Warn "Could not generate HTML report: $($_.Exception.Message)" }
    }
    $global:IMMERSE_LAST_RUN_DIR = $RunDirAbs

    Push-Status -Phase $(if ($scenarioOk) { 'completed' } else { 'completed_with_failures' }) -Extra @{
        scenario_ok    = $scenarioOk
        user_load_ok   = $loadOk
        auto_connected = $autoConnected
    }
    Step 'DONE'
    if ($LocalMode) {
        Write-Host "Results (local-only): $RunDirAbs" -ForegroundColor Green
    } else {
        Write-Host "Results: https://github.com/$Owner/$Repo/tree/$Branch/$RunDirRel" -ForegroundColor Green
    }
    if (Test-Path $reportPath) { Write-Host "HTML report: $reportPath" -ForegroundColor Green }
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    try { Push-Status -Phase 'failed' -Extra @{ error = "$_" } } catch { }
}

Read-Host 'Press Enter to close'

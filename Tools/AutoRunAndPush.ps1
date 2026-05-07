$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false
try { $PSStyle.OutputRendering = 'PlainText' } catch { }

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir  = Split-Path -Parent $ScriptDir
$RunId       = Get-Date -Format 'yyyyMMdd-HHmmss'
$ResultsRoot = Join-Path $ScriptDir '_results_repo'
$Owner       = 'kevinboettger'
$Repo        = 'kevinboettger'
$Branch      = 'claude/test-immerse-audio-plugin-su44W'
$RunDirRel   = "immerse_runs/$RunId"
$RunDirAbs   = $null

function Step($m) { Write-Host "==== $m ====" -ForegroundColor Cyan }
function Info($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GitArgs)
    $tempErr = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = & git @GitArgs 2>$tempErr
        $code = $LASTEXITCODE
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
if (-not (Test-Path $tokenFile)) {
    Write-Host "MISSING: $tokenFile" -ForegroundColor Red
    Read-Host 'Press Enter to close'; exit 1
}
$Token     = (Get-Content $tokenFile -Raw).Trim()
$RemoteUrl = "https://x-access-token:$Token@github.com/$Owner/$Repo.git"

$verCheck = Invoke-Git --version
if ($verCheck.ExitCode -ne 0) {
    Write-Host "FATAL: git not on PATH." -ForegroundColor Red
    Read-Host 'Press Enter to close'; exit 1
}
$env:GIT_TERMINAL_PROMPT = '0'

function Init-ResultsRepo {
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
            Write-Host "git clone failed (exit $($r.ExitCode))" -ForegroundColor Red
            if ($r.StdErr) { Write-Host "stderr:`n$($r.StdErr)" -ForegroundColor Red }
            throw "git clone failed (exit $($r.ExitCode))"
        }
    } else {
        $null = Invoke-Git -C $ResultsRoot remote set-url origin $RemoteUrl
        $null = Invoke-Git -C $ResultsRoot fetch origin $Branch
        $null = Invoke-Git -C $ResultsRoot checkout $Branch
        $null = Invoke-Git -C $ResultsRoot reset --hard "origin/$Branch"
    }
    $null = Invoke-Git -C $ResultsRoot config user.email 'immerse-bot@local'
    $null = Invoke-Git -C $ResultsRoot config user.name 'ImmerseStressBot'
}

function Push-To-Branch([string]$Msg) {
    $null = Invoke-Git -C $ResultsRoot fetch origin $Branch
    $null = Invoke-Git -C $ResultsRoot reset --soft "origin/$Branch"
    $null = Invoke-Git -C $ResultsRoot add -A
    $diff = Invoke-Git -C $ResultsRoot diff --cached --quiet
    if ($diff.ExitCode -ne 0) {
        $commit = Invoke-Git -C $ResultsRoot commit -m $Msg
        if ($commit.ExitCode -ne 0) {
            Warn "commit failed: $($commit.StdErr)"
            return $false
        }
        for ($i = 0; $i -lt 4; $i++) {
            $push = Invoke-Git -C $ResultsRoot push origin $Branch
            if ($push.ExitCode -eq 0) { return $true }
            Warn "push retry $($i+1): $($push.StdErr)"
            Start-Sleep -Seconds ([math]::Pow(2, $i + 1))
        }
        Warn 'push retries exhausted'
        return $false
    }
    return $true
}

function Push-Status {
    param([string]$Phase, [hashtable]$Extra = @{})
    if (-not $script:RunDirAbs) {
        $script:RunDirAbs = Join-Path $ResultsRoot $RunDirRel
        New-Item -ItemType Directory -Force -Path $script:RunDirAbs | Out-Null
    }
    $obj = @{
        run_id     = $RunId
        phase      = $Phase
        machine    = $env:COMPUTERNAME
        user       = $env:USERNAME
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] }
    ($obj | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $script:RunDirAbs 'status.json') -Encoding UTF8
    [void](Push-To-Branch "[$RunId] $Phase")
    Info "pushed status: $Phase"
}

function Push-File([string]$Local, [string]$Name) {
    if (-not (Test-Path $Local)) { return }
    if (-not $script:RunDirAbs) {
        $script:RunDirAbs = Join-Path $ResultsRoot $RunDirRel
        New-Item -ItemType Directory -Force -Path $script:RunDirAbs | Out-Null
    }
    Copy-Item $Local -Destination (Join-Path $script:RunDirAbs $Name) -Force
}

function Patch-Sources {
    $changes = @()
    $sourceRoot = Join-Path $ProjectDir 'Source\testTP'
    if (-not (Test-Path $sourceRoot)) {
        Warn "no Source/testTP dir at $sourceRoot"
        return
    }

    $keyHeader = Join-Path $sourceRoot 'Public\ImmerseStressTestActor.h'
    if (Test-Path $keyHeader) { Push-File $keyHeader 'ImmerseStressTestActor.h.before' }
    $keyCpp    = Join-Path $sourceRoot 'Private\ImmerseStressTestActor.cpp'
    if (Test-Path $keyCpp)    { Push-File $keyCpp    'ImmerseStressTestActor.cpp.before' }

    # Patch 1: class -> struct for IConsoleCommand to match this user's UE 4.27
    # IConsoleManager.h declaration kind. (Idempotent: if no `class IConsoleCommand`
    # remains it just no-ops.)
    $files = Get-ChildItem $sourceRoot -Recurse -Include *.h,*.cpp -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $orig = Get-Content $f.FullName -Raw
        $patched = $orig -replace 'class(\s+)IConsoleCommand', 'struct$1IConsoleCommand'
        if ($patched -ne $orig) {
            Set-Content -Path $f.FullName -Value $patched -NoNewline -Encoding UTF8
            $changes += "$($f.Name): IConsoleCommand class -> struct"
        }
    }

    if (Test-Path $keyCpp) {
        $cpp = Get-Content $keyCpp -Raw

        # Patch 2: insert AK readiness gate at top of RunPlan() (idempotent).
        # On the first crashing run, RunPlan was called synchronously from
        # PostLoadMap before AK::SoundEngine::Init had finished its internal
        # queue allocation, so AK::SoundEngine::SetMixer dereferenced a null
        # CAkAudioMgr member. Gate gets a retry loop via the timer manager.
        if ($cpp -notmatch 'ImmerseAKReadyRetries') {
            $insertion = @'

	static int ImmerseAKReadyRetries = 0;
	if (FAkAudioDevice::Get() == nullptr)
	{
		++ImmerseAKReadyRetries;
		if (ImmerseAKReadyRetries > 40) {
			UE_LOG(LogTemp, Error, TEXT("[ImmerseStress] FAkAudioDevice still null after ~20s, giving up on auto-run."));
			ImmerseAKReadyRetries = 0;
			return;
		}
		UE_LOG(LogTemp, Display, TEXT("[ImmerseStress] AkAudioDevice not ready (retry %d), waiting 0.5s..."), ImmerseAKReadyRetries);
		if (UWorld* W = GetWorld())
		{
			FTimerHandle Th;
			W->GetTimerManager().SetTimer(Th, FTimerDelegate::CreateUObject(this, &AImmerseStressTestActor::RunPlan), 0.5f, false);
		}
		return;
	}
	ImmerseAKReadyRetries = 0;

'@
            $patternRP = '(void\s+AImmerseStressTestActor::RunPlan\(\)\s*\{)'
            $newCpp = $cpp -replace $patternRP, ('$1' + $insertion)
            if ($newCpp -ne $cpp) {
                $cpp = $newCpp
                $changes += 'RunPlan: gate on FAkAudioDevice::Get() with retry'
            } else {
                Warn 'AK readiness gate insertion did not match RunPlan signature'
            }
        }
        elseif ($cpp -match 'AK::SoundEngine::IsInitialized') {
            # Older variant of the gate used IsInitialized(); replace with FAkAudioDevice
            # because IsInitialized() returns false even when Wwise is fully running
            # under -game -RenderOffscreen with this Wwise 2019.2 build.
            $newCpp = $cpp `
                -replace 'AK::SoundEngine::IsInitialized\(\)', '(FAkAudioDevice::Get() != nullptr)' `
                -replace 'Wwise SoundEngine still not initialized', 'FAkAudioDevice still null' `
                -replace 'Wwise not ready', 'AkAudioDevice not ready'
            if ($newCpp -ne $cpp) {
                $cpp = $newCpp
                $changes += 'RunPlan gate: IsInitialized() -> FAkAudioDevice::Get()'
            }
        }

        # Patch 3: defer RunPlan from BeginPlay via 2.5s timer.
        # Even when FAkAudioDevice exists, calling SetMixer from the
        # PostLoadMap-spawned-actor's BeginPlay races the Wwise audio thread.
        # Firing RunPlan from a TimerManager timer pushes it onto a normal
        # tick after the engine has stabilized.
        if ($cpp -notmatch 'AutoRunBeginPlayTimer') {
            $patternBP = '(?s)(if\s*\(\s*bAutoRunOnBeginPlay\s*\)\s*\{)[^{}]*?RunPlan\s*\(\s*\)\s*;[^{}]*?\}'
            $replacementBP = @'
$1
		// AutoRunBeginPlayTimer: defer RunPlan via 2.5s timer so SetMixer is
		// called from a normal Tick (after Wwise stabilizes), not during the
		// PostLoadMap-driven BeginPlay where the AK audio thread is mid-init.
		if (UWorld* WAuto = GetWorld())
		{
			FTimerHandle ThAuto;
			WAuto->GetTimerManager().SetTimer(ThAuto, FTimerDelegate::CreateUObject(this, &AImmerseStressTestActor::RunPlan), 2.5f, false);
		}
		else
		{
			RunPlan();
		}
	}
'@
            $newCpp = $cpp -replace $patternBP, $replacementBP
            if ($newCpp -ne $cpp) {
                $cpp = $newCpp
                $changes += 'BeginPlay AutoRun: deferred 2.5s via TimerManager'
            } else {
                Warn 'BeginPlay timer insertion did not match the bAutoRunOnBeginPlay block'
            }
        }

        Set-Content -Path $keyCpp -Value $cpp -NoNewline -Encoding UTF8
    }

    # Dump engine excerpt for kind verification.
    $candidates = @(
        'C:\Program Files\Epic Games\UE_4.27\Engine\Source\Runtime\Core\Public\HAL\IConsoleManager.h',
        'D:\Program Files\Epic Games\UE_4.27\Engine\Source\Runtime\Core\Public\HAL\IConsoleManager.h',
        'E:\Program Files\Epic Games\UE_4.27\Engine\Source\Runtime\Core\Public\HAL\IConsoleManager.h'
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) {
            $allLines = Get-Content $p
            $startIdx = [Math]::Max(0, 470 - 1)
            $endIdx   = [Math]::Min($allLines.Count - 1, 530 - 1)
            $excerpt  = @("// IConsoleManager.h lines $($startIdx + 1)-$($endIdx + 1) from $p","") + $allLines[$startIdx..$endIdx]
            $excerpt | Set-Content -Path (Join-Path $script:RunDirAbs 'IConsoleManager.h.excerpt.txt') -Encoding UTF8
            break
        }
    }

    if (Test-Path $keyHeader) { Push-File $keyHeader 'ImmerseStressTestActor.h.after' }
    if (Test-Path $keyCpp)    { Push-File $keyCpp    'ImmerseStressTestActor.cpp.after' }

    if ($changes.Count -gt 0) {
        Info "source patches applied:"
        foreach ($c in $changes) { Info "  - $c" }
    } else {
        Info 'no source patches needed'
    }
}

try {
    Init-ResultsRepo
    $RunDirAbs = Join-Path $ResultsRoot $RunDirRel
    New-Item -ItemType Directory -Force -Path $RunDirAbs | Out-Null
    Push-Status -Phase 'started' -Extra @{ project_dir = $ProjectDir }

    Step 'Checking Visual Studio (Game Dev C++ workload)'
    Push-Status -Phase 'vs_check'
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vsPath = $null
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Workload.NativeGame `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
    }
    if (-not $vsPath) {
        Push-Status -Phase 'vs_installing'
        Step 'Downloading + installing VS 2022 Community (20-40 min, ~10 GB)'
        $bs = Join-Path $env:TEMP 'vs_community.exe'
        Invoke-WebRequest 'https://aka.ms/vs/17/release/vs_community.exe' -OutFile $bs -UseBasicParsing
        $vsArgs = @(
            '--quiet','--wait','--norestart','--nocache',
            '--add','Microsoft.VisualStudio.Workload.NativeGame',
            '--add','Microsoft.VisualStudio.Workload.NativeDesktop',
            '--add','Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
            '--add','Microsoft.VisualStudio.Component.Windows10SDK.19041',
            '--includeRecommended'
        )
        $p = Start-Process -FilePath $bs -ArgumentList $vsArgs -Wait -PassThru
        if ($p.ExitCode -eq 3010) {
            Push-Status -Phase 'vs_reboot_needed' -Extra @{ exit_code = 3010 }
            Read-Host 'Press Enter'; exit 0
        }
        if ($p.ExitCode -ne 0) {
            Push-Status -Phase 'failed' -Extra @{ stage='vs_install'; exit_code = $p.ExitCode }
            throw "VS install failed: $($p.ExitCode)"
        }
    } else {
        Info "Found VS at $vsPath"
    }
    Push-Status -Phase 'vs_ready'

    Step 'Locating UE 4.27'
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
    Push-Status -Phase 'ue_located' -Extra @{ engine_root = $engineRoot }

    Step 'Patching sources for known UE 4.27 issues'
    Patch-Sources
    Push-Status -Phase 'sources_patched'

    Step 'Regenerating project files'
    $uproject = (Get-ChildItem $ProjectDir -Filter '*.uproject' | Select-Object -First 1).FullName
    $ubt = Join-Path $engineRoot 'Engine\Binaries\DotNET\UnrealBuildTool.exe'
    $regenLog = Join-Path $env:TEMP "immerse_regen_$RunId.log"
    & $ubt -projectfiles -project="$uproject" -game -engine -progress *>&1 | Tee-Object -FilePath $regenLog | Out-Host
    $regenExit = $LASTEXITCODE
    Push-File $regenLog 'regen.log'
    if ($regenExit -ne 0) {
        Push-Status -Phase 'failed' -Extra @{ stage='regen'; exit_code=$regenExit }
        throw "Regen failed: $regenExit"
    }
    Push-Status -Phase 'regen_done'

    Step 'Building testTPEditor / Win64 / Development'
    Push-Status -Phase 'building'
    $buildBat = Join-Path $engineRoot 'Engine\Build\BatchFiles\Build.bat'
    $buildLog = Join-Path $env:TEMP "immerse_build_$RunId.log"
    & $buildBat 'testTPEditor' 'Win64' 'Development' "-Project=$uproject" '-WaitMutex' *>&1 | Tee-Object -FilePath $buildLog | Out-Host
    $buildExit = $LASTEXITCODE
    Push-File $buildLog 'build.log'
    $buildHasErrors = $false
    if (Test-Path $buildLog) {
        $logTail = Get-Content $buildLog -Tail 200 -ErrorAction SilentlyContinue
        if ($logTail -match 'error C\d+|: error : |Error executing|fatal error') {
            $buildHasErrors = $true
        }
    }
    if ($buildExit -ne 0 -or $buildHasErrors) {
        Push-Status -Phase 'failed' -Extra @{ stage='build'; exit_code=$buildExit; sniffed_errors=$buildHasErrors }
        throw "Build failed (exit $buildExit, sniffed_errors=$buildHasErrors)"
    }
    Push-Status -Phase 'build_done'

    Step 'Launching headless editor for stress sweep'
    Push-Status -Phase 'testing'
    $editor    = Join-Path $engineRoot 'Engine\Binaries\Win64\UE4Editor.exe'
    $editorLog = Join-Path $env:TEMP "immerse_editor_$RunId.log"
    $editorArgs = @(
        "`"$uproject`"",
        '/Game/ThirdPersonBP/Maps/ThirdPersonExampleMap',
        '-game','-RenderOffscreen','-unattended','-nopause','-NoSplash',
        "-abslog=$editorLog"
    )
    $editorStart = Get-Date
    $proc = Start-Process -FilePath $editor -ArgumentList $editorArgs -PassThru -WindowStyle Hidden
    Info "Editor PID: $($proc.Id), log: $editorLog"

    $startedAt = Get-Date
    $lastTail  = Get-Date
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 10
        if (((Get-Date) - $lastTail).TotalSeconds -ge 30) {
            if (Test-Path $editorLog) {
                $tail = Get-Content $editorLog -Tail 120 -ErrorAction SilentlyContinue
                if ($tail) {
                    ($tail -join "`n") | Set-Content -Path (Join-Path $RunDirAbs 'editor_tail.log') -Encoding UTF8
                    $markers = $tail | Where-Object { $_ -match '\[ImmerseStress\]' }
                    Push-Status -Phase 'testing' -Extra @{
                        elapsed_s = [int]((Get-Date) - $startedAt).TotalSeconds
                        markers   = if ($markers) { $markers[-1] } else { $null }
                    }
                }
            }
            $lastTail = Get-Date
        }
        if (((Get-Date) - $startedAt).TotalMinutes -ge 12) {
            Write-Host 'TIMEOUT: killing editor after 12 min' -ForegroundColor Red
            try { Stop-Process -Id $proc.Id -Force } catch { }
            Push-Status -Phase 'failed' -Extra @{ stage='editor'; error='timeout_12min' }
            break
        }
    }

    Step 'Collecting CSV + final log'
    $resultsDir = Join-Path $ProjectDir 'Saved\ImmerseStress'
    $csv = $null
    if (Test-Path $resultsDir) {
        # Only consider CSVs created AFTER the editor was launched, so we don't
        # accidentally re-upload an old run's CSV when the current run failed.
        $csv = Get-ChildItem $resultsDir -Filter 'run_*.csv' -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTime -ge $editorStart } |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($csv) { Push-File $csv.FullName 'results.csv'; Info "CSV: $($csv.Name)" }
    if (Test-Path $editorLog) { Push-File $editorLog 'editor.log' }

    if ($csv) {
        Push-Status -Phase 'completed' -Extra @{ csv_name = $csv.Name }
        Step 'DONE'
        Write-Host "Results: https://github.com/$Owner/$Repo/tree/$Branch/$RunDirRel" -ForegroundColor Green
    } else {
        Push-Status -Phase 'completed_no_csv' -Extra @{ note='editor exited but no CSV produced this run' }
    }
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    try { Push-Status -Phase 'failed' -Extra @{ error = "$_" } } catch { }
}

Read-Host 'Press Enter to close'

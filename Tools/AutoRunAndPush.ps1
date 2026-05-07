$ErrorActionPreference = 'Continue'
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

$tokenFile = Join-Path $ScriptDir '.github_token'
if (-not (Test-Path $tokenFile)) {
    Write-Host "MISSING: $tokenFile" -ForegroundColor Red
    Write-Host "Create a fine-grained PAT (Contents=Read+Write on kevinboettger/kevinboettger) and save it as the only line in that file." -ForegroundColor Yellow
    Read-Host 'Press Enter to close'; exit 1
}
$Token     = (Get-Content $tokenFile -Raw).Trim()
$RemoteUrl = "https://x-access-token:$Token@github.com/$Owner/$Repo.git"

$gitOk = $false
try { & git --version *> $null; $gitOk = ($LASTEXITCODE -eq 0) } catch { }
if (-not $gitOk) {
    Write-Host "FATAL: git not on PATH. Install Git for Windows: https://git-scm.com/download/win" -ForegroundColor Red
    Read-Host 'Press Enter to close'; exit 1
}

function Init-ResultsRepo {
    if (-not (Test-Path $ResultsRoot)) {
        Step "Cloning results checkout"
        & git clone --branch $Branch --single-branch $RemoteUrl $ResultsRoot 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    } else {
        & git -C $ResultsRoot remote set-url origin $RemoteUrl *> $null
        & git -C $ResultsRoot fetch origin $Branch *> $null
        & git -C $ResultsRoot checkout $Branch *> $null
        & git -C $ResultsRoot reset --hard "origin/$Branch" *> $null
    }
    & git -C $ResultsRoot config user.email 'immerse-bot@local' *> $null
    & git -C $ResultsRoot config user.name 'ImmerseStressBot' *> $null
}

function Push-To-Branch([string]$Msg) {
    & git -C $ResultsRoot fetch origin $Branch *> $null
    & git -C $ResultsRoot reset --soft "origin/$Branch" *> $null
    & git -C $ResultsRoot add -A *> $null
    & git -C $ResultsRoot diff --cached --quiet *> $null
    if ($LASTEXITCODE -ne 0) {
        & git -C $ResultsRoot commit -m $Msg *> $null
        for ($i = 0; $i -lt 4; $i++) {
            & git -C $ResultsRoot push origin $Branch *> $null
            if ($LASTEXITCODE -eq 0) { return $true }
            Start-Sleep -Seconds ([math]::Pow(2, $i + 1))
        }
        Write-Host "WARN: push retries exhausted" -ForegroundColor Yellow
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
            Write-Host 'VS install needs reboot. Reboot, then re-run AutoRunAndPush.bat.' -ForegroundColor Yellow
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

    Step 'Regenerating project files'
    $uproject = (Get-ChildItem $ProjectDir -Filter '*.uproject' | Select-Object -First 1).FullName
    $ubt = Join-Path $engineRoot 'Engine\Binaries\DotNET\UnrealBuildTool.exe'
    $regenLog = Join-Path $env:TEMP "immerse_regen_$RunId.log"
    & $ubt -projectfiles -project="$uproject" -game -engine -progress *>&1 | Tee-Object -FilePath $regenLog | Out-Host
    Push-File $regenLog 'regen.log'
    if ($LASTEXITCODE -ne 0) {
        Push-Status -Phase 'failed' -Extra @{ stage='regen'; exit_code=$LASTEXITCODE }
        throw "Regen failed: $LASTEXITCODE"
    }
    Push-Status -Phase 'regen_done'

    Step 'Building testTPEditor / Win64 / Development'
    Push-Status -Phase 'building'
    $buildBat = Join-Path $engineRoot 'Engine\Build\BatchFiles\Build.bat'
    $buildLog = Join-Path $env:TEMP "immerse_build_$RunId.log"
    & $buildBat 'testTPEditor' 'Win64' 'Development' "-Project=$uproject" '-WaitMutex' *>&1 | Tee-Object -FilePath $buildLog | Out-Host
    Push-File $buildLog 'build.log'
    if ($LASTEXITCODE -ne 0) {
        Push-Status -Phase 'failed' -Extra @{ stage='build'; exit_code=$LASTEXITCODE }
        throw "Build failed: $LASTEXITCODE"
    }
    Push-Status -Phase 'build_done'

    Step 'Launching headless editor for stress sweep'
    Push-Status -Phase 'testing'
    $editor   = Join-Path $engineRoot 'Engine\Binaries\Win64\UE4Editor.exe'
    $editorLog = Join-Path $env:TEMP "immerse_editor_$RunId.log"
    $args = @(
        "`"$uproject`"",
        '/Game/ThirdPersonBP/Maps/ThirdPersonExampleMap',
        '-game','-RenderOffscreen','-unattended','-nopause','-NoSplash',
        "-abslog=$editorLog"
    )
    $proc = Start-Process -FilePath $editor -ArgumentList $args -PassThru -WindowStyle Hidden
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
        $csv = Get-ChildItem $resultsDir -Filter 'run_*.csv' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($csv) { Push-File $csv.FullName 'results.csv'; Info "CSV: $($csv.Name)" }
    if (Test-Path $editorLog) { Push-File $editorLog 'editor.log' }

    if ($csv) {
        Push-Status -Phase 'completed' -Extra @{ csv_name = $csv.Name }
        Step 'DONE'
        Write-Host "Results: https://github.com/$Owner/$Repo/tree/$Branch/$RunDirRel" -ForegroundColor Green
    } else {
        Push-Status -Phase 'completed_no_csv' -Extra @{ note='editor exited but no CSV produced' }
    }
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    try { Push-Status -Phase 'failed' -Extra @{ error = "$_" } } catch { }
}

Read-Host 'Press Enter to close'

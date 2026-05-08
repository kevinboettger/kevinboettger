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
$ImmerseUserId = 'kevin_tencenttest1_emb'

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

function Read-AllText {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path $Path)) { throw "File not found: $Path" }
    return [System.IO.File]::ReadAllText($Path)
}

function Write-AllText-Safe {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][AllowNull()][AllowEmptyString()]$Content,
        [int]$MinLengthGuard = 0
    )
    if ($null -eq $Content -or [string]::IsNullOrEmpty($Content)) {
        throw "Refusing to write null/empty content to $Path"
    }
    if ((Test-Path $Path) -and $MinLengthGuard -gt 0 -and $Content.Length -lt $MinLengthGuard) {
        throw "Refusing to write ${Path}: new length $($Content.Length) is below guard ($MinLengthGuard)"
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

# NOTE: parameter renamed from $Input -> $InputText. PS5 has an automatic
# pipeline variable named $input, and declaring a parameter with the same
# name (case-insensitive) silently shadows it with an empty enumerator,
# which made Regex-Replace return an empty string and trip the safety guard.
function Regex-Replace {
    param(
        [Parameter(Mandatory=$true)][string]$Step,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$InputText,
        [Parameter(Mandatory=$true)][string]$Pattern,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Replacement
    )
    if ($null -eq $InputText) {
        throw "Regex-Replace[$Step]: input is null"
    }
    $rx = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    return $rx.Replace($InputText, $Replacement)
}

function Restore-CppFromBackup {
    param(
        [Parameter(Mandatory=$true)][string]$KeyCpp,
        [Parameter(Mandatory=$true)][string]$RepoRoot
    )
    $runsDir = Join-Path $RepoRoot 'immerse_runs'
    if (-not (Test-Path $runsDir)) {
        Warn "  no immerse_runs/ in $RepoRoot"
        return $false
    }
    $backups = Get-ChildItem $runsDir -Recurse -Filter 'ImmerseStressTestActor.cpp.before' -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 1000 } |
        Sort-Object LastWriteTime -Descending
    if (-not $backups -or $backups.Count -eq 0) {
        Warn '  no valid (>1KB) cpp.before backups in immerse_runs/'
        return $false
    }
    $best = $backups | Select-Object -First 1
    Info "  restoring cpp from $($best.FullName) ($($best.Length) bytes)"
    Copy-Item $best.FullName $KeyCpp -Force
    return $true
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

function Push-To-Branch {
    param([string]$Msg)
    $null = Invoke-Git -C $ResultsRoot fetch origin $Branch
    $null = Invoke-Git -C $ResultsRoot reset --soft "origin/$Branch"
    $null = Invoke-Git -C $ResultsRoot add -A
    $diff = Invoke-Git -C $ResultsRoot diff --cached --quiet
    if ($diff.ExitCode -ne 0) {
        $commit = Invoke-Git -C $ResultsRoot commit -m $Msg
        if ($commit.ExitCode -ne 0) { Warn "commit failed: $($commit.StdErr)"; return $false }
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

function Ensure-AkAudioMixerWrapper {
    $wwiseSrcRoot = Join-Path $ProjectDir 'Plugins\Wwise\Source\AkAudio'
    $publicDir    = Join-Path $wwiseSrcRoot 'Public'
    $privateDir   = Join-Path $wwiseSrcRoot 'Private'
    if (-not (Test-Path $publicDir) -or -not (Test-Path $privateDir)) {
        Warn "AkAudio module source dirs not present at $wwiseSrcRoot; skipping wrapper install."
        return $false
    }

    $hdr = Join-Path $publicDir  'ImmerseStressMixerWrapper.h'
    $src = Join-Path $privateDir 'ImmerseStressMixerWrapper.cpp'

    $hdrContent = @'
// Auto-generated by Tools/AutoRunAndPush.ps1.
#pragma once

#include "AkInclude.h"

class FString;

namespace ImmerseStress
{
	AKAUDIO_API AKRESULT SetMixerOnBus(const FString& BusName, AkUniqueID MixerSharesetID);
	AKAUDIO_API AKRESULT SetMixerOnBusByName(const FString& BusName, const FString& MixerSharesetName);
}
'@

    $srcContent = @'
// Auto-generated by Tools/AutoRunAndPush.ps1.
#include "ImmerseStressMixerWrapper.h"
#include "AK/SoundEngine/Common/AkSoundEngine.h"
#include "Containers/UnrealString.h"

namespace ImmerseStress
{
	AKRESULT SetMixerOnBus(const FString& BusName, AkUniqueID MixerSharesetID)
	{
		FTCHARToUTF8 BusUtf8(*BusName);
		return AK::SoundEngine::SetMixer(BusUtf8.Get(), MixerSharesetID);
	}

	AKRESULT SetMixerOnBusByName(const FString& BusName, const FString& MixerSharesetName)
	{
		AkUniqueID id = AK_INVALID_UNIQUE_ID;
		if (!MixerSharesetName.IsEmpty())
		{
			FTCHARToUTF8 NameUtf8(*MixerSharesetName);
			id = AK::SoundEngine::GetIDFromString(NameUtf8.Get());
		}
		FTCHARToUTF8 BusUtf8(*BusName);
		return AK::SoundEngine::SetMixer(BusUtf8.Get(), id);
	}
}
'@

    if (-not (Test-Path $hdr)) {
        [System.IO.File]::WriteAllText($hdr, $hdrContent, [System.Text.UTF8Encoding]::new($false))
        Info "Wrote $hdr"
    }
    if (-not (Test-Path $src)) {
        [System.IO.File]::WriteAllText($src, $srcContent, [System.Text.UTF8Encoding]::new($false))
        Info "Wrote $src"
    }
    return ((Test-Path $hdr) -and (Test-Path $src))
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

    if (Test-Path $keyCpp) {
        $cppItem = Get-Item $keyCpp
        if ($cppItem.Length -lt 1000) {
            Warn "ImmerseStressTestActor.cpp is only $($cppItem.Length) bytes -- attempting restore from backup..."
            if (Restore-CppFromBackup -KeyCpp $keyCpp -RepoRoot $ResultsRoot) {
                $cppItem = Get-Item $keyCpp
                Info "  restored to $($cppItem.Length) bytes"
                $changes += "ImmerseStressTestActor.cpp: restored from cpp.before backup"
            } else {
                Warn '  RESTORE FAILED. Cannot proceed without a valid cpp.'
                Push-Status -Phase 'failed' -Extra @{ stage='restore_cpp'; error='no valid backup found' }
                return
            }
        }
        Push-File $keyCpp 'ImmerseStressTestActor.cpp.before'
    }

    Info 'Patch step: class IConsoleCommand -> struct'
    $files = Get-ChildItem $sourceRoot -Recurse -Include *.h,*.cpp -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        try { $orig = Read-AllText -Path $f.FullName } catch {
            Warn "Skipping $($f.Name): $($_.Exception.Message)"; continue
        }
        if ([string]::IsNullOrEmpty($orig)) {
            Warn "Skipping empty file: $($f.Name)"; continue
        }
        $patched = Regex-Replace -Step "icc-$($f.Name)" -InputText $orig -Pattern 'class(\s+)IConsoleCommand' -Replacement 'struct$1IConsoleCommand'
        if ($patched -ne $orig) {
            Write-AllText-Safe -Path $f.FullName -Content $patched -MinLengthGuard ([Math]::Max(1, [int]($orig.Length / 2)))
            $changes += "$($f.Name): IConsoleCommand class -> struct"
        }
    }

    Info 'Patch step: install AkAudio wrapper files'
    $wrapperReady = Ensure-AkAudioMixerWrapper
    if ($wrapperReady) {
        $changes += 'AkAudio: ImmerseStressMixerWrapper installed'
    }

    if (-not (Test-Path $keyCpp)) { return }

    $cpp = Read-AllText -Path $keyCpp
    if ([string]::IsNullOrEmpty($cpp) -or $cpp.Length -lt 1000) {
        Warn "ImmerseStressTestActor.cpp is empty/tiny on disk after restore attempt -- aborting."
        return
    }
    $originalLength = $cpp.Length
    Info "Patch step: probe cpp markers (length=$originalLength)"

    $hasGate    = $cpp.Contains('ImmerseAKReadyRetries')
    $hasIsInit  = $cpp.Contains('AK::SoundEngine::IsInitialized')
    $hasTimer   = $cpp.Contains('AutoRunBeginPlayTimer')
    $hasUidLog  = $cpp.Contains('IMMERSE_USER_ID env')
    $hasWrapper = $cpp.Contains('IMMERSE_SETMIXER_WRAPPER_v2')
    $hasNoop    = $cpp.Contains('NOOP_SETMIXER_v1')
    $hasInc     = $cpp.Contains('ImmerseStressMixerWrapper.h')
    Info "  gate=$hasGate isInit=$hasIsInit timer=$hasTimer uidLog=$hasUidLog wrapper=$hasWrapper noop=$hasNoop include=$hasInc"

    if (-not $hasGate) {
        Info 'Patch step: insert FAkAudioDevice readiness gate at top of RunPlan'
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
        $rxRP = [regex]::new('(void\s+AImmerseStressTestActor::RunPlan\(\)\s*\{)')
        $cpp = $rxRP.Replace($cpp, '$1' + $insertion, 1)
        $changes += 'RunPlan: FAkAudioDevice gate'
    }
    elseif ($hasIsInit) {
        Info 'Patch step: convert legacy IsInitialized() gate -> FAkAudioDevice::Get()'
        $cpp = Regex-Replace -Step 'IsInit-1' -InputText $cpp -Pattern 'AK::SoundEngine::IsInitialized\(\)' -Replacement '(FAkAudioDevice::Get() != nullptr)'
        $cpp = Regex-Replace -Step 'IsInit-2' -InputText $cpp -Pattern 'Wwise SoundEngine still not initialized' -Replacement 'FAkAudioDevice still null'
        $cpp = Regex-Replace -Step 'IsInit-3' -InputText $cpp -Pattern 'Wwise not ready' -Replacement 'AkAudioDevice not ready'
        $changes += 'RunPlan gate: IsInitialized() -> FAkAudioDevice::Get()'
    }

    if (-not $hasTimer) {
        Info 'Patch step: defer auto-run via 2.5s timer in BeginPlay'
        $patternBP = '(if\s*\(\s*bAutoRunOnBeginPlay\s*\)\s*\{)[^{}]*?RunPlan\s*\(\s*\)\s*;[^{}]*?\}'
        $replacementBP = @'
$1
		// AutoRunBeginPlayTimer
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
        $rxBP = [regex]::new($patternBP, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $cpp = $rxBP.Replace($cpp, $replacementBP, 1)
        $changes += 'BeginPlay AutoRun: deferred 2.5s'
    }

    if (-not $hasUidLog) {
        Info 'Patch step: log IMMERSE_USER_ID env vars at BeginPlay'
        $logBlock = @'

	UE_LOG(LogTemp, Display, TEXT("[ImmerseStress] IMMERSE_USER_ID env=%s | IMMERSE_USERID=%s | IMMERSE_USER=%s"),
		*FPlatformMisc::GetEnvironmentVariable(TEXT("IMMERSE_USER_ID")),
		*FPlatformMisc::GetEnvironmentVariable(TEXT("IMMERSE_USERID")),
		*FPlatformMisc::GetEnvironmentVariable(TEXT("IMMERSE_USER")));

'@
        $rxR = [regex]::new('(\[ImmerseStress\] Ready\. Defaults:[^;]+;\s*)')
        $cpp = $rxR.Replace($cpp, '$1' + $logBlock, 1)
        $changes += 'BeginPlay: IMMERSE_USER_ID logging'
    }

    if (-not $hasWrapper -and $wrapperReady) {
        Info 'Patch step: rewire BypassImmerse/EnableImmerse to wrapper'
        if (-not $hasInc) {
            $incReplace = '$1#include "ImmerseStressMixerWrapper.h"' + [Environment]::NewLine
            $rxInc = [regex]::new('(#include\s+"AK/SoundEngine/Common/AkSoundEngine\.h"[^\n]*\n)')
            $cpp = $rxInc.Replace($cpp, $incReplace, 1)
        }

        $bypassReplacement = @'
void AImmerseStressTestActor::BypassImmerse()
{
	// IMMERSE_SETMIXER_WRAPPER_v2: route through AkAudio DLL boundary
	const AKRESULT Res = ImmerseStress::SetMixerOnBus(BusName, AK_INVALID_UNIQUE_ID);
	bImmerseBypassed = (Res == AK_Success);
	UE_LOG(LogTemp, Display, TEXT("[ImmerseStress] BypassImmerse(bus=%s) -> %s"),
		*BusName, bImmerseBypassed ? TEXT("OK") : TEXT("FAILED"));
}
'@
        $rxBypass = [regex]::new('void\s+AImmerseStressTestActor::BypassImmerse\s*\(\s*\)\s*\{[^{}]*\}', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $cpp = $rxBypass.Replace($cpp, $bypassReplacement, 1)

        $enableReplacement = @'
void AImmerseStressTestActor::EnableImmerse()
{
	// IMMERSE_SETMIXER_WRAPPER_v2: route through AkAudio DLL boundary
	const AKRESULT Res = ImmerseStress::SetMixerOnBusByName(BusName, ImmerseShareSetName);
	bImmerseBypassed = !(Res == AK_Success);
	UE_LOG(LogTemp, Display, TEXT("[ImmerseStress] EnableImmerse(bus=%s, shareset=%s) -> %s"),
		*BusName, *ImmerseShareSetName, (Res == AK_Success) ? TEXT("OK") : TEXT("FAILED"));
}
'@
        $rxEnable = [regex]::new('void\s+AImmerseStressTestActor::EnableImmerse\s*\(\s*\)\s*\{[^{}]*\}', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $cpp = $rxEnable.Replace($cpp, $enableReplacement, 1)

        $changes += 'BypassImmerse/EnableImmerse: wrapper-based'
    }

    Write-AllText-Safe -Path $keyCpp -Content $cpp -MinLengthGuard ([int]($originalLength / 2))

    if (Test-Path $keyHeader) { Push-File $keyHeader 'ImmerseStressTestActor.h.after' }
    if (Test-Path $keyCpp)    { Push-File $keyCpp    'ImmerseStressTestActor.cpp.after' }

    if ($changes.Count -gt 0) {
        Info "source patches applied:"
        foreach ($c in $changes) { Info "  - $c" }
    } else {
        Info 'no source patches needed'
    }
}

function Get-WwisePluginBinDir {
    $candidates = @(
        (Join-Path $ProjectDir 'Plugins\Wwise\ThirdParty\x64_vc150\Profile\bin'),
        (Join-Path $ProjectDir 'Plugins\Wwise\ThirdParty\x64_vc160\Profile\bin'),
        (Join-Path $ProjectDir 'Plugins\Wwise\ThirdParty\x64_vc170\Profile\bin')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Stage-ImmersePlugin {
    $binDir = Get-WwisePluginBinDir
    if (-not $binDir) { Warn 'No project-side Wwise plugin bin dir found.'; return $null }
    Info "Wwise plugin bin dir (target): $binDir"

    $immerseAlready = Get-ChildItem $binDir -Filter 'Immerse*.dll' -ErrorAction SilentlyContinue
    if ($immerseAlready) {
        Info "Existing Immerse DLLs already in target bin:"
        foreach ($d in $immerseAlready) { Info "  $($d.Name)" }
        return $binDir
    }

    Warn "No Immerse*.dll in $binDir -- searching project ThirdParty subdirs..."

    $sourceCandidates = @(
        (Join-Path $ProjectDir 'Plugins\Wwise\ThirdParty\x64_vc160\Profile\bin'),
        (Join-Path $ProjectDir 'Plugins\Wwise\ThirdParty\x64_vc160\Release\bin'),
        (Join-Path $ProjectDir 'Plugins\Wwise\ThirdParty\x64_vc160\Debug\bin'),
        (Join-Path $ProjectDir 'Plugins\Wwise\ThirdParty\x64_vc170\Profile\bin'),
        (Join-Path $ProjectDir 'Plugins\Wwise\ThirdParty\x64_vc170\Release\bin'),
        (Join-Path $ProjectDir 'Plugins\Wwise\ThirdParty\x64_vc150\Release\bin'),
        (Join-Path $ProjectDir 'Plugins\Wwise\ThirdParty\x64_vc150\Debug\bin')
    )

    $copied = 0
    foreach ($srcDir in $sourceCandidates) {
        if (-not (Test-Path $srcDir)) { continue }
        if ($srcDir -ieq $binDir)     { continue }
        $dlls = Get-ChildItem $srcDir -Filter 'Immerse*.dll' -ErrorAction SilentlyContinue
        if (-not $dlls -or $dlls.Count -eq 0) { continue }

        Info "Source dir with Immerse DLLs: $srcDir"
        foreach ($d in $dlls) {
            try {
                Copy-Item $d.FullName (Join-Path $binDir $d.Name) -Force
                Info "  staged $($d.Name)"; $copied++
            } catch { Warn "  failed to copy $($d.Name): $_" }
        }
        if ($copied -gt 0) { break }
    }
    Info "Total Immerse DLLs staged: $copied"
    return $binDir
}

try {
    Init-ResultsRepo
    $RunDirAbs = Join-Path $ResultsRoot $RunDirRel
    New-Item -ItemType Directory -Force -Path $RunDirAbs | Out-Null
    Push-Status -Phase 'started' -Extra @{ project_dir = $ProjectDir; immerse_user_id = $ImmerseUserId }

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
    try {
        Patch-Sources
    } catch {
        Warn "Patch-Sources error: $($_.Exception.Message)"
        Warn "Stack trace:"
        Warn ($_.ScriptStackTrace -as [string])
        throw
    }
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
        if ($logTail -match 'error C\d+|: error : |Error executing|fatal error') { $buildHasErrors = $true }
    }
    if ($buildExit -ne 0 -or $buildHasErrors) {
        Push-Status -Phase 'failed' -Extra @{ stage='build'; exit_code=$buildExit; sniffed_errors=$buildHasErrors }
        throw "Build failed (exit $buildExit, sniffed_errors=$buildHasErrors)"
    }
    Push-Status -Phase 'build_done'

    Step 'Verifying Immerse plugin DLL on Wwise plugin search path'
    $stagedBinDir = Stage-ImmersePlugin
    Push-Status -Phase 'immerse_dll_check' -Extra @{ bin_dir = $stagedBinDir }

    Step 'Setting Immerse user ID env vars'
    $env:IMMERSE_USER_ID  = $ImmerseUserId
    $env:IMMERSE_USERID   = $ImmerseUserId
    $env:IMMERSE_USER     = $ImmerseUserId
    $env:IMMERSE_EMBODY_USER_ID = $ImmerseUserId
    $env:IMMERSE_EMB_USER_ID = $ImmerseUserId
    Info "IMMERSE_USER_ID = $ImmerseUserId"
    Push-Status -Phase 'immerse_userid_set' -Extra @{ user_id = $ImmerseUserId }

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

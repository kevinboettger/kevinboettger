$ErrorActionPreference = 'Stop'

$projectDir = $env:TESTTP_PROJECT
if (-not $projectDir) {
    $candidates = @(
        "$env:USERPROFILE\OneDrive\Documents\Unreal Projects\testTP",
        "$env:USERPROFILE\Documents\Unreal Projects\testTP",
        'C:\Users\kapil\OneDrive\Documents\Unreal Projects\testTP'
    )
    $projectDir = $candidates | Where-Object { Test-Path (Join-Path $_ 'testTP.uproject') } | Select-Object -First 1
}
if (-not $projectDir -or -not (Test-Path (Join-Path $projectDir 'testTP.uproject'))) {
    Write-Host 'ERROR: Could not auto-detect testTP project.' -ForegroundColor Red
    return
}
Write-Host "Project: $projectDir" -ForegroundColor Cyan

$toolsDir = Join-Path $projectDir 'Tools'
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null

# Fetch via the GitHub Contents API instead of raw.githubusercontent.com.
# raw.gh aggressively caches even with ?_= cache-busters and no-cache headers;
# the Contents API serves the branch tip immediately.
$apiBase = 'https://api.github.com/repos/kevinboettger/kevinboettger/contents/Tools'
$ref     = 'claude/test-immerse-tier1-waapi'
$files   = @('AutoRunAndPush.ps1','AutoRunAndPush.bat','DebugStreamListener.ps1','Run-Scenarios.ps1','TestScenarios.json','StartGui.ps1','StartGui.bat','Generate-HtmlReport.ps1','ImmerseAudioRenderer.xml')
$headers = @{
    Accept       = 'application/vnd.github.v3.raw'
    'User-Agent' = 'immerse-tier1-bootstrap'
}
foreach ($name in $files) {
    $dest = Join-Path $toolsDir $name
    Write-Host "Downloading $name..." -ForegroundColor DarkGray
    Invoke-WebRequest -Uri "$apiBase/$name`?ref=$ref" -OutFile $dest -UseBasicParsing -Headers $headers
}

$tokenFile = Join-Path $toolsDir '.github_token'
if (-not (Test-Path $tokenFile)) {
    Write-Host ''
    Write-Host '=== GitHub Personal Access Token Setup ===' -ForegroundColor Yellow
    Write-Host 'Generate a fine-grained PAT at: https://github.com/settings/personal-access-tokens/new' -ForegroundColor Yellow
    Write-Host '  Resource owner: kevinboettger' -ForegroundColor Yellow
    Write-Host '  Repository access: Only select repositories -> kevinboettger/kevinboettger' -ForegroundColor Yellow
    Write-Host '  Repository permissions: Contents = Read and write' -ForegroundColor Yellow
    Write-Host ''
    $secure = Read-Host -Prompt 'Paste your PAT (input is hidden)' -AsSecureString
    $patPlain = [System.Net.NetworkCredential]::new('', $secure).Password
    if (-not $patPlain) { Write-Host 'No PAT entered. Aborting.' -ForegroundColor Red; return }
    Set-Content -Path $tokenFile -Value $patPlain -Encoding UTF8 -NoNewline
    Write-Host "PAT saved to $tokenFile" -ForegroundColor Green
} else {
    Write-Host 'Existing PAT found, reusing.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '=== Launching GUI ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolsDir 'StartGui.ps1')

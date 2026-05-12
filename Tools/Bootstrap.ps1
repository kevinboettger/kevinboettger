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

# Cache-bust raw.githubusercontent.com -- it can serve stale content for ~5 min.
# Append a random query param + send no-cache headers.
$buster = "?_=" + [DateTime]::UtcNow.Ticks
$base = 'https://raw.githubusercontent.com/kevinboettger/kevinboettger/claude/test-immerse-audio-plugin-su44W/Tools'
$files = @{
    'AutoRunAndPush.ps1'         = "$base/AutoRunAndPush.ps1$buster"
    'AutoRunAndPush.bat'         = "$base/AutoRunAndPush.bat$buster"
    'WaapiOrchestrator.ps1'      = "$base/WaapiOrchestrator.ps1$buster"
    'DebugStreamListener.ps1'    = "$base/DebugStreamListener.ps1$buster"
    'Verify-ImmerseToggles.ps1'  = "$base/Verify-ImmerseToggles.ps1$buster"
}
$headers = @{
    'Cache-Control' = 'no-cache, no-store, max-age=0'
    'Pragma'        = 'no-cache'
}
foreach ($name in $files.Keys) {
    $dest = Join-Path $toolsDir $name
    Write-Host "Downloading $name..." -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $files[$name] -OutFile $dest -UseBasicParsing -Headers $headers
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
Write-Host '=== Launching AutoRunAndPush ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolsDir 'AutoRunAndPush.ps1')

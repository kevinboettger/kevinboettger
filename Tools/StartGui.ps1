$ErrorActionPreference = 'Continue'
try { $PSStyle.OutputRendering = 'PlainText' } catch { }

# TIER1_GUI_v1: WinForms config form for the Tier 1 test harness.
# User picks the four required paths/IDs, clicks Run. We then set the env vars
# AutoRunAndPush.ps1 reads, invoke it, and at the end open the HTML report in
# the default browser.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Auto-detect defaults ---------------------------------------------------------

function Find-WwiseExe {
    if ($env:IMMERSE_WWISE_EXE -and (Test-Path $env:IMMERSE_WWISE_EXE)) { return $env:IMMERSE_WWISE_EXE }
    foreach ($glob in @(
        'C:\Program Files (x86)\Audiokinetic\Wwise*\Authoring\x64\Release\bin\Wwise.exe',
        'C:\Program Files\Audiokinetic\Wwise*\Authoring\x64\Release\bin\Wwise.exe'
    )) {
        $hit = Get-ChildItem -Path $glob -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return ''
}

function Find-Wproj {
    if ($env:IMMERSE_WPROJ -and (Test-Path $env:IMMERSE_WPROJ)) { return $env:IMMERSE_WPROJ }
    foreach ($p in @(
        (Join-Path $env:USERPROFILE 'OneDrive\Documents\WwiseProjects\TencentRCTest\TencentRCTest.wproj'),
        (Join-Path $env:USERPROFILE 'Documents\WwiseProjects\TencentRCTest\TencentRCTest.wproj')
    )) { if (Test-Path $p) { return $p } }
    return ''
}

function Find-Uproject {
    if ($env:IMMERSE_UPROJECT -and (Test-Path $env:IMMERSE_UPROJECT)) { return $env:IMMERSE_UPROJECT }
    # Tools/ is normally inside the UE project; default to the .uproject sibling of Tools.
    $parent = Split-Path -Parent $ScriptDir
    $hit = Get-ChildItem -Path $parent -Filter '*.uproject' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return ''
}

$defWwiseExe  = Find-WwiseExe
$defWproj     = Find-Wproj
$defUproject  = Find-Uproject
$defUserId    = if ($env:IMMERSE_USER_ID) { $env:IMMERSE_USER_ID } else { 'kevin_tencenttest1_emb' }

# Build form -------------------------------------------------------------------

[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Immerse Audio Renderer - Test Harness'
$form.Size = New-Object System.Drawing.Size(760, 420)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'Immerse Audio Renderer - Test Configuration'
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object System.Drawing.Point(20, 15)
$lblTitle.AutoSize = $true
$form.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = 'Configure the test inputs and click Run Tests. The HTML report opens when the run completes.'
$lblSubtitle.Location = New-Object System.Drawing.Point(20, 42)
$lblSubtitle.AutoSize = $true
$lblSubtitle.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblSubtitle)

function Add-Row($form, $y, $label, $value, $browseAction) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $label
    $lbl.Location = New-Object System.Drawing.Point(20, ($y + 4))
    $lbl.Size = New-Object System.Drawing.Size(180, 20)
    $form.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(205, $y)
    $tb.Size = New-Object System.Drawing.Size(450, 24)
    $tb.Text = $value
    $form.Controls.Add($tb)

    if ($browseAction) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = 'Browse...'
        $btn.Location = New-Object System.Drawing.Point(665, ($y - 1))
        $btn.Size = New-Object System.Drawing.Size(70, 26)
        $btn.Add_Click({ & $browseAction $tb }.GetNewClosure())
        $form.Controls.Add($btn)
    }
    return $tb
}

$txtUproject = Add-Row $form 85  'Unreal Engine project (.uproject):' $defUproject {
    param($tb)
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'UE project (*.uproject)|*.uproject'
    if ($ofd.ShowDialog() -eq 'OK') { $tb.Text = $ofd.FileName }
}

$txtWproj = Add-Row $form 125 'Wwise project (.wproj):' $defWproj {
    param($tb)
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'Wwise project (*.wproj)|*.wproj'
    if ($ofd.ShowDialog() -eq 'OK') { $tb.Text = $ofd.FileName }
}

$txtWwise = Add-Row $form 165 'Wwise Authoring exe:' $defWwiseExe {
    param($tb)
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'Wwise.exe|Wwise.exe'
    if ($ofd.ShowDialog() -eq 'OK') { $tb.Text = $ofd.FileName }
}

$txtUser = Add-Row $form 205 'Immerse User ID:' $defUserId $null

# Status row -------------------------------------------------------------------

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(20, 255)
$lblStatus.Size = New-Object System.Drawing.Size(715, 50)
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray
$lblStatus.Text = ''
$form.Controls.Add($lblStatus)

function Update-Status {
    $missing = @()
    if (-not (Test-Path $txtUproject.Text)) { $missing += 'UE project' }
    if (-not (Test-Path $txtWproj.Text))    { $missing += 'Wwise project' }
    if (-not (Test-Path $txtWwise.Text))    { $missing += 'Wwise exe' }
    if (-not $txtUser.Text)                 { $missing += 'User ID' }
    if ($missing.Count -eq 0) {
        $lblStatus.Text = 'All inputs valid. Ready to run.'
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(31, 136, 61)
        $btnRun.Enabled = $true
    } else {
        $lblStatus.Text = 'Missing or invalid: ' + ($missing -join ', ')
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(207, 34, 46)
        $btnRun.Enabled = $false
    }
}

foreach ($t in @($txtUproject, $txtWproj, $txtWwise, $txtUser)) {
    $t.Add_TextChanged({ Update-Status })
}

# Buttons ----------------------------------------------------------------------

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(530, 330)
$btnCancel.Size = New-Object System.Drawing.Size(100, 32)
$btnCancel.Add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })
$form.Controls.Add($btnCancel)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = 'Run Tests'
$btnRun.Location = New-Object System.Drawing.Point(635, 330)
$btnRun.Size = New-Object System.Drawing.Size(100, 32)
$btnRun.BackColor = [System.Drawing.Color]::FromArgb(31, 111, 235)
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.FlatStyle = 'Flat'
$btnRun.Add_Click({ $form.DialogResult = 'OK'; $form.Close() })
$form.Controls.Add($btnRun)

Update-Status
$result = $form.ShowDialog()

if ($result -ne 'OK') {
    Write-Host 'Cancelled.'
    return
}

# Run --------------------------------------------------------------------------

$env:IMMERSE_UPROJECT  = $txtUproject.Text
$env:IMMERSE_WPROJ     = $txtWproj.Text
$env:IMMERSE_WWISE_EXE = $txtWwise.Text
$env:IMMERSE_USER_ID   = $txtUser.Text

Write-Host ''
Write-Host '==== Launching test harness ====' -ForegroundColor Cyan
Write-Host "  UE project:    $($txtUproject.Text)"
Write-Host "  Wwise project: $($txtWproj.Text)"
Write-Host "  Wwise exe:     $($txtWwise.Text)"
Write-Host "  User ID:       $($txtUser.Text)"
Write-Host ''

$launcher = Join-Path $ScriptDir 'AutoRunAndPush.ps1'
if (-not (Test-Path $launcher)) {
    Write-Host "ERROR: missing $launcher" -ForegroundColor Red
    Read-Host 'Press Enter to close'; return
}

& $launcher

# After the launcher exits, find the run dir and open the HTML report ---------

$lastRunDir = $global:IMMERSE_LAST_RUN_DIR
if (-not $lastRunDir -or -not (Test-Path $lastRunDir)) {
    # Fallback: pick the most recent immerse_runs/<timestamp> folder
    $resultsRoot = Join-Path $ScriptDir '_results_repo'
    $runsDir = Join-Path $resultsRoot 'immerse_runs'
    if (Test-Path $runsDir) {
        $latest = Get-ChildItem $runsDir -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { $lastRunDir = $latest.FullName }
    }
}

if ($lastRunDir -and (Test-Path $lastRunDir)) {
    $reportPath = Join-Path $lastRunDir 'report.html'
    if (Test-Path $reportPath) {
        Write-Host ''
        Write-Host "Opening report: $reportPath" -ForegroundColor Green
        Start-Process $reportPath
    } else {
        Write-Host "Report not found at $reportPath" -ForegroundColor Yellow
    }
} else {
    Write-Host 'Could not locate run directory; no report opened.' -ForegroundColor Yellow
}

Write-Host ''
Read-Host 'Press Enter to close'

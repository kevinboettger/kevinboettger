$ErrorActionPreference = 'Continue'
try { $PSStyle.OutputRendering = 'PlainText' } catch { }

# TIER1_GUI_v2: config + parameter discovery from ImmerseAudioRenderer.xml.
# User picks the four paths/IDs, selects which Immerse plug-in properties to
# include in the test cycle, chooses a cycle count, and clicks Run. A
# TestScenarios.json is generated dynamically from the selections and the
# launcher runs it. Property metadata (names, types, valid enum values) is
# read from the XML so the GUI scales when the dev team adds properties.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Auto-detect helpers ---------------------------------------------------------

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
    $parent = Split-Path -Parent $ScriptDir
    $hit = Get-ChildItem -Path $parent -Filter '*.uproject' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return ''
}

function Find-PluginXml([string]$WwiseExePath) {
    # Prefer the XML inside the actual Wwise install (reflects what is loaded).
    if ($WwiseExePath -and (Test-Path $WwiseExePath)) {
        $installRoot = (Get-Item $WwiseExePath).Directory.Parent.Parent.Parent.Parent.FullName
        $pluginsDir = Join-Path $installRoot 'Authoring\Data\Plugins'
        if (Test-Path $pluginsDir) {
            $hit = Get-ChildItem $pluginsDir -Recurse -Filter 'ImmerseAudioRenderer.xml' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    # Fallback: the bundled copy next to this script.
    $local = Join-Path $ScriptDir 'ImmerseAudioRenderer.xml'
    if (Test-Path $local) { return $local }
    return ''
}

function Parse-PluginProperties([string]$XmlPath) {
    $list = @()
    if (-not (Test-Path $XmlPath)) { return $list }
    try {
        [xml]$x = Get-Content $XmlPath -Raw
    } catch { return $list }
    $eff = $x.PluginModule.EffectPlugin | Where-Object { $_.Name -eq 'Immerse Audio Renderer' } | Select-Object -First 1
    if (-not $eff) { return $list }
    foreach ($p in $eff.Properties.Property) {
        $values = @()
        $enum = $p.Restrictions.ValueRestriction.Enumeration.Value
        if ($enum) {
            foreach ($v in @($enum)) {
                $values += @{ Display = "$($v.DisplayName)"; Value = "$($v.'#text')" }
            }
        }
        # If the dev team ever annotates the XML with a visibility marker,
        # respect it. Recognized forms:
        #   <UserInterface Hidden="true"/>
        #   <UserInterface Hide="true"/>
        #   <UserInterface Visible="false"/>
        $hiddenFromXml = $false
        if ($p.UserInterface) {
            $ui = $p.UserInterface
            if ($ui.Hidden -eq 'true' -or $ui.Hide -eq 'true' -or $ui.Visible -eq 'false') {
                $hiddenFromXml = $true
            }
        }
        $list += [pscustomobject]@{
            Name          = "$($p.Name)"
            Type          = "$($p.Type)"
            DisplayName   = if ($p.DisplayName) { "$($p.DisplayName)" } else { "$($p.Name)" }
            Default       = "$($p.DefaultValue)"
            Values        = $values
            HiddenFromXml = $hiddenFromXml
        }
    }
    return $list
}

# Compute defaults ------------------------------------------------------------

$defWwiseExe = Find-WwiseExe
$defWproj    = Find-Wproj
$defUproject = Find-Uproject
$defUserId   = if ($env:IMMERSE_USER_ID) { $env:IMMERSE_USER_ID } else { 'kevin_tencenttest1_emb' }
$defXmlPath  = Find-PluginXml $defWwiseExe
$allProps    = Parse-PluginProperties $defXmlPath

# Properties we currently know how to test and their known log signatures.
# Other XML properties are still selectable but run in discovery mode (no
# assertion regex). When the dev team confirms a log pattern, encode it here.
$knownTestable = @{
    'EnableImmerse'        = $true
    'ConvolutionType'      = $true
    'HeadphoneEq'          = $true
    'Tuning'               = $true
    'FieldOfView'          = $true
    'BusContent'           = $true
    'HeadTrackingEnabled'  = $true
}
# These four require EHM ON + ConvolutionType = 1 (Personalized) to take effect.
$personalizedDeps = @('HeadphoneEq','Tuning','FieldOfView','BusContent')

# Properties to filter from the parameter selector. The XML doesn't carry an
# explicit visibility marker today; until the dev team adds one (see
# Parse-PluginProperties, which already honours <UserInterface Hidden="true"/>
# style attributes), keep a small static list of properties that aren't in the
# Immerse plug-in UI in Wwise (or that the harness handles elsewhere).
#   UserID                 - has its own field at the top of the form already
#   HeadTrackingEnabled    - not surfaced in the plug-in's authoring UI
#   HeadTrackingCameraId   - not surfaced in the plug-in's authoring UI
$hiddenProperties = @('UserID','HeadTrackingEnabled','HeadTrackingCameraId')

# Build form ------------------------------------------------------------------

[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Immerse Audio Renderer - Test Harness'
$form.Size = New-Object System.Drawing.Size(820, 720)
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
$lblSubtitle.Text = "Choose paths + parameters to test. Properties read from $(if ($defXmlPath) { Split-Path -Leaf $defXmlPath } else { '<no XML found>' })."
$lblSubtitle.Location = New-Object System.Drawing.Point(20, 42)
$lblSubtitle.AutoSize = $true
$lblSubtitle.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblSubtitle)

function Add-PathRow($form, $y, $label, $value, $filter, $filterText) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $label
    $lbl.Location = New-Object System.Drawing.Point(20, ($y + 4))
    $lbl.Size = New-Object System.Drawing.Size(180, 20)
    $form.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(205, $y)
    $tb.Size = New-Object System.Drawing.Size(510, 24)
    $tb.Text = $value
    $form.Controls.Add($tb)

    if ($filter) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = 'Browse...'
        $btn.Location = New-Object System.Drawing.Point(725, ($y - 1))
        $btn.Size = New-Object System.Drawing.Size(70, 26)
        $btn.Add_Click({
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = "${filterText}|${filter}"
            if ($ofd.ShowDialog() -eq 'OK') { $tb.Text = $ofd.FileName }
        }.GetNewClosure())
        $form.Controls.Add($btn)
    }
    return $tb
}

$txtUproject = Add-PathRow $form 80  'Unreal Engine project (.uproject):' $defUproject '*.uproject' 'UE project'
$txtWproj    = Add-PathRow $form 115 'Wwise project (.wproj):'             $defWproj    '*.wproj'    'Wwise project'
$txtWwise    = Add-PathRow $form 150 'Wwise Authoring exe:'                $defWwiseExe 'Wwise.exe'  'Wwise.exe'
$txtUser     = Add-PathRow $form 185 'Immerse User ID:'                    $defUserId   $null        $null

# Parameter selection panel ---------------------------------------------------

$grp = New-Object System.Windows.Forms.GroupBox
$grp.Location = New-Object System.Drawing.Point(20, 225)
$grp.Size = New-Object System.Drawing.Size(775, 305)
$form.Controls.Add($grp)

$lstParams = New-Object System.Windows.Forms.CheckedListBox
$lstParams.Location = New-Object System.Drawing.Point(15, 25)
$lstParams.Size = New-Object System.Drawing.Size(745, 270)
$lstParams.CheckOnClick = $true
$lstParams.Font = New-Object System.Drawing.Font('Consolas', 9)
$grp.Controls.Add($lstParams)

# Defaults to pre-check (matches the proven 9-scenario baseline).
$defaultChecked = @('EnableImmerse','ConvolutionType','HeadphoneEq','BusContent','FieldOfView')

# Visible properties = parsed list minus XML-hidden ones minus our static
# filter list (UserID + HeadTracking* not in plug-in UI today).
$visibleProps = @($allProps | Where-Object { -not $_.HiddenFromXml -and ($_.Name -notin $hiddenProperties) })
$hiddenCount  = $allProps.Count - $visibleProps.Count

$grp.Text = "Parameters to test ($($visibleProps.Count) discovered$(if ($hiddenCount) { ", $hiddenCount hidden" }))"

$paramIndex = @{}
$idx = 0
foreach ($p in $visibleProps) {
    $prefix = if ($knownTestable[$p.Name]) { '[testable] ' } else { '[discovery] ' }
    $depMark = if ($p.Name -in $personalizedDeps) { ' (needs EHM on + Personalized)' } else { '' }
    $valueSummary = if ($p.Values.Count -gt 0) {
        $first = ($p.Values | Select-Object -First 3 | ForEach-Object { "$($_.Display)=$($_.Value)" }) -join ', '
        if ($p.Values.Count -gt 3) { $first += ", ... ($($p.Values.Count) total)" }
        " [$first]"
    } else { " [type=$($p.Type)]" }
    $label = "$prefix$($p.DisplayName)  ($($p.Name))$valueSummary$depMark"
    [void]$lstParams.Items.Add($label, ($p.Name -in $defaultChecked))
    $paramIndex[$idx] = $p
    $idx++
}

# Cycles + close-Wwise row ----------------------------------------------------

$lblCycles = New-Object System.Windows.Forms.Label
$lblCycles.Text = 'Cycles:'
$lblCycles.Location = New-Object System.Drawing.Point(20, 545)
$lblCycles.AutoSize = $true
$form.Controls.Add($lblCycles)

$numCycles = New-Object System.Windows.Forms.NumericUpDown
$numCycles.Location = New-Object System.Drawing.Point(70, 543)
$numCycles.Size = New-Object System.Drawing.Size(60, 24)
$numCycles.Minimum = 1
$numCycles.Maximum = 100
$numCycles.Value = 1
$form.Controls.Add($numCycles)

$chkCloseWwise = New-Object System.Windows.Forms.CheckBox
$chkCloseWwise.Text = 'Close Wwise after test'
$chkCloseWwise.Location = New-Object System.Drawing.Point(150, 545)
$chkCloseWwise.AutoSize = $true
$chkCloseWwise.Checked = $true
$form.Controls.Add($chkCloseWwise)

# Status + buttons ------------------------------------------------------------

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(20, 585)
$lblStatus.Size = New-Object System.Drawing.Size(775, 40)
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblStatus)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(585, 635)
$btnCancel.Size = New-Object System.Drawing.Size(100, 32)
$btnCancel.Add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })
$form.Controls.Add($btnCancel)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = 'Run Tests'
$btnRun.Location = New-Object System.Drawing.Point(695, 635)
$btnRun.Size = New-Object System.Drawing.Size(100, 32)
$btnRun.BackColor = [System.Drawing.Color]::FromArgb(31, 111, 235)
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.FlatStyle = 'Flat'
$btnRun.Add_Click({ $form.DialogResult = 'OK'; $form.Close() })
$form.Controls.Add($btnRun)

function Update-Status {
    $missing = @()
    if (-not (Test-Path $txtUproject.Text)) { $missing += 'UE project' }
    if (-not (Test-Path $txtWproj.Text))    { $missing += 'Wwise project' }
    if (-not (Test-Path $txtWwise.Text))    { $missing += 'Wwise exe' }
    if (-not $txtUser.Text)                 { $missing += 'User ID' }
    $selectedCount = $lstParams.CheckedItems.Count
    if ($missing.Count -eq 0 -and $selectedCount -gt 0) {
        $lblStatus.Text = "Ready. $selectedCount parameter(s) selected, $($numCycles.Value) cycle(s)."
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(31, 136, 61)
        $btnRun.Enabled = $true
    } elseif ($missing.Count -eq 0) {
        $lblStatus.Text = 'Select at least one parameter to test.'
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(207, 34, 46)
        $btnRun.Enabled = $false
    } else {
        $lblStatus.Text = 'Missing or invalid: ' + ($missing -join ', ')
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(207, 34, 46)
        $btnRun.Enabled = $false
    }
}
foreach ($t in @($txtUproject, $txtWproj, $txtWwise, $txtUser)) { $t.Add_TextChanged({ Update-Status }) }
$lstParams.Add_ItemCheck({ $form.BeginInvoke([Action]{ Update-Status }) })
$numCycles.Add_ValueChanged({ Update-Status })
Update-Status

$result = $form.ShowDialog()
if ($result -ne 'OK') { Write-Host 'Cancelled.'; return }

# Build scenarios -------------------------------------------------------------

$selectedProps = @()
for ($i = 0; $i -lt $lstParams.Items.Count; $i++) {
    if ($lstParams.GetItemChecked($i)) { $selectedProps += $paramIndex[$i] }
}

$cycles = [int]$numCycles.Value
$scenarios = New-Object System.Collections.ArrayList

function Add-Scenario($map) { [void]$scenarios.Add($map) }

# Prereq for personalized-dependent properties.
$needsPersonalizedPrereq = ($selectedProps | Where-Object { $_.Name -in $personalizedDeps }).Count -gt 0

# 1. Test EnableImmerse (transitions, ConvType forced to 0 = Universal so
#    EHM ON -> inMode:2 is deterministic).
if ($selectedProps | Where-Object { $_.Name -eq 'EnableImmerse' }) {
    Add-Scenario @{ name = 'Setup for EHM: ConvolutionType = 0 (Universal)'; property = 'ConvolutionType'; value = 0; captureSeconds = 1 }
    Add-Scenario @{ name = 'Setup for EHM: force EHM off';                    property = 'EnableImmerse';   value = $false; captureSeconds = 1 }
    Add-Scenario @{ name = 'EHM: assert ON  (off -> on, inMode:2)';           property = 'EnableImmerse';   value = $true;  expectLog = 'Immerse_EnableImmerse\s+inMode:\s*2'; timeoutMs = 3000 }
    Add-Scenario @{ name = 'EHM: assert OFF (on -> off, inMode:0)';           property = 'EnableImmerse';   value = $false; expectLog = 'Immerse_EnableImmerse\s+inMode:\s*0'; timeoutMs = 3000 }
    Add-Scenario @{ name = 'EHM: assert ON  (off -> on, inMode:2)';           property = 'EnableImmerse';   value = $true;  expectLog = 'Immerse_EnableImmerse\s+inMode:\s*2'; timeoutMs = 3000 }
}

# 2. Test ConvolutionType through all enum values.
if ($selectedProps | Where-Object { $_.Name -eq 'ConvolutionType' }) {
    Add-Scenario @{ name = 'Setup ConvType: force EHM on';      property = 'EnableImmerse';   value = $true; captureSeconds = 1 }
    Add-Scenario @{ name = 'Setup ConvType: force to 0 (Universal)'; property = 'ConvolutionType'; value = 0; captureSeconds = 1 }
    Add-Scenario @{ name = 'ConvolutionType: assert Personalized (1) -> inMode:1'; property = 'ConvolutionType'; value = 1; expectLog = 'Immerse_EnableImmerse\s+inMode:\s*1'; timeoutMs = 3000 }
    Add-Scenario @{ name = 'ConvolutionType: assert Universal (0) -> inMode:2';    property = 'ConvolutionType'; value = 0; expectLog = 'Immerse_EnableImmerse\s+inMode:\s*2'; timeoutMs = 3000 }
}

# 3. Establish EHM on + Personalized as prereq for dependent properties.
if ($needsPersonalizedPrereq) {
    Add-Scenario @{ name = 'Prereq: EnableImmerse = true';            property = 'EnableImmerse';   value = $true; captureSeconds = 1 }
    Add-Scenario @{ name = 'Prereq: ConvolutionType = 1 (Personalized)'; property = 'ConvolutionType'; value = 1; captureSeconds = 1 }
}

# 4. For each dependent enum property, cycle through its values (discovery
#    until we know each one's log signature).
function Add-EnumCycle($prop) {
    if ($prop.Values.Count -eq 0) { return }
    # Force to the first enum value as setup.
    $first = $prop.Values[0]
    Add-Scenario @{ name = "Setup $($prop.Name): force to $($first.Display) ($($first.Value))"; property = $prop.Name; value = ([int]$first.Value); captureSeconds = 1 }
    foreach ($v in ($prop.Values | Select-Object -Skip 1)) {
        Add-Scenario @{ name = "$($prop.DisplayName): $($v.Display) ($($v.Value))"; property = $prop.Name; value = ([int]$v.Value); captureSeconds = 2 }
    }
}
foreach ($p in $selectedProps) {
    if ($p.Name -in @('HeadphoneEq','Tuning','FieldOfView','BusContent')) { Add-EnumCycle $p }
}

# 5. HeadTrackingEnabled (independent bool).
if ($selectedProps | Where-Object { $_.Name -eq 'HeadTrackingEnabled' }) {
    Add-Scenario @{ name = 'HeadTrackingEnabled: false (setup)'; property = 'HeadTrackingEnabled'; value = $false; captureSeconds = 1 }
    Add-Scenario @{ name = 'HeadTrackingEnabled: true (transition)';  property = 'HeadTrackingEnabled'; value = $true; captureSeconds = 2 }
}

# Skip UserID and HeadTrackingCameraId for v1.5 (no preconditions known yet
# for HTCameraId; UserID intentionally pending manual verification).

# Write TestScenarios.json ----------------------------------------------------

$plan = [ordered]@{
    schema      = 'v1'
    description = "GUI-generated test plan: $($selectedProps.Count) parameter(s), $cycles cycle(s). Generated $((Get-Date).ToString('o'))."
    cycles      = $cycles
    scenarios   = @($scenarios)
}
$jsonPath = Join-Path $ScriptDir 'TestScenarios.json'
$plan | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

# Set env vars + run launcher -------------------------------------------------

$env:IMMERSE_UPROJECT   = $txtUproject.Text
$env:IMMERSE_WPROJ      = $txtWproj.Text
$env:IMMERSE_WWISE_EXE  = $txtWwise.Text
$env:IMMERSE_USER_ID    = $txtUser.Text
$env:IMMERSE_CLOSE_WWISE = if ($chkCloseWwise.Checked) { '1' } else { '0' }

Write-Host ''
Write-Host '==== Launching test harness ====' -ForegroundColor Cyan
Write-Host "  UE project:    $($txtUproject.Text)"
Write-Host "  Wwise project: $($txtWproj.Text)"
Write-Host "  Wwise exe:     $($txtWwise.Text)"
Write-Host "  User ID:       $($txtUser.Text)"
Write-Host "  Close Wwise:   $($chkCloseWwise.Checked)"
Write-Host "  Cycles:        $cycles"
Write-Host "  Parameters:    $(($selectedProps | ForEach-Object { $_.Name }) -join ', ')"
Write-Host "  Scenarios:     $($scenarios.Count) per cycle ($($scenarios.Count * $cycles) total)"
Write-Host ''

$launcher = Join-Path $ScriptDir 'AutoRunAndPush.ps1'
if (-not (Test-Path $launcher)) {
    Write-Host "ERROR: missing $launcher" -ForegroundColor Red
    Read-Host 'Press Enter to close'; return
}

& $launcher

# Open the report ------------------------------------------------------------

$lastRunDir = $global:IMMERSE_LAST_RUN_DIR
if (-not $lastRunDir -or -not (Test-Path $lastRunDir)) {
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
    } else { Write-Host "Report not found at $reportPath" -ForegroundColor Yellow }
}

Write-Host ''
Read-Host 'Press Enter to close'

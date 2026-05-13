[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ResultsJson,
    [string]$SummaryTxt = '',
    [Parameter(Mandatory=$true)][string]$OutPath,
    [hashtable]$Metadata = @{}
)

# TIER1_HTML_REPORT_v1
# Renders scenario_results.json into a self-contained HTML page with embedded
# CSS so it can be double-clicked and opened in any browser without a server.

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ResultsJson)) { Write-Host "Missing $ResultsJson"; return }
$data = Get-Content -Raw $ResultsJson | ConvertFrom-Json

function Esc([object]$s) {
    if ($null -eq $s) { return '' }
    return ([string]$s).Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

$pass  = [int]$data.pass
$fail  = [int]$data.fail
$skip  = [int]$data.skip
$total = [int]$data.total
$overall = if ($fail -eq 0) { 'pass' } else { 'fail' }

$rows = New-Object System.Text.StringBuilder
foreach ($r in $data.results) {
    $statusCls = $r.status
    $statusText = switch ($r.status) {
        'pass'      { 'PASS' }
        'fail'      { 'FAIL' }
        'discovery' { 'DISC' }
        'skip'      { 'SKIP' }
        default     { ($r.status).ToUpper() }
    }
    [void]$rows.AppendLine("    <tr class=`"row-$statusCls`">")
    [void]$rows.AppendLine("      <td class=`"step`">#$(Esc $r.index)</td>")
    [void]$rows.AppendLine("      <td><span class=`"badge $statusCls`">$statusText</span></td>")
    [void]$rows.AppendLine("      <td class=`"name`">$(Esc $r.name)</td>")
    $detail = ''
    if ($r.property) { $detail += "<code>$(Esc $r.property)</code> = <code>$(Esc $r.value)</code>" }
    if ($r.lag_ms)   { $detail += "<span class=`"meta`"> lag=$(Esc $r.lag_ms)ms</span>" }
    if ($r.error)    { $detail += "<div class=`"err`">$(Esc $r.error)</div>" }
    if ($r.expect_log -and ($r.status -eq 'fail')) {
        $detail += "<div class=`"meta`">expected: <code>$(Esc $r.expect_log)</code></div>"
    }
    if ($r.matched_line) {
        $detail += "<details><summary>matched line</summary><pre>$(Esc $r.matched_line)</pre></details>"
    }
    if ($r.captured_lines -and $r.captured_lines.Count -gt 0) {
        $sb = New-Object System.Text.StringBuilder
        foreach ($l in $r.captured_lines) { [void]$sb.AppendLine((Esc $l)) }
        $detail += "<details><summary>captured $($r.captured_lines.Count) lines</summary><pre>$($sb.ToString())</pre></details>"
    }
    if ($r.note) { $detail += "<div class=`"meta`">$(Esc $r.note)</div>" }
    [void]$rows.AppendLine("      <td class=`"detail`">$detail</td>")
    [void]$rows.AppendLine('    </tr>')
}

$metaRows = New-Object System.Text.StringBuilder
foreach ($k in $Metadata.Keys) {
    [void]$metaRows.AppendLine("    <tr><th>$(Esc $k)</th><td>$(Esc $Metadata[$k])</td></tr>")
}

$summaryHtml = if ($SummaryTxt -and (Test-Path $SummaryTxt)) { "<pre class=`"summary`">$(Esc (Get-Content -Raw $SummaryTxt))</pre>" } else { '' }

$ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Immerse Test Report - $ts</title>
<style>
  :root { color-scheme: light; }
  * { box-sizing: border-box; }
  body { margin: 0; font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #f4f5f7; color: #1f2328; }
  header { background: linear-gradient(135deg, #1f6feb 0%, #0d47a1 100%); color: #fff; padding: 24px 32px; }
  header h1 { margin: 0; font-size: 22px; font-weight: 600; }
  header .ts { opacity: 0.85; font-size: 13px; margin-top: 4px; }
  .container { max-width: 1100px; margin: 0 auto; padding: 24px 32px; }
  .summary-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin-bottom: 24px; }
  .card { background: #fff; border-radius: 8px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); text-align: center; border-top: 4px solid #6e7681; }
  .card.pass { border-top-color: #1f883d; }
  .card.fail { border-top-color: #cf222e; }
  .card.disc { border-top-color: #1f6feb; }
  .card.skip { border-top-color: #6e7681; }
  .card.total { border-top-color: #8250df; }
  .card .num { font-size: 28px; font-weight: 600; margin: 0; }
  .card .label { font-size: 12px; color: #6e7681; margin-top: 4px; text-transform: uppercase; letter-spacing: 0.5px; }
  .verdict { background: #fff; border-radius: 8px; padding: 16px 20px; margin-bottom: 24px; display: flex; align-items: center; gap: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
  .verdict.pass { border-left: 4px solid #1f883d; }
  .verdict.fail { border-left: 4px solid #cf222e; }
  .verdict .icon { font-size: 24px; }
  .verdict.pass .icon::before { content: "OK"; background: #1f883d; color: white; padding: 2px 10px; border-radius: 4px; font-size: 14px; font-weight: 600; }
  .verdict.fail .icon::before { content: "X";  background: #cf222e; color: white; padding: 2px 10px; border-radius: 4px; font-size: 14px; font-weight: 600; }
  .verdict .text { font-size: 16px; }
  section { background: #fff; border-radius: 8px; padding: 16px 20px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
  section h2 { margin: 0 0 12px 0; font-size: 16px; font-weight: 600; color: #1f2328; }
  table { width: 100%; border-collapse: collapse; font-size: 14px; }
  thead th { text-align: left; padding: 8px 10px; background: #f6f8fa; border-bottom: 1px solid #d0d7de; font-weight: 600; color: #6e7681; text-transform: uppercase; font-size: 11px; letter-spacing: 0.5px; }
  tbody td { padding: 10px; border-bottom: 1px solid #eaeef2; vertical-align: top; }
  tbody tr:last-child td { border-bottom: none; }
  .badge { display: inline-block; padding: 2px 10px; border-radius: 12px; font-size: 11px; font-weight: 600; letter-spacing: 0.5px; }
  .badge.pass      { background: #dafbe1; color: #1f883d; }
  .badge.fail      { background: #ffebe9; color: #cf222e; }
  .badge.discovery { background: #ddf4ff; color: #0969da; }
  .badge.skip      { background: #f0f0f0; color: #6e7681; }
  .step { width: 50px; color: #6e7681; font-variant-numeric: tabular-nums; }
  .name { font-weight: 500; }
  .detail code { background: #f6f8fa; padding: 1px 6px; border-radius: 4px; font-size: 12px; color: #1f2328; }
  .detail .meta { color: #6e7681; font-size: 12px; margin-top: 4px; }
  .detail .err { color: #cf222e; font-size: 12px; margin-top: 6px; }
  details { margin-top: 6px; }
  details summary { cursor: pointer; color: #0969da; font-size: 12px; }
  details pre { background: #f6f8fa; padding: 10px; border-radius: 6px; overflow-x: auto; font-size: 11px; line-height: 1.4; margin: 6px 0 0 0; }
  .summary pre, pre.summary { white-space: pre-wrap; }
  .meta-table th { background: transparent; color: #6e7681; font-weight: 500; padding: 4px 12px 4px 0; text-transform: none; letter-spacing: normal; font-size: 13px; border: 0; text-align: right; width: 1%; white-space: nowrap; }
  .meta-table td { padding: 4px 0; border: 0; font-family: ui-monospace, "SF Mono", Consolas, monospace; font-size: 12px; }
  footer { text-align: center; padding: 16px; color: #6e7681; font-size: 12px; }
</style>
</head>
<body>
<header>
  <h1>Immerse Audio Renderer - Test Report</h1>
  <div class="ts">$ts</div>
</header>
<div class="container">
  <div class="verdict $overall">
    <div class="icon"></div>
    <div class="text">$(if ($fail -eq 0) { "All $total scenarios completed without failures." } else { "$fail of $total scenarios failed." })</div>
  </div>
  <div class="summary-cards">
    <div class="card total"><div class="num">$total</div><div class="label">Total</div></div>
    <div class="card pass"><div class="num">$pass</div><div class="label">Pass</div></div>
    <div class="card fail"><div class="num">$fail</div><div class="label">Fail</div></div>
    <div class="card disc"><div class="num">$(($data.results | Where-Object { $_.status -eq 'discovery' }).Count)</div><div class="label">Discovery</div></div>
    <div class="card skip"><div class="num">$skip</div><div class="label">Skip</div></div>
  </div>
  <section>
    <h2>Configuration</h2>
    <table class="meta-table">
$($metaRows.ToString())
    </table>
  </section>
  <section>
    <h2>Scenarios</h2>
    <table>
      <thead><tr><th>#</th><th>Status</th><th>Scenario</th><th>Detail</th></tr></thead>
      <tbody>
$($rows.ToString())
      </tbody>
    </table>
  </section>
$(if ($summaryHtml) { "<section><h2>Console Summary</h2>$summaryHtml</section>" })
</div>
<footer>Generated $ts</footer>
</body>
</html>
"@

$dir = Split-Path -Parent $OutPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
Set-Content -Path $OutPath -Value $html -Encoding UTF8
Write-Host "Report written: $OutPath"

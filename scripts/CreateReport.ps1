<#! 
.SYNOPSIS
  Render the structured build report as CLI text or HTML.
##>
param(
    [Parameter(Mandatory)][string]$ReportPath,
    [ValidateSet('Cli','Html')][string]$Format = 'Cli',
    [string]$OutputPath
)

$report = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Rows($items) { @($items | Where-Object { $null -ne $_ }) }
function HtmlCell([object]$value) { [System.Net.WebUtility]::HtmlEncode([string]$value) }
function HtmlValue([object]$value) {
    $text = [string]$value
    if ($text -match '^https?://') {
        return '<a href="' + (HtmlCell $text) + '" target="_blank" rel="noopener noreferrer">' + (HtmlCell $text) + '</a>'
    }
    return HtmlCell $value
}
function StatusClass([object]$item) {
    $status = [string]$item.Status
    if ($status -match '^(OK|WINNER|CACHE)$') { return 'ok' }
    if ($status -match '^(404|5\d\d|RequestError|PARSE_ERROR|DOWNLOAD_ERROR)') { return 'bad' }
    if ($status -match '^(EMPTY|API_MISSING|WARN|WARNING|FILTERED)') { return 'warn' }
    return ''
}
function StatusRank([object]$item) {
    $status = [string]$item.Status
    if ($status -match '^(404|5\d\d|RequestError)') { return 0 }
    if ($status -match '^(PARSE_ERROR|DOWNLOAD_ERROR)') { return 1 }
    if ($status -match '^(EMPTY|API_MISSING|WARN|WARNING|FILTERED)') { return 2 }
    return 3
}
function HtmlTable([string[]]$Headers, [object[]]$Items, [scriptblock]$Values, [switch]$CountDescending) {
    $head = ($Headers | ForEach-Object { '<th>' + (HtmlCell $_) + '</th>' }) -join ''
    $sort = @(@{Expression={ StatusRank $_ }; Ascending=$true })
    if ($CountDescending) { $sort += @{Expression={ [int]$_.Count }; Descending=$true} }
    $body = foreach ($item in (Rows $Items | Sort-Object $sort)) {
        $cells = & $Values $item | ForEach-Object { '<td>' + (HtmlValue $_) + '</td>' }
        '<tr class="' + (StatusClass $item) + '">' + ($cells -join '') + '</tr>'
    }
    return '<table><thead><tr>' + $head + '</tr></thead><tbody>' + ($body -join '') + '</tbody></table>'
}

if ($Format -eq 'Cli') {
    Write-Output '=== Structured build report ==='
    foreach ($section in @('Sources','Deduplication','ApiResolution','ZipFallback','OfficialExclusions','Outputs')) {
        $items = Rows $report.$section
        if ($items.Count -eq 0) { continue }
        Write-Output ""
        Write-Output ("[$section]")
        $items | ConvertTo-Csv -NoTypeInformation | Write-Output
    }
    if ($report.Summary) {
        Write-Output ""
        Write-Output '[Summary]'
        $report.Summary | ConvertTo-Json -Depth 10 | Write-Output
    }
    exit 0
}

$parts = @('<!doctype html><html><head><meta charset="utf-8"><style>body{font:14px sans-serif;color:#222}h1{font-size:22px}h2{font-size:17px;margin-top:24px}h3{font-size:15px;margin:12px 0 4px}details{margin:14px 0}summary{cursor:pointer;font-size:17px;font-weight:600;padding:6px;background:#f1f3f5;border:1px solid #ccc}table{border-collapse:collapse;margin:8px 0 18px;width:100%}th,td{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top}th{background:#f1f3f5}.ok{color:#176b35;background:#effaf2}.warn{color:#856404;background:#fff8d8}.bad{color:#a61b1b;background:#fff0f0}.muted{color:#666}.nested{margin-left:20px;width:calc(100% - 20px)}</style></head><body>')
$parts += '<h1>DalamudRepo-Build-Report</h1>'
$parts += '<p>Strukturierter Report, erzeugt von <code>CreateReport.ps1</code>.</p>'
$parts += '<details><summary>Stage 1: Quellen sammeln (' + (Rows $report.Sources).Count + ' Quellen)</summary>'
$parts += HtmlTable @('Status','Kandidaten','Quelle') $report.Sources { param($x) @($x.Status,$x.Count,$x.Url) } -CountDescending
$parts += '</details>'
$parts += '<details><summary>Stage 2: Kandidaten verarbeiten</summary>'
$parts += '<details><summary>Deduplication (' + (Rows $report.Deduplication).Count + ' Plugin-Gruppen)</summary>'
$parts += '<table><thead><tr><th>Plugin</th><th>Gewinner</th><th>Verworfene Kandidaten</th></tr></thead><tbody>'
foreach ($d in (Rows $report.Deduplication | Sort-Object Plugin)) {
    $winner = if ($d.Winner -is [string]) { [pscustomobject]@{ Version = ''; Url = $d.Winner } } else { $d.Winner }
    $winnerHtml = '<table class="nested"><thead><tr><th>Status</th><th>Version</th><th>Quelle</th></tr></thead><tbody><tr class="ok"><td>WINNER</td><td>' + (HtmlCell $winner.Version) + '</td><td>' + (HtmlValue $winner.Url) + '</td></tr></tbody></table>'
    $candidateRows = foreach ($candidate in @($d.Candidates | Where-Object { $_.Status -ne 'WINNER' })) {
        if ($candidate -is [string]) {
            '<tr><td>DROP</td><td></td><td>' + (HtmlValue $candidate) + '</td></tr>'
        } else {
            '<tr><td>DROP</td><td>' + (HtmlCell $candidate.Version) + '</td><td>' + (HtmlValue $candidate.Url) + '</td></tr>'
        }
    }
    $candidateHtml = '<table class="nested"><thead><tr><th>Status</th><th>Version</th><th>Quelle</th></tr></thead><tbody>' + ($candidateRows -join '') + '</tbody></table>'
    $parts += '<tr><td>' + (HtmlCell $d.Plugin) + '</td><td>' + $winnerHtml + '</td><td>' + $candidateHtml + '</td></tr>'
}
$parts += '</tbody></table>'
$parts += '</details>'
$parts += '<details><summary>Versions- und API-Auflösung (' + (Rows $report.ApiResolution).Count + ' Plugins)</summary>'
$parts += '<table><thead><tr><th>Plugin</th><th>Quell-Repository</th><th>Stable</th><th>Testing</th></tr></thead><tbody>'
foreach ($x in (Rows $report.ApiResolution | Sort-Object Plugin)) {
    $stable = (HtmlCell $x.StableApi) + ' <span class="muted">[' + (HtmlCell $x.StableSource) + $(if ($x.StableZipStatus) { ': ' + (HtmlCell $x.StableZipStatus) } else { '' }) + ']</span>'
    $testing = (HtmlCell $x.TestingApi) + ' <span class="muted">[' + (HtmlCell $x.TestingSource) + $(if ($x.TestingZipStatus) { ': ' + (HtmlCell $x.TestingZipStatus) } else { '' }) + ']</span>'
    $hasHardError = $x.StableZipStatus -match '^(404|5\d\d|RequestError|PARSE_ERROR|DOWNLOAD_ERROR)' -or $x.TestingZipStatus -match '^(404|5\d\d|RequestError|PARSE_ERROR|DOWNLOAD_ERROR)'
    $hasWarning = $x.StableSource -eq 'unresolved' -or $x.TestingSource -eq 'unresolved' -or $x.StableZipStatus -match '^(EMPTY|API_MISSING)' -or $x.TestingZipStatus -match '^(EMPTY|API_MISSING)'
    $rowClass = if ($hasHardError) { 'bad' } elseif ($hasWarning) { 'warn' } else { 'ok' }
    $parts += '<tr class="' + $rowClass + '"><td>' + (HtmlCell $x.Plugin) + '</td><td>' + (HtmlValue $x.SourceUrl) + '</td><td>' + $stable + '</td><td>' + $testing + '</td></tr>'
}
$parts += '</tbody></table>'
$parts += '</details>'
$parts += '<details><summary>Zip-Fallback (' + (Rows $report.ZipFallback).Count + ' Versuche)</summary>'
$parts += HtmlTable @('Plugin','Status','API','URL') $report.ZipFallback { param($x) @($x.Plugin,$x.Status,$x.Api,$x.Url) }
$parts += '</details>'
$parts += '<details><summary>Offizielle Plugin-Ausschlüsse (' + (Rows $report.OfficialExclusions).Count + ' Plugins)</summary>'
foreach ($source in (Rows $report.OfficialExclusions | Group-Object SourceFile | Sort-Object Name)) {
    $parts += '<h3>' + (HtmlCell $source.Name) + ' <span class="muted">(' + $source.Count + ' Plugins)</span></h3>'
    foreach ($repo in ($source.Group | Group-Object RepositoryUrl | Sort-Object Name)) {
        $parts += '<details><summary>' + (HtmlValue $repo.Name) + ' (' + $repo.Count + ')</summary>'
        $parts += '<table class="nested"><thead><tr><th>Plugin</th><th>InternalName</th><th>Version</th><th>API</th></tr></thead><tbody>'
        foreach ($plugin in ($repo.Group | Sort-Object InternalName)) {
            $pluginName = if ($plugin.Plugin) { $plugin.Plugin } else { $plugin.InternalName }
            $version = if ($plugin.PluginVersion) { $plugin.PluginVersion } else { '-' }
            $api = if ($plugin.ApiVersion) { $plugin.ApiVersion } else { '-' }
            $parts += '<tr class="bad"><td>' + (HtmlCell $pluginName) + '</td><td>' + (HtmlCell $plugin.InternalName) + '</td><td>' + (HtmlCell $version) + '</td><td>' + (HtmlCell $api) + '</td></tr>'
        }
        $parts += '</tbody></table></details>'
    }
}
$parts += '</details>'
$parts += '</details>'
$parts += '<details><summary>Stage 3: Ausgaben erzeugen (' + (Rows $report.Outputs).Count + ' Ausgaben)</summary>'
$parts += HtmlTable @('Ausgabe','Einträge','Status') $report.Outputs { param($x) @($x.Name,$x.Count,$x.Status) } -CountDescending
$parts += '</details>'
$summaryRows = @(
    [pscustomobject]@{ Metric = 'Gefiltert'; Value = $report.Summary.Filtered; Meaning = 'Plugins, die weder im Stable- noch im Testing-Kanal das Mindest-API-Level erreichen' }
    [pscustomobject]@{ Metric = 'Durch Zip-Fallback gerettet'; Value = $report.Summary.ZipFallbackRescued; Meaning = 'Plugins, deren API-Level aus einem Zip-Manifest gelesen werden konnte' }
    [pscustomobject]@{ Metric = 'Snapshot-Treffer'; Value = $report.Summary.SnapshotHits; Meaning = 'API-Level aus dem lokalen Snapshot-Cache ohne erneuten Zip-Download' }
    [pscustomobject]@{ Metric = 'Neue Zip-Downloads'; Value = $report.Summary.ZipDownloads; Meaning = 'Für die API-Auflösung heruntergeladene Zip-Dateien' }
    [pscustomobject]@{ Metric = 'Quellen'; Value = $report.Summary.Sources; Meaning = 'Ausgewertete Repository-Quell-URLs' }
    [pscustomobject]@{ Metric = 'Dedup-Gruppen'; Value = $report.Summary.DeduplicationGroups; Meaning = 'Plugin-Gruppen mit mehreren Kandidaten' }
    [pscustomobject]@{ Metric = 'Offizielle Ausschlüsse'; Value = $report.Summary.OfficialExclusions; Meaning = 'Aus externen Quellen entfernte offizielle Plugins' }
    [pscustomobject]@{ Metric = 'Ausgabedateien'; Value = $report.Summary.Outputs; Meaning = 'Erzeugte Pluginmaster-Ausgabedateien' }
)
$parts += '<details><summary>Stage 4: Zusammenfassung</summary>'
$parts += HtmlTable @('Kennzahl','Wert','Bedeutung') $summaryRows { param($x) @($x.Metric,$x.Value,$x.Meaning) } -CountDescending
$parts += '</details>'
$parts += '</body></html>'
$html = $parts -join "`n"
if ($OutputPath) { Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8 } else { Write-Output $html }

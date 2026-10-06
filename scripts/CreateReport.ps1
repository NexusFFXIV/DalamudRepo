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
function OfficialMasterRows($value) {
    $items = @($value | Where-Object { $null -ne $_ })
    # Older reports (and hand-built reports) may contain one object with
    # array-valued properties. Expand that shape into one row per plugin.
    if ($items.Count -eq 1 -and @($items[0].InternalName).Count -gt 1) {
        $root = $items[0]
        $count = @($root.InternalName).Count
        return @(for ($i = 0; $i -lt $count; $i++) {
            [pscustomobject]@{
                Plugin = @($root.Plugin)[$i]
                InternalName = @($root.InternalName)[$i]
                PluginVersion = @($root.PluginVersion)[$i]
                ApiVersion = @($root.ApiVersion)[$i]
                RepositoryUrl = @($root.RepositoryUrl)[$i]
            }
        })
    }
    return $items
}
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
function InlineStatusStyle([string]$class) {
    switch ($class) {
        'ok'   { return 'color:#176b35;background-color:#effaf2' }
        'warn' { return 'color:#856404;background-color:#fff8d8' }
        'bad'  { return 'color:#a61b1b;background-color:#fff0f0' }
        'beta' { return 'color:#7a4b00;background-color:#fff3d6' }
        default { return '' }
    }
}
function HtmlTable([string[]]$Headers, [object[]]$Items, [scriptblock]$Values, [switch]$CountDescending) {
    $head = ($Headers | ForEach-Object { '<th>' + (HtmlCell $_) + '</th>' }) -join ''
    $sort = @(@{Expression={ StatusRank $_ }; Ascending=$true })
    if ($CountDescending) { $sort += @{Expression={ [int]$_.Count }; Descending=$true} }
    $body = foreach ($item in (Rows $Items | Sort-Object $sort)) {
        $cells = & $Values $item | ForEach-Object { '<td>' + (HtmlValue $_) + '</td>' }
        $class = StatusClass $item
        $style = InlineStatusStyle $class
        $styleAttribute = if ($style) { ' style="' + $style + '"' } else { '' }
        '<tr class="' + $class + '"' + $styleAttribute + '>' + ($cells -join '') + '</tr>'
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

$parts = @('<!doctype html><html lang="en"><head><meta charset="utf-8"><style>body{font:14px sans-serif;color:#222}h1{font-size:22px}h2{font-size:17px;margin-top:24px}h3{font-size:15px;margin:12px 0 4px}details{margin:14px 0}details details{margin-left:24px;border-left:3px solid #d7dde3;padding-left:12px}summary{cursor:pointer;font-size:17px;font-weight:600;padding:6px;background:#f1f3f5;border:1px solid #ccc}details details>summary{font-size:15px;background:#fafbfc;border-color:#d7dde3}table{border-collapse:collapse;margin:8px 0 18px;width:100%}th,td{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top}th{background:#f1f3f5;cursor:pointer;user-select:none}th:hover{background:#e2e6ea}.ok{color:#176b35;background:#effaf2}.warn{color:#856404;background:#fff8d8}.bad{color:#a61b1b;background:#fff0f0}.muted{color:#666}.nested{margin-left:20px;width:calc(100% - 20px)}.toolbar{float:right;margin:4px 0}.toolbar button{border:1px solid #bbb;background:#fff;padding:4px 8px;cursor:pointer}.toolbar button.active{font-weight:700;background:#e2e6ea}.legend-en{display:inline}.legend-de{display:none}</style></head><body>')
$parts += '<style>.beta{color:#7a4b00;background:#fff3d6}</style>'
$generatedAt = ''
try { $generatedAt = ([DateTimeOffset]::Parse([string]$report.GeneratedAt)).ToLocalTime().ToString('dd.MM.yyyy HH:mm:ss') } catch { $generatedAt = (Get-Date).ToString('dd.MM.yyyy HH:mm:ss') }
$parts += '<div class="toolbar"><button id="lang-en" type="button">EN</button><button id="lang-de" type="button">DE</button></div><h1>DalamudRepo-Build-Report <span class="muted">(' + (HtmlCell $generatedAt) + ')</span></h1>'
$sourceRows = Rows $report.Sources
$sourceCandidateCount = [int](($sourceRows | ForEach-Object { [int]$_.Count } | Measure-Object -Sum).Sum)
$parts += '<details><summary><span class="legend-de">Stage 1: Quellen sammeln (' + $sourceRows.Count + ' Quellen, ' + $sourceCandidateCount + ' Kandidaten)</span><span class="legend-en">Stage 1: Collect sources (' + $sourceRows.Count + ' sources, ' + $sourceCandidateCount + ' candidates)</span></summary>'
$parts += HtmlTable @('Status','Kandidaten','Quelle') $sourceRows { param($x) @($x.Status,$x.Count,$x.Url) } -CountDescending
$parts += '</details>'
$parts += '<details><summary>Stage 2: Kandidaten verarbeiten</summary>'
$officialCatalogForFlow = if ($report.Summary.OfficialCatalog) { [int]$report.Summary.OfficialCatalog } else { 0 }
$parts += '<p class="muted"><span class="legend-de"><strong>Ablauf:</strong> 1. Offizielle Master-Blacklist laden (' + $officialCatalogForFlow + ' Plugins) → 2. Custom-Repositories sammeln → 3. Offizielle Treffer mit <code>OFFICIAL_MASTER</code> ausschließen → 4. verbleibende Kandidaten deduplizieren und prüfen.</span><span class="legend-en"><strong>Flow:</strong> 1. Load official Master blacklist (' + $officialCatalogForFlow + ' plugins) → 2. Collect custom repositories → 3. Exclude official matches with <code>OFFICIAL_MASTER</code> → 4. deduplicate and validate the remaining candidates.</span></p>'
$officialRows = Rows $report.OfficialExclusions
$officialMasterRows = OfficialMasterRows $report.OfficialMaster
$officialCatalog = if ($report.Summary.OfficialCatalog) { [int]$report.Summary.OfficialCatalog } else { 0 }
$officialPluginCount = @($officialRows | Group-Object { [string]$_.Plugin + "|" + [string]$_.InternalName }).Count
$officialDe = 'Offizielles Master-Repo (' + $officialCatalog + ' Plugins, durch Dedup entfernt (' + $officialPluginCount + ' Plugins))'
$officialEn = 'Official Master Repo (' + $officialCatalog + ' Plugins, Removed by dedup (' + $officialPluginCount + ' plugins))'
$parts += '<details><summary><span class="legend-de">' + (HtmlCell $officialDe) + '</span><span class="legend-en">' + (HtmlCell $officialEn) + '</span></summary>'
if ($officialMasterRows.Count -gt 0) {
    $masterSource = 'https://kamori.goats.dev/Plugin/PluginMaster'
    $parts += '<p class="muted"><span class="legend-de">Quelle: ' + (HtmlValue $masterSource) + '</span><span class="legend-en">From source: ' + (HtmlValue $masterSource) + '</span></p>'
    $parts += '<table><thead><tr><th>Plugin</th><th>InternalName</th><th>Version</th><th>API</th><th>Source</th></tr></thead><tbody>'
    foreach ($plugin in ($officialMasterRows | Sort-Object Plugin, InternalName, PluginVersion, RepositoryUrl)) {
        $parts += '<tr><td>' + (HtmlCell $plugin.Plugin) + '</td><td>' + (HtmlCell $plugin.InternalName) + '</td><td>' + (HtmlCell $plugin.PluginVersion) + '</td><td>' + (HtmlCell $plugin.ApiVersion) + '</td><td>' + (HtmlValue $plugin.RepositoryUrl) + '</td></tr>'
    }
    $parts += '</tbody></table>'
}
$parts += '</details>'
$parts += '<details><summary>Deduplication (' + (Rows $report.Deduplication).Count + ' Plugin-Gruppen)</summary>'
$parts += '<p class="muted"><strong><span class="legend-de">Legende:</span><span class="legend-en">Legend:</span></strong><span class="legend-de"> Der WINNER wird weiterhin zuerst nach höchster Version ausgewählt. Die Spalte <code>Bewertung</code> zeigt den stärksten erkannten Indikator in dieser Reihenfolge: <code>AUTHOR_MATCH</code> → <code>UPSTREAM_MATCH</code> → <code>HIGHEST_VERSION</code> → <code>FIRST_INPUT</code>. Drop-Gründe: <code>LOWER_VERSION</code>, <code>UPSTREAM_LOST</code>, <code>AUTHOR_LOST</code> oder <code>FIRST_INPUT_LOST</code>.</span><span class="legend-en"> The WINNER is still selected by highest version first. The Reason column shows the strongest detected indicator in this order: <code>AUTHOR_MATCH</code> → <code>UPSTREAM_MATCH</code> → <code>HIGHEST_VERSION</code> → <code>FIRST_INPUT</code>. Drop reasons: <code>LOWER_VERSION</code>, <code>UPSTREAM_LOST</code>, <code>AUTHOR_LOST</code> or <code>FIRST_INPUT_LOST</code>.</span></p>'
$parts += '<p class="muted"><span class="legend-de">' + $officialPluginCount + ' eindeutige Plugins wurden entfernt, weil sie im offiziellen Master-Repo gefunden wurden. Die zugehörigen entfernten Quellen sind unten je Plugin mit dem Drop-Grund <code>OFFICIAL_MASTER</code> aufgeführt.</span><span class="legend-en">' + $officialPluginCount + ' unique plugins were removed because they are present in the official Master repository. Their removed source candidates are listed below per plugin with drop reason <code>OFFICIAL_MASTER</code>.</span></p>'
$parts += '<table><thead><tr><th>Plugin</th><th>Gewinner</th><th>Verworfene Kandidaten</th></tr></thead><tbody>'
foreach ($d in (Rows $report.Deduplication | Sort-Object Plugin)) {
    $winner = if ($d.Winner -is [string]) { [pscustomobject]@{ Version = ''; Url = $d.Winner } } else { $d.Winner }
    $winnerHtml = '<table class="nested"><thead><tr><th>Status</th><th>Bewertung</th><th>Version</th><th>Quelle</th></tr></thead><tbody><tr class="ok" style="' + (InlineStatusStyle 'ok') + '"><td>WINNER</td><td>' + (HtmlCell $winner.Reason) + '</td><td>' + (HtmlCell $winner.Version) + '</td><td>' + (HtmlValue $winner.Url) + '</td></tr></tbody></table>'
    $candidateRows = foreach ($candidate in @($d.Candidates | Where-Object { $_.Status -ne 'WINNER' })) {
        if ($candidate -is [string]) {
            '<tr><td>DROP</td><td></td><td></td><td>' + (HtmlValue $candidate) + '</td></tr>'
        } else {
            '<tr><td>DROP</td><td>' + (HtmlCell $candidate.Reason) + '</td><td>' + (HtmlCell $candidate.Version) + '</td><td>' + (HtmlValue $candidate.Url) + '</td></tr>'
        }
    }
    $candidateHtml = '<table class="nested"><thead><tr><th>Status</th><th>Bewertung</th><th>Version</th><th>Quelle</th></tr></thead><tbody>' + ($candidateRows -join '') + '</tbody></table>'
    $parts += '<tr><td>' + (HtmlCell $d.Plugin) + '</td><td>' + $winnerHtml + '</td><td>' + $candidateHtml + '</td></tr>'
}
if ($officialRows.Count -gt 0) {
    # Official exclusions are collected once per external source entry. Group
    # them by plugin so one plugin row can show all of its removed candidates,
    # just like the normal deduplication table does.
    $officialGroups = $officialRows | Group-Object { [string]$_.Plugin + "|" + [string]$_.InternalName } | Sort-Object Name
    foreach ($group in $officialGroups) {
        $officialEntries = @($group.Group | Sort-Object PluginVersion, RepositoryUrl)
        $official = $officialEntries[0]
        $officialWinner = '<table class="nested"><thead><tr><th>Status</th><th>Reason</th><th>Version</th><th>Source</th></tr></thead><tbody><tr class="warn" style="' + (InlineStatusStyle 'warn') + '"><td>DROPPED</td><td>OFFICIAL_MASTER</td><td>' + (HtmlCell $official.PluginVersion) + '</td><td>' + (HtmlValue $official.SourceFile) + '</td></tr></tbody></table>'
        $officialCandidates = foreach ($entry in $officialEntries) {
            '<tr><td>DROP</td><td>OFFICIAL_MASTER</td><td>' + (HtmlCell $entry.PluginVersion) + '</td><td>' + (HtmlValue $entry.RepositoryUrl) + '</td></tr>'
        }
        $officialCandidate = '<table class="nested"><thead><tr><th>Status</th><th>Reason</th><th>Version</th><th>Source</th></tr></thead><tbody>' + ($officialCandidates -join '') + '</tbody></table>'
        $parts += '<tr class="warn" style="' + (InlineStatusStyle 'warn') + '"><td>' + (HtmlCell $official.Plugin) + '</td><td>' + $officialWinner + '</td><td>' + $officialCandidate + '</td></tr>'
    }
}
$parts += '</tbody></table>'
$parts += '</details>'
$latestApi = if ($report.Summary.MinDalamudApiLevel) { [int]$report.Summary.MinDalamudApiLevel } else { 15 }
$parts += '<details><summary><span class="legend-de">Versions- und API-Auflösung (' + (Rows $report.ApiResolution).Count + ' Plugins)</span><span class="legend-en">Version and API resolution (' + (Rows $report.ApiResolution).Count + ' plugins)</span></summary>'
$parts += '<p class="muted"><strong><span class="legend-de">Legende:</span><span class="legend-en">Legend:</span></strong><span class="legend-de"> <span class="ok">Grün</span> = Stable verwendet die aktuelle API ' + $latestApi + '. <span class="beta">Gelb</span> = Testing verwendet die aktuelle API, Stable ist aber noch nicht aktuell (Beta). Fehlendes Testing ist optional und bei aktueller Stable-Version kein Fehler. <span class="bad">Rot</span> = Fehler beim Stable-Abruf oder Parsing.</span><span class="legend-en"> <span class="ok">Green</span> = Stable uses the current API ' + $latestApi + '. <span class="beta">Amber</span> = Testing uses the current API, but Stable is not current yet (beta). Missing Testing is optional and is not an error when Stable is current. <span class="bad">Red</span> = Stable download or parsing error.</span></p>'
$parts += '<p class="muted"><span class="legend-de"><strong>Aufgelöst durch:</strong> <code>repo</code> = direkt aus dem Repository-Eintrag, <code>zip</code> = aus dem eingebetteten Plugin-Manifest des ZIPs, <code>zip (cached)</code> = derselbe validierte ZIP-Befund aus dem Snapshot-Cache ohne neuen Download, <code>unresolved</code> = konnte nicht ermittelt werden. Stable wird nie durch Fallback-Daten überschrieben. Testing ist optional und wird nur aufgelöst, wenn der aktuelle Repo-Eintrag einen Testing-Kanal enthält.</span><span class="legend-en"><strong>Resolved by:</strong> <code>repo</code> = read directly from the repository entry, <code>zip</code> = read from the embedded plugin manifest in the ZIP, <code>zip (cached)</code> = the same validated ZIP result served from the snapshot cache without a new download, <code>unresolved</code> = could not be determined. Stable is never overridden by fallback data. Testing is optional and is resolved only when the current repository entry still contains a testing channel.</span></p>'
$parts += '<table><thead><tr><th>Plugin</th><th><span class="legend-de">Stable Version</span><span class="legend-en">Stable version</span></th><th><span class="legend-de">Stable API-Version</span><span class="legend-en">Stable API version</span></th><th><span class="legend-de">Stable aufgelöst durch</span><span class="legend-en">Stable resolved by</span></th><th><span class="legend-de">Testing Version</span><span class="legend-en">Testing version</span></th><th><span class="legend-de">Testing API-Version</span><span class="legend-en">Testing API version</span></th><th><span class="legend-de">Testing aufgelöst durch</span><span class="legend-en">Testing resolved by</span></th><th><span class="legend-de">Quell-Repository</span><span class="legend-en">Source repository</span></th></tr></thead><tbody>'
foreach ($x in (Rows $report.ApiResolution | Sort-Object Plugin)) {
    $stableStatus = if ($x.StableZipStatus) { [string]$x.StableSource + ': ' + [string]$x.StableZipStatus } else { [string]$x.StableSource }
    $testingStatus = if ($x.TestingZipStatus) { [string]$x.TestingSource + ': ' + [string]$x.TestingZipStatus } else { [string]$x.TestingSource }
    # Stable is mandatory, so an unresolved stable value is actionable and
    # remains visible. Testing is optional; an absent testing channel is the
    # normal state and should therefore render as an empty cell instead of an
    # error-looking status.
    $stableResolution = if ($stableStatus -eq 'unresolved') { 'unresolved' } elseif ($stableStatus.Split(':')[0] -eq 'repo.json') { 'repo' } else { $stableStatus.Split(':')[0] }
    $testingResolution = if ($testingStatus -eq 'unresolved') { '' } elseif ($testingStatus.Split(':')[0] -eq 'repo.json') { 'repo' } else { $testingStatus.Split(':')[0] }
    $stable = (HtmlCell $x.StableApi)
    $testing = (HtmlCell $x.TestingApi)
    $stableApi = $null; $testingApi = $null
    try { if ($null -ne $x.StableApi) { $stableApi = [int]$x.StableApi } } catch {}
    try { if ($null -ne $x.TestingApi) { $testingApi = [int]$x.TestingApi } } catch {}
    $stableCurrent = $null -ne $stableApi -and $stableApi -ge $latestApi
    $testingCurrent = $null -ne $testingApi -and $testingApi -ge $latestApi
    $stableError = $x.StableZipStatus -match '^(404|5\d\d|RequestError|PARSE_ERROR|DOWNLOAD_ERROR)'
    $stableWarning = $x.StableSource -eq 'unresolved' -or $x.StableZipStatus -match '^(EMPTY|API_MISSING)'
    $rowClass = if ($stableError) { 'bad' } elseif ($stableCurrent) { 'ok' } elseif ($testingCurrent) { 'beta' } elseif ($stableWarning) { 'warn' } else { 'warn' }
    $parts += '<tr class="' + $rowClass + '"><td>' + (HtmlCell $x.Plugin) + '</td><td>' + (HtmlCell $x.StableVersion) + '</td><td>' + $stable + '</td><td>' + (HtmlCell $stableResolution) + '</td><td>' + (HtmlCell $x.TestingVersion) + '</td><td>' + $testing + '</td><td>' + (HtmlCell $testingResolution) + '</td><td>' + (HtmlValue $x.SourceUrl) + '</td></tr>'
}
$parts += '</tbody></table>'
$parts += '</details>'
$zipAttemptCount = (Rows $report.ZipFallback).Count
$zipFreshCount = if ($report.Summary.ZipDownloads) { [int]$report.Summary.ZipDownloads } else { @($report.ZipFallback | Where-Object { $_.Resolution -ne 'CACHE' }).Count }
$zipCachedCount = if ($report.Summary.SnapshotHits) { [int]$report.Summary.SnapshotHits } else { @($report.ZipFallback | Where-Object { $_.Resolution -eq 'CACHE' }).Count }
$parts += '<details><summary><span class="legend-de">Versions- und API-Auflösung – Zip-Fallbacks (' + $zipAttemptCount + ' Versuche: ' + $zipFreshCount + ' frisch, ' + $zipCachedCount + ' aus Cache)</span><span class="legend-en">Version and API resolution – Zip fallbacks (' + $zipAttemptCount + ' attempts: ' + $zipFreshCount + ' fresh, ' + $zipCachedCount + ' cached)</span></summary>'
$parts += '<p class="muted"><span class="legend-de">Die Zählung im Header umfasst alle Fallback-Versuche; die Tabelle zeigt daraus nur die bereits durch Stage 2 ausgewählten Gewinner. <code>FRESH</code> bedeutet, dass das ZIP in diesem Lauf neu geladen und geprüft wurde. <code>CACHE</code> bedeutet, dass der validierte ZIP-Befund aus dem Snapshot übernommen wurde; dafür wurde kein ZIP neu geladen. <code>Fehlende Daten</code> nennt die konkrete Kombination, z. B. <code>TestingAPI</code> oder <code>StableVersion, StableAPI</code>. Die vier Ergebnis-Spalten werden direkt aus dem ZIP-Manifest befüllt.</span><span class="legend-en">The header count includes all fallback attempts; the table shows only the winners already selected by Stage 2. <code>FRESH</code> means the ZIP was downloaded and checked during this run. <code>CACHE</code> means a validated ZIP result was reused from the snapshot; no ZIP was downloaded for that row. <code>Missing data</code> names the exact combination, for example <code>TestingAPI</code> or <code>StableVersion, StableAPI</code>. The four result columns are populated directly from the ZIP manifest.</span></p>'
$dedupMap = @{}
foreach ($d in (Rows $report.Deduplication)) { $dedupMap[[string]$d.Plugin] = $d }
$zipRowsAll = foreach ($x in (Rows $report.ZipFallback)) {
    $d = if ($dedupMap.ContainsKey([string]$x.Plugin)) { $dedupMap[[string]$x.Plugin] } else { $null }
    $winnerSource = if ($d -and $d.Winner -and $d.Winner.Url) { [string]$d.Winner.Url } else { '' }
    $source = if ($x.SourceUrl) { [string]$x.SourceUrl } else { '' }
    $selected = (-not $winnerSource) -or ($source -and $source -eq $winnerSource)
    $missingParts = @([string]$x.Missing -split '\s*\+\s*' | Where-Object { $_ }) | ForEach-Object {
        $field = if ($_ -eq 'VERSION') { 'Version' } elseif ($_ -eq 'API') { 'API' } else { $_ }
        if ($x.Channel -eq 'Testing') { 'Testing' + $field } else { 'Stable' + $field }
    }
    $apiValue = if ([string]$x.Api -eq '-') { '' } else { $x.Api }
    $zipVersion = if ([string]$x.Status -match '^(404|5\d\d|RequestError|DOWNLOAD_ERROR|PARSE_ERROR)') { '' } else { $x.Version }
    [pscustomobject]@{
        Selected = $selected
        Resolution = if ($x.Resolution) { $x.Resolution } elseif ($x.Status -eq 'CACHE') { 'CACHE' } else { 'FRESH' }
        Status = $x.Status
        Plugin = $x.Plugin
        MissingData = ($missingParts -join ', ')
        StableVersion = if ($x.Channel -eq 'Stable') { $zipVersion } else { '' }
        StableApi = if ($x.Channel -eq 'Stable') { $apiValue } else { '' }
        TestingVersion = if ($x.Channel -eq 'Testing') { $zipVersion } else { '' }
        TestingApi = if ($x.Channel -eq 'Testing') { $apiValue } else { '' }
        Url = $x.Url
    }
}
$zipRows = @($zipRowsAll | Where-Object Selected)
$parts += HtmlTable @('Run','Status','Plugin','Fehlende Daten','Stable Version','Stable API','Testing Version','Testing API','Zip-URL') $zipRows { param($x) @($x.Resolution,$x.Status,$x.Plugin,$x.MissingData,$x.StableVersion,$x.StableApi,$x.TestingVersion,$x.TestingApi,$x.Url) }
$parts += '</details>'
$parts += '</details>'
$parts += '<details><summary>Stage 3: Ausgaben erzeugen (' + (Rows $report.Outputs).Count + ' Ausgaben)</summary>'
$parts += HtmlTable @('Status','Ausgabe','Einträge') $report.Outputs { param($x) @($x.Status,$x.Name,$x.Count) } -CountDescending
$parts += '</details>'
$summaryRows = @(
    [pscustomobject]@{ MetricDe = 'Gefiltert'; MetricEn = 'Filtered'; Value = $report.Summary.Filtered; MeaningDe = 'Plugins, die weder im Stable- noch im Testing-Kanal das Mindest-API-Level erreichen'; MeaningEn = 'Plugins that meet neither the Stable nor Testing minimum API level' }
    [pscustomobject]@{ MetricDe = 'Durch Zip-Fallback gerettet'; MetricEn = 'Rescued by zip fallback'; Value = $report.Summary.ZipFallbackRescued; MeaningDe = 'Plugins, deren API-Level aus einem Zip-Manifest gelesen werden konnte'; MeaningEn = 'Plugins whose API level was read from a ZIP manifest' }
    [pscustomobject]@{ MetricDe = 'Snapshot-Treffer'; MetricEn = 'Snapshot hits'; Value = $report.Summary.SnapshotHits; MeaningDe = 'API-Level aus dem lokalen Snapshot-Cache ohne erneuten Zip-Download'; MeaningEn = 'API levels served from the local snapshot cache without downloading a new ZIP' }
    [pscustomobject]@{ MetricDe = 'Neue Zip-Downloads'; MetricEn = 'Fresh ZIP downloads'; Value = $report.Summary.ZipDownloads; MeaningDe = 'Für die API-Auflösung heruntergeladene Zip-Dateien'; MeaningEn = 'ZIP files downloaded for API resolution' }
    [pscustomobject]@{ MetricDe = 'Quellen'; MetricEn = 'Sources'; Value = $report.Summary.Sources; MeaningDe = 'Ausgewertete Repository-Quell-URLs'; MeaningEn = 'Repository source URLs evaluated' }
    [pscustomobject]@{ MetricDe = 'Dedup-Gruppen'; MetricEn = 'Dedup groups'; Value = $report.Summary.DeduplicationGroups; MeaningDe = 'Plugin-Gruppen mit mehreren Kandidaten'; MeaningEn = 'Plugin groups with multiple candidates' }
    [pscustomobject]@{ MetricDe = 'Offizielle Ausschlüsse'; MetricEn = 'Official exclusions'; Value = $report.Summary.OfficialExclusions; MeaningDe = 'Aus externen Quellen entfernte offizielle Plugins'; MeaningEn = 'Official plugins removed from external sources' }
    [pscustomobject]@{ MetricDe = 'Offizieller Plugin-Katalog'; MetricEn = 'Official plugin catalog'; Value = $report.Summary.OfficialCatalog; MeaningDe = 'Plugins, die aktuell aus der offiziellen Dalamud-Masterquelle geladen wurden'; MeaningEn = 'Plugins currently loaded from the official Dalamud Master source' }
    [pscustomobject]@{ MetricDe = 'Ausgabedateien'; MetricEn = 'Outputs'; Value = $report.Summary.Outputs; MeaningDe = 'Erzeugte Pluginmaster-Ausgabedateien'; MeaningEn = 'Generated pluginmaster output files' }
)
$parts += '<script>(function(){function syncLegend(){var en=document.documentElement.lang==="en";document.querySelectorAll(".legend-de").forEach(function(x){x.style.display=en?"none":"inline";});document.querySelectorAll(".legend-en").forEach(function(x){x.style.display=en?"inline":"none";});}new MutationObserver(syncLegend).observe(document.documentElement,{attributes:true,attributeFilter:["lang"]});syncLegend();})();</script>'
$parts += '<details><summary>Stage 4: Zusammenfassung</summary>'
$parts += '<table><thead><tr><th><span class="legend-de">Kennzahl</span><span class="legend-en">Metric</span></th><th><span class="legend-de">Wert</span><span class="legend-en">Value</span></th><th><span class="legend-de">Bedeutung</span><span class="legend-en">Meaning</span></th></tr></thead><tbody>'
foreach ($x in ($summaryRows | Sort-Object @{Expression={ [int]$_.Value }; Descending=$true})) {
    $parts += '<tr><td><span class="legend-de">' + (HtmlCell $x.MetricDe) + '</span><span class="legend-en">' + (HtmlCell $x.MetricEn) + '</span></td><td>' + (HtmlValue $x.Value) + '</td><td><span class="legend-de">' + (HtmlCell $x.MeaningDe) + '</span><span class="legend-en">' + (HtmlCell $x.MeaningEn) + '</span></td></tr>'
}
$parts += '</tbody></table>'
$parts += '</details>'
$parts += '<script>(function(){var pairs=[["Stage 1: Quellen sammeln","Stage 1: Collect sources"],["Stage 2: Kandidaten verarbeiten","Stage 2: Process candidates"],["Stage 3: Ausgaben erzeugen","Stage 3: Build outputs"],["Stage 4: Zusammenfassung","Stage 4: Summary"],["Versions- und API-Auflösung","Version and API resolution"],["Offizielle Plugin-Ausschlüsse","Official plugin exclusions"],["Verworfene Kandidaten","Dropped candidates"],["Plugin-Gruppen","plugin groups"],["Quellen","sources"],["Kandidaten","candidates"],["Versuche","attempts"],["Plugins","plugins"],["Ausgaben","outputs"],["Einträge","entries"],["Kennzahl","Metric"],["Bedeutung","Meaning"],["Gewinner","Winner"],["Bewertung","Reason"],["Quelle","Source"],["Repository","Repository"],["Ausgabe","Output"],["Gefiltert","Filtered"],["Durch Zip-Fallback gerettet","Rescued by zip fallback"],["Snapshot-Treffer","Snapshot hits"],["Neue Zip-Downloads","Fresh zip downloads"],["Dedup-Gruppen","Dedup groups"],["Offizielle Ausschlüsse","Official exclusions"],["Ausgabedateien","Output files"],["Der WINNER wird weiterhin zuerst nach höchster Version ausgewählt.","The WINNER is still selected by highest version first."],["Die Spalte","The column"],["zeigt den stärksten erkannten Indikator in dieser Reihenfolge:","shows the strongest detected indicator in this order:"],["Drop-Gründe:","Drop reasons:"],["Klicken zum Sortieren","Click to sort"]];function translate(s,lang){var out=s;for(var i=0;i<pairs.length;i++){var a=lang==="en"?pairs[i][0]:pairs[i][1];var b=lang==="en"?pairs[i][1]:pairs[i][0];out=out.split(a).join(b);}return out;}function setLanguage(lang){document.documentElement.lang=lang;document.querySelectorAll("body *:not(script):not(style)").forEach(function(el){if(el.children.length===0&&el.dataset.originalText===undefined){el.dataset.originalText=el.textContent;}});document.querySelectorAll("[data-original-text]").forEach(function(el){el.textContent=translate(el.dataset.originalText,lang);});document.querySelectorAll("th").forEach(function(h){h.title=lang==="en"?"Click to sort":"Klicken zum Sortieren";});document.getElementById("lang-en").classList.toggle("active",lang==="en");document.getElementById("lang-de").classList.toggle("active",lang==="de");}function sortTable(table,index,ascending){var body=table.tBodies[0];if(!body)return;var rows=Array.from(body.rows).map(function(row,pos){return{row:row,pos:pos,value:row.cells[index]?row.cells[index].textContent.trim():""};});var numeric=rows.every(function(x){return x.value===""||!isNaN(Number(x.value.replace(",",".")));});rows.sort(function(a,b){var av=a.value,bv=b.value,cmp;if(numeric){cmp=Number(av.replace(",","."))-Number(bv.replace(",","."));}else{cmp=av.localeCompare(bv,undefined,{numeric:true,sensitivity:"base"});}return (cmp||a.pos-b.pos)*(ascending?1:-1);});rows.forEach(function(x){body.appendChild(x.row);});}document.querySelectorAll("table").forEach(function(table){var headers=table.querySelectorAll("thead th");headers.forEach(function(header,index){header.dataset.sortAscending="true";header.addEventListener("click",function(){var ascending=header.dataset.sortAscending!=="false";headers.forEach(function(h){delete h.dataset.sortAscending;});header.dataset.sortAscending=ascending?"false":"true";sortTable(table,index,ascending);});});});document.getElementById("lang-en").addEventListener("click",function(){setLanguage("en");});document.getElementById("lang-de").addEventListener("click",function(){setLanguage("de");});setLanguage("en");})();</script></body></html>'
$html = $parts -join "`n"
if ($OutputPath) { Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8 } else { Write-Output $html }

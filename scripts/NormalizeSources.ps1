<#
.SYNOPSIS
  Detect and optionally remove duplicate repository URLs from source YAML files.

.DESCRIPTION
  Repository URLs are compared using the same canonicalization as the build:
  GitHub's /raw/ form and raw.githubusercontent.com are treated as identical.
  Deduplication is intentionally scoped to each source file. The same URL in
  two different source files may feed different output repositories and is
  therefore retained.
#>
param(
    [string]$SourcesDir = "sources",
    [string]$ArchivePath = "",
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

function Get-CanonicalSourceUrl {
    param([string]$Url)
    if (-not $Url) { return '' }
    $text = $Url.Trim()
    if ($text -match '^https?://github\.com/([^/]+)/([^/]+)/raw/([^/]+)(/.*)?$') {
        $suffix = if ($Matches[4]) { $Matches[4] } else { '' }
        return ('https://raw.githubusercontent.com/{0}/{1}/{2}{3}' -f $Matches[1], $Matches[2], $Matches[3], $suffix).TrimEnd('/')
    }
    try {
        $uri = [uri]$text
        $builder = [System.UriBuilder]$uri
        $builder.Host = $uri.Host.ToLowerInvariant()
        $builder.Path = $uri.AbsolutePath.TrimEnd('/')
        return $builder.Uri.AbsoluteUri.TrimEnd('/')
    } catch {
        return $text.TrimEnd('/')
    }
}

$total = 0
$archiveRecords = @()
if (-not $ArchivePath) { $ArchivePath = Join-Path $SourcesDir 'duplicate-sources.yml' }
foreach ($file in Get-ChildItem -LiteralPath $SourcesDir -Filter '*.yml' -File | Where-Object Name -notin @('offline-repos.yml','duplicate-sources.yml')) {
    $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8)
    $seen = @{}
    $remove = [System.Collections.Generic.HashSet[int]]::new()
    $inExternalRepos = $false
    $duplicates = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if ($line -match '^externalRepos:\s*$') { $inExternalRepos = $true; continue }
        if ($inExternalRepos -and $line -match '^[A-Za-z][A-Za-z0-9_-]*:\s*') { $inExternalRepos = $false; continue }
        if (-not $inExternalRepos) { continue }
        if ($line -notmatch '^\s*-\s+(https?://\S+?)(?:\s+#.*)?$') { continue }
        $url = $Matches[1]
        $canonical = Get-CanonicalSourceUrl $url
        if ($seen.ContainsKey($canonical)) {
            [void]$remove.Add($i)
            $duplicates += [pscustomobject]@{ Removed = $url; Kept = $seen[$canonical] }
            $archiveRecords += [pscustomobject]@{ SourceFile = $file.Name; Url = $url; Canonical = $canonical; Kept = $seen[$canonical] }
        } else {
            $seen[$canonical] = $url
        }
    }

    if ($duplicates.Count -gt 0) {
        $total += $duplicates.Count
        Write-Output ("{0}: {1} duplicate source URL(s)" -f $file.Name, $duplicates.Count)
        foreach ($d in $duplicates) { Write-Output ("  remove: {0}`n  keep:   {1}" -f $d.Removed, $d.Kept) }
        if ($Apply) {
            $keptLines = for ($i = 0; $i -lt $lines.Count; $i++) { if (-not $remove.Contains($i)) { $lines[$i] } }
            Set-Content -LiteralPath $file.FullName -Value $keptLines -Encoding UTF8
        }
    }
}

if ($total -eq 0) { Write-Output 'No duplicate source URLs found.' }
elseif (-not $Apply) { Write-Output ("Dry run: {0} duplicate(s) found. Use -Apply to remove them." -f $total) }
else { Write-Output ("Removed {0} duplicate source URL(s)." -f $total) }

if ($Apply -and $archiveRecords.Count -gt 0) {
    $archiveLines = @()
    if (Test-Path $ArchivePath) { $archiveLines = @(Get-Content -LiteralPath $ArchivePath -Encoding UTF8) }
    if ($archiveLines.Count -eq 0) {
        $archiveLines = @(
            '# Duplicate source URL archive — maintained by NormalizeSources.ps1.',
            '# These entries are not build inputs; they are retained for traceability.',
            'duplicateSources:'
        )
    }
    foreach ($record in $archiveRecords) {
        $marker = "  - sourceFile: $($record.SourceFile)`n    url: $($record.Url)`n    canonical: $($record.Canonical)`n    kept: $($record.Kept)"
        if (-not (($archiveLines -join "`n") -like "*$($record.Url)*")) { $archiveLines += $marker -split "`n" }
    }
    Set-Content -LiteralPath $ArchivePath -Value $archiveLines -Encoding UTF8
    Write-Output ("Archived {0} removed URL(s) in {1}." -f $archiveRecords.Count, $ArchivePath)
}

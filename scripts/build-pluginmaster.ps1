<#
.SYNOPSIS
  Rebuild per-source and merged pluginmaster.json files.

.DESCRIPTION
  Thin orchestrator. The heavy lifting lives in:
    scripts/lib/collect-plugins.ps1  — Part A: source collectors
    scripts/lib/build-outputs.ps1    — Part B: dedup, write, summary

  Source files in `sources/*.yml` are auto-discovered. Each declares its own
  `type:` (nexus / external-plugins / external-repos) and `out:` (filename of
  the per-source output). Optional `includeInUnion: false` keeps the source's
  entries out of the merged `all.json`.

  `config.yml` (repo root) controls minDalamudApiLevel /
  minTestingDalamudApiLevel + per-source enable toggles (with a `default:`
  flag for sources not explicitly listed). Filter is OR: an entry is kept
  when either the stable or the testing channel meets its threshold.
#>

param(
    [string]$ConfigYaml = "config.yml",
    [string]$SourcesDir = "sources",

    # InternalName(s) whose own release pipeline just published — republished in
    # full, fresh DownloadCount included, bypassing the republish gate. Matched
    # across every pool, not just the nexus one: that is what one would expect
    # from the flag, and dispatch runs are rare.
    #
    # Barely load-bearing in practice: a genuine release moves AssemblyVersion,
    # DownloadLink* and LastUpdate, so the entry is never frozen anyway. It
    # matters for a re-dispatch at an unchanged version — edited release notes,
    # a re-run of the release workflow, a re-uploaded asset.
    [string[]]$ForcePlugin = @(),

    # Adopt every fresh DownloadCount this run, gate off. Bulk escape hatch;
    # produces a large diff by design.
    [switch]$ForceAll
)

$ForcePlugin = @($ForcePlugin | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Install-Module -Name powershell-yaml -Force -Scope CurrentUser -AllowClobber -SkipPublisherCheck | Out-Null
}
Import-Module powershell-yaml

. "$PSScriptRoot\lib\collect-plugins.ps1"
. "$PSScriptRoot\lib\build-outputs.ps1"

# Durable cache for zip-fallback api-level lookups. Without it, each run
# re-downloads the same upstream zips, which inflates the upstream
# download_count and produces a "refresh" PR every cycle even when nothing
# real changed. See Get-ZipManifestApiLevel for the lookup logic.
Initialize-Snapshot

# ── Build config ─────────────────────────────────────────────────────────────
$buildConfig = $null
if (Test-Path $ConfigYaml) {
    try { $buildConfig = Get-Content $ConfigYaml -Raw | ConvertFrom-Yaml }
    catch { Write-Warning "Failed to parse $ConfigYaml — using defaults. $($_.Exception.Message)" }
}
$MinDalamudApiLevel        = if ($buildConfig -and $buildConfig.minDalamudApiLevel)        { [int]$buildConfig.minDalamudApiLevel }        else { 15 }
$MinTestingDalamudApiLevel = if ($buildConfig -and $buildConfig.minTestingDalamudApiLevel) { [int]$buildConfig.minTestingDalamudApiLevel } else { 15 }
$sourceDefault     = if ($buildConfig -and $buildConfig.sources -and $null -ne $buildConfig.sources.default) { [bool]$buildConfig.sources.default } else { $true }
$allEnabled        = if ($buildConfig -and $buildConfig.all -and $null -ne $buildConfig.all.enabled) { [bool]$buildConfig.all.enabled } else { $true }
$allOut            = if ($buildConfig -and $buildConfig.all -and $buildConfig.all.out) { [string]$buildConfig.all.out } else { "all.json" }

function IsSourceEnabled([string]$basename) {
    if (-not $buildConfig -or -not $buildConfig.sources) { return $sourceDefault }
    $val = $buildConfig.sources.$basename
    if ($null -eq $val) { return $sourceDefault }
    return [bool]$val
}

Write-Host "Config: minDalamudApiLevel=$MinDalamudApiLevel; minTestingDalamudApiLevel=$MinTestingDalamudApiLevel; sources.default=$sourceDefault; all.enabled=$allEnabled"

# ── Enumerate sources/*.yml ──────────────────────────────────────────────────
if (-not (Test-Path $SourcesDir)) {
    throw "Sources directory '$SourcesDir' not found."
}
$sourceFiles = Get-ChildItem -Path $SourcesDir -Filter "*.yml" -File | Sort-Object Name

# Per-source results accumulated for the union + summary.
$processed = @()  # array of @{ basename; type; out; entries; deduped; filtered; enabled; includeInUnion }

foreach ($file in $sourceFiles) {
    $basename = $file.Name
    $enabled  = IsSourceEnabled $basename
    Write-Host ""
    Write-Host "==> $basename"

    if (-not $enabled) {
        Write-Host "  (skipped — config.sources.$basename = false)"
        $processed += @{ basename = $basename; enabled = $false; deduped = @(); filtered = 0 }
        continue
    }

    $yaml = $null
    try { $yaml = Get-Content $file.FullName -Raw | ConvertFrom-Yaml }
    catch { Write-Warning "Failed to parse $basename — skipping. $($_.Exception.Message)"; continue }
    if (-not $yaml) { Write-Warning "$basename is empty — skipping."; continue }

    $type = [string]$yaml.type
    $out  = [string]$yaml.out
    if (-not $type) { Write-Warning "$basename has no 'type' — skipping."; continue }
    if (-not $out)  { Write-Warning "$basename has no 'out' — skipping."; continue }
    $includeInUnion = if ($null -eq $yaml.includeInUnion) { $true } else { [bool]$yaml.includeInUnion }

    switch ($type) {
        "nexus" {
            $r = Collect-NexusPool -Yaml $yaml
        }
        "external-plugins" {
            $r = Collect-ExternalPluginPool -Yaml $yaml
        }
        "external-repos" {
            $r = Collect-RepoUrlsPool -Yaml $yaml -SectionLabel $basename
        }
        default {
            Write-Warning "Unknown source type '$type' in $basename — skipping."
            continue
        }
    }

    # Republish gate. Must run BEFORE anything is written to $out, and the result
    # is assigned back into $r.entries so both the per-source file and the union
    # pool below see the same objects — that is what keeps all-repo.json
    # consistent with the per-source output for free. The @() wrap matters: a
    # single-element array would otherwise unroll.
    $published = Get-PublishedEntryMap $out
    $keep = Resolve-PublishedEntries -NewEntries $r.entries -Published $published `
                                     -ForceNames $ForcePlugin -ForceAll:$ForceAll
    $r.entries = @($keep.entries)

    $deduped = Get-Deduped $r.entries
    Write-Pluginmaster $deduped $out
    $processed += @{
        basename       = $basename
        type           = $type
        out            = $out
        entries        = $r.entries
        deduped        = $deduped
        filtered       = $r.filtered
        frozen         = $keep.frozen
        enabled        = $true
        includeInUnion = $includeInUnion
    }
}

# ── Curated union (all.json) ─────────────────────────────────────────────────
$unionPool = @()
foreach ($p in $processed) {
    if ($p.enabled -and $p.includeInUnion) { $unionPool += $p.entries }
}
$union = Build-FullUnion -NexusEntries @() -ExternalPluginEntries @() -CommonRepoEntries $unionPool
if ($allEnabled) { Write-Pluginmaster $union.entries $allOut }

# ── Summary ──────────────────────────────────────────────────────────────────
$outputs = @()
foreach ($p in $processed) {
    if ($p.enabled) {
        $outputs += @{ name = $p.out; count = @($p.deduped).Count; enabled = $true; frozen = $p.frozen }
    } else {
        $outputs += @{ name = $p.basename; count = 0; enabled = $false }
    }
}
$dupesRemoved = $union.before - $union.after
$outputs += @{ name = $allOut; count = $union.after; enabled = $allEnabled; extra = "($dupesRemoved duplicates removed)" }
Write-BuildSummary -Outputs $outputs

$totalFiltered = ($processed | ForEach-Object { $_.filtered } | Measure-Object -Sum).Sum
if ($totalFiltered -gt 0) {
    Write-Host ""
    Write-Host ("Total filtered out (DalamudApiLevel < {0} AND TestingDalamudApiLevel < {1}): {2}" -f $MinDalamudApiLevel, $MinTestingDalamudApiLevel, $totalFiltered)
    foreach ($p in $processed) {
        if ($p.filtered -gt 0) { Write-Host ("  {0}: {1}" -f $p.basename, $p.filtered) }
    }
}
if ($script:ZipFallbackRescued -gt 0) {
    Write-Host ""
    Write-Host ("Zip fallback rescued {0} entries (API level read from embedded manifest)." -f $script:ZipFallbackRescued)
    Write-Host ("  Snapshot hits: {0}; fresh zip downloads: {1}." -f $script:SnapshotHits, $script:ZipDownloads)
}

# A -ForcePlugin that matched nothing usually means a typo in a plugin's release
# workflow dispatch. Surface it instead of silently doing nothing.
foreach ($name in $ForcePlugin) {
    if (-not $script:ForceMatched.ContainsKey($name)) {
        Write-Host ("::warning::-ForcePlugin '{0}' matched no entry in any source pool." -f $name)
    }
}

Save-Snapshot

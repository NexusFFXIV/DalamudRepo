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

  `config.yml` (repo root) controls minDalamudApiLevel + per-source enable
  toggles (with a `default:` flag for sources not explicitly listed).
#>

param(
    [string]$ConfigYaml = "config.yml",
    [string]$SourcesDir = "sources",
    [string]$DalamudMasterUrl = "https://kamori.goats.dev/Plugin/PluginMaster"
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Install-Module -Name powershell-yaml -Force -Scope CurrentUser -AllowClobber -SkipPublisherCheck | Out-Null
}
Import-Module powershell-yaml

. "$PSScriptRoot\lib\collect-plugins.ps1"
. "$PSScriptRoot\lib\build-outputs.ps1"

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

    $deduped = Get-Deduped $r.entries
    Write-Pluginmaster $deduped $out
    $processed += @{
        basename       = $basename
        type           = $type
        out            = $out
        entries        = $r.entries
        deduped        = $deduped
        filtered       = $r.filtered
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
        $outputs += @{ name = $p.out; count = @($p.deduped).Count; enabled = $true }
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

<#
.SYNOPSIS
  Rebuild pluginmaster.json from the configured plugin repositories.

.DESCRIPTION
  Reads plugins.yml, fetches each plugin's latest stable + pre-release from
  GitHub Releases, downloads the embedded <InternalName>.json manifest from
  the release assets, and merges everything into pluginmaster.json.

  Stable / testing pointer semantics (per Dalamud spec):
    - Only stable          -> testing == stable (no downgrade for testers)
    - Stable + newer pre   -> stable stays, testing advances
    - Pre older than stab  -> testing pulled up to stable
    - Only pre-release     -> entry marked IsTestingExclusive=true

  Runs in a GitHub Action under ubuntu-latest with pwsh. Uses gh CLI for
  authenticated API calls (GITHUB_TOKEN of the workflow); release-asset
  downloads are anonymous over HTTPS.

.PARAMETER PluginsYaml
  Path to the config file. Defaults to plugins.yml in the repo root.

.PARAMETER OutFile
  Path to the output pluginmaster.json. Defaults to pluginmaster.json.

#>
param(
    [string]$PluginsYaml = "plugins.yml",
    [string]$ExternalPluginsYaml = "external-plugins.yml",
    [string]$ExternalReposYaml = "external-repos.yml",
    # Four outputs — one per source plus the merged "all" file. Users subscribe
    # to whichever scope they want; the default `pluginmaster.json` URL keeps
    # working and now only contains our own plugins.
    [string]$OutFile = "pluginmaster.json",
    [string]$ExternalPluginsOutFile = "external.json",
    [string]$ExternalReposOutFile = "repos.json",
    [string]$FullOutFile = "all.json",
    [string]$DalamudMasterUrl = "https://kamori.goats.dev/Plugin/PluginMaster"
)

$ErrorActionPreference = 'Stop'

# powershell-yaml is the easiest path to read plugins.yml on a fresh runner.
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Install-Module -Name powershell-yaml -Force -Scope CurrentUser -AllowClobber -SkipPublisherCheck | Out-Null
}
Import-Module powershell-yaml

function Invoke-GhApi {
    param([string]$Path)
    $raw = gh api $Path --paginate
    if ($LASTEXITCODE -ne 0) {
        throw "gh api $Path failed with exit code $LASTEXITCODE"
    }
    # --paginate concatenates JSON arrays without commas; wrap as single array
    # by collecting via gh's --jq if multi-page, or just parse if single page.
    # In practice single-page is enough for releases.
    return $raw | ConvertFrom-Json
}

function Get-LatestRelease {
    param($Releases, [bool]$Prerelease)
    $filtered = @($Releases | Where-Object { -not $_.draft -and $_.prerelease -eq $Prerelease })
    if ($filtered.Count -eq 0) { return $null }
    return $filtered | Sort-Object -Property published_at -Descending | Select-Object -First 1
}

function Get-AssetUrl {
    param($Release, [string]$Pattern)
    $asset = $Release.assets | Where-Object { $_.name -like $Pattern } | Select-Object -First 1
    if (-not $asset) { return $null }
    return $asset.browser_download_url
}

function Get-ManifestFromRelease {
    param($Release, [string]$InternalName)
    $url = Get-AssetUrl -Release $Release -Pattern "$InternalName.json"
    if (-not $url) {
        Write-Warning "Release $($Release.tag_name) of has no '$InternalName.json' asset — entry will be skipped."
        return $null
    }
    $tmp = New-TemporaryFile
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp.FullName -UseBasicParsing
        return Get-Content $tmp.FullName -Raw | ConvertFrom-Json
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

function Get-CumulativeDownloads {
    # Sum download_count across the plugin .zip assets of all non-draft
    # releases (past releases included). The .json manifest assets are
    # deliberately excluded — this script itself fetches them via the
    # asset's browser_download_url on every refresh, which would otherwise
    # inflate the user-facing count by ~4/day per release.
    param($Releases)
    $sum = 0
    foreach ($r in $Releases) {
        if ($r.draft) { continue }
        foreach ($a in $r.assets) {
            if ($a.name -like '*.zip') { $sum += $a.download_count }
        }
    }
    return $sum
}

$config = Get-Content $PluginsYaml -Raw | ConvertFrom-Yaml

# Each source feeds its own pool so we can emit a per-source pluginmaster
# alongside the merged "full" one.
$nexusEntries = @()
$externalPluginEntries = @()
$externalRepoEntries = @()

# External plugins are looked up by InternalName in Dalamud's official
# pluginmaster and copied verbatim. Fetch the master once so the lookup is
# cheap for any number of external entries.
$externalConfig = $null
$dalamudMaster = $null
if (Test-Path $ExternalPluginsYaml) {
    try {
        $externalConfig = Get-Content $ExternalPluginsYaml -Raw | ConvertFrom-Yaml
    } catch {
        Write-Warning "Failed to parse $ExternalPluginsYaml — skipping external-plugin imports. $($_.Exception.Message)"
        $externalConfig = $null
    }
    if ($externalConfig -and $externalConfig.externalPlugins -and @($externalConfig.externalPlugins).Count -gt 0) {
        Write-Host "Fetching Dalamud official pluginmaster for external lookups..."
        try {
            $dalamudMaster = Invoke-RestMethod -Uri $DalamudMasterUrl -UseBasicParsing -TimeoutSec 30
        } catch {
            Write-Warning "Failed to fetch $DalamudMasterUrl — external-plugin imports will be skipped. $($_.Exception.Message)"
            $dalamudMaster = $null
        }
    }
}

Write-Host "plugins:"
$nexusCount = 0
foreach ($plugin in $config.plugins) {
    $name = $plugin.internalName
    $repo = $plugin.repo
    $iconPath = $plugin.icon

    # Fetch the full releases list ONCE per plugin — used for stable+testing
    # selection AND cumulative download-count aggregation.
    $allReleases = Invoke-GhApi "repos/$repo/releases"
    $stable = Get-LatestRelease -Releases $allReleases -Prerelease $false
    $testing = Get-LatestRelease -Releases $allReleases -Prerelease $true

    if (-not $stable -and -not $testing) {
        Write-Warning "No releases for $name — skipping."
        continue
    }

    # Reconcile: testing only counts if it's strictly newer than stable.
    if ($testing -and $stable) {
        $tDate = [DateTime]::Parse($testing.published_at)
        $sDate = [DateTime]::Parse($stable.published_at)
        if ($tDate -le $sDate) { $testing = $null }
    }

    $isTestingExclusive = ($null -eq $stable -and $null -ne $testing)
    $primaryRelease = if ($stable) { $stable } else { $testing }
    $primaryManifest = Get-ManifestFromRelease -Release $primaryRelease -InternalName $name
    if (-not $primaryManifest) { continue }

    $entry = [ordered]@{
        Author = $primaryManifest.Author
        Name = $primaryManifest.Name
        InternalName = $primaryManifest.InternalName
        Description = $primaryManifest.Description
        Punchline = $primaryManifest.Punchline
        Tags = $primaryManifest.Tags
        ApplicableVersion = $primaryManifest.ApplicableVersion
        DalamudApiLevel = $primaryManifest.DalamudApiLevel
        AssemblyVersion = $primaryManifest.AssemblyVersion
        RepoUrl = "https://github.com/$repo"
        IconUrl = "https://raw.githubusercontent.com/$repo/main/$iconPath"
        AcceptsFeedback = if ($null -ne $primaryManifest.AcceptsFeedback) { $primaryManifest.AcceptsFeedback } else { $true }
        FeedbackMessage = $primaryManifest.FeedbackMessage
        IsHide = $false
        IsTestingExclusive = $isTestingExclusive
        LastUpdate = [DateTimeOffset]::Parse($primaryRelease.published_at).ToUnixTimeSeconds()
        DownloadCount = Get-CumulativeDownloads $allReleases
    }

    # Stable Install/Update links
    if ($stable) {
        $stableZip = Get-AssetUrl -Release $stable -Pattern "*.zip"
        $entry.DownloadLinkInstall = $stableZip
        $entry.DownloadLinkUpdate = $stableZip
        # If no separate pre-release: testing mirrors stable so testers don't get downgraded.
        if (-not $testing) {
            $entry.DownloadLinkTesting = $stableZip
            $entry.TestingAssemblyVersion = $primaryManifest.AssemblyVersion
            $entry.TestingDalamudApiLevel = $primaryManifest.DalamudApiLevel
        }
    }

    # Testing-only (newer pre-release) → fill testing-specific fields
    if ($testing) {
        $testingManifest = Get-ManifestFromRelease -Release $testing -InternalName $name
        $testingZip = Get-AssetUrl -Release $testing -Pattern "*.zip"
        if ($testingManifest -and $testingZip) {
            $entry.DownloadLinkTesting = $testingZip
            $entry.TestingAssemblyVersion = $testingManifest.AssemblyVersion
            $entry.TestingDalamudApiLevel = $testingManifest.DalamudApiLevel
        }
    }

    # Testing-exclusive (no stable yet): install/update fields use the pre-release
    if ($isTestingExclusive) {
        $testingZip = Get-AssetUrl -Release $testing -Pattern "*.zip"
        $entry.DownloadLinkInstall = $testingZip
        $entry.DownloadLinkUpdate = $testingZip
    }

    $nexusEntries += [pscustomobject]$entry
    Write-Host ("  -> {0} ({1})" -f $name, $entry.AssemblyVersion)
    $nexusCount++
}
if ($nexusCount -eq 0) { Write-Host "  (none)" }

Write-Host ""
Write-Host "external:"
$externalCount = 0
if ($externalConfig -and $externalConfig.externalPlugins -and $dalamudMaster) {
    foreach ($ext in $externalConfig.externalPlugins) {
        $name = $ext.internalName
        $upstream = $dalamudMaster | Where-Object { $_.InternalName -eq $name } | Select-Object -First 1
        if (-not $upstream) {
            Write-Host "  -> $name (not found in $DalamudMasterUrl)"
            Write-Warning "External plugin '$name' not found in Dalamud official pluginmaster — skipping."
            continue
        }
        $externalPluginEntries += $upstream
        Write-Host ("  -> {0} ({1})" -f $upstream.InternalName, $upstream.AssemblyVersion)
        $externalCount++
    }
}
if ($externalCount -eq 0) { Write-Host "  (none)" }

# External repos: pull the whole pluginmaster from each third-party repo and
# fold every entry into our pool. Third-party repos go down, change format,
# rate-limit, etc. — any failure on a single repo is logged as a warning and
# skipped, the rest of the build keeps going.
Write-Host ""
Write-Host "external Repos:"
$externalReposLogged = 0
if (Test-Path $ExternalReposYaml) {
    $extReposConfig = $null
    try {
        $extReposConfig = Get-Content $ExternalReposYaml -Raw | ConvertFrom-Yaml
    } catch {
        Write-Warning "Failed to parse $ExternalReposYaml — skipping external-repo imports. $($_.Exception.Message)"
    }
    if ($extReposConfig -and $extReposConfig.externalRepos) {
        foreach ($url in $extReposConfig.externalRepos) {
            if (-not $url) { continue }
            Write-Host "  -> ${url}:"
            $externalReposLogged++
            $resp = $null
            try {
                $resp = Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 30
            } catch {
                Write-Host "    (unreachable: $($_.Exception.Message))"
                Write-Warning "External repo $url unreachable: $($_.Exception.Message)"
                continue
            }
            if (-not $resp) {
                Write-Host "    (empty response)"
                Write-Warning "External repo $url returned empty response"
                continue
            }
            # Most pluginmasters are JSON arrays; some single-plugin manifests
            # are a bare object. Normalize to an array either way.
            $items = if ($resp -is [System.Array]) { $resp } else { @($resp) }
            $added = 0
            foreach ($e in $items) {
                if ($e -and $e.InternalName) {
                    $externalRepoEntries += $e
                    Write-Host ("    -> {0} ({1})" -f $e.InternalName, $e.AssemblyVersion)
                    $added++
                }
            }
            if ($added -eq 0) { Write-Host "    (no usable entries)" }
        }
    }
}
if ($externalReposLogged -eq 0) { Write-Host "  (none configured)" }

# Deduplicate each pool by InternalName, keeping the entry with the highest
# AssemblyVersion. Same plugin published by multiple repos is common; this
# rule picks the most up-to-date copy. Missing/unparseable versions sort
# below valid ones (treated as 0.0.0.0).
function Resolve-Version {
    param($Entry)
    try { [System.Version]$Entry.AssemblyVersion } catch { [System.Version]"0.0.0.0" }
}

function Get-Deduped {
    param([array]$Entries)
    $arr = @($Entries)
    if ($arr.Count -eq 0) { return @() }
    $result = @()
    foreach ($g in ($arr | Group-Object -Property InternalName)) {
        $winner = $g.Group | Sort-Object -Property { Resolve-Version $_ } -Descending | Select-Object -First 1
        $result += $winner
    }
    return $result
}

function Write-Pluginmaster {
    param([array]$Entries, [string]$Path)
    $arr = @($Entries)
    $json = $arr | ConvertTo-Json -Depth 10
    # ConvertTo-Json wraps single-element arrays as objects; force an array even if <=1 entry.
    if ($arr.Count -le 1) { $json = "[`n" + ($json -replace '(?ms)^', '  ') + "`n]" }
    Set-Content -Path $Path -Value $json -Encoding UTF8 -NoNewline
    Add-Content -Path $Path -Value "`n" -NoNewline
}

$nexusDeduped = Get-Deduped $nexusEntries
$externalPluginDeduped = Get-Deduped $externalPluginEntries
$externalRepoDeduped = Get-Deduped $externalRepoEntries

# Verbose dedup logging happens on the full union — that's where cross-source
# collisions actually matter ("plugin X also exists in repo Y at older version").
Write-Host ""
Write-Host "Deduping (full pluginmaster):"
$allEntries = $nexusEntries + $externalPluginEntries + $externalRepoEntries
$beforeFullCount = @($allEntries).Count
$fullDeduped = @()
foreach ($g in ($allEntries | Group-Object -Property InternalName)) {
    $sorted = $g.Group | Sort-Object -Property { Resolve-Version $_ } -Descending
    $winner = $sorted | Select-Object -First 1
    $others = $g.Count - 1
    $suffix = if ($others -gt 0) { "$others other version$(if ($others -ne 1) { 's' }) in list" } else { "unique" }
    Write-Host ("Added {0} ({1}) ({2})" -f $winner.InternalName, $winner.AssemblyVersion, $suffix)
    $fullDeduped += $winner
}

Write-Pluginmaster $nexusDeduped $OutFile
Write-Pluginmaster $externalPluginDeduped $ExternalPluginsOutFile
Write-Pluginmaster $externalRepoDeduped $ExternalReposOutFile
Write-Pluginmaster $fullDeduped $FullOutFile

$dupesRemoved = $beforeFullCount - @($fullDeduped).Count
Write-Host ""
Write-Host "Summary:"
Write-Host ("  {0,-40} {1} entries" -f $OutFile, @($nexusDeduped).Count)
Write-Host ("  {0,-40} {1} entries" -f $ExternalPluginsOutFile, @($externalPluginDeduped).Count)
Write-Host ("  {0,-40} {1} entries" -f $ExternalReposOutFile, @($externalRepoDeduped).Count)
Write-Host ("  {0,-40} {1} entries ({2} duplicates removed)" -f $FullOutFile, @($fullDeduped).Count, $dupesRemoved)

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
    [string]$OutFile = "pluginmaster.json",
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
$entries = @()

# External plugins are looked up by InternalName in Dalamud's official
# pluginmaster and copied verbatim. Fetch the master once so the lookup is
# cheap for any number of external entries.
$externalConfig = $null
$dalamudMaster = $null
if (Test-Path $ExternalPluginsYaml) {
    $externalConfig = Get-Content $ExternalPluginsYaml -Raw | ConvertFrom-Yaml
    if ($externalConfig.externalPlugins -and $externalConfig.externalPlugins.Count -gt 0) {
        Write-Host "Fetching Dalamud official pluginmaster for external lookups..."
        $dalamudMaster = Invoke-RestMethod -Uri $DalamudMasterUrl -UseBasicParsing
    }
}

foreach ($plugin in $config.plugins) {
    $name = $plugin.internalName
    $repo = $plugin.repo
    $iconPath = $plugin.icon
    Write-Host "==> $name ($repo)"

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

    $entries += [pscustomobject]$entry
}

if ($externalConfig -and $externalConfig.externalPlugins -and $dalamudMaster) {
    foreach ($ext in $externalConfig.externalPlugins) {
        $name = $ext.internalName
        Write-Host "==> $name (external, from $DalamudMasterUrl)"
        $upstream = $dalamudMaster | Where-Object { $_.InternalName -eq $name } | Select-Object -First 1
        if (-not $upstream) {
            Write-Warning "External plugin '$name' not found in Dalamud official pluginmaster — skipping."
            continue
        }
        $entries += $upstream
    }
}

$json = $entries | ConvertTo-Json -Depth 10
# ConvertTo-Json wraps single-element arrays as objects; force an array even if 1 entry.
if ($entries.Count -le 1) { $json = "[`n" + ($json -replace '(?ms)^', '  ') + "`n]" }

Set-Content -Path $OutFile -Value $json -Encoding UTF8 -NoNewline
Add-Content -Path $OutFile -Value "`n" -NoNewline
Write-Host "Wrote $OutFile with $($entries.Count) entries"

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

.PARAMETER IconBaseUrl
  Base URL for icon paths from plugins.yml. The script appends each plugin's
  icon path to this base to form the absolute IconUrl in pluginmaster.json.
#>
param(
    [string]$PluginsYaml = "plugins.yml",
    [string]$OutFile = "pluginmaster.json",
    [string]$IconBaseUrl = "https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main"
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
    param([string]$Repo, [bool]$Prerelease)
    $releases = Invoke-GhApi "repos/$Repo/releases"
    $filtered = @($releases | Where-Object { -not $_.draft -and $_.prerelease -eq $Prerelease })
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

function Get-TotalDownloads {
    param($Release)
    $sum = 0
    foreach ($a in $Release.assets) { $sum += $a.download_count }
    return $sum
}

$config = Get-Content $PluginsYaml -Raw | ConvertFrom-Yaml
$entries = @()

foreach ($plugin in $config.plugins) {
    $name = $plugin.internalName
    $repo = $plugin.repo
    $iconPath = $plugin.icon
    Write-Host "==> $name ($repo)"

    $stable = Get-LatestRelease -Repo $repo -Prerelease $false
    $testing = Get-LatestRelease -Repo $repo -Prerelease $true

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
        IconUrl = "$IconBaseUrl/$iconPath"
        AcceptsFeedback = if ($null -ne $primaryManifest.AcceptsFeedback) { $primaryManifest.AcceptsFeedback } else { $true }
        FeedbackMessage = $primaryManifest.FeedbackMessage
        IsHide = $false
        IsTestingExclusive = $isTestingExclusive
        LastUpdate = [DateTimeOffset]::Parse($primaryRelease.published_at).ToUnixTimeSeconds()
        DownloadCount = Get-TotalDownloads $primaryRelease
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

$json = $entries | ConvertTo-Json -Depth 10
# ConvertTo-Json wraps single-element arrays as objects; force an array even if 1 entry.
if ($entries.Count -le 1) { $json = "[`n" + ($json -replace '(?ms)^', '  ') + "`n]" }

Set-Content -Path $OutFile -Value $json -Encoding UTF8 -NoNewline
Add-Content -Path $OutFile -Value "`n" -NoNewline
Write-Host "Wrote $OutFile with $($entries.Count) entries"

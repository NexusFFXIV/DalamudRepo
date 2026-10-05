# Part A — source collectors.
#
# Each Collect-* function takes an already-parsed yaml hashtable, fetches
# its source pool, applies the API-level filter (OR over DalamudApiLevel
# and TestingDalamudApiLevel — see Test-MeetsApi), emits structured
# logging, and returns @{ entries = @(...); filtered = <int> }.
#
# Relies on script-scope vars set by the orchestrator: $MinDalamudApiLevel,
# $MinTestingDalamudApiLevel.

# Upstream Dalamud master plugin list — source for `type: external-plugins`
# entries (we pull individual plugins out of it by InternalName).
$DalamudMasterUrl = "https://kamori.goats.dev/Plugin/PluginMaster"

# Durable cache file for zip-fallback api-level lookups. Kept under cache/
# (separate from sources/ which is for plugin source definitions) so it's
# obviously a build artifact.
$SnapshotPath = "cache/snapshot.json"
$script:RepoDedupHeaderWritten = $false

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

function Invoke-GhApi {
    param([string]$Path)
    $raw = gh api $Path --paginate
    if ($LASTEXITCODE -ne 0) {
        throw "gh api $Path failed with exit code $LASTEXITCODE"
    }
    return $raw | ConvertFrom-Json
}

function Get-HttpErrorLabel {
    param([Parameter(Mandatory)]$ErrorRecord)
    $response = $ErrorRecord.Exception.Response
    if ($response -and $response.StatusCode) {
        return ("{0}{1}" -f [int]$response.StatusCode, $response.StatusCode.ToString())
    }
    return "RequestError"
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
        Write-Warning "Release $($Release.tag_name) has no '$InternalName.json' asset — skipping."
        return $null
    }
    $tmp = New-TemporaryFile
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp.FullName -UseBasicParsing -ErrorAction Stop 2>$null
        return Get-Content $tmp.FullName -Raw | ConvertFrom-Json
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

function Get-CumulativeDownloads {
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

# =============================================================================
# Snapshot cache for badly-formatted upstream entries
# =============================================================================
#
# Purpose
# -------
# Some upstream pluginmaster entries omit DalamudApiLevel /
# TestingDalamudApiLevel. When we hit one we have to download the linked zip
# and read the level out of the embedded <InternalName>.json. Every zip GET
# counts toward the upstream release's download_count — without a cache, each
# workflow run would inflate that counter, the next run would see the new
# value, and a "refresh" PR would open every cycle for no real reason.
#
# The cache exists for that single purpose: avoid unnecessary zip downloads.
# Nothing else. It does not mirror upstream data, it is not a backup of the
# pluginmaster, it doesn't store anything we'd serve to consumers.
#
# Layers
# ------
#   * $script:ZipApiLevelCache — per-run dedup, keyed by URL.
#   * $script:Snapshot         — durable cross-run cache (one entry per
#                                plugin, keyed by InternalName), persisted
#                                to cache/snapshot.json.
#
# Snapshot value schema (per plugin):
#   { InternalName, AssemblyVersion, DalamudApiLevel,
#                   TestingAssemblyVersion, TestingDalamudApiLevel }
#
# Resolve priority per channel (prod and testing run independently):
#   1. Upstream entry has the level                  → use it, no cache touch
#   2. Snapshot has matching AssemblyVersion + level → use it (snapshot hit)
#   3. Download the zip                              → use, store in snapshot
#
# AssemblyVersion mismatch between cache and upstream invalidates the cached
# level for that channel and falls through to steps 1/3 — which is why a
# version bump doesn't automatically cause a zip download (upstream may have
# fixed its formatting between releases).
#
# Per-channel write/cleanup rules
# -------------------------------
# Cache fields are stored/dropped per channel, never all-or-nothing:
#   * channel resolved via fallback this run     → its fields are stored
#   * channel where upstream provides the level  → its fields drop to null
#   * channel that doesn't exist on this plugin  → its fields stay null
# When both channels end up null the whole entry is removed.
#
# Edge case matrix (one row per plugin shape we've thought about):
#
#   Plugin shape                              | Outcome
#   ------------------------------------------|----------------------------------
#   prod-only, upstream broken                | cache holds prod fields
#   prod-only, upstream fixed                 | cache entry deleted
#   testing-only fresh plugin, upstream broken| cache holds testing fields
#   testing-only fresh plugin, upstream fixed | cache entry deleted
#   both channels broken                      | cache holds both
#   both channels, only prod fixed            | cache holds testing only
#   both channels, only testing fixed         | cache holds prod only
#   both channels fully fixed                 | cache entry deleted
#   AV bumped on a channel, level missing     | cache ignored, fresh resolve
#   AV bumped, upstream now provides level    | cache ignored, used directly
#   testing channel newly added (broken)      | cache gains testing fields
#   testing channel removed by upstream       | cache testing fields drop
#   zip download failed                       | level stays null, not cached
#                                             | (no "failure cache")
#
# Counters surfaced in the orchestrator summary:
#   $script:SnapshotHits       - resolves served from snapshot
#   $script:ZipDownloads       - actual HTTP fetches
#   $script:ZipFallbackRescued - entries kept that would have been filtered
#                                otherwise
# =============================================================================
$script:ZipApiLevelCache = @{}
$script:ZipFallbackRescued = 0
$script:SnapshotHits = 0
$script:ZipDownloads = 0
$script:ZipReports = @()
$script:ReportSources = @()
$script:ReportDeduplication = @()
$script:ReportApiResolution = @()
$script:ApiResolutionSeen = @{}

$script:Snapshot = @{}

function Initialize-Snapshot {
    $script:Snapshot = @{}
    if (Test-Path $SnapshotPath) {
        try {
            $loaded = Get-Content $SnapshotPath -Raw | ConvertFrom-Json -AsHashtable
            if ($loaded) { $script:Snapshot = $loaded }
        } catch {
            Write-Warning "Failed to parse snapshot at $SnapshotPath — starting fresh. $($_.Exception.Message)"
        }
    }
}

function Save-Snapshot {
    # Create the cache dir on demand — fresh clones / first runs after a
    # rename won't have it yet.
    $parent = Split-Path $SnapshotPath -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    # Sort by InternalName for stable, diff-friendly output across runs.
    $sorted = [ordered]@{}
    foreach ($k in ($script:Snapshot.Keys | Sort-Object)) { $sorted[$k] = $script:Snapshot[$k] }
    ($sorted | ConvertTo-Json -Depth 5) + "`n" | Set-Content -Path $SnapshotPath -Encoding UTF8 -NoNewline
}

function Get-ZipManifestApiLevel {
    # Pure: download the zip, read DalamudApiLevel from the embedded
    # manifest, return it (or $null on any failure). All caching happens at
    # the caller (Resolve-EntryApiLevels) — this function just does the I/O.
    # The URL-keyed in-process map is the one piece of dedup that lives here,
    # to cover the (rare) case of two entries pointing at the same zip in
    # one run.
    param([string]$Url, [string]$InternalName)
    if (-not $Url -or -not $InternalName) { return $null }
    if ($script:ZipApiLevelCache.ContainsKey($Url)) { return $script:ZipApiLevelCache[$Url] }

    $script:ZipDownloads++
    $result = $null
    $status = "DOWNLOAD_ERROR"
    $tmp = $null
    try {
        $tmp = New-TemporaryFile
        $probe = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 30 -SkipHttpErrorCheck
        if ([int]$probe.StatusCode -lt 200 -or [int]$probe.StatusCode -ge 300) {
            $statusText = if ($probe.StatusDescription) { [string]$probe.StatusDescription } else { "HTTP" }
            $status = ("{0}{1}" -f [int]$probe.StatusCode, ($statusText -replace '[^A-Za-z0-9]', ''))
            $script:ZipApiLevelCache[$Url] = $null
            $script:ZipReports += [pscustomobject]@{ Plugin = $InternalName; Status = $status; Api = "-"; Url = $Url }
            return $null
        }
        Invoke-WebRequest -Uri $Url -OutFile $tmp.FullName -UseBasicParsing -TimeoutSec 30 -SkipHttpErrorCheck
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tmp.FullName)
        try {
            $entry = $zip.Entries | Where-Object { $_.Name -ieq "$InternalName.json" } | Select-Object -First 1
            if ($entry) {
                $reader = New-Object System.IO.StreamReader($entry.Open())
                try {
                    try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } catch { $manifest = $null; $status = "PARSE_ERROR" }
                    if ($manifest -and $null -ne $manifest.DalamudApiLevel) {
                        $result = [int]$manifest.DalamudApiLevel
                        $status = "OK"
                    } elseif ($status -ne "PARSE_ERROR") { $status = "API_MISSING" }
                } finally { $reader.Dispose() }
            } else {
                $status = "API_MISSING"
            }
        } finally { $zip.Dispose() }
    } catch {
        Write-Verbose "Zip fallback failed for $Url ($InternalName): $($_.Exception.Message)"
    } finally {
        if ($tmp) { Remove-Item $tmp.FullName -ErrorAction SilentlyContinue }
    }
    $script:ZipReports += [pscustomobject]@{ Plugin = $InternalName; Status = $status; Api = if ($null -ne $result) { $result } else { "-" }; Url = $Url }
    $script:ZipApiLevelCache[$Url] = $result
    return $result
}

function Resolve-EntryApiLevels {
    # Resolves DalamudApiLevel + TestingDalamudApiLevel for one upstream
    # entry, falling back to the snapshot cache and then to the zip
    # manifest. Full design notes (priority order, per-channel write rules,
    # edge case matrix) live in the snapshot-cache header block above.
    param($Entry)
    if (-not $Entry -or -not $Entry.InternalName) {
        return [pscustomobject]@{ DalamudApiLevel = $null; TestingDalamudApiLevel = $null }
    }
    $cached  = $script:Snapshot[$Entry.InternalName]
    $prodAv  = if ($Entry.AssemblyVersion)        { [string]$Entry.AssemblyVersion }        else { $null }
    $prodLvl = $Entry.DalamudApiLevel
    $testAv  = if ($Entry.TestingAssemblyVersion) { [string]$Entry.TestingAssemblyVersion } else { $null }
    $testLvl = $Entry.TestingDalamudApiLevel

    $prodFromFallback = $false
    $testFromFallback = $false

    if ($null -eq $prodLvl -and $prodAv) {
        if ($cached -and ([string]$cached.AssemblyVersion -eq $prodAv) -and ($null -ne $cached.DalamudApiLevel)) {
            $prodLvl = [int]$cached.DalamudApiLevel
            $script:SnapshotHits++
            Write-Host ("    [cache] {0} prod {1} api={2}" -f $Entry.InternalName, $prodAv, $prodLvl)
        } else {
            $url = if ($Entry.DownloadLinkInstall) { $Entry.DownloadLinkInstall } else { $Entry.DownloadLinkUpdate }
            $prodLvl = Get-ZipManifestApiLevel -Url $url -InternalName $Entry.InternalName
            if ($null -ne $prodLvl) {
                $script:ZipFallbackRescued++
                Write-Host ("    [zip]   {0} prod {1} api={2}" -f $Entry.InternalName, $prodAv, $prodLvl)
            } else {
            }
        }
        $prodFromFallback = $true
    }

    if ($null -eq $testLvl -and $testAv) {
        if ($cached -and ([string]$cached.TestingAssemblyVersion -eq $testAv) -and ($null -ne $cached.TestingDalamudApiLevel)) {
            $testLvl = [int]$cached.TestingDalamudApiLevel
            $script:SnapshotHits++
            Write-Host ("    [cache] {0} test {1} api={2}" -f $Entry.InternalName, $testAv, $testLvl)
        } else {
            $testLvl = Get-ZipManifestApiLevel -Url $Entry.DownloadLinkTesting -InternalName $Entry.InternalName
            if ($null -ne $testLvl) {
                $script:ZipFallbackRescued++
                Write-Host ("    [zip]   {0} test {1} api={2}" -f $Entry.InternalName, $testAv, $testLvl)
            } else {
            }
        }
        $testFromFallback = $true
    }

    # Per-channel decision: each channel's cache fields are kept only when
    # we actually needed the fallback path to resolve that channel. Upstream
    # providing the level directly (or the channel not existing at all) is
    # enough to drop just that channel's cache — independent of the other.
    # The cache exists purely to avoid re-downloading zips, so any channel
    # that no longer needs a zip lookup has no reason to stay cached.
    $keepProd = $prodFromFallback -and ($null -ne $prodLvl)
    $keepTest = $testFromFallback -and ($null -ne $testLvl)

    if ($keepProd -or $keepTest) {
        $script:Snapshot[$Entry.InternalName] = [ordered]@{
            InternalName           = $Entry.InternalName
            AssemblyVersion        = if ($keepProd) { $prodAv }       else { $null }
            DalamudApiLevel        = if ($keepProd) { [int]$prodLvl } else { $null }
            TestingAssemblyVersion = if ($keepTest) { $testAv }       else { $null }
            TestingDalamudApiLevel = if ($keepTest) { [int]$testLvl } else { $null }
        }
    } elseif ($cached) {
        $script:Snapshot.Remove($Entry.InternalName) | Out-Null
    }

    return [pscustomobject]@{
        DalamudApiLevel        = $prodLvl
        TestingDalamudApiLevel = $testLvl
    }
}

function Test-MeetsApi {
    # An entry passes if either the stable OR the testing channel meets its
    # respective minimum API level. This way a plugin whose stable build is
    # behind but whose testing build keeps up doesn't get dropped from
    # testing-eligible scopes. Resolve-EntryApiLevels handles the
    # snapshot/zip fallback for missing levels — see that function for the
    # full lookup order.
    param($Entry)
    if (-not $Entry) { return $false }
    $resolved = Resolve-EntryApiLevels $Entry
    $reportKey = "{0}|{1}|{2}" -f $Entry.InternalName, $Entry.AssemblyVersion, $Entry.TestingAssemblyVersion
    if (-not $script:ApiResolutionSeen.ContainsKey($reportKey)) {
        $script:ApiResolutionSeen[$reportKey] = $true
        $prodUrl = if ($Entry.DownloadLinkInstall) { [string]$Entry.DownloadLinkInstall } else { [string]$Entry.DownloadLinkUpdate }
        $testUrl = [string]$Entry.DownloadLinkTesting
        $prodSource = if ($null -ne $Entry.DalamudApiLevel) { 'repo.json' } elseif ($script:Snapshot[$Entry.InternalName].DalamudApiLevel) { 'snapshot' } elseif ($prodUrl) { 'zip' } else { 'unresolved' }
        $testSource = if ($null -ne $Entry.TestingDalamudApiLevel) { 'repo.json' } elseif ($script:Snapshot[$Entry.InternalName].TestingDalamudApiLevel) { 'snapshot' } elseif ($testUrl) { 'zip' } else { 'unresolved' }
        $prodZip = @($script:ZipReports | Where-Object Url -eq $prodUrl | Select-Object -Last 1).Status
        $testZip = @($script:ZipReports | Where-Object Url -eq $testUrl | Select-Object -Last 1).Status
        $script:ReportApiResolution += [pscustomobject]@{
            Plugin = $Entry.InternalName
            SourceUrl = if ($Entry.__ReportSourceUrl) { $Entry.__ReportSourceUrl } else { $Entry.RepoUrl }
            StableApi = $resolved.DalamudApiLevel; StableSource = $prodSource; StableZipStatus = if ($prodSource -eq 'zip') { $prodZip } else { '' }
            TestingApi = $resolved.TestingDalamudApiLevel; TestingSource = $testSource; TestingZipStatus = if ($testSource -eq 'zip') { $testZip } else { '' }
        }
    }
    $prodOk = $false
    $testOk = $false
    if ($null -ne $resolved.DalamudApiLevel) {
        try { $prodOk = ([int]$resolved.DalamudApiLevel) -ge $MinDalamudApiLevel } catch {}
    }
    if ($null -ne $resolved.TestingDalamudApiLevel) {
        try { $testOk = ([int]$resolved.TestingDalamudApiLevel) -ge $MinTestingDalamudApiLevel } catch {}
    }
    return ($prodOk -or $testOk)
}

function Warn-OnVersionMismatch {
    # Flags an entry whose advertised version disagrees with the release tag its
    # download link points at.
    #
    # Dalamud decides whether an update exists by comparing the AssemblyVersion
    # here against the installed assembly. When the two disagree the failure is
    # silent and nasty: pluginmaster looks healthy, the link points at the new
    # zip, and yet nobody is offered the update because the version says they
    # already have it. PlayerNexusTracker v0.2.0 shipped exactly that way — the
    # tag said v0.2.0, the manifest said 0.1.2.0.
    #
    # A warning rather than an error on purpose: external plugins are not ours to
    # gate, and plenty of upstreams version their assemblies independently of
    # their tags. Anything whose tag is not a plain version is skipped instead of
    # guessed at.
    param(
        [string] $InternalName,
        [string] $Label,
        [string] $Url,
        [string] $AssemblyVersion
    )
    if ([string]::IsNullOrWhiteSpace($Url) -or [string]::IsNullOrWhiteSpace($AssemblyVersion)) { return }
    if ($Url -notmatch '/releases/download/([^/]+)/') { return }

    $tag = $Matches[1]
    $numeric = ($tag.TrimStart('v', 'V') -split '-')[0]
    if ($numeric -notmatch '^\d+\.\d+(\.\d+)?$') { return }

    $av = $null; $tv = $null
    try { $av = [version]$AssemblyVersion } catch { return }
    try { $tv = [version]$numeric } catch { return }

    # Compare only the components the tag actually states; AssemblyVersion
    # carries a fourth (revision) part that no tag expresses.
    $mismatch = ($av.Major -ne $tv.Major) -or ($av.Minor -ne $tv.Minor)
    if (-not $mismatch -and $tv.Build -ge 0) {
        $mismatch = ([Math]::Max($av.Build, 0) -ne $tv.Build)
    }
    if ($mismatch) {
        Write-Host ("::warning::{0}: {1} is {2} but its download link points at tag {3}. Dalamud compares that version against the installed plugin, so users already on {2} will not be offered this release." -f `
            $InternalName, $Label, $AssemblyVersion, $tag)
    }
}

function Collect-NexusPool {
    param([Parameter(Mandatory)]$Yaml)
    $entries = @()
    $filtered = 0
    $count = 0
    foreach ($plugin in $Yaml.plugins) {
        $name = $plugin.internalName
        $repo = $plugin.repo
        $iconPath = $plugin.icon

        $allReleases = Invoke-GhApi "repos/$repo/releases"
        $stable = Get-LatestRelease -Releases $allReleases -Prerelease $false
        $testing = Get-LatestRelease -Releases $allReleases -Prerelease $true

        if (-not $stable -and -not $testing) {
            Write-Warning "No releases for $name — skipping."
            continue
        }
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
        if ($stable) {
            $stableZip = Get-AssetUrl -Release $stable -Pattern "*.zip"
            $entry.DownloadLinkInstall = $stableZip
            $entry.DownloadLinkUpdate = $stableZip
            if (-not $testing) {
                $entry.DownloadLinkTesting = $stableZip
                $entry.TestingAssemblyVersion = $primaryManifest.AssemblyVersion
                $entry.TestingDalamudApiLevel = $primaryManifest.DalamudApiLevel
            }
        }
        if ($testing) {
            $testingManifest = Get-ManifestFromRelease -Release $testing -InternalName $name
            $testingZip = Get-AssetUrl -Release $testing -Pattern "*.zip"
            if ($testingManifest -and $testingZip) {
                $entry.DownloadLinkTesting = $testingZip
                $entry.TestingAssemblyVersion = $testingManifest.AssemblyVersion
                $entry.TestingDalamudApiLevel = $testingManifest.DalamudApiLevel
            }
        }
        if ($isTestingExclusive) {
            $testingZip = Get-AssetUrl -Release $testing -Pattern "*.zip"
            $entry.DownloadLinkInstall = $testingZip
            $entry.DownloadLinkUpdate = $testingZip
        }

        $obj = [pscustomobject]$entry
        if (-not (Test-MeetsApi $obj)) { $filtered++; continue }
        Warn-OnVersionMismatch -InternalName $name -Label "AssemblyVersion" `
            -Url $entry.DownloadLinkInstall -AssemblyVersion $entry.AssemblyVersion
        Warn-OnVersionMismatch -InternalName $name -Label "TestingAssemblyVersion" `
            -Url $entry.DownloadLinkTesting -AssemblyVersion $entry.TestingAssemblyVersion
        $entries += $obj
        Write-Host ("  -> {0} ({1})" -f $name, $entry.AssemblyVersion)
        $count++
    }
    if ($count -eq 0) { Write-Host "  (none)" }
    if ($filtered -gt 0) { Write-Host ("  ($filtered ignored — both API levels below thresholds ($MinDalamudApiLevel / $MinTestingDalamudApiLevel))") }
    return @{ entries = $entries; filtered = $filtered }
}

function Collect-ExternalPluginPool {
    param([Parameter(Mandatory)]$Yaml)
    # Official Dalamud plugins must never be re-published through this
    # repository. The official PluginMaster is used only as the deny-list in
    # build-pluginmaster.ps1 for filtering third-party feeds.
    if ($Yaml.externalPlugins -and @($Yaml.externalPlugins).Count -gt 0) {
        Write-Warning "external-plugins.yml entries are disabled: official Dalamud plugins are not imported or re-published."
    } else {
        Write-Host "  (official plugin imports disabled)"
    }
    return @{ entries = @(); filtered = 0 }
}

function Test-IsOriginalUpstream {
    # Heuristic tiebreaker: when the source URL we're fetching from sits on
    # the same host as the plugin's own RepoUrl, we treat that source as the
    # plugin's original upstream and prefer it over aggregator-style mirrors.
    param([string]$SourceUrl, $Entry)
    if (-not $Entry.RepoUrl -or -not $SourceUrl) { return $false }
    try {
        $source = [uri]$SourceUrl
        $repo = [uri]$Entry.RepoUrl
        if ($source.Host -ne $repo.Host) { return $false }
        $sourceParts = @($source.AbsolutePath.Trim('/') -split '/')
        $repoParts = @($repo.AbsolutePath.Trim('/') -split '/')
        return ($sourceParts.Count -ge 2 -and $repoParts.Count -ge 2 -and
            $sourceParts[0].Equals($repoParts[0], [StringComparison]::OrdinalIgnoreCase) -and
            $sourceParts[1].Equals($repoParts[1], [StringComparison]::OrdinalIgnoreCase))
    } catch { return $false }
}

function Test-IsAuthorUpstream {
    param([string]$SourceUrl, $Entry)
    if (-not $Entry.Author -or -not $SourceUrl) { return $false }
    try {
        $uri = [uri]$SourceUrl
        $parts = @($uri.AbsolutePath.Trim('/') -split '/')
        if ($parts.Count -lt 1 -or -not $parts[0]) { return $false }
        $owner = ($parts[0] -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if (-not $owner) { return $false }
        $authors = [string]$Entry.Author -split '[,;&/|]|\band\b'
        foreach ($authorValue in $authors) {
            $author = ($authorValue -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
            if ($author -and $author -notin @('unknown','anonymous') -and $owner -eq $author) { return $true }
        }
        return $false
    } catch { return $false }
}

function Select-RepoWinners {
    # Cross-repo dedup for external-repos pools: pick one winner per
    # InternalName so we never merge fields from multiple sources.
    #
    # Winner priority:
    #   1. highest effective version (max of AssemblyVersion / TestingAssemblyVersion)
    #   2. candidate whose source URL host matches its RepoUrl host
    #      (the plugin's own upstream beats third-party mirrors)
    #   3. first wins (input order)
    #
    # Dropped candidates are logged for debuggability — you can see at a
    # glance which source got picked over which.
    param($Candidates)
    $byName = @{}
    foreach ($c in $Candidates) {
        $name = $c.entry.InternalName
        if (-not $name) { continue }
        if (-not $byName.ContainsKey($name)) { $byName[$name] = @() }
        $byName[$name] += $c
    }
    $winners = @()
    $duplicateReports = @()
    if (-not $script:RepoDedupHeaderWritten) {
        Write-Host ""
        Write-Host "=== Stage 2: Deduplicate repository candidates ==="
        $script:RepoDedupHeaderWritten = $true
    }
    foreach ($name in ($byName.Keys | Sort-Object)) {
        $group = $byName[$name]
        if ($group.Count -eq 1) {
            $winners += $group[0]
            continue
        }
        $scored = foreach ($c in $group) {
            [pscustomobject]@{
                cand   = $c
                eff    = Resolve-Version $c.entry
                origin = Test-IsOriginalUpstream -SourceUrl $c.sourceUrl -Entry $c.entry
                author = Test-IsAuthorUpstream -SourceUrl $c.sourceUrl -Entry $c.entry
            }
        }
        $sorted = $scored | Sort-Object @{Expression={ $_.eff };    Descending=$true},
                                         @{Expression={ $_.origin }; Descending=$true},
                                         @{Expression={ $_.author }; Descending=$true}
        $winner = $sorted[0]
        # The winner is still selected by version first. The displayed reason
        # is the strongest matching indicator, so useful provenance signals
        # are not hidden behind HIGHEST_VERSION.
        $winnerReason = if ($winner.author) {
            'AUTHOR_MATCH'
        } elseif ($winner.origin) {
            'UPSTREAM_MATCH'
        } elseif (@($sorted | Select-Object -Skip 1 | Where-Object { [string]$_.eff -eq [string]$winner.eff }).Count -eq 0) {
            'HIGHEST_VERSION'
        } else {
            'FIRST_INPUT'
        }
        $winners += $winner.cand
        $duplicateReports += [pscustomobject]@{
            Name = $name
            Winner = $winner
            WinnerReason = $winnerReason
            Candidates = @($sorted)
        }
    }
    foreach ($report in $duplicateReports) {
        $script:ReportDeduplication += [pscustomobject]@{
            Plugin = $report.Name
            Winner = [pscustomobject]@{ Version = [string]$report.Winner.eff; Url = [string]$report.Winner.cand.sourceUrl; Reason = $report.WinnerReason }
            Candidates = @($report.Candidates | ForEach-Object {
                $candidateReason = if ($_ -eq $report.Winner) { $report.WinnerReason }
                    elseif ([string]$_.eff -lt [string]$report.Winner.eff) { 'LOWER_VERSION' }
                    elseif ($report.Winner.origin -and -not $_.origin) { 'UPSTREAM_LOST' }
                    elseif ($report.Winner.author -and -not $_.author) { 'AUTHOR_LOST' }
                    else { 'FIRST_INPUT_LOST' }
                [pscustomobject]@{ Version = [string]$_.eff; Url = [string]$_.cand.sourceUrl; Status = if ($_ -eq $report.Winner) { 'WINNER' } else { 'DROP' }; Reason = $candidateReason }
            })
        }
        Write-Host ""
        Write-Host ("  Plugin: {0}" -f $report.Name)
        Write-Host "    Status   Version       Source"
        Write-Host "    -------  ------------  ------"
        foreach ($candidate in $report.Candidates) {
            $status = if ($candidate -eq $report.Winner) { "WINNER" } else { "drop" }
            Write-Host ("    {0,-7}  v{1,-11}  {2}" -f $status, $candidate.eff, $candidate.cand.sourceUrl)
        }
    }
    return $winners
}

function Collect-RepoUrlsPool {
    # Three-phase collection for an `externalRepos:` source:
    #
    #   1. Fetch every URL, gather raw candidates (entry + sourceUrl)
    #   2. Cross-repo dedup by InternalName → one winner per plugin
    #      (see Select-RepoWinners for the rules)
    #   3. Filter winners via Test-MeetsApi
    #
    # Filtering + cache writes only happen in phase 3, so losing duplicates
    # never touch the snapshot. This stops the cache from being overwritten
    # by whichever source happened to be processed last.
    param([Parameter(Mandatory)]$Yaml, [Parameter(Mandatory)][string]$SectionLabel)
    if (-not $Yaml.externalRepos) {
        Write-Host "  (none configured)"
        return @{ entries = @(); filtered = 0; unreachable = @(); reachable = @() }
    }

    $candidates = @()
    $unreachable = @()
    $reachable = @()
    $repoReports = @()
    $seenSourceUrls = @{}
    $logged = 0
    foreach ($url in $Yaml.externalRepos) {
        if (-not $url) { continue }
        $canonicalUrl = Get-CanonicalSourceUrl $url
        if ($seenSourceUrls.ContainsKey($canonicalUrl)) {
            continue
        }
        $seenSourceUrls[$canonicalUrl] = $url
        $logged++
        # Do not use Invoke-RestMethod with -ErrorAction Stop here. Under
        # Start-Transcript PowerShell records the terminating error before the
        # catch block, which leaked a noisy PS>TerminatingError line into mail.
        # SkipHttpErrorCheck lets us classify the HTTP status ourselves without
        # emitting a transcript error record.
        $http = $null
        try {
            $http = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -SkipHttpErrorCheck
        } catch {
            $repoReports += [pscustomobject]@{ Status = "RequestError"; Count = 0; Url = $url }
            $unreachable += $url
            continue
        }
        $statusCode = [int]$http.StatusCode
        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            $statusText = if ($http.StatusDescription) { [string]$http.StatusDescription } else { "HTTP" }
            $repoReports += [pscustomobject]@{ Status = ("{0}{1}" -f $statusCode, ($statusText -replace '[^A-Za-z0-9]', '')); Count = 0; Url = $url }
            $unreachable += $url
            Write-Host ("  {0} -> {1}" -f ("{0}{1}" -f $statusCode, ($statusText -replace '[^A-Za-z0-9]', '')), $url)
            continue
        }
        $resp = $null
        try {
            # GitHub raw responses may include an UTF-8 BOM. ConvertFrom-Json
            # rejects that leading character even though the payload is valid.
            $jsonText = [string]$http.Content
            if ($jsonText.Length -gt 0 -and $jsonText[0] -eq [char]0xFEFF) {
                $jsonText = $jsonText.Substring(1)
            }
            $resp = $jsonText | ConvertFrom-Json -ErrorAction Stop
        } catch { $resp = $null }
        if (-not $resp) {
            $repoReports += [pscustomobject]@{ Status = "EMPTY"; Count = 0; Url = $url }
            $unreachable += $url
            continue
        }
        $items = if ($resp -is [System.Array]) { $resp } else { @($resp) }
        $hereCount = 0
        foreach ($e in $items) {
            if (-not ($e -and $e.InternalName)) { continue }
            if (-not $e.PSObject.Properties['__ReportSourceUrl']) {
                Add-Member -InputObject $e -NotePropertyName __ReportSourceUrl -NotePropertyValue $url
            } else { $e.__ReportSourceUrl = $url }
            $candidates += @{ entry = $e; sourceUrl = $url }
            $hereCount++
        }
        if ($hereCount -eq 0) {
            $repoReports += [pscustomobject]@{ Status = "EMPTY"; Count = 0; Url = $url }
            $unreachable += $url
        } else {
            $repoReports += [pscustomobject]@{ Status = "OK"; Count = $hereCount; Url = $url }
            $reachable += $url
        }
    }
    if ($logged -eq 0) {
        Write-Host "  (none configured)"
    } else {
        Write-Host "  Source status:"
        Write-Host "    Status       Candidates  Source"
        Write-Host "    -----------  ----------  ------"
        foreach ($report in $repoReports) {
            $script:ReportSources += [pscustomobject]@{ Status = $report.Status; Count = $report.Count; Url = $report.Url }
            Write-Host ("    {0,-11}  {1,10}  {2}" -f $report.Status, $report.Count, $report.Url)
        }
    }

    $winners = Select-RepoWinners $candidates

    Write-Host ""
    Write-Host "  === Stage 2b: Resolve versions and API levels ==="

    $entries = @()
    $filtered = 0
    $repoMissingFields = @{}
    foreach ($w in $winners) {
        $e = $w.entry
        # Some feeds publish a release-template value (for example
        # "{version}.0") instead of a real AssemblyVersion. Try to recover the
        # version from the released plugin DLL before the entry reaches any
        # generated output. This is deliberately limited to GitHub release
        # zips and remains protected by Write-Pluginmaster's final validator.
        try { [void]([System.Version]$e.AssemblyVersion) }
        catch {
            $repoMatch = [regex]::Match([string]$e.RepoUrl, 'github\.com/([^/]+)/([^/#]+)')
            $tag = $null
            if ($repoMatch.Success) {
                try {
                    $release = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/{1}/releases/latest" -f $repoMatch.Groups[1].Value, $repoMatch.Groups[2].Value) -Headers @{ 'User-Agent' = 'DalamudRepoGenerator' } -TimeoutSec 20 -ErrorAction Stop 2>$null
                    $tag = [string]$release.tag_name
                } catch { Write-Warning ("Could not resolve latest release for {0}: {1}" -f $e.InternalName, $_.Exception.Message) }
            }
            if ($tag) {
                $download = [string]$e.DownloadLinkInstall -replace '\{version\}', $tag -replace '\{tag\}', $tag
                try {
                    $tmpZip = New-TemporaryFile
                    $probe = Invoke-WebRequest -Uri $download -Method Head -UseBasicParsing -TimeoutSec 30 -SkipHttpErrorCheck
                    if ([int]$probe.StatusCode -lt 200 -or [int]$probe.StatusCode -ge 300) {
                        $statusText = if ($probe.StatusDescription) { [string]$probe.StatusDescription } else { "HTTP" }
                        Write-Host ("    {0} -> {1}" -f ("{0}{1}" -f [int]$probe.StatusCode, ($statusText -replace '[^A-Za-z0-9]', '')), $download)
                        throw "HTTP $([int]$probe.StatusCode)"
                    }
                    Invoke-WebRequest -Uri $download -OutFile $tmpZip.FullName -UseBasicParsing -TimeoutSec 30 -SkipHttpErrorCheck
                    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
                    Expand-Archive -LiteralPath $tmpZip.FullName -DestinationPath $tmpDir
                    $dll = Get-ChildItem -LiteralPath $tmpDir -Recurse -Filter ([string]$e.InternalName + '.dll') | Select-Object -First 1
                    if (-not $dll) { $dll = Get-ChildItem -LiteralPath $tmpDir -Recurse -Filter '*.dll' | Select-Object -First 1 }
                    if ($dll) {
                        $e.AssemblyVersion = ([System.Reflection.AssemblyName]::GetAssemblyName($dll.FullName).Version.ToString())
                        foreach ($field in 'DownloadLinkInstall','DownloadLinkUpdate','DownloadLinkTesting') {
                            if ($e.$field) { $e.$field = ([string]$e.$field -replace '\{version\}', $tag -replace '\{tag\}', $tag) }
                        }
                        Write-Host ("    [dll]   {0} AssemblyVersion recovered as {1}" -f $e.InternalName, $e.AssemblyVersion)
                    }
                    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $tmpZip.FullName -Force -ErrorAction SilentlyContinue
                } catch { Write-Warning ("Could not recover AssemblyVersion from {0}: {1}" -f $e.InternalName, $_.Exception.Message) }
            }
        }
        if ($null -eq $e.DalamudApiLevel -or $null -eq $e.TestingDalamudApiLevel) {
            if (-not $repoMissingFields.ContainsKey($w.sourceUrl)) { $repoMissingFields[$w.sourceUrl] = 0 }
            $repoMissingFields[$w.sourceUrl]++
        }
        if (-not (Test-MeetsApi $e)) { $filtered++; continue }
        $entries += $e
        Write-Host ("    -> {0} ({1})" -f $e.InternalName, $e.AssemblyVersion)
    }

    foreach ($u in $repoMissingFields.Keys) {
        $cnt = $repoMissingFields[$u]
        Write-Host "    (badly formatted: $cnt winner(s) missing api-level field from $u — zip fallback used)"
        Write-Warning "Badly formatted repo $u — $cnt plugin(s) missing DalamudApiLevel and/or TestingDalamudApiLevel; api level was read from the zip's embedded manifest."
    }
    if ($filtered -gt 0) {
        Write-Host "    ($filtered ignored — both API levels below thresholds ($MinDalamudApiLevel / $MinTestingDalamudApiLevel))"
    }

    return @{ entries = $entries; filtered = $filtered; unreachable = $unreachable; reachable = $reachable }
}

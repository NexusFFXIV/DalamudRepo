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

function Invoke-GhApi {
    param([string]$Path)
    $raw = gh api $Path --paginate
    if ($LASTEXITCODE -ne 0) {
        throw "gh api $Path failed with exit code $LASTEXITCODE"
    }
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
        Write-Warning "Release $($Release.tag_name) has no '$InternalName.json' asset — skipping."
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
    $tmp = $null
    try {
        $tmp = New-TemporaryFile
        Invoke-WebRequest -Uri $Url -OutFile $tmp.FullName -UseBasicParsing -TimeoutSec 30
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tmp.FullName)
        try {
            $entry = $zip.Entries | Where-Object { $_.Name -ieq "$InternalName.json" } | Select-Object -First 1
            if ($entry) {
                $reader = New-Object System.IO.StreamReader($entry.Open())
                try {
                    $manifest = $reader.ReadToEnd() | ConvertFrom-Json
                    if ($null -ne $manifest.DalamudApiLevel) { $result = [int]$manifest.DalamudApiLevel }
                } finally { $reader.Dispose() }
            }
        } finally { $zip.Dispose() }
    } catch {
        Write-Verbose "Zip fallback failed for $Url ($InternalName): $($_.Exception.Message)"
    } finally {
        if ($tmp) { Remove-Item $tmp.FullName -ErrorAction SilentlyContinue }
    }
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
                Write-Host ("    [zip-fail] {0} prod {1} (api level could not be read)" -f $Entry.InternalName, $prodAv)
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
                Write-Host ("    [zip-fail] {0} test {1} (api level could not be read)" -f $Entry.InternalName, $testAv)
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
    $entries = @()
    $filtered = 0
    $count = 0
    if (-not $Yaml.externalPlugins -or @($Yaml.externalPlugins).Count -eq 0) {
        Write-Host "  (none)"
        return @{ entries = $entries; filtered = $filtered }
    }
    $dalamudMaster = $null
    try {
        $dalamudMaster = Invoke-RestMethod -Uri $DalamudMasterUrl -UseBasicParsing -TimeoutSec 30
    } catch {
        Write-Warning "Failed to fetch $DalamudMasterUrl — external imports skipped. $($_.Exception.Message)"
        return @{ entries = $entries; filtered = $filtered }
    }
    foreach ($ext in $Yaml.externalPlugins) {
        $name = $ext.internalName
        $upstream = $dalamudMaster | Where-Object { $_.InternalName -eq $name } | Select-Object -First 1
        if (-not $upstream) {
            Write-Host "  -> $name (not found in $DalamudMasterUrl)"
            Write-Warning "External plugin '$name' not found upstream — skipping."
            continue
        }
        if (-not (Test-MeetsApi $upstream)) { $filtered++; continue }
        $entries += $upstream
        Write-Host ("  -> {0} ({1})" -f $upstream.InternalName, $upstream.AssemblyVersion)
        $count++
    }
    if ($count -eq 0) { Write-Host "  (none)" }
    if ($filtered -gt 0) { Write-Host ("  ($filtered ignored — both API levels below thresholds ($MinDalamudApiLevel / $MinTestingDalamudApiLevel))") }
    return @{ entries = $entries; filtered = $filtered }
}

function Collect-RepoUrlsPool {
    # Shared loop for any source with an `externalRepos:` list of URLs.
    param([Parameter(Mandatory)]$Yaml, [Parameter(Mandatory)][string]$SectionLabel)
    $entries = @()
    $filtered = 0
    $logged = 0
    if (-not $Yaml.externalRepos) {
        Write-Host "  (none configured)"
        return @{ entries = $entries; filtered = $filtered }
    }
    foreach ($url in $Yaml.externalRepos) {
        if (-not $url) { continue }
        Write-Host "  -> ${url}:"
        $logged++
        $resp = $null
        try {
            $resp = Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 30
        } catch {
            Write-Host "    (unreachable: $($_.Exception.Message))"
            Write-Warning "$SectionLabel repo $url unreachable: $($_.Exception.Message)"
            continue
        }
        if (-not $resp) {
            Write-Host "    (empty response)"
            Write-Warning "$SectionLabel repo $url returned empty response"
            continue
        }
        $items = if ($resp -is [System.Array]) { $resp } else { @($resp) }
        $added = 0
        $repoFiltered = 0
        # Count entries from THIS repo whose api-level fields are missing —
        # used to flag the repo as badly formatted in the log + mail.
        $repoMissingFields = 0
        foreach ($e in $items) {
            if (-not ($e -and $e.InternalName)) { continue }
            if ($null -eq $e.DalamudApiLevel -or $null -eq $e.TestingDalamudApiLevel) {
                $repoMissingFields++
            }
            if (-not (Test-MeetsApi $e)) { $repoFiltered++; $filtered++; continue }
            $entries += $e
            Write-Host ("    -> {0} ({1})" -f $e.InternalName, $e.AssemblyVersion)
            $added++
        }
        if ($added -eq 0 -and $repoFiltered -eq 0) { Write-Host "    (no usable entries)" }
        if ($repoFiltered -gt 0) { Write-Host "    ($repoFiltered ignored — both API levels below thresholds ($MinDalamudApiLevel / $MinTestingDalamudApiLevel))" }
        if ($repoMissingFields -gt 0) {
            Write-Host "    (badly formatted: $repoMissingFields plugin(s) missing api-level field — zip fallback used)"
            Write-Warning "Badly formatted repo $url — $repoMissingFields plugin(s) missing DalamudApiLevel and/or TestingDalamudApiLevel; api level was read from the zip's embedded manifest."
        }
    }
    if ($logged -eq 0) { Write-Host "  (none configured)" }
    return @{ entries = $entries; filtered = $filtered }
}

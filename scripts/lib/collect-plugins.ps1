# Part A — source collectors.
#
# Each Collect-* function takes an already-parsed yaml hashtable, fetches
# its source pool, applies the API-level filter (OR over DalamudApiLevel
# and TestingDalamudApiLevel — see Test-MeetsApi), emits structured
# logging, and returns @{ entries = @(...); filtered = <int> }.
#
# Relies on script-scope vars set by the orchestrator: $MinDalamudApiLevel,
# $MinTestingDalamudApiLevel, $DalamudMasterUrl.

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

# Some badly-formatted upstream repos omit DalamudApiLevel /
# TestingDalamudApiLevel from their pluginmaster entries. In that case we
# download the linked zip and read the API level out of the embedded
# <InternalName>.json that DalamudPackager generates inside it. Cached per
# URL so we don't re-download anything.
$script:ZipApiLevelCache = @{}
$script:ZipFallbackRescued = 0

function Get-ZipManifestApiLevel {
    param([string]$Url, [string]$InternalName)
    if (-not $Url -or -not $InternalName) { return $null }
    if ($script:ZipApiLevelCache.ContainsKey($Url)) { return $script:ZipApiLevelCache[$Url] }
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

function Test-MeetsApi {
    # An entry passes if either the stable OR the testing channel meets its
    # respective minimum API level. This way a plugin whose stable build is
    # behind but whose testing build keeps up doesn't get dropped from
    # testing-eligible scopes.
    #
    # Fallback: if a level field is missing from the upstream entry we look
    # it up in the embedded <InternalName>.json inside the corresponding zip
    # (install/update zip for prod, testing zip for testing). Rescued
    # entries bump $script:ZipFallbackRescued so the orchestrator can show
    # how many entries were saved that way.
    param($Entry)
    if (-not $Entry) { return $false }
    $prodLvl = $Entry.DalamudApiLevel
    $testLvl = $Entry.TestingDalamudApiLevel
    if ($null -eq $prodLvl) {
        $url = if ($Entry.DownloadLinkInstall) { $Entry.DownloadLinkInstall } else { $Entry.DownloadLinkUpdate }
        $prodLvl = Get-ZipManifestApiLevel -Url $url -InternalName $Entry.InternalName
        if ($null -ne $prodLvl) { $script:ZipFallbackRescued++ }
    }
    if ($null -eq $testLvl) {
        $testLvl = Get-ZipManifestApiLevel -Url $Entry.DownloadLinkTesting -InternalName $Entry.InternalName
        if ($null -ne $testLvl) { $script:ZipFallbackRescued++ }
    }
    $prodOk = $false
    $testOk = $false
    if ($null -ne $prodLvl) {
        try { $prodOk = ([int]$prodLvl) -ge $MinDalamudApiLevel } catch {}
    }
    if ($null -ne $testLvl) {
        try { $testOk = ([int]$testLvl) -ge $MinTestingDalamudApiLevel } catch {}
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

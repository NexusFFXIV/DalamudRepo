# Offline repository lifecycle helpers.

$script:OfflineReposPath = ""
$script:OfflineStatePath = ""
$script:OfflineRepos = @{}
$script:OfflineState = @{}
$script:OfflineChanges = @()
$script:OfflineGraceRuns = 10

function Expand-OfflineUrls {
    param([object[]]$Values)

    # Older runs could serialize a YAML sequence as one concatenated scalar.
    # Split such legacy values at every embedded URL before using or saving
    # the archive again.
    foreach ($value in $Values) {
        if ($null -eq $value) { continue }
        foreach ($part in [regex]::Split(([string]$value).Trim(), '(?=https?://)')) {
            $url = $part.Trim()
            if (-not $url) { continue }
            if ($url -notmatch '^https?://[^\s]+$' -or $url -match 'https?://.*https?://') {
                Write-Warning "Ignoring malformed offline repository URL: $url"
                continue
            }
            $url
        }
    }
}

function Initialize-OfflineRepos {
    param(
        [Parameter(Mandatory)][string]$ReposPath,
        [Parameter(Mandatory)][string]$StatePath,
        [int]$GraceRuns = 10
    )
    $script:OfflineReposPath = $ReposPath
    $script:OfflineStatePath = $StatePath
    $script:OfflineGraceRuns = [Math]::Max(1, $GraceRuns)
    $script:OfflineRepos = @{}
    $script:OfflineState = @{}
    $script:OfflineChanges = @()

    if (Test-Path -LiteralPath $ReposPath) {
        try {
            $doc = Get-Content -LiteralPath $ReposPath -Raw -Encoding UTF8 | ConvertFrom-Yaml
            if ($doc -and $doc.offlineRepos) {
                if ($doc.offlineRepos -is [System.Collections.IDictionary]) {
                    foreach ($section in $doc.offlineRepos.Keys) {
                        $script:OfflineRepos[[string]$section] = @(Expand-OfflineUrls -Values @($doc.offlineRepos[$section]) | Sort-Object -Unique)
                    }
                } else {
                    foreach ($section in $doc.offlineRepos.PSObject.Properties) {
                        $script:OfflineRepos[$section.Name] = @(Expand-OfflineUrls -Values @($section.Value) | Sort-Object -Unique)
                    }
                }
            }
        } catch {
            Write-Warning "Could not read $ReposPath — starting with an empty offline archive. $($_.Exception.Message)"
        }
    }
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $loaded = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            if ($loaded) { $script:OfflineState = $loaded }
        } catch {
            Write-Warning "Could not read $StatePath — starting failure counters from zero. $($_.Exception.Message)"
        }
    }

}

function Get-OfflineKey {
    param([string]$Section, [string]$Url)
    return "$Section|$Url"
}

function Get-HttpErrorLabel {
    param([Parameter(Mandatory)]$ErrorRecord)
    $response = $ErrorRecord.Exception.Response
    if ($response -and $response.StatusCode) {
        return ("{0}{1}" -f [int]$response.StatusCode, $response.StatusCode.ToString())
    }
    return "RequestError"
}

function Get-OfflineUrls {
    param([Parameter(Mandatory)][string]$Section)
    if ($script:OfflineRepos.ContainsKey($Section)) {
        return @(Expand-OfflineUrls -Values @($script:OfflineRepos[$Section]) | Sort-Object -Unique)
    }
    return @()
}

function Get-OfflineSectionForUrl {
    param([Parameter(Mandatory)][string]$Url)
    foreach ($section in $script:OfflineRepos.Keys) {
        if (@($script:OfflineRepos[$section]) -contains $Url) { return $section }
    }
    return $null
}

function Test-OfflineDisabled {
    param([Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Url)
    $key = Get-OfflineKey $Section $Url
    if (-not $script:OfflineState.ContainsKey($key)) { return $false }
    $entry = $script:OfflineState[$key]
    return ($entry -is [System.Collections.IDictionary] -and $entry.ContainsKey('disabled') -and $entry.disabled -eq $true)
}

function Test-RepositoryReachable {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $http = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -SkipHttpErrorCheck
        if ([int]$http.StatusCode -lt 200 -or [int]$http.StatusCode -ge 300) {
            $label = "{0}{1}" -f [int]$http.StatusCode, (($http.StatusDescription -as [string]) -replace '[^A-Za-z0-9]', '')
            Write-Host ("  {0} -> {1}" -f $label, $Url)
            return $false
        }
        $response = $http.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        $items = if ($response -is [System.Array]) { @($response) } else { @($response) }
        $valid = @($items | Where-Object { $_ -and $_.InternalName })
        if ($valid.Count -gt 0) { return $true }
        Write-Host ("  EmptyResponse -> {0}" -f $Url)
        return $false
    } catch {
        Write-Host ("  {0} -> {1}" -f (Get-HttpErrorLabel $_), $Url)
        return $false
    }
}

function Set-UrlInSourceFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][bool]$Present
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $text = [IO.File]::ReadAllText($Path)
    $escaped = [regex]::Escape($Url)
    $pattern = "(?m)^[ \t]*-[ \t]*$escaped[ \t]*(?:#.*)?(?:\r?\n|$)"
    if ($Present) {
        if ($text -match $pattern) { return }
        $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $text = $text.TrimEnd("`r", "`n") + $newline + "  - $Url" + $newline
    } else {
        $text = [regex]::Replace($text, $pattern, "")
    }
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
}

function Save-OfflineRepos {
    $lines = @(
        "# Repositories temporarily removed after repeated failed probes.",
        "# URLs are automatically restored to their original source when reachable again.",
        "offlineRepos:"
    )
    $sections = @('external-repos', 'external-repos-gen') + @($script:OfflineRepos.Keys | Where-Object { $_ -notin @('external-repos', 'external-repos-gen') } | Sort-Object)
    foreach ($section in $sections) {
        $urls = @()
        if ($script:OfflineRepos.ContainsKey($section)) {
            $urls = @(Expand-OfflineUrls -Values @($script:OfflineRepos[$section]) | Sort-Object -Unique)
        }
        if ($urls.Count -eq 0) {
            $lines += "  ${section}: []"
        } else {
            $lines += "  ${section}:"
            foreach ($url in $urls) { $lines += "    - $url" }
        }
    }
    $content = ($lines -join "`n") + "`n"
    $old = if (Test-Path -LiteralPath $script:OfflineReposPath) { [IO.File]::ReadAllText($script:OfflineReposPath) } else { "" }
    if ($old -ne $content) { [IO.File]::WriteAllText($script:OfflineReposPath, $content, (New-Object Text.UTF8Encoding($false))) }
}

function Save-OfflineState {
    $sorted = [ordered]@{}
    $orderedKeys = $script:OfflineState.Keys | Sort-Object `
        @{ Expression = { if ($script:OfflineState[$_].disabled -eq $true) { 1 } else { 0 } } }, `
        @{ Expression = { [int]$script:OfflineState[$_].failures } }, `
        @{ Expression = { [string]$_ } }
    foreach ($key in $orderedKeys) { $sorted[$key] = $script:OfflineState[$key] }
    $parent = Split-Path $script:OfflineStatePath -Parent
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($script:OfflineStatePath, (($sorted | ConvertTo-Json -Depth 5) + "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Restore-OfflineRepository {
    param([string]$Section, [string]$Url, [string]$SourcePath)
    # Add the URL back to its source before removing it from the archive. If a
    # run is interrupted between these operations, the next run sees a safe
    # duplicate and can complete the transition without data loss.
    Set-UrlInSourceFile -Path $SourcePath -Url $Url -Present $true
    $urls = @(Get-OfflineUrls $Section | Where-Object { $_ -ne $Url })
    $script:OfflineRepos[$Section] = $urls
    Save-OfflineRepos
    $key = Get-OfflineKey $Section $Url
    $script:OfflineState.Remove($key)
    $script:OfflineChanges += "RESTORED [$Section] $Url"
}

function Register-OfflineFailure {
    param(
        [string]$Section,
        [string]$Url,
        [string]$SourcePath,
        [switch]$AlreadyArchived
    )
    $key = Get-OfflineKey $Section $Url
    $entry = if ($script:OfflineState.ContainsKey($key)) { $script:OfflineState[$key] } else { [ordered]@{ failures = 0; disabled = $false } }
    $now = [DateTime]::UtcNow.ToString('o')
    # Keep the first observed failure permanently so the archive can show how
    # long a repository has been failing. Existing entries are migrated in the
    # tracked state file; new entries get the timestamp on their first probe.
    if (-not $entry.firstFailure) { $entry.firstFailure = $now }
    $entry.failures = [int]$entry.failures + 1
    $entry.lastFailure = $now
    $script:OfflineState[$key] = $entry
    # Persist each probe result so a cancelled run does not reset the grace counter.
    Save-OfflineState
    # Recovery probes already belong to the archive. Keep counting and update
    # timestamps, but do not repeat the archive transition on every run.
    if ($AlreadyArchived -or $entry.failures -lt $script:OfflineGraceRuns) { return }

    # Persist the archive first. If removal from the source is interrupted,
    # the next run safely filters the duplicate until this transition finishes.
    $script:OfflineRepos[$Section] = @((Get-OfflineUrls $Section) + $Url | Sort-Object -Unique)
    Save-OfflineRepos
    Set-UrlInSourceFile -Path $SourcePath -Url $Url -Present $false
    $script:OfflineChanges += "OFFLINE [$Section] $Url"
}

function Register-OfflineSuccess {
    param([string]$Section, [string]$Url)
    $key = Get-OfflineKey $Section $Url
    if ($script:OfflineState.ContainsKey($key)) { $script:OfflineState.Remove($key) }
}

function Write-OfflineSummary {
    if ($script:OfflineChanges.Count -eq 0) { return }
    Write-Host ""
    Write-Host "Offline repository changes:"
    foreach ($change in $script:OfflineChanges) { Write-Host "  $change" }
}

# Offline repository lifecycle helpers.

$script:OfflineReposPath = ""
$script:OfflineStatePath = ""
$script:OfflineRepos = @{}
$script:OfflineState = @{}
$script:OfflineChanges = @()
$script:OfflineGraceRuns = 10

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
                foreach ($section in $doc.offlineRepos.PSObject.Properties) {
                    $script:OfflineRepos[$section.Name] = @($section.Value)
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

function Get-OfflineUrls {
    param([Parameter(Mandatory)][string]$Section)
    if ($script:OfflineRepos.ContainsKey($Section)) { return @($script:OfflineRepos[$Section]) }
    return @()
}

function Test-RepositoryReachable {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $response = Invoke-RestMethod -Uri $Url -UseBasicParsing -TimeoutSec 30
        return ($null -ne $response)
    } catch {
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
        if ($script:OfflineRepos.ContainsKey($section)) { $urls = @($script:OfflineRepos[$section] | Sort-Object -Unique) }
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
    foreach ($key in ($script:OfflineState.Keys | Sort-Object)) { $sorted[$key] = $script:OfflineState[$key] }
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
    param([string]$Section, [string]$Url, [string]$SourcePath)
    $key = Get-OfflineKey $Section $Url
    $entry = if ($script:OfflineState.ContainsKey($key)) { $script:OfflineState[$key] } else { [ordered]@{ failures = 0 } }
    $entry.failures = [int]$entry.failures + 1
    $entry.lastFailure = [DateTime]::UtcNow.ToString('o')
    $script:OfflineState[$key] = $entry
    # Persist each probe result so a cancelled run does not reset the grace counter.
    Save-OfflineState
    if ($entry.failures -lt $script:OfflineGraceRuns) { return }

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

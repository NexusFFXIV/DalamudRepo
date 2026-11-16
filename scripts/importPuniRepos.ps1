<#
.SYNOPSIS
  Discover Puni.sh author repositories and return a runtime source definition.

.DESCRIPTION
  Puni.sh publishes a directory of author pages. Each author page has a
  stable JSON feed at https://puni.sh/api/repository/<author>. The directory
  is the source of truth for the author slugs; this script deliberately does
  not maintain a hand-written list of Puni repositories.

  The provider feed at https://love.puni.sh/ment.json is included explicitly:
  it contains core plugins that are intentionally published without a normal
  author directory entry.
#>
param(
    [string]$DirectoryUrl = 'https://puni.sh/directory/repositories',
    [string]$UserAgent = 'NexusFFXIV-DalamudRepo/1.0'
)

$ErrorActionPreference = 'Stop'

function Get-Text([string]$Url) {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -UserAgent $UserAgent -SkipHttpErrorCheck
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
        throw "HTTP $($response.StatusCode) while reading $Url"
    }
    return [string]$response.Content
}

function Get-Json([string]$Url) {
    try {
        $text = Get-Text $Url
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        return $text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Could not read Puni repository feed $Url : $($_.Exception.Message)"
        return $null
    }
}

$html = Get-Text $DirectoryUrl
$slugs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($match in [regex]::Matches($html, 'href=["'']/directory/([^"''/?#>]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $slug = [uri]::UnescapeDataString($match.Groups[1].Value)
    if ($slug -and $slug -notin @('repositories', 'puni.sh')) { [void]$slugs.Add($slug) }
}
if ($slugs.Count -eq 0) { throw "No Puni author pages found at $DirectoryUrl" }

$urls = @($slugs | Sort-Object | ForEach-Object { "https://puni.sh/api/repository/$($_)" })
# The provider feed is intentionally outside the author directory.
$urls += 'https://love.puni.sh/ment.json'

Write-Host ("Puni discovery: {0} author feeds + provider feed" -f $slugs.Count)
[pscustomobject]@{
    Name = 'puni-repos-runtime'
    Type = 'external-repos'
    Out = $null
    IncludeInUnion = $true
    Priority = 100
    ExternalRepos = @($urls)
}

<#!
.SYNOPSIS
  Create a Shields.io endpoint document describing report freshness.
##>
param(
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][string]$OutputPath
)

$report = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
$generated = [DateTimeOffset]::Parse([string]$report.GeneratedAt).ToUniversalTime()
$now = [DateTimeOffset]::UtcNow
$age = $now - $generated
$builtText = $generated.ToString('yyyy-MM-dd HH:mm') + ' UTC'

# The scheduled workflow runs at 00:00 UTC. This is deliberately an estimate:
# release, source-change and manual runs can refresh the report earlier.
$nextRefresh = [DateTimeOffset]::new($now.UtcDateTime.Date.AddDays(1), [TimeSpan]::Zero)
$untilNext = $nextRefresh - $now.UtcDateTime
$nextText = if ($untilNext.TotalHours -lt 1) { 'next <1h' } else { 'next {0}h' -f [math]::Floor($untilNext.TotalHours) }

if ($age.TotalHours -le 30) {
    $state = 'fresh'
    $color = 'brightgreen'
} elseif ($age.TotalHours -le 48) {
    $state = 'aging'
    $color = 'yellow'
} else {
    $state = 'outdated'
    $color = 'red'
}

[pscustomobject]@{
    schemaVersion = 1
    label = 'Build report'
    # Shields reads this file as a static endpoint. Show the immutable build
    # timestamp instead of an age that would become stale immediately after
    # the workflow finishes.
    message = '{0} · built {1} · {2}' -f $state, $builtText, $nextText
    color = $color
    generatedAt = $generated.ToString('o')
    nextRefreshAt = ([DateTimeOffset]$nextRefresh).ToString('o')
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

# Part B — output builders: dedup, write, summary.

function Resolve-Version {
    # Effective version for cross-source winner selection: max of
    # AssemblyVersion / TestingAssemblyVersion. A source that ships only a
    # newer testing build still wins dedup against a source whose stable is
    # older — the user explicitly wanted this so a single source's "100%
    # truth" view drives the choice, not just the prod channel.
    param($Entry)
    $av  = try { [System.Version]$Entry.AssemblyVersion }        catch { [System.Version]"0.0.0.0" }
    $tav = try { [System.Version]$Entry.TestingAssemblyVersion } catch { [System.Version]"0.0.0.0" }
    if ($tav -gt $av) { return $tav } else { return $av }
}

function Get-Deduped {
    # Group by InternalName, pick the entry with the highest AssemblyVersion.
    param($Entries)
    $arr = @(@($Entries) | Where-Object { $null -ne $_ })
    if ($arr.Count -eq 0) { return @() }
    $result = @()
    foreach ($g in ($arr | Group-Object -Property InternalName)) {
        $winner = $g.Group | Sort-Object -Property { Resolve-Version $_ } -Descending | Select-Object -First 1
        $result += $winner
    }
    return $result
}

function Write-Pluginmaster {
    # Writes a clean JSON array. Empty / null-only input → "[]" (avoids the
    # "[ null ]" trap from ConvertTo-Json's single-element wrap on $null).
    param($Entries, [string]$Path)
    $arr = @(@($Entries) | Where-Object { $null -ne $_ })
    if ($arr.Count -eq 0) {
        Set-Content -Path $Path -Value "[]`n" -NoNewline -Encoding UTF8
        return
    }
    $json = $arr | ConvertTo-Json -Depth 10
    if ($arr.Count -eq 1) { $json = "[`n" + ($json -replace '(?ms)^', '  ') + "`n]" }
    Set-Content -Path $Path -Value $json -Encoding UTF8 -NoNewline
    Add-Content -Path $Path -Value "`n" -NoNewline
}

function Build-FullUnion {
    # Deduped union of the three curated pools (nexus + external + common).
    # The auto-discovered gen pool is intentionally NOT folded in here — gen
    # gets its own standalone gen-repos.json.
    param($NexusEntries, $ExternalPluginEntries, $CommonRepoEntries)
    Write-Host ""
    Write-Host "Deduping (full pluginmaster, gen excluded):"
    $all = @($NexusEntries) + @($ExternalPluginEntries) + @($CommonRepoEntries)
    $before = @($all).Count
    $result = @()
    foreach ($g in ($all | Group-Object -Property InternalName)) {
        $sorted = $g.Group | Sort-Object -Property { Resolve-Version $_ } -Descending
        $winner = $sorted | Select-Object -First 1
        $others = $g.Count - 1
        $suffix = if ($others -gt 0) { "$others other version$(if ($others -ne 1) { 's' }) in list" } else { "unique" }
        Write-Host ("Added {0} ({1}) ({2})" -f $winner.InternalName, $winner.AssemblyVersion, $suffix)
        $result += $winner
    }
    return @{ entries = $result; before = $before; after = @($result).Count }
}

function Write-BuildSummary {
    param(
        $Outputs  # array of @{ name; count; enabled; extra? }
    )
    Write-Host ""
    Write-Host "Summary:"
    foreach ($o in $Outputs) {
        $disabled = if (-not $o.enabled) { " (disabled — file not written)" } else { "" }
        $extra    = if ($o.extra) { " " + $o.extra } else { "" }
        Write-Host ("  {0,-40} {1} entries{2}{3}" -f $o.name, $o.count, $extra, $disabled)
    }
}

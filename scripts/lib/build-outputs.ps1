# Part B — output builders: dedup, republish gate, write, summary.

# ─── Republish gate ──────────────────────────────────────────────────────────
#
# Upstream download counters tick constantly, and every tick used to rewrite an
# entry and open a refresh PR. Before this gate existed, 27 of 27 consecutive
# bot commits carried DownloadCount changes and nothing else in ~60% of them —
# the "no changes, nothing to commit" branch of the workflow had literally never
# been taken.
#
# The rule: an entry whose ONLY difference from the one we already published is
# a volatile field is not republished at all. Anything else republishes the
# entry in full, fresh counter included.
#
# Implemented by reusing the previously published object VERBATIM rather than by
# stripping or merging fields. That matters for correctness, not just diff size:
# a field-merge could pair an old download link with a new version, while
# verbatim reuse cannot produce a mixed object by construction. It is also
# textually a no-op, because the published file is already a fixed point of
# ConvertTo-Json ∘ ConvertFrom-Json — it was produced by Write-Pluginmaster.

# Fields whose value alone must never justify republishing an entry. Adding one
# here does not change the rule; the rule stays "if only these moved, keep what
# we already published".
$script:VolatileEntryFields = @('DownloadCount')

# Per-path memo of the previously published entries, plus counters for the
# build summary.
$script:PublishedCache = @{}
$script:FrozenTotal = 0
$script:ForceMatched = @{}

function Get-EntryFingerprint {
    # Canonical JSON of one entry with the volatile fields removed.
    #
    # Key order is deliberately PRESERVED, not sorted: two entries count as the
    # same only when they would serialize to identical text, which is exactly
    # what makes reusing the old object an empty diff. Sorting would weaken that
    # guarantee and buy nothing — key reordering does not occur in these diffs.
    #
    # ConvertTo-Json rather than a hand-built string on purpose: it is
    # culture-invariant, renders every integer width identically, and keeps
    # nested arrays intact. That last point is why this is not a per-field
    # comparison loop — in PowerShell, @('a','b') -eq @('a','b') yields an empty
    # array, which is falsy, so a naive loop would report "changed" for every
    # entry that has a Tags array. It would simultaneously MISS real type flips,
    # since $true -eq 'true' and '15' -eq 15 are both true.
    #
    # Type-lenience is exactly right here: [int64]49 and [int32]49 both render as
    # 49 and compare equal (our LastUpdate is Int64, the previously published one
    # is a JSON round-trip), while a genuine 49 -> "49" flip is a real text change
    # and is treated as one.
    #
    # Corollary worth knowing: a false "changed" verdict is harmless — the new
    # entry gets taken and the file does not change anyway. Only a false
    # "unchanged" could hide something, and that requires identical canonical
    # JSON modulo the volatile fields, i.e. nothing to publish.
    #
    # Never put a non-JSON primitive into an entry. A raw DateTime would
    # serialize differently on the two sides and mismatch forever, i.e. churn
    # forever. collect-plugins.ps1 is correct here (ToUnixTimeSeconds).
    param($Entry)
    if ($null -eq $Entry) { return $null }

    $proj = [ordered]@{}
    if ($Entry -is [System.Collections.IDictionary]) {
        foreach ($k in $Entry.Keys) {
            if ($script:VolatileEntryFields -contains [string]$k) { continue }
            $proj[[string]$k] = $Entry[$k]
        }
    } else {
        foreach ($prop in $Entry.PSObject.Properties) {
            if ($prop.MemberType -notin 'NoteProperty', 'Property') { continue }
            if ($script:VolatileEntryFields -contains $prop.Name) { continue }
            $proj[$prop.Name] = $prop.Value
        }
    }
    # Real max depth is 3 (entry -> Tags/ImageUrls -> string); 20 is headroom.
    return ($proj | ConvertTo-Json -Depth 20 -Compress)
}

function Get-PublishedEntryMap {
    # Previously published content of one output file, keyed by InternalName.
    #
    # Memoized per path and always consulted before that path is written this
    # run, so the map is the pre-run state. The memo also covers the case where
    # two sources/*.yml ever declare the same `out:` — nothing forbids it, and
    # without the memo the second pool would read what the first just wrote.
    #
    # Missing / empty / unparsable file yields an empty map: every entry then
    # looks new, you get one noisy run, and it is quiet again afterwards. Must
    # never throw — the orchestrator runs with $ErrorActionPreference = 'Stop'.
    param([string]$Path)
    if ($script:PublishedCache.ContainsKey($Path)) { return $script:PublishedCache[$Path] }

    $map = @{}
    if (Test-Path -LiteralPath $Path) {
        try {
            # -Encoding UTF8 explicitly: these files are BOM-less UTF-8, and
            # Get-Content's default encoding is host-dependent. Reading them as
            # ANSI mangles non-Latin text (one upstream changelog contains CJK),
            # which would make that entry's fingerprint never match and churn
            # forever. Write-Pluginmaster writes UTF8, so read UTF8.
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                # Assign before wrapping: Windows PowerShell 5.1 passes a parsed
                # JSON array through the pipeline as ONE object, so
                # @($raw | ConvertFrom-Json) would collapse to a single element
                # holding the whole array. pwsh 7 enumerates. Assigning first
                # behaves the same on both.
                $parsed = $raw | ConvertFrom-Json
                foreach ($entry in @($parsed)) {
                    if ($null -ne $entry -and $entry.InternalName) {
                        $map[[string]$entry.InternalName] = $entry
                    }
                }
            }
        } catch {
            Write-Warning ("Could not read previously published '{0}' ({1}) — every entry will be treated as changed this run." -f `
                $Path, $_.Exception.Message)
        }
    }
    $script:PublishedCache[$Path] = $map
    return $map
}

function Resolve-PublishedEntries {
    # Replaces a new entry with the one already published when the two differ
    # only in volatile fields.
    #
    # This is a LOOKUP over the new entries, never a merge with the old file — an
    # entry that vanished upstream must stay vanished, and its deletion must show
    # up in the diff.
    param(
        $NewEntries,
        [hashtable]$Published,
        [string[]]$ForceNames = @(),
        [switch]$ForceAll
    )
    $out = @()
    $frozen = 0
    foreach ($entry in @($NewEntries)) {
        if ($null -eq $entry) { continue }
        $name = if ($entry.InternalName) { [string]$entry.InternalName } else { $null }

        if ($ForceAll -or -not $name -or -not $Published.ContainsKey($name)) {
            $out += $entry
            continue
        }
        if ($ForceNames -contains $name) {
            $script:ForceMatched[$name] = $true
            Write-Host ("    [force] {0} republished in full (release dispatch)" -f $name)
            $out += $entry
            continue
        }

        $previous = $Published[$name]
        if ((Get-EntryFingerprint $previous) -eq (Get-EntryFingerprint $entry)) {
            # Verbatim reuse — the emitted text for this entry is unchanged.
            $out += $previous
            $frozen++
            if ("$($previous.DownloadCount)" -ne "$($entry.DownloadCount)") {
                Write-Host ("    [keep]  {0} (DownloadCount {1} -> {2} not adopted)" -f `
                    $name, $previous.DownloadCount, $entry.DownloadCount)
            }
        } else {
            $out += $entry
        }
    }
    if ($frozen -gt 0) {
        $script:FrozenTotal += $frozen
        Write-Host ("  ({0} entr{1} kept as published — only volatile fields moved)" -f `
            $frozen, $(if ($frozen -eq 1) { 'y' } else { 'ies' }))
    }
    return @{ entries = $out; frozen = $frozen }
}

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
    #
    # Entries are sorted by InternalName here, the single choke point for all
    # five outputs. The A-Z order these files already have is NOT produced by
    # the pipeline — it falls out of Group-Object's key ordering under pwsh 7,
    # which is what CI runs. Windows PowerShell 5.1 preserves input order
    # instead, and Select-RepoWinners iterates a plain hashtable in bucket
    # order, so nothing upstream of here guarantees anything. Pinning the order
    # means a change in that behaviour — or a refactor away from Group-Object —
    # cannot reshuffle a 155-entry file in one commit.
    #
    # Deliberately the culture-aware default comparer, not StringComparer
    # .Ordinal: the committed files sort AntiAfkKick-Dalamud before ARDiscard,
    # which is culture order. Switching to ordinal would rewrite every output
    # once for no benefit.
    param($Entries, [string]$Path)
    $arr = @(@($Entries) | Where-Object { $null -ne $_ } | Sort-Object -Property InternalName)
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
        $frozen   = if ($o.frozen) { " [{0} kept as published]" -f $o.frozen } else { "" }
        Write-Host ("  {0,-40} {1} entries{2}{3}{4}" -f $o.name, $o.count, $frozen, $extra, $disabled)
    }

    # Without this line, "the run found nothing to publish" and "the republish
    # gate swallowed a real change" look identical in the build log.
    if ($script:FrozenTotal -gt 0) {
        Write-Host ""
        Write-Host ("Kept as published (only volatile fields moved): {0}" -f $script:FrozenTotal)
        Write-Host ("  Volatile fields: {0}" -f ($script:VolatileEntryFields -join ', '))
    }
}

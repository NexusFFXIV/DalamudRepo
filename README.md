# NexusFFXIV — Dalamud Plugin Repository

**A custom Dalamud plugin repository for FINAL FANTASY XIV — host for [NexusFFXIV](https://github.com/NexusFFXIV) plugins plus a curated mirror of third-party Dalamud repos.**

[![Update pluginmaster](https://github.com/NexusFFXIV/DalamudRepo/actions/workflows/update.yml/badge.svg)](https://github.com/NexusFFXIV/DalamudRepo/actions/workflows/update.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Dalamud API](https://img.shields.io/badge/Dalamud_API-15-9D5BFF)](https://github.com/goatcorp/Dalamud)
[![All plugins](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/all-repo.json&query=$.length&label=all%20plugins&color=brightgreen)](https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/all-repo.json)
[![NexusFFXIV](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/pluginmaster.json&query=$.length&label=nexusffxiv&color=blue)](https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/pluginmaster.json)
[![External](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/external-repo.json&query=$.length&label=external&color=orange)](https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/external-repo.json)
[![Common repos](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/common-repo.json&query=$.length&label=common%20repos&color=yellow)](https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/common-repo.json)
[![Gen repos](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/gen-repo.json&query=$.length&label=gen%20repos&color=lightgrey)](https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/gen-repo.json)

> [!TIP]
> ### 🎮 Quick install
>
> In Dalamud open **Settings → Experimental → Custom Plugin Repositories**, paste the URL below, tick Enabled, hit Save:
>
> ```
> https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/all-repo.json
> ```
>
> Then open `/xlplugins`, switch to **All Plugins**, and you'll see every plugin from this repo. Want a narrower scope (e.g. only NexusFFXIV plugins)? See [Available scopes](#available-scopes) below.

## Overview

This repo publishes four pluginmaster manifests that the [Dalamud](https://github.com/goatcorp/Dalamud) plugin installer can read. Each one is scoped differently — pick the URL that matches what you want to see in Dalamud.

## 📥 Install (as a player)

1. Open Dalamud's **Settings → Experimental** tab (the ⚠️ icon in the Settings window).
2. Under **Custom Plugin Repositories**, paste one of the URLs from [Available scopes](#available-scopes) below.
3. Tick the new entry as **Enabled** and hit Save.
4. Open `/xlplugins`, switch to **All Plugins**, search for the plugin you want, click Install.

> [!NOTE]
> You can add several scope URLs at once — Dalamud merges them. To get *everything*, just add `all-repo.json`.

## Available scopes

Hover over a code block and click the copy icon (top-right) to grab the URL.

### NexusFFXIV plugins (default) ![](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/pluginmaster.json&query=$.length&label=plugins&color=blue)

```
https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/pluginmaster.json
```

Only plugins built by NexusFFXIV (currently PlayerNexusTracker).

### External plugins ![](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/external-repo.json&query=$.length&label=plugins&color=orange)

```
https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/external-repo.json
```

Third-party plugins imported by `InternalName` from Dalamud's official pluginmaster.

### Common (third-party) repos ![](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/common-repo.json&query=$.length&label=plugins&color=yellow)

```
https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/common-repo.json
```

Plugins from popular community-maintained Dalamud repos (the curated `external-repos.yml` list), deduped by `InternalName` (highest `AssemblyVersion` wins).

### All (curated) ![](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/all-repo.json&query=$.length&label=plugins&color=brightgreen)

```
https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/all-repo.json
```

Curated union: NexusFFXIV plugins + external plugins + common (curated) third-party repos, deduped end-to-end. **Does not include the auto-discovered `gen-repo.json` pool** — opt into that separately below if you want the wider catalogue.

### Auto-discovered (gen) ![](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/gen-repo.json&query=$.length&label=plugins&color=lightgrey)

```
https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/gen-repo.json
```

**Standalone repo built from auto-discovered entries** — a much larger list of third-party Dalamud repos gathered from community aggregators + GitHub code-search. Quality and reachability vary; broken entries log a warning and are skipped. Subscribe in addition to the curated scopes if you want maximum coverage.

### Testing builds (opt-in)

Tick **Settings → Experimental → Get plugin testing builds** to surface pre-release versions when available. Stable users continue to see only stable releases.

## Available plugins

Auto-derived from `plugins.yml`. As of now:

- [**PlayerNexusTracker**](https://github.com/NexusFFXIV/PlayerNexusTracker) — Track players you meet in FFXIV.

## How this repo works

```
pluginmaster.json                 ← Dalamud-facing, NexusFFXIV plugins only (default)
external-repo.json                     ← Dalamud-facing, external-plugins.yml only
common-repo.json                 ← Dalamud-facing, external-repos.yml only (curated, commonly used)
gen-repo.json                    ← Dalamud-facing, external-repos-gen.yml only (auto-discovered)
all-repo.json                          ← Dalamud-facing, curated union (gen excluded)

config.yml                        ← build config: min Dalamud API + per-source toggles
plugins.yml                       ← config: our own plugin repos
external-plugins.yml              ← config: third-party plugins to re-publish by name
external-repos.yml                ← config: third-party Dalamud repos to mirror (curated)
external-repos-gen.yml            ← config: third-party Dalamud repos (auto-discovered)

scripts/build-pluginmaster.ps1    ← rebuild script — emits all four .json files
.github/workflows/update.yml      ← runs the script, opens a PR when any output changed
```

All five `.json` files are **generated**, not edited by hand. The workflow runs on:

- `repository_dispatch` events emitted by each plugin's release workflow (immediate update on tag push)
- `workflow_dispatch` (manual trigger)
- A 6-hourly cron (safety net if a dispatch fails)

The diff check covers all five outputs — a change in any single file triggers one combined refresh PR.

### config.yml — build configuration

Two knobs:

- **`minDalamudApiLevel`** (default `15`) — entries with `DalamudApiLevel` lower than this are dropped from **every** source (nexus, external, common-repos, gen-repos). Missing field counts as too low. Filtered counts are summarised in the build log; individual entries are not listed.
- **`repos.<source>`** — set to `false` to skip fetching from that source AND skip writing its output file. The on-disk file is left at its last committed state so subscribers don't see a sudden empty repo. Available toggles: `nexus`, `external`, `commonRepos`, `genRepos`, `all`. Defaults to `true` for all keys.

### plugins.yml — our own plugins

For each entry, the script fetches the latest stable + latest pre-release from GitHub, downloads the embedded `<Plugin>.json` manifest from the release assets, and merges the data into `pluginmaster.json`. Stable and testing pointers are reconciled per the Dalamud-spec semantics:

| Plugin's release state | `DownloadLinkInstall` | `DownloadLinkTesting` |
|---|---|---|
| Only stable | → stable | → stable (testers see the same build) |
| Stable + newer pre-release | → stable (unchanged) | → pre-release |
| Pre-release older than stable | → stable | → stable (no downgrade for testers) |
| Only pre-release (never stable) | → pre-release | → pre-release; entry marked `IsTestingExclusive: true` |

### external-plugins.yml — single third-party plugins

Each entry names a plugin by its `InternalName`. The script looks it up in Dalamud's official pluginmaster (`https://kamori.goats.dev/Plugin/PluginMaster`) and copies the entry verbatim — download links keep pointing at the upstream CDN, `IconUrl` stays with the upstream author. Lands in `external-repo.json` and `all-repo.json`.

### external-repos.yml — third-party Dalamud repos

Each entry is a URL to another Dalamud repo's `pluginmaster.json` (or single-plugin manifest). The script fetches each, folds every entry into the pool, and writes them to `common-repo.json` (and `all-repo.json`).

When the same `InternalName` appears in multiple sources — whether two external repos, or `external-repos.yml` overlapping with `external-plugins.yml`, or our own `plugins.yml` — the entry with the **highest `AssemblyVersion`** wins. Missing or unparseable versions sort below valid ones.

Unreachable repos (down, bad JSON, rate-limited) log a warning and are skipped; the rest of the rebuild keeps going.

### external-repos-gen.yml — auto-discovered third-party repos

Same format and handling as `external-repos.yml`, but **generated** by trawling community aggregators (Akurosia's `MyCustomDalamudPluginRepoCollection`, the Puni.sh directory, GitHub code-search for the `TestingDalamudApiLevel` / `Punchline` fields). Hundreds of URLs in one file; the curated list stays small.

Entries from this file land in **`gen-repo.json` only** — they are **not** folded into `all-repo.json`. Users who want this wider catalogue subscribe to `gen-repo.json` explicitly in addition to (or instead of) `all-repo.json`.

Don't hand-edit — regenerate on demand. Entries are grouped by host, sorted A-Z, and ones that were unreachable at curation time get an inline `# unreachable` comment (the workflow keeps probing them).

## Adding things

### A new NexusFFXIV plugin

1. Add a new entry to `plugins.yml` with `internalName`, `repo`, `icon` (path relative to the plugin repo's `main`).
2. Commit + push (via PR — `main` is branch-protected).
3. Trigger the workflow (or wait for the next cron).

The plugin's own release workflow needs to:

- Upload its DalamudPackager-generated `<InternalName>.json` as a release asset (next to the `.zip`)
- Send a `repository_dispatch` to this repo on tag push (see [PlayerNexusTracker's release workflow](https://github.com/NexusFFXIV/PlayerNexusTracker/blob/main/.github/workflows/release.yml) for the pattern)

### A third-party plugin by name

Append an entry to `external-plugins.yml`:

```yaml
externalPlugins:
  - internalName: SomePlugin.InternalName
```

The name must match what appears in https://kamori.goats.dev/Plugin/PluginMaster.

### A third-party Dalamud repo wholesale

Append the URL to `external-repos.yml`:

```yaml
externalRepos:
  - https://raw.githubusercontent.com/SomeAuthor/SomeRepo/main/pluginmaster.json
```

## Email notifications

The update workflow can email the build log (and attach all four `.json` files) whenever the manifests change. Set these repo secrets to enable it; leave any one empty to disable silently:

| Secret | Example |
|---|---|
| `SMTP_HOST` | `smtp.gmail.com` |
| `SMTP_PORT` | `587` |
| `SMTP_USERNAME` | sender mail address |
| `SMTP_PASSWORD` | SMTP password / Google App Password |
| `MAIL_TO` | recipient |

## License

[AGPL-3.0-only](LICENSE) — consistent with the rest of the NexusFFXIV org.

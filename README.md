# NexusFFXIV — Dalamud Plugin Repository

[![Update pluginmaster](https://github.com/NexusFFXIV/DalamudRepo/actions/workflows/update.yml/badge.svg)](https://github.com/NexusFFXIV/DalamudRepo/actions/workflows/update.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

This repo hosts the `pluginmaster.json` manifest that the [Dalamud](https://github.com/goatcorp/Dalamud) plugin installer reads to surface NexusFFXIV plugins inside the in-game UI.

## Install (as a player)

In Dalamud:

1. Open **Settings → Experimental** (the small ⚠️ tab in the Settings window).
2. Under **Custom Plugin Repositories**, paste:
   ```
   https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/pluginmaster.json
   ```
3. Hit Save.
4. Open `/xlplugins`, switch to **All Plugins**, search for any NexusFFXIV plugin (e.g. **PlayerNexusTracker**), Install.

### Testing builds (opt-in)

Tick **Settings → Experimental → Get plugin testing builds** to surface pre-release versions when available. Stable users continue to see only stable releases.

## Available plugins

Auto-derived from `plugins.yml`. As of now:

- [**PlayerNexusTracker**](https://github.com/NexusFFXIV/PlayerNexusTracker) — Track players you meet in FFXIV.

## How this repo works

```
pluginmaster.json                 ← what Dalamud fetches
plugins.yml                       ← config: list of tracked plugin repos
images/<Plugin>.png               ← 256×256 icons (stable URLs)
scripts/build-pluginmaster.ps1    ← rebuild script
.github/workflows/update.yml      ← runs the script
```

`pluginmaster.json` is **generated**, not edited by hand. The workflow runs on:

- `repository_dispatch` events emitted by each plugin's release workflow (immediate update on tag push)
- `workflow_dispatch` (manual trigger)
- A 6-hourly cron (safety net if a dispatch fails)

For each plugin in `plugins.yml`, the script fetches the latest stable + latest pre-release from GitHub, downloads the embedded `<Plugin>.json` manifest from the release assets, and merges the data into `pluginmaster.json`. Stable and testing pointers are reconciled per the Dalamud-spec semantics:

| Plugin's release state | `DownloadLinkInstall` | `DownloadLinkTesting` |
|---|---|---|
| Only stable | → stable | → stable (testers see the same build) |
| Stable + newer pre-release | → stable (unchanged) | → pre-release |
| Pre-release older than stable | → stable | → stable (no downgrade for testers) |
| Only pre-release (never stable) | → pre-release | → pre-release; entry marked `IsTestingExclusive: true` |

## Adding a new plugin

1. Add a new entry to `plugins.yml` with `internalName`, `repo`, `icon`.
2. Drop a 256×256 icon PNG into `images/`.
3. Commit + push (via PR — `main` is branch-protected).
4. Trigger the workflow (or wait for the next cron).

The plugin's own release workflow needs to:
- Upload its DalamudPackager-generated `<InternalName>.json` as a release asset (next to the `.zip`)
- Send a `repository_dispatch` to this repo on tag push (see [PlayerNexusTracker's release workflow](https://github.com/NexusFFXIV/PlayerNexusTracker/blob/main/.github/workflows/release.yml) for the pattern)

## License

[AGPL-3.0-only](LICENSE) — consistent with the rest of the NexusFFXIV org.

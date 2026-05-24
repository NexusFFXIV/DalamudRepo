# NexusFFXIV — Dalamud Plugin Repository

[![Update pluginmaster](https://github.com/NexusFFXIV/DalamudRepo/actions/workflows/update.yml/badge.svg)](https://github.com/NexusFFXIV/DalamudRepo/actions/workflows/update.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

This repo publishes four pluginmaster manifests that the [Dalamud](https://github.com/goatcorp/Dalamud) plugin installer can read. Each one is scoped differently — pick the URL that matches what you want to see in Dalamud.

## Install (as a player)

In Dalamud:

1. Open **Settings → Experimental** (the small ⚠️ tab in the Settings window).
2. Under **Custom Plugin Repositories**, paste **one** of the URLs below (or several — Dalamud merges them).
3. Hit Save.
4. Open `/xlplugins`, switch to **All Plugins**, search, Install.

### Available scopes

Base URL: `https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/`

| Scope | File | Contents |
|---|---|---|
| **NexusFFXIV plugins** (default) | `pluginmaster.json` | Only plugins built by NexusFFXIV (currently PlayerNexusTracker). |
| **External plugins** | `external.json` | Third-party plugins imported by `InternalName` from Dalamud's official pluginmaster. |
| **External repos** | `repos.json` | Whole pluginmaster.jsons pulled from third-party Dalamud repos, deduped by `InternalName` (highest `AssemblyVersion` wins). |
| **All** | `all.json` | Union of the three above, deduped end-to-end. One URL, everything. |

Subscribe by pasting `<base-url><file>` into Dalamud's Custom Plugin Repositories field.

### Testing builds (opt-in)

Tick **Settings → Experimental → Get plugin testing builds** to surface pre-release versions when available. Stable users continue to see only stable releases.

## Available plugins

Auto-derived from `plugins.yml`. As of now:

- [**PlayerNexusTracker**](https://github.com/NexusFFXIV/PlayerNexusTracker) — Track players you meet in FFXIV.

## How this repo works

```
pluginmaster.json                 ← Dalamud-facing, NexusFFXIV plugins only (default)
external.json                     ← Dalamud-facing, external-plugins.yml only
repos.json                        ← Dalamud-facing, external-repos.yml only
all.json                          ← Dalamud-facing, everything merged + deduped

plugins.yml                       ← config: our own plugin repos
external-plugins.yml              ← config: third-party plugins to re-publish by name
external-repos.yml                ← config: third-party Dalamud repos to mirror

scripts/build-pluginmaster.ps1    ← rebuild script — emits all four .json files
.github/workflows/update.yml      ← runs the script, opens a PR when any output changed
```

All four `.json` files are **generated**, not edited by hand. The workflow runs on:

- `repository_dispatch` events emitted by each plugin's release workflow (immediate update on tag push)
- `workflow_dispatch` (manual trigger)
- A 6-hourly cron (safety net if a dispatch fails)

The diff check covers all four outputs — a change in any single file triggers one combined refresh PR.

### plugins.yml — our own plugins

For each entry, the script fetches the latest stable + latest pre-release from GitHub, downloads the embedded `<Plugin>.json` manifest from the release assets, and merges the data into `pluginmaster.json`. Stable and testing pointers are reconciled per the Dalamud-spec semantics:

| Plugin's release state | `DownloadLinkInstall` | `DownloadLinkTesting` |
|---|---|---|
| Only stable | → stable | → stable (testers see the same build) |
| Stable + newer pre-release | → stable (unchanged) | → pre-release |
| Pre-release older than stable | → stable | → stable (no downgrade for testers) |
| Only pre-release (never stable) | → pre-release | → pre-release; entry marked `IsTestingExclusive: true` |

### external-plugins.yml — single third-party plugins

Each entry names a plugin by its `InternalName`. The script looks it up in Dalamud's official pluginmaster (`https://kamori.goats.dev/Plugin/PluginMaster`) and copies the entry verbatim — download links keep pointing at the upstream CDN, `IconUrl` stays with the upstream author. Lands in `external.json` and `all.json`.

### external-repos.yml — third-party Dalamud repos

Each entry is a URL to another Dalamud repo's `pluginmaster.json` (or single-plugin manifest). The script fetches each, folds every entry into the pool, and writes them to `repos.json` (and `all.json`).

When the same `InternalName` appears in multiple sources — whether two external repos, or `external-repos.yml` overlapping with `external-plugins.yml`, or our own `plugins.yml` — the entry with the **highest `AssemblyVersion`** wins. Missing or unparseable versions sort below valid ones.

Unreachable repos (down, bad JSON, rate-limited) log a warning and are skipped; the rest of the rebuild keeps going.

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

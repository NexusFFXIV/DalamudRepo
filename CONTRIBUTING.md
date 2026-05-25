# Contributing to NexusFFXIV DalamudRepo

This repo aggregates several Dalamud plugin source lists into the JSON files that XIVLauncher subscribes to. The sections below cover the build pipeline, the YAML configs, and how to add new entries.

## How this repo works

```
[pluginmaster.json](#pluginsyml--our-own-plugins)       ← Dalamud-facing, NexusFFXIV plugins only
[common-repo.json](#external-reposyml--third-party-dalamud-repos)        ← Dalamud-facing, external-repos.yml (curated)
[external-repo.json](#external-pluginsyml--single-third-party-plugins)      ← Dalamud-facing, external-plugins.yml only
all-repo.json           ← Dalamud-facing, curated union (gen excluded)
[gen-repo.json](#external-repos-genyml--auto-discovered-third-party-repos)           ← Dalamud-facing, external-repos-gen.yml (auto-discovered, standalone)

[config.yml](#configyml--build-configuration)              ← build config: min Dalamud API + per-source toggles
[plugins.yml](#pluginsyml--our-own-plugins)             ← our own plugin repos
[external-repos.yml](#external-reposyml--third-party-dalamud-repos)      ← third-party Dalamud repos to mirror (curated)
[external-plugins.yml](#external-pluginsyml--single-third-party-plugins)    ← third-party plugins to re-publish by name
[external-repos-gen.yml](#external-repos-genyml--auto-discovered-third-party-repos)  ← third-party Dalamud repos (auto-discovered)

scripts/build-pluginmaster.ps1   ← rebuild script — emits all five .json files
.github/workflows/update.yml     ← runs the script, opens a PR when any output changed
```

### When the repo refreshes

All five `.json` files are **generated**, not edited by hand. The workflow runs on:

- `repository_dispatch` events emitted by each plugin's release workflow (immediate update on tag push)
- `workflow_dispatch` (manual trigger)
- A 48-hour cron (safety net if a dispatch fails)

The diff check covers all five outputs plus `cache/snapshot.json` — a change in any single one triggers one combined refresh PR.

### config.yml — build configuration

Two knobs:

- **`minDalamudApiLevel` / `minTestingDalamudApiLevel`** (both default `15`) — an entry is kept if **either** its `DalamudApiLevel` ≥ `minDalamudApiLevel` (prod-ready) **or** its `TestingDalamudApiLevel` ≥ `minTestingDalamudApiLevel` (testing-ready). Entries with neither field meeting its threshold are dropped from every source pool. Filtered counts are summarised in the build log; individual entries are not listed.
- **`sources.<filename>`** — set to `false` to skip fetching from that source AND skip writing its output file. The on-disk file is left at its last committed state so subscribers don't see a sudden empty repo. `default:` controls behaviour for sources not explicitly listed.

### plugins.yml — our own plugins

For each entry, the script fetches the latest stable + latest pre-release from GitHub, downloads the embedded `<Plugin>.json` manifest from the release assets, and merges the data into `pluginmaster.json`. Stable and testing pointers are reconciled per the Dalamud-spec semantics:

| Plugin's release state | `DownloadLinkInstall` | `DownloadLinkTesting` |
|---|---|---|
| Only stable | → stable | → stable (testers see the same build) |
| Stable + newer pre-release | → stable (unchanged) | → pre-release |
| Pre-release older than stable | → stable | → stable (no downgrade for testers) |
| Only pre-release (never stable) | → pre-release | → pre-release; entry marked `IsTestingExclusive: true` |

### external-repos.yml — third-party Dalamud repos

Each entry is a URL to another Dalamud repo's `pluginmaster.json` (or single-plugin manifest). The script fetches each, folds every entry into the pool, and writes them to `common-repo.json` (and `all-repo.json`).

Unreachable repos (down, bad JSON, rate-limited) log a warning and are skipped; the rest of the rebuild keeps going.

### external-plugins.yml — single third-party plugins

Each entry names a plugin by its `InternalName`. The script looks it up in Dalamud's official pluginmaster (`https://kamori.goats.dev/Plugin/PluginMaster`) and copies the entry verbatim — download links keep pointing at the upstream CDN, `IconUrl` stays with the upstream author. Lands in `external-repo.json` and `all-repo.json`.

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

### A third-party Dalamud repo wholesale

Append the URL to `external-repos.yml`:

```yaml
externalRepos:
  - https://raw.githubusercontent.com/SomeAuthor/SomeRepo/main/pluginmaster.json
```

### A third-party plugin by name

Append an entry to `external-plugins.yml`:

```yaml
externalPlugins:
  - internalName: SomePlugin.InternalName
```

The name must match what appears in https://kamori.goats.dev/Plugin/PluginMaster.

# NexusFFXIV — Dalamud Plugin Repository

**A custom Dalamud plugin repository for FINAL FANTASY XIV — host for [NexusFFXIV](https://github.com/NexusFFXIV) plugins plus a curated mirror of third-party Dalamud repos.**

[![Update pluginmaster](https://github.com/NexusFFXIV/DalamudRepo/actions/workflows/update.yml/badge.svg)](https://github.com/NexusFFXIV/DalamudRepo/actions/workflows/update.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Dalamud API](https://img.shields.io/badge/Dalamud_API-15-9D5BFF)](https://github.com/goatcorp/Dalamud)

<table>
<thead>
<tr>
<th>Repo file</th>
<th>Plugin count</th>
<th>Scope</th>
</tr>
</thead>
<tbody>
<tr>
<td><a href="https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/pluginmaster.json"><code>pluginmaster.json</code></a></td>
<td><a href="https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/pluginmaster.json"><img alt="pluginmaster" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/pluginmaster.json&query=$.length&label=pluginmaster&color=blue"></a></td>
<td><a href="CONTRIBUTING.md#pluginsyml--our-own-plugins">NexusFFXIV plugins only</a></td>
</tr>
<tr>
<td colspan="3">

```
https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/pluginmaster.json
```

</td>
</tr>
<tr>
<td><a href="https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/common-repo.json"><code>common-repo.json</code></a></td>
<td><a href="https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/common-repo.json"><img alt="common-repo" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/common-repo.json&query=$.length&label=common-repo&color=yellow"></a></td>
<td><a href="CONTRIBUTING.md#external-reposyml--third-party-dalamud-repos">Plugins from selected third-party repos</a></td>
</tr>
<tr>
<td colspan="3">

```
https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/common-repo.json
```

</td>
</tr>
<tr>
<td><a href="https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/external-repo.json"><code>external-repo.json</code></a></td>
<td><a href="https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/external-repo.json"><img alt="external-repo" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/external-repo.json&query=$.length&label=external-repo&color=orange"></a></td>
<td><a href="CONTRIBUTING.md#external-pluginsyml--single-third-party-plugins">Individual third-party plugins</a></td>
</tr>
<tr>
<td colspan="3">

```
https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/external-repo.json
```

</td>
</tr>
<tr>
<td><a href="https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/all-repo.json"><code>all-repo.json</code></a></td>
<td><a href="https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/all-repo.json"><img alt="all-repo" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/all-repo.json&query=$.length&label=all-repo&color=brightgreen"></a></td>
<td><strong>Everything above — default subscribe URL</strong></td>
</tr>
<tr>
<td colspan="3">

```
https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/all-repo.json
```

</td>
</tr>
<tr>
<td><a href="https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/gen-repo.json"><code>gen-repo.json</code></a></td>
<td><a href="https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/gen-repo.json"><img alt="gen-repo" src="https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/gen-repo.json&query=$.length&label=gen-repo&color=lightgrey"></a></td>
<td><a href="CONTRIBUTING.md#external-repos-genyml--auto-discovered-third-party-repos">Auto-discovered third-party repos (standalone, not in <code>all-repo</code>)</a></td>
</tr>
<tr>
<td colspan="3">

```
https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/gen-repo.json
```

</td>
</tr>
</tbody>
</table>

## 📥 Install (as a player)

1. Open Dalamud's **Settings → Experimental** tab (the ⚠️ icon in the Settings window).
2. Under **Custom Plugin Repositories**, paste the default URL:

   ```
   https://raw.githubusercontent.com/NexusFFXIV/DalamudRepo/main/all-repo.json
   ```

3. Tick the new entry as **Enabled** and hit Save.
4. Open `/xlplugins`, switch to **All Plugins**, search for the plugin you want, click Install.

> [!NOTE]
> **Other scopes** — pick a different URL from the table at the top if you want a narrower view (e.g. only NexusFFXIV plugins).
>
> **Testing builds** — tick **Settings → Experimental → Get plugin testing builds** to surface pre-release versions when available.

## Contributing

Want to add a plugin, mirror another repo, or understand how the pipeline works? See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[AGPL-3.0-only](LICENSE) — consistent with the rest of the NexusFFXIV org.

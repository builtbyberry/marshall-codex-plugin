# Marshall — OpenAI Codex marketplace

Release coordination for AI coding agents, backed by the hosted **Marshall**
store: claims, drift, and startability live in one shared store — the same
across machines, people, and agents — instead of repo-local JSON. This is the
Codex client for the same store the Claude plugin serves.

This repository is a **Codex plugin marketplace** — one plugin, `marshall`,
under `plugins/marshall`. Codex installs it as a first-class plugin, so its
skills, hooks, and MCP connection register together, with the per-tool approval
posture that gates every mutation.

## Install

```
codex plugin marketplace add builtbyberry/marshall-codex-plugin
codex plugin install marshall@marshall
```

Installing connects the hosted Marshall MCP server over OAuth: the client
self-registers, you approve the connection in your browser and pick the
workspace it may operate in — there is no token to paste or store. (For a
browserless CI path, see the install/CI guide.)

The `marshall` CLI (`@builtbyberry/marshall-cli`) is a separate, agent-agnostic
path for humans, CI, and hooks. It is not required to use this plugin.

## What's in here

| Path | What |
| --- | --- |
| `.agents/plugins/marketplace.json` | The marketplace manifest (one plugin: `marshall`) |
| `plugins/marshall/` | The Marshall Codex plugin — see its own README |

## This repository is generated

**Do not edit these files by hand.** This repo is a published artifact: every
tracked path except `CHANGELOG.md`, `.github/`, and this notice's own tooling is
rendered from canon in the private `builtbyberry/swarm-release-manager` repo and
synced by `php artisan srm:publish-plugin codex <path>`. A hand edit will be
pruned or overwritten by the next publish, and CI's `--check` gate will fail the
moment the tree drifts from canon.

To change a skill, change it at the source and publish.

## License

MIT — see [LICENSE](LICENSE).

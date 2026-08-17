# Marshall — OpenAI Codex plugin

Release coordination for AI coding agents, backed by the hosted **Marshall**
store: claims, drift, and startability live in one shared store — the same
across machines, people, and agents — instead of repo-local JSON. This is the
Codex client for the same store the Claude plugin serves.

## Connecting

Installing this plugin (`codex plugin add marshall@marshall`) connects the
hosted Marshall MCP server declared in `.mcp.json` using **OAuth 2.1**
(authorization-code + PKCE, Dynamic
Client Registration): the client self-registers, you approve the connection in
your browser and pick the workspace it may operate in.

The interactive plugin deliberately omits `bearer_token_env_var`. Current Codex
versions select bearer mode whenever that field is configured, even when the named
environment variable is absent, which suppresses OAuth and leaves the server with no
tools. See the install/CI guide for the current separate browserless path and for
credential provisioning, workspace grants, rotation, and revocation.

The plugin holds **every mutating MCP tool for approval** and pre-approves only the
read-only tools — a fail-safe posture, because Codex's OS sandbox does not gate
MCP calls. The `.mcp.json` sets `default_tools_approval_mode = prompt`
and lists exactly the nine reads (`release_get`, `release_next`, `release_status`,
`release_changelog`, `project_list`, `my_claims`, `dispatch_get`, `lenses_get`,
`lenses_applicable`) as `approve`; every other tool — every create, state move,
deploy/ship step, archive/delete, and any tool added later — inherits `prompt`.

## What's in here

| Path | What |
| --- | --- |
| `.codex-plugin/plugin.json` | Plugin manifest — points at skills, `.mcp.json`, hooks |
| `.mcp.json` | The hosted Marshall MCP endpoint + per-tool approval posture |
| `skills/<skill>/SKILL.md` | The release skill's instructions |
| `hooks/hooks.json` + `hooks/session-start.sh` | SessionStart repo opt-in context (silent unless the repo opts in) |

The `marshall` CLI (`@builtbyberry/marshall-cli`) is a separate, agent-agnostic
path for humans, CI, and hooks. It is not required to use this plugin.

## Skills

Fourteen release skills render from the shared canon into Codex's Skills format.
Each names Marshall's MCP tools in Codex's `mcp__marshall__<tool>` form.

| Skill | What it does |
| --- | --- |
| `release-init` | Bootstrap a project + release directly in the Marshall store |
| `release-plan` | Plan a release into the store — theme, component sweep, out-of-scope |
| `release-graph` | Declare a release's dependency graph so components become startable |
| `release-open` | Open a release session — cut the branch, scaffold the CHANGELOG, draft PR |
| `release-next` | Recommend the next startable work across releases |
| `release-topic` | Claim a component (the cross-machine lock), then cut its topic branch |
| `release-build` | Carry one component from unclaimed to merged in one guided loop |
| `change-review` | Multi-lens review over a component's diff; record findings in the store |
| `release-readiness` | Release-wide readiness review; record findings in the store |
| `release-parallel` | Dispatch parallel work across a release's startable components |
| `release-wrap` | Wrap a release — review, CHANGELOG, readiness gate, hand off |
| `release-deploy` | Drive the final cut-over — deploy or tag mode — recorded on the store |
| `release-unclaim` | Hand a component's claim back, or force-revoke a stuck one |
| `release-admin` | Archive, restore, delete, or repair a tracker link on a store record |

## This plugin is generated

**Do not edit these files by hand.** They are rendered from canon in the private
`builtbyberry/swarm-release-manager` repo and synced by
`php artisan srm:publish-plugin codex <path>`. To change a skill, change it at
the source and publish.

## License

MIT — see [LICENSE](LICENSE).

# Changelog

All notable changes to the Marshall Codex plugin.

This file is hand-authored and is **not** rendered by the publisher. The plugin's
version is set at the source in `builtbyberry/swarm-release-manager` and rendered
into `plugins/marshall/.codex-plugin/plugin.json`; the heading and git tag here must
match whatever that render declares.

## 1.11.0 — 2026-09-25

The skills say where they run, and reuse the worktree they are in.

### Changed

- **`release-topic` and `release-build` report their location on every claim and
  heartbeat** — the agent (`codex`), the Mac's hostname and the absolute worktree
  path — so Marshall Workspace can show who is working a part, on which Mac, in which
  folder. An older store ignores the new fields.
- **They reuse the checkout that is already there.** Started on the part's topic
  branch (for example in a worktree Marshall Workspace created), the skill says
  `Reusing worktree <path> on <branch>` and does not add another; a branch that exists
  but is checked out nowhere is attached without `-b`; a branch checked out in another
  worktree is a stop that names that path.
- **One claim rule for fresh, continued and lapsed work.** A lapsed or released part is
  re-claimed (the fence bumps); a revoked one stops; one someone else holds stops with
  `Held by <name> on <machine> via <agent> — stopping.`

#!/usr/bin/env bash
# Surface the Marshall store connection at Codex session start — but ONLY for repos
# that opt into Marshall. For every other repo this stays completely silent, so it
# never nags unrelated projects.
#
# Registered as a Codex PLUGIN hook (plugin.json "hooks" → hooks/hooks.json, which
# runs this via ${PLUGIN_ROOT}), so it fires from wherever `codex plugin install`
# placed the plugin — not from a repo-local .codex/config.toml, which codex#17532
# stops firing in interactive sessions. It still gates itself per-repo from inside
# (via --require-repo below), staying silent in every non-Marshall repo.
set -uo pipefail

# The agent talks to Marshall over MCP; this hook is just an optional readiness
# ping via the secondary CLI. No CLI on PATH -> say nothing.
command -v marshall >/dev/null 2>&1 || exit 0

# --require-repo is what keeps this silent outside Marshall repos: non-zero means
# any of "this repo doesn't use Marshall", "not signed in", or "store unreachable"
# — all of which mean the same thing to us: say nothing. On success, inject
# readiness as Codex's NESTED SessionStart output. The flat Claude shape
# ({"additionalContext":...}) parses to nothing here — Codex reads
# hookSpecificOutput.additionalContext.
if who="$(marshall me --require-repo 2>/dev/null)"; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Marshall store connected as %s. Use $release-status or $release-next."}}\n' "$who"
fi

exit 0

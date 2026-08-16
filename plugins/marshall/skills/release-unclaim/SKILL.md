---
name: release-unclaim
description: "Hand a release component's claim back to the Marshall store, or force-revoke a stuck one. Use when the user says /release-unclaim, release the claim, drop the hold, or revoke <component>."
---

# Release Unclaim (Marshall)

Return a claim to the shared Marshall store so the component is free for someone else
— either gracefully (you hold it) or by force (recovering a stuck/dead hold).

## How it talks to the store

- `mcp__marshall__release_status` — see current holds (and the claim ids).
- `mcp__marshall__release_claim` — gracefully hand back your own claim.
- `mcp__marshall__revoke_claim` — force a claim off (recovery; any workspace member).

## Procedure

1. Identify the claim. If you don't have the claim id, run `$release-status`
   to find who holds what (each hold carries its claim id).
2. Choose the path:
   - **Your own claim, work done or paused** → `mcp__marshall__release_claim { claim }`.
   - **A stuck or dead hold** (the holder's machine went away, the lease is
     stale) → `mcp__marshall__revoke_claim { claim }`. Confirm with the user first —
     revoking pulls the lock out from under whoever held it.
3. Both advance the component's fence, so a superseded worker's next write fails
   loud rather than silently clobbering. Report the component as free.

## Guardrails

- Prefer `release_claim` for your own work; reserve `revoke_claim` for genuine
  recovery, and confirm before revoking someone else's hold.
- Releasing doesn't undo committed work — it only frees the coordination lock.
- **Releasing is not "done."** If the work merged, also mark the component
  merged: `mcp__marshall__set_component_state { component, state: "merged" }`.
  Releasing the lock alone leaves the component `open`, so its dependents stay
  blocked until you mark it merged.

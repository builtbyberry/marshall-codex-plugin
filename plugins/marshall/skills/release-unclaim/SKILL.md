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

**Autonomy refusals.** `worker_paused` (stop, say who paused it and when, wait for the
person), `lease_lost` after a stop (stop, do not re-claim), `autonomy_disabled`,
`looser_than_release` and `not_authorized` wrote nothing: surface the body and never
retry one in a loop. `$release-topic`'s **Autonomy — the claim's mode and the
refusals** says what each means and what to do.

## Procedure

1. Identify the claim. If you don't have the claim id, call `mcp__marshall__release_status`
   to find who holds what (each hold carries its claim id).
2. Choose the path:
   - **Your own claim, work paused** → `mcp__marshall__release_claim { claim }`.
   - **Your own claim, work landed** (its PR merged) → mark it merged **before**
     you release: `mcp__marshall__set_component_state { component, state: "merged" }`,
     then `mcp__marshall__release_claim { claim }`. (If the hold was the one `in_progress`
     took for you, the move to `merged` already handed it back, and the release is
     a harmless no-op.) If the move is refused with `missing_gate_records`,
     nothing changed: **stop before releasing** and name the missing gates — the
     part is not merged in the store, and its dependents stay blocked. Release
     anyway only if the operator says to. What the refusal means and the way past
     it are `$release-topic`'s step 5, **Refused with
     `missing_gate_records`**.
   - **A stuck or dead hold** (the holder's machine went away, the lease is
     stale) → `mcp__marshall__revoke_claim { claim }`. Confirm with the user first —
     revoking pulls the lock out from under whoever held it.
3. Both advance the component's fence, so a superseded worker's next write fails
   loud rather than silently clobbering. Report the component as free.

## Guardrails

- Prefer `release_claim` for your own work; reserve `revoke_claim` for genuine
  recovery, and confirm before revoking someone else's hold.
- Releasing doesn't undo committed work — it only frees the coordination lock.
- **Releasing is not "done."** Releasing changes the claim, not the work-state:
  the component stays in whatever state it was in. A part whose PR merged stays
  unmerged in the store, and its dependents stay blocked, until it is marked
  merged (step 2).

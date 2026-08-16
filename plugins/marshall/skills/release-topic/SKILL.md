---
name: release-topic
description: "Start work on a release component: claim it in the Marshall store (the cross-machine lock), then create its topic branch. Use when the user says /release-topic, start <component>, begin work on, or pick up an issue."
---

# Release Topic (Marshall)

Start work on a component the right way: **claim it first** in the shared Marshall
store — the exclusive, cross-machine lock — then cut the topic branch. The claim
is what stops two people (or agents) from doing the same work on different
machines.

## How it talks to the store

- `mcp__marshall__release_next` — confirm the component is startable.
- `mcp__marshall__claim_component` — take the lock (returns the claim id + fence).
- `mcp__marshall__my_claims` — list **your own** live holds (claim id,
  component, fence, machine, lease). The recovery surface after context
  compaction — see **Recovering a lost claim** below.
- `mcp__marshall__heartbeat_claim` — keep the lock alive on a cadence tied to the work (see step 4).
  Takes **either** the claim id **or** the `component` id whose hold you own.
- `mcp__marshall__release_claim` — hand it back when the work is parked or done
  (or use `$release-unclaim`).
- `mcp__marshall__set_component_state` /
  `mcp__marshall__set_component_states` — move the work-state; the second is
  the batch counterpart for landing several at once (step 5).

## Session setup — set the verbosity once, both directions

At the **start of a working session**, set this actor's write-return and
read-view defaults once, so every subsequent write comes back as the affected
entity instead of the whole release document, and every subsequent read comes
back as the index instead of the whole document:

```
mcp__marshall__set_default_return { default_return: "minimal" }
mcp__marshall__set_default_view   { default_view: "summary" }
```

These are **stored per-actor preferences**, not per-call flags — set them once,
not before every call, and never in a loop. They apply to this actor across the
session; an explicit `return` (writes) or `view` (reads) on any individual call
still wins over the stored default, so a step that genuinely needs the whole
document (reading the newly-unblocked wave after a `merged`) can still ask for
`return: "full"` / `view: "full"` inline.

Restore the whole-document defaults with `{ default_return: "full" }` and
`{ default_view: "full" }` when a session wants full payloads back. A fresh actor
that never calls either is byte-unchanged — `full` is the default on both sides.

## Procedure

1. Identify the component (by tracker ref or title). If unclear, run
   `$release-next` first and let the user pick.
2. Claim it: `mcp__marshall__claim_component { component: <id> }`.
   - **Success** → you hold it; note the returned claim `id` and `fence`.
   - **`claim_conflict`** → someone else holds it (the error names the holder).
     Stop — do not start; surface who has it.
   - **`not_startable`** → blockers unmet or the graph is `unverified`. Stop and
     explain; if unverified, run `$release-graph` first.
3. Only after a successful claim, mark the work started:
   `mcp__marshall__set_component_state { component, state: "in_progress" }`, then
   create the topic branch (`<type>/<release>-<ref>-<slug>`) and begin work.
4. Keep the claim alive on a cadence tied to the work, not a timer you have to
   remember: beat it as you finish **each meaningful chunk** of the work, and
   **immediately before a long-running operation** (a full test run, static
   analysis). If a heartbeat returns `lease_lost`, **stop** — the lease lapsed or was
   revoked; recover it deliberately (see **Recovering a lost claim**) before continuing.
5. When the PR **lands**, advance the work-state so dependents unblock:
   `mcp__marshall__set_component_state { component, state: "merged" }`. This is
   separate from the lock — releasing the claim alone does NOT mark it merged,
   so a merged blocker won't open its dependents until you set this.
   - **Landing several at once** (a wave's PRs merging together): use the batch
     tool instead of a call per component —
     `mcp__marshall__set_component_states { states: [{ component, state: "merged" }, ...] }`.
     One transaction, one minimal ack, and the next wave's startability is
     computed once rather than N times. It is all-or-nothing: an illegal item
     rolls the whole batch back with `batch_item_failed` naming the item **by
     index** and its `from`/`to` — surface that, fix the named item, re-send the
     whole batch. Never decompose a rejected batch into singular calls.
6. Then release the lock (`$release-unclaim` or `mcp__marshall__release_claim`).

## Recovering a lost claim (context compaction)

A long session can lose the opaque claim `id` it was handed at step 2 — a
compaction drops it, or the work resumes in a fresh chat. **The hold is still
yours; the handle is what went missing.** Do not re-claim: `claim_component`
throws `claim_conflict` on a live re-claim *even for the same holder*.

Recover it instead:

```
mcp__marshall__my_claims { release? }
```

It lists every claim **you** still hold — claim id, component, fence, machine,
and lease — scoped to one release if you pass `release`, or across the whole
workspace if you don't. Match the component you are working and take its `id`;
heartbeating and releasing work normally from there.

If you know the component but not the claim, you can also skip the lookup:
`heartbeat_claim { component: <component id> }` and
`release_claim { component: <component id> }` both accept the component id of a
hold you own.

If `my_claims` does **not** list the component, you no longer hold it (the lease
lapsed, or it was released or revoked). That is a stop — re-claim deliberately
via step 2 and check nobody else picked the work up; never assume a hold you
cannot find is still yours. A deliberate re-claim after a genuine lapse succeeds and
**the fence bumps** (2, 3, …) — that increment is expected bookkeeping, not a sign
anything is wrong; it is how the store fences a stale holder out.

## Guardrails

- Never start work without a successful claim. A `claim_conflict` or
  `not_startable` is a hard stop, not a warning to work around.
- The claim is the source of truth, not the branch. If you lose the lease, the
  branch doesn't protect you — re-claim.
- **A lost claim id is a lookup, not a re-claim.** Use `my_claims` (or pass the
  `component` id to `heartbeat_claim` / `release_claim`). Re-claiming a hold you
  already own returns `claim_conflict`.
- One component per claim. To work several, claim each with `$release-topic`,
  or dispatch them as a wave with `$release-parallel`.

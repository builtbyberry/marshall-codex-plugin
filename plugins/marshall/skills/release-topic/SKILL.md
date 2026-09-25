---
name: release-topic
description: "Start work on a release component: claim it in the Marshall store (the cross-machine lock), then reuse, attach, or create its topic branch. Use when the user says /release-topic, start <component>, begin work on, or pick up an issue."
---

# Release Topic (Marshall)

Start work on a component the right way: **claim it first** in the shared Marshall
store — the exclusive, cross-machine lock — then reuse, attach, or create its
topic branch. The claim
is what stops two people (or agents) from doing the same work on different
machines.

## How it talks to the store

- `mcp__marshall__release_next` — confirm the component is startable.
- `mcp__marshall__release_get` — read the component's `topic_branch`, `hold`, and
  `last_worked`. Always pass `view: "full"`: the summary view you set below omits
  all three.
- `mcp__marshall__claim_component` — take the lock (returns the claim id + fence), and
  report where the work happens (see **Reporting where you work**).
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

## Reporting where you work

Every claim and every heartbeat carries three location fields, so the store (and
anyone reading it) can tell which agent, on which Mac, in which folder, holds the
part:

- `agent` — always `agent: "codex"`.
- `machine` — the Mac's hostname:
  ```bash
  machine=$(scutil --get LocalHostName 2>/dev/null); [ -n "$machine" ] || machine=$(hostname -s)
  ```
- `worktree` — the absolute path of the folder the work happens in, read from
  inside that folder: `git rev-parse --show-toplevel`. Pass it only if it starts
  with `/`.

A field you cannot determine is **omitted** — never sent as `null` or `""`. On a
heartbeat an omitted field keeps its stored value, so passing all three on every
beat keeps them current. An older store ignores these fields; nothing to do.

## Where the work happens — the reuse rule

Read the component's `topic_branch` from
`mcp__marshall__release_get { release, view: "full" }` (an older store that returns
none: fall back to `<type>/<release>-<ref>-<slug>`). Then pick the **first** case
that matches — run these checks **before** claiming, and create nothing until the
claim succeeds:

- **(a) Already there.** `git branch --show-current` equals the topic branch —
  you are already in a checkout on it (a worktree or the main checkout). **Reuse
  it**: do not run `git worktree add`, do not create or switch branches. Print:
  ```
  Reusing worktree <git rev-parse --show-toplevel> on <branch>
  ```
- **(b) Branch exists, checked out nowhere.** `git show-ref --verify --quiet
  refs/heads/<branch>` succeeds and `git worktree list --porcelain` shows no
  `branch refs/heads/<branch>`. **Attach** to it — never `-b`, which fails on an
  existing branch:
  - worktree mode: `git worktree add <path> <branch>`
  - otherwise: `git switch <branch>`
- **(b′) Branch checked out in another worktree.** `git worktree list --porcelain`
  shows `branch refs/heads/<branch>` under a different `worktree <path>`. **Stop**
  and name that path — the work belongs there; do not add a second worktree.
- **(c) No branch.** Create it off the active release branch:
  - worktree mode: `git worktree add -b <branch> <path> <release-branch>`
  - otherwise: `git switch -c <branch> <release-branch>`

**Worktree mode** (`--worktree`, as `$release-parallel` invokes it)
puts the part in a sibling folder instead of the current checkout. `<path>` is
`<parent>/<leaf>`: `<parent>` is `worktrees.parent_dir` from
`.claude/release-config.json` (relative to the main checkout) if set, else
`<main-checkout>-worktrees`; `<leaf>` is the topic branch with every `/` replaced
by `-`. The main checkout is
`dirname "$(git rev-parse --path-format=absolute --git-common-dir)"`.

## Procedure

1. Identify the component (by tracker ref or title). If unclear, run
   `$release-next` first and let the user pick. Then decide where the
   work happens (**the reuse rule** above) — checks only, no branch or worktree
   yet. A (b′) is a stop before any claim.
2. Take the claim (**Taking the claim** below). Pass the location fields; include
   `worktree` now only when you already work in that folder — case (a), or (b)/(c)
   outside worktree mode:
   `mcp__marshall__claim_component { component: <id>, agent: "codex", machine: <machine>, worktree: <worktree> }`
   - **Success** → you hold it; note the returned claim `id` and `fence`.
   - **`claim_conflict`** → someone else holds it. Stop — do not start; name the
     holder (see **Taking the claim**).
   - **`not_startable`** → blockers unmet or the graph is `unverified`. Stop and
     explain; if unverified, run `$release-graph` first.
3. Only after a successful claim (or on finding you still hold it), mark the work
   started: `mcp__marshall__set_component_state { component, state: "in_progress" }` —
   **only when the part is `open`.** A continued part is already `in_progress`
   (or further along): **skip the call** — `in_progress` → `in_progress` is an
   `invalid_transition`. Then apply the reuse-rule case you picked (reuse, attach,
   or create). From inside the
   folder the work happens in, beat once so the store has the final location:
   `mcp__marshall__heartbeat_claim { component: <id>, agent: "codex", machine: <machine>, worktree: <worktree> }`.
   Begin work.
4. Keep the claim alive on a cadence tied to the work, not a timer you have to
   remember: beat it as you finish **each meaningful chunk** of the work, and
   **immediately before a long-running operation** (a full test run, static
   analysis) — every beat with the same three location fields. If a heartbeat
   returns `lease_lost`, **stop** — the lease lapsed or was revoked; run
   **Taking the claim** again before continuing.
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

## Taking the claim — fresh, continuing, or lapsed

The same rule covers a first claim, continuing a part you worked before, and
recovering from `lease_lost`:

1. `mcp__marshall__my_claims { release }` lists the component → **you still hold it.**
   Do not re-claim (a live re-claim throws `claim_conflict` even for the same
   holder); take its `id` and beat it with the location fields.
2. Otherwise read `mcp__marshall__release_get { release, view: "full" }` and check the
   component:
   - `hold` is set → **someone else holds it. Stop** and print:
     ```
     Held by <hold.actor.display_name> on <hold.machine> via <hold.agent> — stopping.
     ```
   - `hold` is null and `last_worked.ended` is `revoked` → **stop.** Say the claim
     was revoked, not lapsed. Re-claim only when the operator explicitly says to.
   - `hold` is null and `last_worked` is null, or `last_worked.ended` is `lapsed`
     or `released` (an older store may return no `last_worked` at all) → claim it
     with the location fields. After a lapse **the fence bumps** (2, 3, …) — that
     increment is expected bookkeeping, not a sign anything is wrong; it is how the
     store fences a stale holder out.
3. The claim returns `claim_conflict` → someone took it in between. Read
   `mcp__marshall__release_get { release, view: "full" }` for `hold.machine` and
   `hold.agent`, then **stop** with the same line, naming `current_holder`:
   ```
   Held by <current_holder> on <hold.machine> via <hold.agent> — stopping.
   ```

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

If `my_claims` does **not** list the component, you no longer hold it. Never
assume a hold you cannot find is still yours — run **Taking the claim**: it
re-claims a lapsed part, or stops and names whoever holds it now.

## Guardrails

- Never start work without a successful claim. A `claim_conflict` or
  `not_startable` is a hard stop, not a warning to work around.
- The claim is the source of truth, not the branch. If you lose the lease, the
  branch doesn't protect you — run **Taking the claim**: re-claim a lapsed part,
  stop and name the holder of a taken one, stop on a revoked one.
- **Reuse before you create.** Already on the topic branch → reuse the checkout;
  branch exists → attach without `-b`; branch checked out elsewhere → stop. Never
  add a second worktree for a part.
- Every claim and heartbeat carries `agent`, `machine`, and `worktree`; omit one
  you cannot determine, never send it empty.
- **A lost claim id is a lookup, not a re-claim.** Use `my_claims` (or pass the
  `component` id to `heartbeat_claim` / `release_claim`). Re-claiming a hold you
  already own returns `claim_conflict`.
- One component per claim. To work several, claim each with `$release-topic`,
  or dispatch them as a wave with `$release-parallel`.

---
name: release-parallel
description: "Dispatch parallel work across a release's startable components against the shared Marshall store: open a dispatch_run for the wave, then for each member let $release-topic --worktree take the claim and materialize a worktree, and spawn one Claude subagent each that reports progress back to the run. Use when the user says /release-parallel, work on these in parallel, dispatch parallel work, start wave <n>, or run several components concurrently."
---

# Release Parallel (Marshall)

Fan a wave of work out across several startable components at once — driven
against the shared Marshall store, not a repo-local `release-plan.json`. The store's
**`dispatch_run` record is the single source of truth** for the wave: which
components were dispatched together, each member's status, and its last-progress
note. That is what makes a fan-out **observable from the live screens and
resumable** across sessions, machines, and agents — not state trapped in one
orchestrator's context that dies when the session does.

It is **store-driven**: the candidate set comes from the store (`release_next` /
`release_get`) and the wave is recorded as a `dispatch_run`, rather than being
inferred from a local plan file. Nothing about the fan-out reads a tracker.
Claude Code first — built to exploit Claude's parallel subagent dispatch.

The layering, kept clean: the **claim is the lock/liveness** (one per component,
cross-machine); the **`dispatch_run` is the grouping + semantic progress**. They
sit side by side — the run never duplicates drift or re-implements the lock.

## How it talks to the store

- `mcp__marshall__release_next` — the startable candidate set, ranked by what it
  unblocks. The wave's default membership.
- `mcp__marshall__release_get` — the full release document, **including any open
  `dispatch_run`** with per-member status. Read it on **every** invocation; never
  trust prior conversation memory for whether a wave is already open.
- `mcp__marshall__dispatch_open` — open a `dispatch_run` for the release over a set of
  member components; returns the run id and a per-member verdict. The
  **server-side graph guard** lives here (see below).
- `mcp__marshall__dispatch_report` — a member reports its status
  (`dispatched | in_progress | proposed | merged | failed`) plus an optional
  last-progress note. Targets the **member id** (`members[].id` from the run, the
  dispatch_member ULID — **not** the component id). One call per meaningful checkpoint.
  `merged` is the only terminal status; `failed` records that one **attempt** ended and
  can be retried to any forward status (see **Resume**).
- `mcp__marshall__dispatch_reports` — the **batch** counterpart, and the
  orchestrator's default when it is moving **several members at once**. One transaction
  for the whole wave instead of a round trip per member. Members may belong to different
  runs — a report is addressed by member id, not by run.
- `mcp__marshall__dispatch_get` — read a run's per-member status directly (the same
  data `release_get` inlines); the resume + status-board read.
- `mcp__marshall__dispatch_close` — the **manual** run-level terminal signal, for a
  finished or abandoned run. A run never closes itself by member aggregation. See
  **Closing a run** below.
- `mcp__marshall__heartbeat_claim` / `mcp__marshall__release_claim` — the per-component lock
  lifecycle. The wave does **not** claim members itself: each member's claim is
  taken once by `$release-topic` during per-member setup (it claims, then cuts
  the branch/worktree), and the subagent heartbeats that claim while it works.

If the MCP server isn't connected, **stop and say so** — the `dispatch_run` is
the only place a wave is durable; never drive a fan-out from conversation memory
or a local file.

## Rely on the server-side graph guard — do not re-implement it

`dispatch_open` runs the **dependency-graph guard server-side**: it refuses to
admit any member whose `depends_on` are not yet `merged`, returning a clear
per-member reason (mirrors `not_startable`). **Do not pre-filter the requested
set against the graph client-side** and do not relax the verdict — pass the set
the user (or `release_next`) gave you and let the store decide. On return:

- **admitted** members are part of the run — claim, worktree, and dispatch them.
- **rejected** members come back with their reason (unmet blocker, unverified
  graph). Surface each one verbatim; do **not** spawn a subagent for it. If the
  graph is `unverified`, route to `$release-graph` first.

This is the same fail-loud contract as the rest of the store: the guard is the
backstop, not a warning to work around.

## Config

Reads `.claude/release-config.json` (tracked, from the current checkout):
`repo`, `default_branch`, `versioning.release_branch_pattern` (to resolve the
active release branch), and `branch_types` (passed through to
`$release-topic` when it materializes each worktree). Refuse if the config is
missing.

## Resume — read the store, never memory

On every invocation, `release_get { release }` (or `dispatch_get`) and look for an
**open** `dispatch_run`:

- **No open run** → this is a fresh wave; go to **Preflight** then **The flow**.
- **An open run exists** → **re-attach, do not re-dispatch.** Read each member's
  recorded status and report the board:
  - `merged` → terminal; report and leave alone.
  - `failed` → **not terminal — this is the resume signal.** The note says why the
    last attempt ended. **Check reality before believing it**: read the component's
    own state and look for a PR. A member that failed on a `lease_lost` very often
    has work that is complete, or already in review, because the failure was about
    the *lock*, not the *work*. Then **reconcile the member to the truth** with a
    single `dispatch_report` — `proposed` if a PR is open, `merged` if it landed,
    `dispatched` / `in_progress` if it genuinely needs redoing. A failed member may
    move to **any** forward status; you never have to report a status you know is
    false to get to the true one. The failure is not erased by this: the member
    keeps `failures` {count, last_at, last_note}, and the audit trail keeps every
    attempt. **Do not leave a member at `failed` when its component has moved on** —
    that is precisely the divergence that makes the board lie to the next session.
  - `proposed` → work landed a PR; report it (merging/wrap is out of scope here).
  - `in_progress` / `dispatched` → still live. Re-attach to the member: confirm
    its claim is still held (`heartbeat_claim`; if `lease_lost`, the hold is dead —
    re-claim via `$release-topic`), confirm its worktree exists, and re-spawn
    its subagent **only if** no live subagent is carrying it. Never re-open the
    run, never re-`dispatch_open` an already-admitted member, and never re-claim a
    component whose claim is still live — `claim_component` throws `claim_conflict`
    on a live re-claim even for the same holder, so re-claim **only** after a
    `lease_lost`.

The whole point of the record: a fresh session re-attaches and reports
`Wave N: 5 dispatched, 3 in progress, 1 proposed, 1 failed` instead of starting
the wave over.

## Closing a run

A `dispatch_run` has **no automatic terminal state.** Every member reaching
`merged` does not close it — member statuses and the run's own lifecycle are
deliberately separate, so a wave whose orchestrator died stays "active" forever
and keeps showing up in the release's summaries as live work that nobody is doing.

`mcp__marshall__dispatch_close { run, reason? }` is the manual
terminal signal. Reach for it in exactly two situations:

- **The wave is genuinely finished** — every member is `merged` (or reconciled to
  the truth), and the run is just sitting there. Close it with a reason like
  `"wave 2 complete"`.
- **The wave was abandoned** — the orchestrator died, the plan changed, the
  release moved on without it. Close it with a reason that says so, e.g.
  `"abandoned — orchestrator died"`. Always pass `reason`; a closed run with no
  explanation is the same lie in a quieter voice.

**Closing is a run-level bookkeeping act, not a work outcome.** It does not touch
member rows, does not change any member's status, does not release any claim, and
does not merge any component. So closing a run whose members are still
`in_progress` **abandons the wave's progress record** while the underlying claims
and branches stay exactly as they were — the work does not stop, it just stops
being tracked here.

Because of that:

- **Reconcile members to the truth *before* you close** (see **Resume**). Closing
  over a member stuck at `failed` whose PR actually merged freezes that lie
  permanently — the run is terminal and the board can no longer be corrected.
- **Confirm with the operator before closing a run with live members.** Ask first;
  a still-live wave is far more often something to re-attach to than something to
  close.
- **Closing is one-way.** `dispatch_already_closed` on a second attempt is the
  store refusing to reopen it. If work continues after a close, that is a **new**
  `dispatch_open`, not a resurrection.
- **A closed run is not a shipped release.** Merging PRs and wrapping are still
  `$release-wrap`'s job.

## Preflight (refuse on failure — do not auto-fix)

In order, stop on the first failure with a clear message:

1. `.claude/release-config.json` exists and the release version resolves (ask if
   ambiguous — don't guess).
2. **The main checkout is on the active release branch.** Resolve the branch from
   `versioning.release_branch_pattern` (e.g. `release/v0.5.0`) and verify HEAD is
   on it. If not, **refuse** — a wave dispatches topic worktrees *off the release
   branch*; dispatching from `main` or a stray branch would base the work wrong.
3. The working tree is clean (each worktree is cut fresh; a dirty main checkout is
   a sign work is in flight that the wave shouldn't disturb).

## The flow

### Step 1 — Choose the wave

Resolve the member set:

- explicit ids/refs from the user (`/release-parallel #41 #42 #45`, or "start
  wave 2") → use them as-is; the graph guard validates them.
- no ids → `mcp__marshall__release_next { release }` and propose the top startable
  components as the wave. **Confirm the set with the user** before dispatching —
  a wave spawns N subagents and N worktrees; it's worth a beat.

### Step 2 — Open the dispatch_run (the graph guard runs here)

`mcp__marshall__dispatch_open { release, components: [<component id>, ...], label? }`.
Capture the returned **run id** and, for each admitted member, its **member id**
(`members[].id` — the dispatch_member ULID, distinct from the component id, and
what every `dispatch_report` below targets) plus the per-member verdict. Report
admitted vs rejected members (rejected ones carry their reason — see the
graph-guard section). Proceed only with the **admitted** set. The run is now
durable; everything below reports against it.

### Step 3 — Per member: claim + worktree via release-topic, then spawn a subagent

For each admitted member, in parallel:

1. **Claim + worktree via `$release-topic --worktree`.** This is the *single*
   place the member is claimed: release-topic claims the component (the
   cross-machine lock) **and** cuts `<type>/<release>-<ref>-<slug>` from the active
   release branch as a **sibling git worktree**. The wave never issues its own
   `claim_component` — a live re-claim throws `claim_conflict` even for the same
   holder, so one owner takes the lock and that owner is release-topic. Capture the
   resulting claim `id` + `fence`.
   - **`claim_conflict`** → someone else already holds it (the error names the
     holder). Do **not** set it up or spawn it; drop it from the wave and carry it
     into the wave-wide report below as `{ member, status: "failed", note:
     "claim_conflict: held by <holder>" }` so the board reflects reality.
2. **Mark the work started** once the claim is held: `mcp__marshall__set_component_state
   { component, state: "in_progress" }`.
3. **Spawn one Claude subagent** scoped to that worktree (see **The subagent
   brief**). Spawn all members' subagents in one batch so they run concurrently —
   this is the parallel dispatch the skill exists for.
4. **Record the whole wave's transition in ONE call**, once every member has been
   set up — not a `dispatch_report` per member:

   ```
   mcp__marshall__dispatch_reports {
     reports: [
       { member: <member id>, status: "dispatched", note: "<branch> @ <worktree path>" },
       { member: <member id>, status: "failed",     note: "claim_conflict: held by <holder>" },
       ...
     ]
   }
   ```

   A wave dispatches N members at once, so this is one round trip and one minimal
   ack (`{ reported, members: [...] }`) instead of N. Mixed statuses in the same
   call are fine — the members that were set up report `dispatched`, the ones that
   lost their claim report `failed`, together.

   The batch is **all-or-nothing**: an unknown member fails with
   `dispatch_member_not_found` before any write, and an illegal transition rolls
   the whole batch back with `batch_item_failed` naming the item **by index** plus
   its `from`/`to`. Surface it verbatim, correct that item, and re-send the whole
   batch — do not decompose it into singular `dispatch_report` calls to push the
   rest through, or the board ends up half-written.

### Step 4 — Track the wave

The subagents report their own progress to the run (item 3 of the brief) — each
for itself, one member, so a subagent uses singular `dispatch_report`. The
orchestrator's job after dispatch is to **track, not to do the work**: poll
`dispatch_get { run }` (or `release_get`) and render the status board on request.

When the orchestrator itself moves **several members at once** — most often
beating a set of landed PRs from `proposed` to `merged` — use
`mcp__marshall__dispatch_reports { reports: [{ member, status: "merged",
note? }, ...] }` rather than looping the singular tool. **Singular for one member,
batch for many** is the whole rule.
Auto-merging / auto-wrapping dispatched work is **out of scope** — this skill
dispatches and reports; landing each PR is the normal per-component lifecycle.

## The subagent brief

Each spawned subagent is scoped to exactly one component and its worktree. Hand
it: the **component id**, its **member id** (the dispatch_member ULID it reports
against), its **worktree path**, its **branch**, the **run id**, and its **claim
id + fence**. Its standing instructions:

1. Work only inside its worktree on its branch; do not touch sibling worktrees or
   the main checkout.
2. **Heartbeat its claim** (`mcp__marshall__heartbeat_claim { claim }`) during long
   work. If a heartbeat returns `lease_lost`, **stop** and report `failed` — the
   lock was lost or revoked; do not keep writing.
3. **Report progress at meaningful checkpoints** via `mcp__marshall__dispatch_report {
   member, status, note }`, advancing through the lifecycle:
   - `in_progress` when it starts (with a one-line plan in `note`),
   - `proposed` when it opens its PR (`note: <PR url>`),
   - `failed` if it can't complete (the `note` carries why — and is the resume
     signal for a retry on the next invocation),
   - `merged` only if its PR actually lands in this session (usually it stops at
     `proposed`; merging is a separate decision).
   Keep `set_component_state` in step with the work-state (`in_progress` →
   `proposed` → `merged`) — that's the lock-adjacent work-state; `dispatch_report`
   is the wave's semantic progress. They mirror, they don't duplicate.
4. It does **not** open or close the run, claim other components, or merge other
   members' work.

## Guardrails

- **Refuse if the main checkout isn't on the active release branch.** A wave bases
  every worktree off the release branch; dispatching from the wrong branch is a
  hard stop, not a warning.
- **Lean on the server-side graph guard.** Never pre-filter or relax it
  client-side; pass the requested set to `dispatch_open` and surface its
  per-member rejections verbatim.
- **The claim is the lock; the `dispatch_run` is the grouping + progress.** Keep
  them side by side — don't fold drift/liveness into the run or invent a parallel
  lock.
- **One owner per claim — `$release-topic` claims, the wave does not.** Each
  member is claimed exactly once, by release-topic during per-member setup; the
  wave never issues its own `claim_component`. A live re-claim returns
  `claim_conflict` even for the same holder, so a second claim would fail.
- **Resumable, not re-runnable.** Re-invoking re-attaches to an open run and
  reports per-member status; it never re-opens the run, re-dispatches an admitted
  member, or re-claims a still-live hold (a live re-claim returns
  `claim_conflict`; only re-claim after a `lease_lost`).
- **Dispatch + report only.** No auto-merge, no auto-wrap, no auto-retry of a
  failed member — those are deliberate next steps (`$release-topic`,
  `$release-wrap`), not things the wave does on its own. This bars
  redoing the **work** unasked; it does not bar **reporting the truth**. If a
  failed member's component has already moved on, reconcile the member's status to
  match (see **Resume**) — leaving a knowingly-stale `failed` on the board is a
  worse outcome than the divergence it was trying to avoid.
- **Surface store errors verbatim** — `claim_conflict`, `not_startable`,
  `lease_lost`, an open-run conflict — and stop. Never work around them.

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
- `mcp__marshall__dispatch_report_fenced_v1` — the versioned, claim-and-fence-required
  counterpart used by supervised execution harnesses. An older Marshall revision
  does not know this name and therefore refuses the call instead of silently
  downgrading it to an unfenced progress write. Interactive skill calls continue to
  use `dispatch_report`; do not substitute this tool without an exact live claim.
- `mcp__marshall__dispatch_reports` — the **batch** counterpart, and the
  orchestrator's default when it is moving **several members at once**. One transaction
  for the whole wave instead of a round trip per member. Members may belong to different
  runs — a report is addressed by member id, not by run.
- `mcp__marshall__dispatch_get` — read a run's per-member status directly (the same
  data `release_get` inlines); the resume + status-board read.
- `mcp__marshall__dispatch_close` — the **manual** run-level terminal signal, for a
  finished or abandoned run. A run never closes itself by member aggregation. See
  **Closing a run** below.
- `mcp__marshall__autonomy_get { release }` — the effective autonomy policy for the
  release, with its `cap` (how many autonomous agents the workspace runs at once) and
  `enabled` (whether the workspace's autonomy is switched on). See **Sizing the wave
  to the policy**.
- `mcp__marshall__worker_list` — every live worker in the workspace; the rows whose `mode`
  is `autonomous` are what the cap counts.
- `mcp__marshall__worker_pause` / `mcp__marshall__worker_stop` — pause or stop a member's claim,
  on the operator's word (see **Pausing or stopping a wave**).
- `mcp__marshall__heartbeat_claim` / `mcp__marshall__release_claim` — the per-component lock
  lifecycle. The wave does **not** claim members itself: each member's claim is
  taken once by `$release-topic` during per-member setup (it claims, then
  reuses, attaches or creates the member's worktree), and the subagent heartbeats
  that claim while it works.

If the MCP server isn't connected, **stop and say so** — the `dispatch_run` is
the only place a wave is durable; never drive a fan-out from conversation memory
or a local file.

**Autonomy refusals.** `worker_paused` (stop, say who paused it and when, wait for the
person), `lease_lost` after a stop (stop, do not re-claim), `autonomy_disabled`,
`looser_than_release` and `not_authorized` wrote nothing: surface the body and never
retry one in a loop. `$release-topic`'s **Autonomy — the claim's mode and the
refusals** says what each means and what to do.

## Sizing the wave to the policy

**Every member of a wave is autonomous work.** `dispatch_open` makes each member's
claim autonomous (operator runbook §30.5), so the store holds it to the part's
autonomy policy — `agent_ok`, the level, and the workspace's cap on autonomous
agents. While the release's `autonomy.enabled` (or `autonomy_get`'s `enabled`) is
`false`, or on a store that reports no autonomy at all, nothing below applies.
Otherwise, when proposing a wave:

- **Leave out a part whose `agent_ok` is off** — its summary entry's
  `autonomy.agent_ok` in `release_next` / `release_get` (`autonomy.policy.agent_ok.value`
  in the full view). Name each one and say it is a person's to take; the store would
  refuse it `agent_not_allowed`.
- **Cap the wave at the room left**: `autonomy_get { release }`'s `policy.cap.value`
  minus the live autonomous claims — the `worker_list` rows whose `mode` is
  `autonomous`. A store whose rows carry no `mode` cannot be counted: say so, and let
  each claim's refusal decide. Propose the top startable parts up to that room and
  name the rest as waiting.

This is policy, not the dependency graph: it never overrides the graph guard below.

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

`dispatch_open` can also refuse the **whole** call, writing nothing:

- `agent_not_allowed` — `parts` names members whose `agent_ok` is off. Surface them,
  drop them from the set, confirm the smaller wave with the operator, then open it.
  On an unattended run there is nobody to confirm with: raise the escalation below
  and open nothing.
- `agent_cap_reached` — the workspace already has `current` of `max` autonomous
  agents live. Surface both numbers and stop: wait for one to end, or ask an owner
  to raise the cap. Never retry it in a loop.

**One escalation for a wave, at most, and it is this session's.** It is raised
**only** when this invocation said the run is unattended (the word `unattended`,
or plain words that mean it); it is asked for on a run and is never a standing
default. Then, when `dispatch_open` is refused as above, raise a single
`mcp__marshall__stop_raise { component, kind: "escalation", note }` —
on the first part the refusal names, or the wave's first requested part when it
names none (`agent_cap_reached`) — the `note` naming the refusal, the parts and
what is asked. Otherwise surface the refusal to the person driving and raise
nothing. Members
never raise one each, and a claim refused while the wave is set up (Step 3) raises
none. `$release-topic`'s **Escalating** and `$release-build`'s
**Leaving a stop record** have the rest.

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
    A member that stopped for a person left a stop on its part: read the part's
    `stops` with `mcp__marshall__release_get { release, view: "full" }` (the summary view
    carries none). Before holding a member back for a stop in `stops.open`, call
    `mcp__marshall__needs_you_list { view: "summary" }` once:
    - it answers normally → the stop is **still waiting on a person**: do not retry
      the member, and raise and clear nothing for it;
    - it answers `needs_you_disabled` → an open stop record is no reason to hold the
      member back: reconcile it as above. This is the **only** answer that lets a
      member with an open stop be retried;
    - the call fails any other way (a timeout, a server error, a denial, a tool
      that is not there to call) → the stop is **still waiting on a person**: do
      not retry the member, say that the inbox could not be read, raise and clear
      nothing for it, and never retry the call in a loop.

    Once a stop is answered, the member is picked up through
    `$release-build`'s Step 0, which reads the reply.
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

- explicit ids/refs from the user (`$release-parallel #41 #42 #45`, or "start
  wave 2") → use them as-is; the graph guard validates them.
- no ids → `mcp__marshall__release_next { release }` and propose the top startable
  components as the wave. **Confirm the set with the user** before dispatching —
  a wave spawns N subagents and N worktrees; it's worth a beat.
- either way, fit the set to the autonomy policy first — leave out parts whose
  `agent_ok` is off and size it to the cap's room (see **Sizing the wave to the
  policy**) — and say what was left out and why.

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

1. **Set the member up through `$release-topic --worktree`.** This is the
   *single* place the member is claimed, and release-topic runs its own procedure
   in its own order: its **reuse rule** checks first (a stop comes before any
   claim), then **Taking the claim**, then `in_progress` (only from `open`), then
   the checkout its reuse rule picked — reuse a checkout already on the part's
   `topic_branch`, attach to that branch if it exists, or create it off the active
   release branch as a **sibling git worktree** — then one beat with the location
   fields. The wave restates none of it, and never issues its own
   `claim_component` — a live re-claim throws `claim_conflict` even for the same
   holder, so one owner takes the lock and that owner is release-topic. Capture the
   resulting claim `id` + `fence` and the worktree path.
   - **release-topic stops** → do **not** spawn a subagent for the member. Drop it
     from the wave and carry it into the wave-wide report below as `{ member,
     status: "failed", note }`, so the board says why. `failed` is retry-able (see
     **Resume**). These stops leave no stop record on the part: the note is their
     trace. The note names the stop:
     - `claim_conflict: held by <holder>` — someone else holds it (the error names
       the holder).
     - `held by you on <machine> in <worktree>` — your actor holds it from another
       session; that session is working it.
     - `b′: <branch> checked out in <path>` — the branch is checked out in another
       worktree; the work belongs there.
     - `revoked: re-claim only on the operator's say-so` — its last claim was
       revoked.
     - `not_startable: <reason>` — its blockers or the graph changed after
       `dispatch_open`.
     - `agent_cap_reached: <current>/<max>` — the workspace's cap filled up: a wave
       wider than the room left still opens, and the claim past the cap is the one
       refused. Do not retry it; it waits for a later wave.
     - `agent_not_allowed` — its `agent_ok` was turned off after the run opened.
     - `worker_paused: workspace` — every worker in the workspace is paused, so no
       claim can be taken until an owner resumes.
2. **Do not set `in_progress` again.** release-topic has already moved the part to
   `in_progress` (only from `open`). A second `mcp__marshall__set_component_state { component,
   state: "in_progress" }` is an `invalid_transition`.
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
       { member: <member id>, status: "failed",     note: "b′: <branch> checked out in <path>" },
       ...
     ]
   }
   ```

   A wave dispatches N members at once, so this is one round trip and one minimal
   ack (`{ reported, members: [...] }`) instead of N. Mixed statuses in the same
   call are fine — the members that were set up report `dispatched`, the ones
   release-topic stopped report `failed`, together.

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

`dispatch_reports` moves only the board. When the orchestrator does land the parts'
work-state — `mcp__marshall__set_component_states { states: [{ component, state: "merged" },
...] }` — read a `batch_item_failed` exactly as `$release-topic`'s step 5
does; it is not restated here. On `reason: "missing_gate_records"` nothing in the
batch moved: **stop that landing**, and leave the refused part's member at
`proposed` with the note `missing_gate_records: <missing>`. Report a member
`merged` only when its part's state actually moved.

Auto-merging / auto-wrapping dispatched work is **out of scope** — this skill
dispatches and reports; landing each PR is the normal per-component lifecycle.

## Pausing or stopping a wave

On the operator's word — and only then — pause or stop members:

- `mcp__marshall__worker_pause { claim }` pauses one member: its claim stays held with the
  lease frozen and its writes wait. `mcp__marshall__worker_stop { claim }` stops it: the
  claim is revoked and the member's sessions stop. Either takes `component` instead of
  `claim`, or `all: true` for every worker in the workspace (a workspace owner's).
- A paused member's subagent ends its run and says so; put the pause on the status
  board from the answer, not with a `dispatch_report` (refused while paused).
- **Resuming** a member — its claim is autonomous — is a person's, from the
  **Workers** screen in Marshall: the store refuses an autonomous resume over MCP.
  Say so and point there.
- `autonomy_disabled` means the workspace's autonomy is off, so the kill switch is
  too; `not_authorized` means the worker is not yours or `all: true` needs an owner.

## The subagent brief

Each spawned subagent is scoped to exactly one component and its worktree. Hand
it: the **component id**, its **member id** (the dispatch_member ULID it reports
against), its **worktree path**, its **branch**, the **run id**, and its **claim
id + fence**. Its standing instructions:

1. Work only inside its worktree on its branch; do not touch sibling worktrees or
   the main checkout.
2. **Heartbeat its claim with its location** —
   `mcp__marshall__heartbeat_claim { claim, agent: "codex", machine: <machine>, worktree: <worktree path> }`,
   with `machine` read as `$release-topic`'s **Reporting where you work**
   says and `worktree` its member worktree — as it finishes each meaningful chunk
   of the work and immediately before a long-running operation (a full test run,
   static analysis). If a heartbeat returns `lease_lost`, **stop** and report
   `failed` — the lock was lost or revoked; do not keep writing.
3. **Report progress at meaningful checkpoints** via `mcp__marshall__dispatch_report {
   member, status, note }`, advancing through the lifecycle:
   - `in_progress` when it starts (with a one-line plan in `note`),
   - `proposed` when it opens its PR (`note: <PR url>`),
   - `failed` if it can't complete (the `note` carries why — and is the resume
     signal for a retry on the next invocation). When it stopped for a person —
     one of `$release-build`'s five stops — the stop record comes first:
     release-build's **Leaving a stop record** is the one raise
     (`mcp__marshall__stop_raise`, on its own part only), and the `failed` note then says
     the same thing in a sentence. It reports `failed` either way,
   - `merged` only if its PR actually lands in this session (usually it stops at
     `proposed`; merging is a separate decision).
   The part is already `in_progress` — release-topic set it during setup — so it
   never sets `in_progress` again. It moves the work-state on with
   `set_component_state`: `proposed` with its PR, `merged` if the PR lands. That is
   the lock-adjacent work-state; `dispatch_report` is the wave's semantic progress.
   They mirror, they don't duplicate.
   - **Read the part before each of those writes** (`mcp__marshall__release_get`) and skip
     one whose value is already there — `proposed` or `merged`, its `pull_request`,
     its `merge_sha`. A host plugin that records a successful `gh pr create` or
     `gh pr merge` on its own (and says so) may already have written it, and
     writing it again is an `invalid_transition`. The `dispatch_report` is still
     the subagent's to send: no plugin reports wave progress.
   - If `merged` is refused with `missing_gate_records`, nothing moved: leave the
     part and the member at `proposed`, report `{ member, status: "proposed", note:
     "missing_gate_records: <missing>" }`, keep the claim, and stop. What the
     refusal means and the way past it are `$release-topic`'s step 5,
     **Refused with `missing_gate_records`**.
4. **It obeys its part's autonomy level** — its claim is autonomous — by running
   `$release-build`, whose **The part's level** says how far it lands: `suggest`
   reports back with no PR, `pr_and_wait` stops at `proposed` for a person's
   **Approve merge**, `merge` lands.
5. **A pause or a stop is a person's.** A heartbeat or write refused `worker_paused`
   means a person paused it: stop at once, and end with what the refusal says — who
   paused it and when (`paused_by.display_name`, `paused_at`). Do **not** send a
   `dispatch_report`: the store refuses that too while the claim is paused. A
   `lease_lost` after a stop means a person stopped it: stop, and do not re-claim.
   Never resume a claim itself. The rest of the refusals are
   `$release-topic`'s **Autonomy — the claim's mode and the refusals**.
6. It does **not** open or close the run, claim other components, or merge other
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
  `lease_lost`, an open-run conflict, `agent_not_allowed`, `agent_cap_reached`,
  `worker_paused`, `autonomy_disabled`, `not_authorized` — and stop. Never work around
  them, and never retry one in a loop.
- **A wave fits the policy.** Leave out parts whose `agent_ok` is off, size the wave
  to the cap's room, and let a person resume a paused member from the Workers screen.

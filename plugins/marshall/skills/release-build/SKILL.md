---
name: release-build
description: "Carry one release component from unclaimed to merged in a single guided loop against the shared Marshall store: claim → plan → pressure-test the plan → build → prove the tests can fail → change-review → fix → independently verify the fixes → land. Composes $release-topic (the claim lifecycle) and $change-review (the lens mechanics); owns only the sequencing, the two reviews that have no home today, and the landing. Use when the user says $release-build, build <component>, run the component loop, take this component to merged, or hands you a claimed component to carry through — including entering mid-stream (resume, or land-only) to finish an already-built, already-reviewed component."
---

# Release Build (Marshall)

Carry **one component** from unclaimed to merged in a single guided loop, against
the shared Marshall store. The sequence — claim, plan, pressure-test the plan
before any code, build, prove the tests can fail, change-review, fix, verify the
fixes independently, land — has been retyped by hand every component. This is that
sequence, once.

The plugin has one composer today, `$release-wrap`, and it works at
**release** level: all-merged → review each component → CHANGELOG → readiness →
gate → hand off. There has been no **component**-level equivalent. This is that
missing sibling: it sits *below* wrap and *produces* the merged components wrap
later consumes.

## What it owns, and what it composes

This skill owns only three things: the **sequencing**, the **two review steps that
have no home anywhere else** (Steps 3 and 8), and the **landing**. Everything else
it composes — it does not restate:

- The **claim lifecycle** — claim, heartbeat, the "lost claim id is a lookup, not a
  re-claim" recovery — is `$release-topic`'s. Step 1 delegates to it wholesale.
- The **lens mechanics and findings** — lens config, the applicable-lens pre-filter,
  the per-lens fan-out, the verdict rubric, `record_findings` / `resolve_findings` —
  are `$change-review`'s. Step 7 delegates to it wholesale.

Changing what either of those skills does is **out of scope** (see Guardrails).

## How it talks to the store

- `mcp__marshall__release_get` — resolve the component, read its
  `notes` (the plan of record: GOAL, acceptance criteria, out-of-scope, `touches`),
  its work-state, and the existing `kind: change` findings. **The store, plus git,
  is where the resume point comes from — never conversation memory.**
- `mcp__marshall__heartbeat_claim` — keep the explicit claim's lease
  alive on a structural cadence: beat it **at each step boundary**, and again
  **immediately before a long-running operation** (Step 4 build, Step 6's full test /
  PHPStan run, Step 7's change-review fan-out) — a cadence tied to the work, not a
  timer to remember. Every beat passes the three location fields —
  `{ component, agent: "codex", machine, worktree }`, determined as
  `$release-topic`'s **Reporting where you work** says. A `lease_lost` is a
  stop — run release-topic's **Taking the claim** rule before continuing.
- `mcp__marshall__set_component_state` — move the work-state:
  `in_progress` (Step 1, only from `open`) → `proposed` (PR open, Step 9) → `merged` (landed, Step 9).
  Marking it `merged` is what unblocks dependents; releasing the claim alone does not.
- `mcp__marshall__record_findings` — **only** to record an out-of-scope
  problem against the release: pass it with **`component_id` omitted** (that omission
  is what keeps it release-scoped rather than folded into this component) and the
  `kind` that fits — `change` for a code concern, `readiness` / `design` otherwise.
  The component's own `kind: change` findings are change-review's to write, never this
  skill's.

The claim lifecycle tools (`claim_component`, `release_claim`, `my_claims`) are
driven **through** `$release-topic`, not called here directly.

## Autonomy — and the three hard stops

This loop is built to run **start-to-merge unattended**: dispatched against a
claimed component, it plans, builds, reviews, fixes, verifies, and lands without a
human at each boundary. That is the point — it matches the standing "auto-merge
when clean" instruction, where *clean* is the exit condition, not a hope.

Within the build loop it **hard-stops on exactly three things**:

1. **A high finding that cannot be fixed inside the acceptance criteria.** Fixing it
   would require inventing scope. Stop; the fix is a scoping decision, not a build one.
2. **CI red after one fix attempt.** One honest attempt to make it green; a second
   red is a signal the change is wrong, not that the test is flaky. Stop.
3. **Genuine scope ambiguity.** The plan of record doesn't answer a question the
   build forces. Stop and ask — never guess and never widen the component to cover it.

These three are the *build-loop* stops. The precondition and lease failures —
`claim_conflict` / `not_startable` at Step 1, `lease_lost` mid-run — and Step 0's
"two signals disagree" stop belong to the **claim lifecycle**, not the loop; they are
`$release-topic`'s stops, and they are not counted among these three. A
further stop — being **blocked by a pre-existing failure outside your `touches`** — is
release-build's own but is likewise not one of the three; it has its own verb (below).

**A hard stop leaves the claim held.** Resuming costs nothing: the lease is yours,
the branch is yours, and Step 0 re-derives exactly where you were. A hard stop is a
pause, not an abandonment.

### The out-of-scope blocker — a stop with a verb

One failure is neither one of the three above nor a claim-lifecycle stop: your
component is **blocked by a pre-existing failure outside your `touches`** — code you
did not write and cannot fix inside your acceptance criteria (a sibling component's
PHPStan debt reddening shared CI, a broken test in a file you never opened). This is
**not hard-stop #2**: you did not cause this red, so "one honest fix attempt" does not
apply — the fix is not yours to make. Nor is it the ordinary *noticed* out-of-scope
problem, the one you record against the release and keep going (Steps 4, 6): a blocker
you merely record **stays red**, because **recording a finding against the release does
not unblock red CI — a finding is a note, not a verb.**

The default is **hard-stop-and-surface** — to the human when a human is driving —
leaving the claim held so resuming is free. Do **not** reach into the other component's
code to make CI green: that smuggles an unclaimed, unreviewed change into this
component's diff, and — the multi-actor hazard — **someone may hold that other
component** right now; silently fixing it and merging past them is exactly
**what claims exist to prevent**.

If fixing the blocker is genuinely sanctioned, it is a **sanctioned sibling** — a
**separate claimed + branched + change-reviewed** unit, recorded on the release and
landed on its own merits, **not merged past the blocked code's owner** and never riding
in on this component's diff. Whether to open that sibling at all is a scoping call, not
a build one: if it is unclear, that is scope ambiguity (hard-stop #3) — surface it,
never guess.

### The merge dial

Landing (Step 9) is the one step with a mode, because whether a clean run *merges*
or *parks* is the operator's call, not the skill's:

- **autonomous** — auto-merge when clean (the three hard stops — and the out-of-scope
  blocker above — are the only brakes). This is how a dispatched/unattended run lands,
  and what `$release-parallel` expects.
- **supervised** — land the PR to `proposed` and stop; a human merges. This is the
  default when a human is driving interactively.

The **gates are identical and mandatory in both** — the dial governs only the final
merge, never whether the plan was pressure-tested or the tests were proven. Resolve
the mode at Step 0 (dispatched → autonomous; interactive → supervised) and say which
one you are driving.

An explicit operator instruction **overrides this default** — `merge it` selects
autonomous even in an interactive session, `park it` selects supervised even in a
dispatched one. The entry mode does **not** add a second merge axis: `land-only`
(below) inherits this same dispatched → autonomous / interactive → supervised
default, with the same override.

## The two steps that must not be optimised away

Both were invented under fire and both caught defects every other layer missed.
They are **non-skippable** — a run that skips either is not a release-build run:

- **Step 3 — pressure-test the PLAN before any code.** A plan reviewed *after*
  implementation gets reviewed as code, and a whole class of defect is invisible at
  that altitude. A real plan here was wrong in nine places, three of which would
  have shipped a fix that looked correct and did not work.
- **Step 8 — verify the FIXES independently**, by a reviewer that **did not produce
  the findings**. An independent pass once found a change that walked operators into
  the exact data loss the release existed to prevent — *after* both review lenses had
  already cleared it. The finder is the wrong judge of the fix.

## Entering to finish — resume and land-only

The loop runs top-to-bottom by default (a **full** run). Two other entries are
first-class, and both run the **gate attestation** at Step 0 rather than assuming
the skipped steps happened:

- **resume** — re-enter your OWN paused run. Step 0's ladder derives where you
  were; because the plan and the two gates leave no store footprint, a resume
  point past Step 3 is **attested out loud**, not silently continued.
- **land-only** — enter to finish a component that was **already built and
  change-reviewed by another owner or session** — the last mile. Run Steps 6 → 9
  (gates → change-review reconciliation → independent verify → land), opening with
  an explicit acknowledgement that **Steps 2–5 were another owner's
  responsibility**, and running the gate attestation to account for Step 3 before
  proceeding. **Land-only drops nothing that guards quality:** Step 8's independent
  verify and the three hard stops stay in force, and Step 5 (prove-can-fail) is
  satisfied vacuously **only if this entry adds no new guard** — if it adds one,
  prove it. Land-only exists so the last mile is not carried by pretending to
  re-run gates that already ran; it is **not** a fast-path around them.

**Worked example — land-only, mid-stream.** Another session built and
change-reviewed a component and stopped; you enter to land it. Step 0 derives a
resume point past Step 3 and says so out loud: *commits and `kind: change`
findings exist, but Step 3 (the plan pressure-test) leaves no footprint and cannot
be confirmed from state, so it will not be assumed to have run.* If you know it was
pressure-tested upstream, you attest that and the loop records it and proceeds; if
you do not, it runs a **plan-vs-implementation review** before touching Step 8.
Either way the skip is surfaced, never buried.

## Procedure

Announce each step on entry; a human driving can interrupt at any boundary. The
whole loop is **resumable from the store + git** (see Step 0) — never from memory.

### Step 0 — Resolve, and derive the resume point
- Resolve the component (an explicit ref → the active Marshall claim → the current
  branch name). On resume, **two present signals that disagree is a STOP** — the diff
  under review and the finding scope would refer to different components.
- **On a resume or land-only entry only** — a part already in progress — confirm
  you still hold it **before deriving anything**. First run
  `$release-topic`'s **reuse rule** checks (its stops come before any
  claim), then its **Taking the claim** rule: it finds a hold you still own through
  `my_claims` and never re-claims it, re-claims a lapsed part, and stops on a part
  someone else holds or that was revoked.
  Never derive a resume point on a part you do not hold.
  A **full** run skips this bullet — Step 1 takes the claim.
- `release_get` and read the component's `notes` — the **plan of record**. Its GOAL,
  acceptance criteria, and out-of-scope are the contract this run delivers against;
  its `touches` names the files.
- Derive the resume point from observable state, and **re-run the covering gate on
  ambiguity** — the plan and the two gates leave no store footprint, so re-running
  them is how resume stays honest, and each is safe to repeat:
  - **the part is not yet claimed** (still `open`, nobody holds it) → start at
    **Step 1**, even when its topic branch or worktree already exists — the
    Workspace app may have created them and opened this terminal inside. Step 1's
    reuse rule picks up that checkout; the ladder below applies once you hold it.
  - **no topic branch** → start at Step 1.
  - **branch exists, no commits** → the plan lived only in memory and is gone;
    re-run **Steps 2–3** (rebuild the plan, then pressure-test it) before Step 4.
  - **commits exist, no `kind: change` findings** → built but unreviewed; re-run
    **Step 5** (prove-can-fail) before Step 7.
  - **findings exist** → reconcile against them in Steps 7–8.
- **Attest the upstream gates — out loud.** The plan (Step 2) and the two gates
  (Steps 3, 8) leave no store footprint, so at any resume point past them the loop
  cannot tell from state whether they ran. **Do not assume they did.** When the
  derived point is at or past Step 4 (commits exist), name the non-skippable gates
  that cannot be confirmed and account for each before continuing — for Step 3: if
  no code exists yet, run it; if code already exists a pre-code pressure-test is
  impossible, so run its closest equivalent, a **plan-vs-implementation review**,
  or — on the operator's attestation that it ran upstream — record it attested, or
  declare it **void with the reason stated**. A gate you cannot confirm and do not
  account for is a silent skip, the one thing this loop must never do.
- Resolve the **merge dial** (dispatched → autonomous; interactive → supervised) —
  an explicit operator instruction overrides it.

### Step 1 — Claim + branch  *(composes `$release-topic`)*
Run `$release-topic`'s procedure: confirm startable, the **reuse rule**
checks (their stops come before any claim), then its **Taking the claim** rule —
which never calls `claim_component` on a part you already hold, so a resume that
confirmed the hold at Step 0 does not claim again. Handle `claim_conflict` /
`not_startable` as hard stops. Set `in_progress` **only when the part is `open`** —
skip it when the part is already `in_progress` (`in_progress` → `in_progress` is
an `invalid_transition`). Then reuse, attach, or create the topic branch as the
reuse rule picked. Delegated wholesale — no claim logic is restated here. Beat the claim at each step boundary
through the loop below (see the `heartbeat_claim` note above).

### Step 2 — Plan the component
Write an implementation plan **before any edit to source**: the files to touch
(cross-checked against the plan-of-record `touches`), the approach, the blast
radius, and the **test strategy** — which guard proves which behavior, and where a
change crosses a protocol boundary so its **wire shape** needs a guard, not just its
code path. No source edits in this step.

### Step 3 — Pressure-test the plan  *(gate — no code until it survives)*
Adversarially critique the Step-2 plan: what it misses, what breaks downstream, the
migration / tenant / flag risk, whether a simpler shape exists. **Hybrid, mirroring
change-review's compressed pass:** an independent subagent for a non-trivial plan
(the author must not grade their own work); an inline adversarial pass for a trivial
one. Every subagent **this skill spawns** (here and Step 8) carries the **scope
constraint verbatim** (see below) — change-review's own per-lens subagents are its to
prompt, not this skill's. Revise until the plan survives. Writing code before it
survives is the failure this step exists to prevent.

### Step 4 — Build
Implement to the surviving plan and the acceptance criteria — **no more.** Do not
invent acceptance criteria; an out-of-scope problem you notice is recorded against
the release (Step 6), not folded in. Beat the claim on entering this step, and again
immediately before a long-running operation (the full test / PHPStan run in Step 6);
a `lease_lost` is a stop → run `$release-topic`'s **Taking the claim** rule.

### Step 5 — Prove the tests can fail  *(gate — a guard you haven't watched fail is not proven)*
For each new or changed guard: **mutate the source it protects, watch the test go
red, then restore.** A test that passes both before and after its guard is removed
does not count. **Where the change crosses a protocol boundary, mutate the WIRE
shape, not only the code path** — a guard that only sees the internal call proves
nothing about the bytes on the wire. This is the single most-skipped step in the
hand loop; it is non-skippable here.

### Step 6 — Run the repo's real gates
Run every gate `.claude/release-config.json` names (tests, lint, static analysis,
and the frontend gates where the change touches frontend) and confirm each **passes
and actually runs** — a config that names a gate it doesn't run is lying, and the
loop is only as honest as the config. **One honest fix attempt on a red gate; a
second red is hard-stop #2, and the claim stays held.** Record any genuinely
out-of-scope problem against the **release** — `record_findings` with `component_id`
**omitted**, never against this component. But a red gate you did **not** cause — a
**pre-existing failure outside your `touches`** — is a different case: not hard-stop #2,
and a release finding notes it without unblocking it. That is the **out-of-scope
blocker** (see Autonomy above), whose default is **hard-stop-and-surface**.

### Step 7 — Change-review  *(composes `$change-review`)*
Run `$change-review` against the component diff. It records `kind: change`
findings scoped with `component_id`, reconciling against existing ones. The diff base
is change-review's (`merge-base origin/<default_branch> HEAD`); this skill only
guarantees the topic branch descends from a clean base. Do not re-specify a base.

### Step 8 — Fix, then verify the fixes independently  *(gate)*
Walk every `open` `kind: change` finding; drive each to fix / defer / accept through
change-review's modes. After a **fix**, re-run the affected gates (**one fix attempt;
a second red gate is hard-stop #2**) and **re-prove (Step 5)** any guard the fix added
or changed.

Then **verify the fixes independently — spawn a subagent that did not produce the
findings and did not write the fixes.** Hand it the diff, the fixes, the acceptance
criteria, and each finding; it confirms that each fix actually resolves its finding
and introduced no new gap. It is a subagent this skill spawns, so it **carries the
scope constraint verbatim** (see below). The finder is the wrong judge of its own fix.

A **high** `kind: change` finding left `open` or `deferred` is hard-stop #1 unless it
can be fixed inside the acceptance criteria.

### Step 9 — Land
- Open/update the component PR → **`set_component_state proposed`**.
- **Merge dial:**
  - autonomous → when clean (no unfixable high, gates green, no ambiguity), merge,
    then **`set_component_state merged`**.
  - supervised → stop at `proposed`; report the landing state and let the human merge,
    who (or a follow-up) sets `merged`.
- `merged` is what unblocks dependents — set it on merge, not just at unclaim.
- Release the claim (`$release-unclaim`), and hand back:
  `$release-next` if components remain, else `$release-wrap`.

## The scope constraint (verbatim, in every subagent this skill spawns)

> Deliver exactly the component's acceptance criteria — do not invent new ones. A
> problem outside this component's scope is **recorded against the release**, not
> folded into this component. If the criteria do not answer a question the work
> forces, that is scope ambiguity: stop and surface it, never guess.

## Guardrails

- **Compose, don't duplicate.** The claim lifecycle is `$release-topic`'s;
  the lenses and findings are `$change-review`'s. This skill restates neither,
  and **changing what either does is out of scope.**
- **The two gates are non-skippable.** No code before Step 3 survives; no landing
  before Step 8's independent verification. The merge dial governs only the merge.
- **No silent gate-skip.** The plan and the two gates leave no store footprint, so
  entering past them means accounting for them **out loud** (Step 0 attestation) —
  run the gate, run its closest equivalent (a plan-vs-implementation review), or
  declare it void with the reason. Never assume a non-skippable gate ran, and never
  let `land-only` become a fast-path around Step 8 or the three hard stops.
- **A guard you have not watched fail is not proven** — including the wire shape at a
  protocol boundary, not only the code path.
- **Deliver the acceptance criteria, nothing more.** Out-of-scope problems are release
  findings (`component_id` omitted), not silent scope creep. Genuine ambiguity is a
  hard stop, not a guess.
- **Exactly three build-loop hard stops** — an unfixable high, CI red after one fix
  attempt, scope ambiguity — and **a hard stop leaves the claim held** so resuming is
  free. Precondition / lease failures are release-topic's stops, not these.
- **The out-of-scope blocker has a verb.** Being **blocked by a pre-existing failure
  outside your `touches`** is **hard-stop-and-surface** by default, claim held; a
  sanctioned fix is a **separate claimed + branched + change-reviewed** sibling recorded
  on the release, never smuggled into this diff and never merged past the blocked code's
  owner. A release finding notes the blocker; it does not unblock it.
- **Resume from the store + git, never conversation memory.** Re-derive the step and
  re-run the covering gate on ambiguity.
- **The claim is the source of truth, not the branch.** Beat an explicit claim at
  each step boundary and before a long-running operation, with `agent`, `machine`,
  and `worktree` on every beat. A lost claim *id* is a lookup, never a re-claim
  (`my_claims`); a genuinely *lapsed* lease is a deliberate re-claim — the fence
  bumps, which is expected — through release-topic's **Taking the claim** rule, which
  stops and names the holder if someone else took the work.
- **Reuse, don't re-create.** Where the part is worked is decided by
  `$release-topic`'s **reuse rule**, never restated here; this skill never
  runs `git worktree add` on its own.
- **Landing is `merged`, not just unclaiming** — releasing the lock alone leaves
  dependents blocked.
- **Build stops at one merged component.** It never wraps, deploys, or tags — and it
  does not enforce the loop server-side; a skill is a prompt, not a gate.

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
  its work-state, its `gate_records`, and the existing `kind: change` findings. **The store, plus git,
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
  A project can **require** gate records: the move to `merged` is then refused with
  `missing_gate_records` while a required gate has no record (see **A merge the store
  refuses**).
- `mcp__marshall__record_findings` — **only** to record an out-of-scope
  problem against the release: pass it with **`component_id` omitted** (that omission
  is what keeps it release-scoped rather than folded into this component) and the
  `kind` that fits — `change` for a code concern, `readiness` / `design` otherwise.
  The component's own `kind: change` findings are change-review's to write, never this
  skill's.
- `mcp__marshall__record_gate` — write a **gate record** on the component
  when a gate finishes (Steps 3, 5 and 8), and at Step 0 when a gate that could not
  be confirmed is accounted for. See **Gate records** below — it is how the loop's
  rigour is read back by the next session.

- `mcp__marshall__component_update` — write the part's **landing facts** at
  Step 9: its closing summary, its pull request and its merge commit. See **The
  landing facts** below — they are what the release's record says this part did.

The claim lifecycle tools (`claim_component`, `release_claim`, `my_claims`) are
driven **through** `$release-topic`, not called here directly.

## Gate records — every gate ends in a record

The three gates each leave a record on the component: `plan_pressure_tested`
(Step 3), `guards_proven` (Step 5), `fixes_verified` (Step 8). The store keeps what
you report and checks its shape; it re-runs nothing. Every call has the same frame:

```
mcp__marshall__record_gate {
  component: <id>, kind: <kind>, outcome: "passed" | "waived",
  commit: <git rev-parse HEAD>, evidence: { … }, reason: <required for a waiver>,
  agent: "codex", machine: <machine>, return: "minimal"
}
```

`commit` is always the output of `git rev-parse HEAD` at the moment the gate
finished — at Step 3 that is the branch tip before any code. `agent` and `machine`
are the same values every heartbeat carries.

| Gate | `evidence` for a `passed` record |
| --- | --- |
| `plan_pressure_tested` | `{ verdict, changes: [what changed in the plan, …] }` — `changes` is `[]` when the plan survived as written |
| `guards_proven` | `{ guards: [{ test, mutation, observed_failure }, …] }` — one entry per guard you watched fail |
| `fixes_verified` | `{ verdict, findings: [<finding id>, …] }` — the finding **ids** the verifier checked (not their refs); `[]` when the review found nothing |

A record of a check that was handed to the other agent also carries `reviewer` in
its `evidence` (see **The reviewer dial**); the store keeps it as it keeps any extra
evidence key.

Records are append-only: recording a gate again adds a record and keeps the earlier
one as history, so re-running a gate is recorded again, never edited.

**A gate that ran is never left unrecorded — losing the record loses the evidence.**
The order of fallbacks, each tried once, never in a loop:

1. **A refusal names its fix.** `invalid_gate_record` carries the `field` at fault and
   the `expected` shape; `session_required` and `verifier_not_independent` say which
   `session` to pass. Correct that field and record again — at most **two**
   corrections.
2. **Still refused → record it as a waiver that carries the evidence.** Send
   `outcome: "waived"` with `reason: "gate ran; the passed record was refused: <error> <field>"`
   and the same `evidence` attached. A waiver needs only its `reason` and a valid
   `commit`: its evidence is not checked and is kept whatever its shape (anything
   that is not an object is stored as `{ notes }`), so nothing you proved is lost. If the refusal was
   about `commit` itself, send `git rev-parse HEAD` again — that is always valid.
3. **The store cannot take a record at all** — the call fails as an unknown tool (a
   store older than gate records) or the store is unreachable. Decide this from the
   call's own failure, never from a tool listing. Append the full call as one JSON
   line to the **gate outbox**,
   `$(git rev-parse --path-format=absolute --git-common-dir)/marshall/gate-outbox/<component id>.jsonl`
   (it lives in the main checkout's git directory, so it survives the worktree being
   removed), say so, and carry on. **Replay the outbox** — send each line, delete the
   file once every line is recorded — at the next step boundary, at Step 9, and at
   Step 0 of any later run on this part.

A record that could not be written is a recording problem, never a build-loop stop:
it does not halt the loop and it is not one of the three hard stops. Nor does a
waiver stand in for a gate you skipped — a waiver is for a gate that did not run
(say why) or for fallback 2 above. The two **non-skippable** gates — Step 3 and
Step 8 — stay non-skippable: neither is waived to save the work of running it. Step
5 is waived only when the component added or changed no guard.

The one place an unrecorded gate matters is landing: when the project **requires**
that gate and the store still has no record of it, the part cannot be marked
`merged` (see **A merge the store refuses**).

## The landing facts — what the record keeps of this part

The summary this loop ends with is gone when the terminal closes, and a part does
not otherwise know its own pull request or merge commit. Step 9 writes them to the
part, in two calls, and a shipped release's page reads them back as its record:

```
mcp__marshall__component_update { component, closing_summary: <text>, pull_request: { number: <N>, url: <link> }, return: "minimal" }
mcp__marshall__component_update { component, merge_sha: <the merge commit>, return: "minimal" }
```

- **The first, once the pull request is open** — on both settings of the merge dial.
  - **`closing_summary`** — plain text, a few short paragraphs, at most 4000
    characters. It says **what the part did**, **how it was proven** (what the
    plan's pressure-test changed, which guards were watched failing, who verified
    the fixes) and **what review found and what was done about it** (found, fixed,
    accepted, deferred — and anything recorded against the release instead). It
    describes the work, not the landing: it never says "merged". It is not the plan
    and not a log of the run's decisions.
  - **`pull_request`** — `{ number, url }`, sent whole in the shape it is read back
    in. The link must be `http` or `https`, with no credentials in it.
- **The second, in the run that sets the part `merged`** — the autonomous merge, or
  a resumed or land-only run that finds the PR already merged by a human and sets
  `merged` itself. Read the commit from the pull request
  (`gh pr view <N> --json mergeCommit --jq .mergeCommit.oid`), never from memory. A
  supervised run that stops at `proposed` has no merge commit to write, and says so
  in its landing report.

These are reported, not verified, and the store takes them at any time — after the
part is merged and after the release has shipped — so a part merged by hand outside
this loop can have them set afterwards with the same calls. A field you leave out
is left as it is.

A store older than the release record ignores these fields: the component it
returns carries no `closing_summary`. Say so in the landing report and carry on —
it is not a stop, and there is nothing to retry.

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
`$release-topic`'s stops, and they are not counted among these three. Two
further stops are release-build's own but are likewise not among the three, and each
has its own verb (below): being **blocked by a pre-existing failure outside your
`touches`**, and **a merge the store refuses** for a gate record the project requires.

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

### A merge the store refuses — a stop, never a waiver

A project can require gate records. Its required gates are `config.required_gates` on
`mcp__marshall__release_get` — any of `plan_pressure_tested`, `guards_proven`,
`fixes_verified`; an empty list, the default, requires none. While a part has no
record of a required gate, the store refuses its move to `merged` with
`missing_gate_records`, naming the gates in `missing`. Any record of the kind
satisfies it, `passed` or `waived`.

Recording the gates as they run (Steps 3, 5, 8) is what keeps this from ever firing.
When it does — Step 9's own check finds a required gate with no record, or the store
answers `missing_gate_records` — **stop and name the missing gate**. The claim stays
held, so resuming is free.

**Never write a waiver to get past it.** Not a void, not an attestation, not a waiver
that carries evidence: from the moment a required gate is found missing at landing, a
waiver for it is the operator's to give. The project asked for that record so that
skipping the gate takes a deliberate act by a person, and a loop that waives its own
way through has answered the requirement with nothing. The rest of **Gate records**
is unchanged — a gate that ran is still recorded when it finishes, by every fallback
there.

### The merge dial

Landing (Step 9) is the one step with a mode, because whether a clean run *merges*
or *parks* is the operator's call, not the skill's:

- **autonomous** — auto-merge when clean (the three hard stops — and the out-of-scope
  blocker and the store's merge refusal above — are the only brakes). This is how a dispatched/unattended run lands,
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

### The reviewer dial

Who runs the checks that must be independent of the builder is the operator's call
too, and it is **asked for, never assumed**:

- **same agent** — a subagent of the builder runs them. This is the default: with
  nothing said, every step below runs exactly as written.
- **the other agent** — the other coding agent on this machine runs them, headless,
  from this session. The operator asks for it in the invocation: `reviewer: other`,
  or plain words that mean it.

It is asked for on a run of a part and **never becomes a standing default**: a
dispatched run does not turn it on, nor does memory, a config file, or what an
earlier run on this part did. `reviewer: same`, or saying nothing, is the same
agent — on a resume too. Resolve it at Step 0 and say which one you are driving. On a
resume with nothing said, if a gate record on the part carries
`reviewer: "claude-code"`, say so — the operator may want to ask again — and
stay on the same agent.

**What is handed off.** Every check this skill requires to be independent of the
builder: Step 3's pressure-test of the plan, the plan-vs-implementation review that
Step 0 runs in its place, and Step 8's verification of the fixes. Step 3 is handed
off **always** — the inline pass a trivial plan may take is the builder's own, so it
is no review by the other agent. Step 5 is the builder's own work and stays with it,
and `$change-review`'s per-lens subagents are its to prompt.

**Handing a check off — a failed hand-off is never retried; it falls back.** The
commands, checked on the CLI version the block names — an older CLI may refuse a
flag, and that is a fallback too:

```bash
# The other agent is Claude Code. Checked on Claude Code 2.1.293.
# 1. Installed, and signed in ("loggedIn": true)? If not, fall back: run
#    nothing below.
command -v claude && claude auth status
# 2. A new folder for every hand-off. Write brief.md (and diff.patch) into
#    the folder this prints.
handoff=$(mktemp -d) && echo "$handoff"
# 3. Run it once, from the part's checkout. Set handoff to that folder again
#    if your shell did not keep it. Read the printed exit= first.
cd "$(git rev-parse --show-toplevel)" && claude -p --safe-mode --tools "Read,Grep,Glob" \
  --strict-mcp-config --permission-prompts none --no-session-persistence \
  --add-dir "$handoff" \
  < "$handoff/brief.md" > "$handoff/verdict.md" 2> "$handoff/log.txt"; echo "exit=$?"
```

The three steps are the block's own `# 1.`, `# 2.` and `# 3.`:

1. Run the command under `# 1.`. If the CLI is missing or not signed in, **fall
   back** (below) and run nothing else.
2. Run the command under `# 2.` and **note the path it prints**: a shell that keeps
   no variables between commands needs `handoff` set to it again in step 3. Write
   the **brief** into that folder as `brief.md`: the check to run; the acceptance
   criteria; what is under review — the plan, or each finding and the fix made for
   it, with the diff saved beside it as `diff.patch` (the reviewer may have no shell
   to run `git diff` with); **the scope constraint verbatim**; for Step 8, the
   verifier's session token; and how to answer — say what it read, change nothing,
   call no store tool, and end with the verdict line. The brief itself never ends
   with a verdict line.
3. Beat the claim, then run the command under `# 3.` once, from the part's checkout
   — in the background where the host can, otherwise with the longest timeout the
   host allows — and keep beating the claim while it runs. A review of real size
   takes minutes. One that has not finished in **30 minutes** is stopped, and that
   is a fallback.

**Read the printed `exit=` first.** Read `verdict.md` only on `exit=0`; on anything
else it is a fallback, whatever the folder holds.

The reviewer is **read-only by construction**: it can read the checkout, the brief
and the diff, it cannot change the builder's files, and it holds no store tool — the
builder records the gate. It starts without the operator's plugins, hooks and MCP
servers, so nothing of the builder's setup steers it. It leaves no session behind for a later "continue the most
recent conversation" to pick up. It runs no test suite, so for Step 8 this is a
narrower check than a same-agent verifier that can run the tests: hand it the test
and mutation output it should weigh, and have its verdict say what it read.

**The verdict.** The last non-empty line of `verdict.md` — a closing code fence
skipped, one pair of backticks around the line removed — must be exactly one of:

- for a plan: `VERDICT: SURVIVES`, `VERDICT: SURVIVES WITH CHANGES`, `VERDICT: DOES NOT SURVIVE`
- for fixes: `VERDICT: VERIFIED`, `VERDICT: NOT VERIFIED`

Everything above that line is the review: read it back into the loop as you would a
subagent's report. `DOES NOT SURVIVE` and `NOT VERIFIED` are verdicts, not failed
hand-offs: revise the plan or fix what was not verified, then hand off again (a new
hand-off, in a new folder). A verdict you do not like is never a reason to fall back.

**Falling back.** The other CLI is **missing**, it is **not signed in**, it **exits
with anything but 0**, it **does not finish** in time, or it finishes **without a
verdict line** — then run the check with a same-agent subagent, exactly as the
default does, and **say plainly that it fell back and why**. The fallback is
**always a subagent, never the inline pass**, however small the plan. A failed
hand-off **never passes a gate on its own**: with no verdict there is no pass until
the fallback's subagent gives one. A fallback covers that one check only: **each
check makes its own hand-off attempt**, so a Step 3 that fell back does not stop
Step 8 trying the other agent.

**The record names the reviewer.** A gate record for a check that was handed off
carries who reviewed, as `reviewer` in its `evidence`: `reviewer: "claude-code"`
when the other agent gave the verdict, `reviewer: "codex"` when it fell back. Its
`verdict` text says the same in words — who reviewed, and on a fallback that it fell
back and why — because the verdict is what a person reads. On the default setting the
record is written exactly as each step shows, with no `reviewer`. The store's
independence rule is untouched: Step 8 still mints the verifier's token, the brief
carries it, and the record is written with it as `session`. `reviewer` says who
reviewed; it never stands in for `session`.

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
  were, and reads the part's **gate records** to see which gates already ran. A
  gate with a record is confirmed from the store; a gate with none is **attested
  out loud**, not silently continued.
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
resume point past Step 3 and reads the part's gate records. If a
`plan_pressure_tested` record is there, it says so — who recorded it, when, against
which commit — and moves on: the gate ran, and nothing is declared void. If there is
none, it says so out loud: *commits and `kind: change` findings exist, but the part
carries no `plan_pressure_tested` record, so Step 3 will not be assumed to have
run.* If you know it was pressure-tested upstream, you attest that and the loop
records it and proceeds; if you do not, it runs a **plan-vs-implementation review**
before touching Step 8, and records that. Either way the skip is surfaced, never
buried.

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
  someone else holds or that was revoked — or that your actor holds from another
  machine or worktree (another session is working it).
  Never derive a resume point on a part you do not hold.
  A **full** run skips this bullet — Step 1 takes the claim.
- `release_get` and read the component's `notes` — the **plan of record**. Its GOAL,
  acceptance criteria, and out-of-scope are the contract this run delivers against;
  its `touches` names the files.
- **Replay the gate outbox** if this part has one (see **Gate records**), so records
  an earlier run could not write land before anything is derived from them.
- **Fill a merge commit a run left blank.** A part that is `merged` with a
  `pull_request` on record and no `merge_sha` was landed by a run that ended before
  writing it. Read the commit from the pull request and write it (see **The landing
  facts**), then report the part as landed — there is nothing else to resume.
- Derive the resume point from observable state — the branch, the commits, the
  `kind: change` findings, and the component's `gate_records` and landing facts
  (`closing_summary`, `pull_request`, `merge_sha`) from
  `mcp__marshall__release_get` — and **re-run the covering gate on
  ambiguity**. The plan itself leaves no store footprint and a gate with no record
  cannot be confirmed, so re-running is how resume stays honest, and each gate is
  safe to repeat (a re-run is recorded again; the earlier record stays as history):
  - **the part is not yet claimed** (still `open`, nobody holds it) → start at
    **Step 1**, even when its topic branch or worktree already exists — the
    Workspace app may have created them and opened this terminal inside. Step 1's
    reuse rule picks up that checkout; the ladder below applies once you hold it.
  - **no topic branch** → start at Step 1.
  - **branch exists, no commits** → the plan lived only in memory and is gone;
    re-run **Steps 2–3** (rebuild the plan, then pressure-test it) before Step 4.
  - **commits exist, no `kind: change` findings** → built but unreviewed; re-run
    **Step 5** (prove-can-fail) before Step 7 — unless the part already carries a
    current `guards_proven` record, in which case go to Step 7.
  - **findings exist** → reconcile against them in Steps 7–8.
- **Read the gate records, then attest what they do not cover — out loud.** For
  each gate behind the derived point, look at the component's `gate_records` (the
  newest record of a kind is the current one; `superseded` marks the history):
  - **a current record is present** → the gate is confirmed from the store. Say so —
    kind, `passed` or `waived`, who recorded it, when, against which commit, and a
    waiver's reason — and continue. **Do not re-run it, and do not declare it void.**
  - **no record** → the loop cannot tell whether the gate ran. **Do not assume it
    did.** Name it and account for it before continuing — for Step 3: if no code
    exists yet, run it; if code already exists a pre-code pressure-test is
    impossible, so run its closest equivalent, a **plan-vs-implementation review**,
    or — on the operator's attestation that it ran upstream — record it attested, or
    declare it **void with the reason stated**. Then **write the record**, so the
    next entry reads it instead of asking again: a plan-vs-implementation review
    that the plan survived is `passed` (its `verdict` says it was run after the
    code existed); an operator attestation or a void is `waived`, with the
    attestation or the reason as its `reason`. With **the other agent** as reviewer
    (see **The reviewer dial**), the plan-vs-implementation review is **handed off**
    like Step 3's — its brief carries the scope constraint verbatim, and its record
    carries `reviewer: "claude-code"` in its evidence, or
    `reviewer: "codex"` if it fell back.

  A gate you cannot confirm and do not account for is a silent skip, the one thing
  this loop must never do.
- Resolve the **merge dial** (dispatched → autonomous; interactive → supervised) —
  an explicit operator instruction overrides it.
- Resolve the **reviewer dial**: the other agent **only** when this invocation asks
  for it (`reviewer: other`, or plain words that mean it); otherwise the same agent.
  Say which one you are driving.

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

When it survives, **record the gate** before any code:
`mcp__marshall__record_gate { component, kind: "plan_pressure_tested", outcome: "passed", commit, evidence: { verdict, changes: [...] }, agent: "codex", machine, return: "minimal" }`
— `verdict` says who pressure-tested it (an independent subagent, or the inline
pass) and that it survived; `changes` lists what the pressure-test changed in the
plan.

**With the other agent as reviewer** (see **The reviewer dial**), this check is
**handed off** to it instead of a subagent — always, with no inline pass, and with
the scope constraint verbatim in its brief. Revise until its verdict is
`VERDICT: SURVIVES` or `VERDICT: SURVIVES WITH CHANGES` with every change taken. The
record then names it:
`mcp__marshall__record_gate { component, kind: "plan_pressure_tested", outcome: "passed", commit, evidence: { verdict, changes: [...], reviewer: "claude-code" }, agent: "codex", machine, return: "minimal" }`
— or `reviewer: "codex"` when the hand-off fell back and a subagent ran it, with
the `verdict` saying that it fell back and why.

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

Then **record the gate**, one entry per guard you watched fail:
`mcp__marshall__record_gate { component, kind: "guards_proven", outcome: "passed", commit, evidence: { guards: [{ test, mutation, observed_failure }, ...] }, agent: "codex", machine, return: "minimal" }`.
A component that added or changed **no** guard has nothing to prove: record
`outcome: "waived"` with that as the `reason` — a `passed` record with no guard in
it would be a false one, and the store refuses it. Guards a Step 8 fix adds or
changes are re-proven and recorded again.

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

**Record the gate under the verifier's identity, not yours.** Before spawning the
verifier, mint it a session token — `verify-` plus a fresh random id — and put it in
its prompt. When it confirms the fixes, the record is written with that token:
`mcp__marshall__record_gate { component, kind: "fixes_verified", outcome: "passed", commit, session: "<the verifier's token>", evidence: { verdict, findings: [<finding id>, ...] }, agent: "codex", machine, return: "minimal" }`
— `findings` are the **ids** of the findings it verified (`[]` when the review
found nothing to fix). The store refuses the record with `verifier_not_independent`
when `session` is the session that recorded those findings, which is what a call
that names no `session` resolves to. That refusal means the verifier's token was
left off, not that the gate failed: pass it and record again. This is an
attestation the store holds you to, not proof — so never mint a token for a
verification you did yourself.

**With the other agent as reviewer** (see **The reviewer dial**), the verification
is **handed off** to it instead of a subagent. Mint the token just the same and put
it in the brief, with the scope constraint verbatim, each finding, what each fix
changed, and the diff. Only `VERDICT: VERIFIED` passes the gate; on
`VERDICT: NOT VERIFIED`, fix what it names and hand off again. The record names it:
`mcp__marshall__record_gate { component, kind: "fixes_verified", outcome: "passed", commit, session: "<the verifier's token>", evidence: { verdict, findings: [<finding id>, ...], reviewer: "claude-code" }, agent: "codex", machine, return: "minimal" }`
— or `reviewer: "codex"` when the hand-off fell back and a subagent verified,
with the `verdict` saying that it fell back and why. `verifier_not_independent`
applies to this record exactly as to the default one.

A **high** `kind: change` finding left `open` or `deferred` is hard-stop #1 unless it
can be fixed inside the acceptance criteria.

### Step 9 — Land
- **Reconcile the gate records first.** Replay the gate outbox if there is one, then
  read the component's `gate_records`: each of `plan_pressure_tested`,
  `guards_proven` and `fixes_verified` must have a current record. Write any that is
  missing now — from the evidence this run holds — before the part is proposed, and
  name in the landing report any gate recorded as a waiver and why. A part does not
  land with a gate that ran and left nothing behind. What is written here is what
  this run already holds — the record of a gate that ran, or Step 5's waiver for a
  part with no guard to prove. It is not where a gate the project requires gets waived:
  a required gate this run holds nothing for stays unrecorded, for the check below.
- Open/update the component PR → **`set_component_state proposed`** — skip the call
  when the part is already `proposed` (a run resumed after the stop below:
  `proposed` → `proposed` is an `invalid_transition`).
- **Write the closing summary and the pull request** (see **The landing facts**):
  `mcp__marshall__component_update { component, closing_summary, pull_request: { number, url }, return: "minimal" }`.
  On a resumed run that finds them already on the part, send the summary again only
  if this run changed what it should say.
- **Then check the gates the project requires**, before the PR is merged. Read
  `config.required_gates` from `mcp__marshall__release_get`. If a required gate still has
  no current record — an outbox line the store has not taken does not count; the
  store cannot see it, so name it as owed — **stop and name the missing gate**, and
  **never write a waiver to get past it** (see **A merge the store refuses**). The
  part stays `proposed` with its PR open and unmerged, and the claim stays held.
  Stopping before the merge keeps the PR and the store in step. This holds on both
  settings of the merge dial.
- **Merge dial** (reached only with every required gate on the record, or none required):
  - autonomous → when clean (no unfixable high, gates green, no ambiguity), merge,
    then **`set_component_state merged`**. If the store still refuses it with
    `missing_gate_records` — a record went missing, or the setting changed, between
    the check and the merge — that is the same stop: name the gates in its `missing`
    list, leave the part `proposed` and the claim held, and write no waiver.
  - supervised → stop at `proposed`; report the landing state and let the human merge,
    who (or a follow-up) sets `merged`.
- `merged` is what unblocks dependents — set it on merge, not just at unclaim.
- **Write the merge commit**, right after setting `merged` (see **The landing
  facts**): `mcp__marshall__component_update { component, merge_sha, return: "minimal" }`.
- Release the claim (`$release-unclaim`), and hand back:
  `$release-next` if components remain, else `$release-wrap`.

## The scope constraint (verbatim, in every subagent this skill spawns and every brief it hands to the other agent)

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
- **No silent gate-skip.** Entering past a gate means reading its **gate record**;
  a gate with no record is accounted for **out loud** (Step 0 attestation) — run
  the gate, run its closest equivalent (a plan-vs-implementation review), or
  declare it void with the reason — and the outcome is recorded. Never assume a
  non-skippable gate ran, never declare void a gate the store shows was run, and
  never let `land-only` become a fast-path around Step 8 or the three hard stops.
- **Every gate ends in a record.** Steps 3, 5 and 8 each write one; a refused record
  is corrected, then falls back to a waiver that carries the evidence; a store that
  cannot take it gets the gate outbox, replayed later. A recording problem is never
  retried in a loop and never stops the loop — except at landing, when the project
  requires that gate and the store has no record of it.
- **The other agent reviews only when asked.** The reviewer dial is the same agent
  unless this invocation asks for the other one; it is never a standing default. A
  hand-off that fails falls back to a same-agent subagent and says so — it never
  passes a gate on its own — and every record of a handed-off check names its
  `reviewer`.
- **A guard you have not watched fail is not proven** — including the wire shape at a
  protocol boundary, not only the code path.
- **Deliver the acceptance criteria, nothing more.** Out-of-scope problems are release
  findings (`component_id` omitted), not silent scope creep. Genuine ambiguity is a
  hard stop, not a guess.
- **Exactly three build-loop hard stops** — an unfixable high, CI red after one fix
  attempt, scope ambiguity — and **a hard stop leaves the claim held** so resuming is
  free. Precondition / lease failures are release-topic's stops, not these.
- **A merge the store refuses is a stop, never a waiver.** When the project requires a
  gate the part has no record of — found by Step 9's check or answered by the store as
  `missing_gate_records` — stop and name the missing gate, claim held. Never write a
  waiver to get past it; that waiver is the operator's to give.
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
- **A landed part keeps its record** — Step 9 writes it, as **The landing facts**
  says.
- **Build stops at one merged component.** It never wraps, deploys, or tags. A skill
  is a prompt, not a gate: the only part of this loop the store enforces is the gate
  records a project requires before `merged`.

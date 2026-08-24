# Shared review protocol (Marshall)

`$change-review` and `$release-readiness` run the **same** protocol —
load a lens selection from the store, fan one subagent out per lens, synthesise, and
record durable findings — over different subjects and with **different verdict
vocabularies**. The common part lives here, once. Each skill binds the parameters
below, keeps what is genuinely its own (how it resolves and gathers its subject, and
how it records in Step 6), and defers here for everything else.

## Parameters each skill binds

Read the concrete values in the skill you came from — they are deliberately
different, and this file never picks one.

| Token | What the skill supplies |
| --- | --- |
| `{{KIND}}` | the finding `kind` it records and filters on — `change` or `readiness` |
| `{{VERDICT_BLOCKING}}` | its word for "do not proceed" — e.g. `changes-required` / `hold` |
| `{{VERDICT_FOLLOWUPS}}` | its word for "proceed with follow-ups" — e.g. `approve-with-followups` / `ship-with-followups` |
| `{{VERDICT_CLEAR}}` | its word for "all clear" — e.g. `approve` / `ship` |
| `{{BLOCKER_RIDER}}` | its extra release-impact blocker clause |
| `{{HOLD_RIDER}}` | its extra clause on the blocking verdict |

Two behaviours are **conditional on the skill's scope**, flagged inline below: whether
the review is *component-scoped* (every finding carries a `component_id`) and whether
the skill *pre-filters* the lens set before fanning out. Its bindings say which apply.

### What deliberately does NOT move into this file

Do not consolidate these further — two CI gates read **only files named `SKILL.md`**
(`srm:check-tool-coverage` and `tests/Feature/PublishPluginTest.php`), so anything moved
out of a `SKILL.md` stops counting as covered and the build goes red:

- **Each skill's `## Store tools` roster.** Every tool must be named in the callable
  `mcp__plugin_marshall_marshall__<tool>` form inside a `SKILL.md`. `lenses_get`,
  `lenses_applicable` (both) and `set_release_lenses` (change-review) are covered by
  *these two skills alone* — move them here and no skill references them.
- **Each Step 6's `record_findings { release, … }` call block** and the sentence
  "do not loop `record_finding` per finding". Both are asserted verbatim, per skill, so
  the recording *step* — not just a tool table — instructs the batch write.

Their `component_id` handling differs by scope anyway, so Step 6 is genuinely
skill-local. Everything below is not.

## Lens config (both selection and definitions come from the store)

- **Selection** — `release_get { release }` returns `project.reviews.{{KIND}}.lenses`,
  the array of lens slugs for this release. If it is empty, no lenses of this kind are
  selected: **stop and say so** (set them with `set_release_lenses`), never review with
  an empty lens set.
- **Definitions** — `lenses_get { slugs }` returns each lens (frontmatter + body). The
  store is authoritative; there is no `~/.claude/skills/_lenses/<slug>.md` fallback. Any
  unresolved slug fails loud (`lens_not_found`) — surface it and stop, never silently skip.

(If the MCP server isn't connected, stop and say so — there is no local fallback for
store findings *or* lenses.)

## The store is the state (no local file)

Unlike the non-Marshall review skills, these keep **no** `review-state.json` /
`release-state.json`. Open/deferred/accepted/fixed findings are read straight from the
release document (`release_get` → `findings`, filtered to `kind: "{{KIND}}"`). Never
create or write a local findings file.

### Status lifecycle (store-defined)

The store enforces the lifecycle; the skill only ever asks for a legal move:

- `open → deferred | accepted | fixed`
- `deferred → accepted | fixed | open` (re-open)
- `accepted` and `fixed` are **terminal**

There is **no `fixed-verified` status** in the store — the non-Marshall skills have one;
this port drops it. `fixed` is terminal, so `verify` mode re-examines and **reports**,
but never transitions a finding. An illegal move (e.g. `fixed → open`) returns
`invalid_finding_transition` from the store — surface it verbatim; never work around it.

## Running the lenses (review process — steps 4 & 5)

The skill's Steps 1–3 resolve the release (and, when component-scoped, the component),
gather the subject, and resolve the lens set — pre-filtering it with `lenses_applicable`
first if the skill defines that step. These two steps are then identical for both.

### Step 4 — Run lenses: one subagent per lens, in parallel

Fan out **one subagent per resolved lens, concurrently** — dispatch them in a single
message (one Task/Agent call per lens) so they run in parallel, then aggregate. If the
skill pre-filtered in Step 3, fan out the **`applicable`** set, not the raw selection.
Give each subagent:
- the lens **`name`, `body`, and `related`** (from `lenses_get`) — `name` for attributing
  its findings, `body` to run the lens, `related` for synthesis,
- the context gathered in Step 2 — the changed-file list plus the diff or release
  history, `CHANGELOG.md`, and any migration/config the lenses care about, and
- the instruction below.

Each subagent:
- evaluates the lens `## Purpose` against that context; if its "skip when" condition
  fires, returns `skipped (not applicable)`.
- otherwise walks `## Questions to ask`, scans `## Anti-patterns to flag`, anchors
  against `## Examples` and `## Severity calibration`, and uses `## How findings from
  this lens sound` to shape voice.
- **returns** its candidate findings as structured data (severity, where, issue, fix),
  attributed to the lens by its frontmatter `name`. It does **not** call
  `record_finding` — recording is centralized in the parent (Step 6) so reconciliation
  stays idempotent.

Aggregate every subagent's findings before continuing.

### Step 5 — Cross-lens synthesis

Do one integration pass using each lens's `related:` array. When a finding was surfaced
or sharpened by another lens, note it: `*(+ <lens-name> via synthesis)*`.

Then return to the skill for **Step 6 — reconcile against the store and record the
pass**; the recording call is skill-local because `component_id` handling differs by scope.

### Recording semantics (shared by both Step 6s)

Recording is **not idempotent** — calling it again writes another row, so reconcile
first. When a semantic match against an existing finding is ambiguous, **bias toward
"already-tracked" and do not record**: a missed-as-new finding still prints in the
output and is recoverable, but a duplicate durable row is the failure mode reconcile
exists to prevent. Match on the summary (and component), **never on the `ref`** — refs
renumber every run.

The write is **all-or-nothing**: one invalid item rolls the whole batch back and fails
loud with `batch_item_failed` naming the offending item **by index** — there is never a
partial write. Surface that verbatim, fix the named item, and re-send the whole batch;
never fall back to recording one at a time to route around it. Always report
`recorded N / already-tracked M` so a duplicate is immediately visible.

> **Concurrent reviews:** reconcile is read-then-write with no findings lock, and a
> component claim does not lock the review *action* — two reviewers running the same
> review simultaneously can each record a row. Accepted residual: the
> `recorded / already-tracked` count surfaces it and `resolve_finding` cleanup is cheap.

## Severity gate

- **high:** fix before the release ships.
- **medium:** fix now unless explicitly deferred with an owner.
- **low:** may defer if documented.

## Verdict and release impact rubric

The three consolidated-verdict **words** are the skill's own vocabulary; the conditions
that map onto them are shared.

**Release impact**
- **blocker:** any unmitigated `high`, inability to roll back safely, {{BLOCKER_RIDER}} —
  unless accepted risk and owner are explicitly recorded (as an `accepted` finding).
- **non-blocker:** no open `high`, or each `high` has a recorded mitigation path.

**Consolidated verdict**
- **{{VERDICT_BLOCKING}}:** one or more `high` without documented mitigation, {{HOLD_RIDER}}.
- **{{VERDICT_FOLLOWUPS}}:** `medium`/`low` remain (or deferred `medium` with a named
  owner), no blocker-level gap.
- **{{VERDICT_CLEAR}}:** no material findings; open gaps minor or absent; tradeoffs recorded.

## Output format

### Verdict (always first)

## `<verdict>` · `<release impact>`
- `N high` · `N medium` · `N low` · `N open gaps`
- **Recorded:** N new `{{KIND}}` findings written to the store · M already tracked
  (or `none — all already tracked`).
- **Passes:** only areas at risk under review that came back clean.
- **Carry-forward:** `id` deferred · `id` accepted — omit if the store has none.

Append ` · component <ref>` to that verdict header when the review is **component-scoped**.

---

### Findings (one H3 per finding, high → medium → low)

### F1 · `<severity>` · `<Primary lens>` *(+ Secondary lens via synthesis)*
- **Where:** [`path:line`](path) or `CHANGELOG.md` / migration / config
- **Issue:** one sentence on what is wrong or risky.
- **Fix:** one sentence concrete fix, test, doc change, or escalation.
- **Store:** `recorded <id>` (new) or `already tracked <id> (<status>)`.

Separate findings with `---`. Omit the synthesis parenthetical if single-lens. Use
`None — informational` for **Fix** only on `low` findings where no action is warranted.

### Open gaps (one H3 per gap)

### OG1 · `<Lens>`
One sentence on what cannot be verified and what would confirm or refute it.

### Tradeoffs (inline)

One line per tradeoff: **Chosen** — **Rejected** — **Rationale** — **Recorded in**.
If none: `Tradeoffs: none identified.`

If no fresh findings, write `No new findings.` after the verdict and still show any
open/deferred store findings.

## Post-review actions

These map 1:1 onto `resolve_finding`. Resolve the `F#` the user names to its store `id`
via the most recent review output or `release_get`.

**When one instruction names more than one finding** — "defer F3 and F4, accept F2",
"accept everything low", or a wrap walking a whole pass to terminal statuses — resolve
them in **one transaction**:

```
mcp__marshall__resolve_findings {
  findings: [
    { finding: <id>, status: "deferred", rationale? },
    { finding: <id>, status: "accepted", rationale? },
    ...
  ]
}
```

One transaction, one minimal ack (`{ resolved, findings: [...] }`), and mixed target
statuses are fine in the same call. It is **all-or-nothing**: an unseeable finding fails
with `finding_not_found` before any write, and an illegal or no-op transition rolls the
whole batch back with `batch_item_failed` naming the item by index and its `from`/`to`.
Surface that verbatim, drop or correct the named item, and re-send — never retry
item-by-item to sneak the legal ones through, because the user asked for one decision.

The singular modes below are the shape of each item, and the tool to use when the user
names exactly one finding.

### Defer

`"defer F3"` or `"defer F3 — fix lands in a follow-up"`:
`resolve_finding { finding: <id>, status: "deferred", rationale }`.

### Accept

`"accept F2 — documented elsewhere instead"`:
`resolve_finding { finding: <id>, status: "accepted", rationale }`.
Acceptance means no fix is planned; use defer when a fix is intended but not now.

### Mark fixed

`"mark F1 as fixed"` (optionally with a rationale):
`resolve_finding { finding: <id>, status: "fixed", rationale? }`. Terminal.

### Re-open

`"re-open F3"` (only from `deferred`):
`resolve_finding { finding: <id>, status: "open" }`. From a terminal status the store
returns `invalid_finding_transition` — surface it; don't force it.

### Verify

`"verify F1 F2"`: re-examine the referenced findings against the current code and report
`✓ resolved` / `✗ unresolved`. The store has no verified state — if a `fixed` finding is
confirmed resolved, leave it `fixed` and say so; if a still-open finding is confirmed
resolved, offer to `mark fixed`.

### List

`"show findings"` / `"what's deferred"`: `release_get { release }`, filter `findings` to
`kind: "{{KIND}}"`, group by status (open / deferred / accepted / fixed) with each
finding's `id`, `ref`, `severity`, and `summary`.

## Guardrails

- Record only `kind: "{{KIND}}"` findings here. The other kinds belong to their own
  gates: change-review owns `change`, release-readiness owns `readiness`, and the design
  gate owns `design`.
- **If component-scoped:** resolve the component fail-loud, and pass its `component_id`
  on every recorded finding. A signal conflict is a stop-and-ask, not a guess.
- **If your skill pre-filters:** always run `lenses_applicable` between selection and
  `lenses_get`, and honor its verdict in both directions. No narrowing is the expected
  answer against a coarse catalog — make the call anyway; it starts paying the moment the
  catalog carries path globs.
- Reconcile before recording — never write a duplicate of a finding the store already
  holds open. Filter every `release_get` read to `kind: "{{KIND}}"`.
- **Batch by default.** A pass writes with `record_findings` and resolves a multi-finding
  instruction with `resolve_findings`; the singular tools are for one-offs. Looping the
  singular tool over a pass is the anti-pattern — it costs a round trip and a full
  document per finding, and it can half-write a pass the batch would have rolled back.
- **A `batch_item_failed` is a stop, not a retry loop.** Surface the named index verbatim,
  fix that item, re-send the whole batch. Never decompose a rejected batch into singular
  calls to get the rest through.
- The store enforces the lifecycle. Ask only for legal transitions; surface
  `invalid_finding_transition` verbatim rather than working around it. There is no
  `fixed-verified`.
- The store is the source of truth — do not create a local `{{KIND}}`-review state file.

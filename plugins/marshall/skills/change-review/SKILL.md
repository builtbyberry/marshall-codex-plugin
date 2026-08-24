---
name: change-review
description: "Run a multi-lens change review over a release component's diff and record the findings in the shared Marshall store (not a local review-state file). Loads the configured change lenses, runs them against the component's diff, and writes findings (kind: change) via record_finding; supports defer/accept/fix/re-open via resolve_finding. Use when the user says $change-review, review this component, change review, or attaches a component diff/PR/branch for a Marshall-tracked release."
---

# Change Review (Marshall)

Run the change lenses over a **component's diff** and record what they find **in
the shared Marshall store** via the findings tools, instead of a repo-local
`review-state.json`. The store is the same across machines, people, and agents —
so a change review one person runs is visible to everyone working the release.

This is the Marshall-store port of `multi-expert-change-review`: same lens mechanics
and verdict rubric, but findings are durable store rows (kind `change`) rather
than a local file. It is the change-review counterpart to `$release-readiness`
(kind `readiness`) — readiness is release-wide; change review is **component-scoped**.

## The shared protocol, and what this skill binds

Lens config, the store lifecycle, the lens fan-out and synthesis (steps 4 & 5), the
severity gate, the verdict rubric, the output format, the post-review actions, and the
guardrails are shared with `$release-readiness` and live once in
**`../../references/review-protocol.md`**. **Read it — it carries the steps this
file does not repeat.** It is written against parameters; this skill binds them:

| Token | change-review |
| --- | --- |
| `{{KIND}}` | `change` |
| `{{VERDICT_BLOCKING}}` | **changes-required** |
| `{{VERDICT_FOLLOWUPS}}` | **approve-with-followups** |
| `{{VERDICT_CLEAR}}` | **approve** |
| `{{BLOCKER_RIDER}}` | `or missing safety-relevant control` |
| `{{HOLD_RIDER}}` | `or a fundamental design/API/changelog mismatch` |

Scope conditionals: this review **is component-scoped** — every finding carries a
`component_id`, and the verdict header gains ` · component <ref>`. It **does pre-filter**
the lens set with `lenses_applicable` before fanning out (Step 3), exactly as readiness
does.

> The verdict vocabulary is deliberately **not** readiness's. Change review approves or
> requires changes to a component; readiness ships or holds a release. Never report a
> change review as `ship` / `hold`.

## Store tools

- `mcp__marshall__release_get` — the release: components (for `component_id`
  scoping), existing findings, and the lens selection at `project.reviews.change.lenses`.
- `mcp__marshall__lenses_applicable` — pre-filter, run **between** the
  selection and `lenses_get` (Step 3); never fan out the raw selection.
- `mcp__marshall__lenses_get` — the applicable lens definitions.
- `mcp__marshall__record_findings` / `mcp__marshall__resolve_findings`
  — **the defaults**: a whole pass of writes (Step 6), or of resolutions, in one atomic call.
- `mcp__marshall__record_finding` / `mcp__marshall__resolve_finding`
  — singular fallbacks, for a genuine one-off after the pass.
- `mcp__marshall__set_release_lenses` — **config**, not part of a pass (below).

Both resolve tools are driven from the shared protocol's **Post-review actions**.

## Config

Selection and definitions come from the store, per the shared protocol's **Lens config**
(`project.reviews.change.lenses`; empty selection → stop, never review with no lenses).

**Changing the selection** — `mcp__marshall__set_release_lenses` writes it.
This is a **config** act, not part of a review pass: change the selection *before* you
review, never mid-pass to make a finding go away.

```
mcp__marshall__set_release_lenses {
  scope:   "change",              // change | readiness | design
  target:  "release",             // "project" (default) | "release"
  release: "<version-or-slug>",
  lenses:  ["security", "laravel-conventions"]
}
```

`target` is the part worth getting right, and it defaults to the **broader** of the two:
- `target: "project"` (**the default**) writes the **project default**, shared by
  **every** release in that project — including ones already in flight. Omitting
  `target` while meaning "just this release" is the mistake to avoid.
- `target: "release"` writes a per-release **override** of that scope only.
  `clear: true` (release target, `lenses` omitted) drops the override so the
  release inherits the project default again.

It overwrites **only the named scope**, preserving the others, and `lenses` replaces
wholesale — so pass the **complete** set you want, not just additions. An empty array is
a deliberate empty selection, not a no-op. Every slug must resolve in the catalog or the
whole call fails loud (`lens_not_found`) and **nothing is written**.

`release_get`'s `reviews.change` block reports the outcome: `effective` (the set that
will actually run), `source` (`release_override` | `project_default`), `project_default`,
and `overridden`. Read it back after writing and report `effective` — that, not what you
passed, is what the next review runs.

`.claude/release-config.json` is still read for non-lens fields only — `default_branch`
(the diff base). Lifting the rest of release-config into the store is roadmapped separately.

## Scope: one component's diff

Change review is scoped to a single component, so every finding it records carries
that component's `component_id`. Resolve the component before reviewing.

### Resolving the component (fail-loud)

Resolve from three signals:

1. an explicit tracker ref the user named (`$change-review #10`),
2. the active Marshall claim on a component,
3. the current branch name `<type>/<release>-<ref>-<slug>`.

The priority order (ref → claim → branch) applies **only to fill absent signals**.
**Any disagreement between two present signals is ambiguity — STOP and ask.** For
example, a claim on `#10` while the branch encodes `#11` means the diff under
review and the finding's `component_id` would refer to different components; do not
let the higher-priority signal silently win. If the component cannot be pinned to
exactly one, **stop and ask** — never default to "the release" or guess. The store
validates that `component_id` is a *member* of the release but not that it is the
*correct* one, so a wrong-but-valid id mis-scopes silently; this step is what makes
mis-scope fail loud instead.

### Gathering the diff (fresh base)

```bash
git fetch origin <default-branch>                       # avoid a stale base
BASE=$(git merge-base origin/<default-branch> HEAD)
git diff "$BASE"..HEAD --name-only                      # changed files
git diff "$BASE"..HEAD                                  # the change under review
```

Fetch before computing the merge-base: a stale local ref resolves to an old commit
and pulls already-merged work into the diff, producing findings about code that is
not part of this component. Use `default_branch` from `.claude/release-config.json`.

## Review process

### Step 1 — Resolve the release + component, load the store state

Resolve the release version (ask if ambiguous — don't guess) and the component (see
**Resolving the component** above). Then `mcp__marshall__release_get { release }` to load:
- the components (ids, titles, refs) — to confirm the resolved `component_id`,
- the **existing findings**, filtered to `kind: "change"` — so this run reconciles
  against them (Step 6), and
- the **lens selection** at `project.reviews.change.lenses` — the slugs to run (Step 3).

### Step 2 — Gather the component diff

Compute the diff as in **Gathering the diff** above. Read `CHANGELOG.md` and any
files the lenses care about. Know what changed before forming a view.

### Step 3 — Resolve lenses from the store

1. Take `project.reviews.change.lenses` from the Step-1 `release_get`; if empty,
   **stop**: no change lenses are selected for this release (set them with
   `set_release_lenses`). Never review with an empty lens set.
2. **Pre-filter against the component's changed files before spawning anything.** The
   fan-out is one subagent per lens, so a lens that cannot apply to these files costs a
   whole subagent to read the diff and conclude "not applicable".

   ```
   mcp__marshall__lenses_applicable {
     slugs: <the selected slugs>,
     changed_paths: <the changed files from Step 2>
   }
   ```

   It returns `applicable` (fan these out) and `skippable` (safe to drop). The store is
   **conservative by construction**: a lens with no `applies_to`, or one carrying a
   coarse project-kind token (`all` / `app` / `package`), is always applicable. Only a
   lens whose `applies_to` is *entirely* file-scoping globs, with none matching any
   changed path, comes back skippable — so a relevant lens is never dropped.

   **Trust the verdict in both directions.** Never skip a lens the store called
   applicable, and never re-add one it called skippable because it "feels relevant" —
   the conservatism is already in the query. Report the narrowing
   (`fanning out N of M lenses; skipped: <slugs>`) so a surprising skip is visible
   rather than silent. If the changed-file list is empty or unknown, pass nothing and
   fan out everything.

   A component diff is the case where this pays most, because a component is usually
   one layer: a backend-only component skips every lens whose `applies_to` is purely
   frontend globs, and a frontend-only one skips the reverse. Expect **no narrowing**
   where the catalog still uses coarse kind-tokens — that is the pre-filter working
   correctly against un-enriched data, not a failure.
3. `mcp__marshall__lenses_get { slugs: <the applicable slugs> }` to fetch
   the definitions. Any `lens_not_found` → surface it verbatim and stop. There is no
   `~/.claude` fallback and no silent skip.

### Steps 4 & 5 — Run the lenses, then synthesise

Follow **`../../references/review-protocol.md` → "Running the lenses"**: one
subagent per **applicable** lens (the `applicable` set from Step 3, not the raw
selection) dispatched in a single message, each returning structured candidate findings
(never recording them itself), then one cross-lens synthesis pass using each lens's
`related:` array. Give each subagent the component **diff** and changed-file list from
Step 2.

### Step 6 — Reconcile against the store, then record the pass in ONE call

Reconcile each fresh finding against the existing `kind: "change"` findings loaded in
Step 1, per the shared protocol's **Recording semantics**:

- **Semantic match to an existing `open` or `deferred` change finding** — match on
  `(component_id + normalized summary)`, never on the `ref`. Carry the existing status
  and id, and do not record it again.
- **Match to an `accepted` or `fixed` finding** → suppress (already resolved),
  unless the issue has genuinely regressed — then record a new one and say so.
- **No match** → it goes in the batch (below). Always carry the resolved
  `component_id`.

Then write the **whole surviving set in a single call**:

```
mcp__marshall__record_findings {
  release,
  findings: [
    { kind: "change", ref, severity, summary, rationale?, evidence?, component_id },
    ...
  ]
}
```

**Batch it — do not loop `record_finding` per finding.** A pass of eight findings
is one round trip, not eight, and the ack is minimal (`{ recorded, findings: [{ id,
ref, kind, severity, status, component_id }] }`) rather than eight full release
documents. Every item carries the same `release`, so pass it once at the top level.
An invalid item here is typically a `component_id` outside this release — the batch
rolls back whole, per the shared protocol.

Use singular `record_finding` only for a genuine one-off — a single finding
recorded after the pass, in follow-up conversation.

### After Step 6

Report per the shared protocol's **Output format** using this skill's vocabulary
(`changes-required` / `approve-with-followups` / `approve`), then handle any
defer/accept/fix/re-open/verify/list request per its **Post-review actions**, filtering
to `kind: "change"`.

## Compressed pass (trivial changes)

For a trivial diff, run the lenses **inline** (skip the per-lens fan-out — the
parallelism isn't worth it) and emit the verdict section followed by one sentence
per lens. Expand any lens that surfaces non-trivial risk to a full finding.

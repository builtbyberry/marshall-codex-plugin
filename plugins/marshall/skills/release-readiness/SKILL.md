---
name: release-readiness
description: "Run a release readiness review and record its findings in the shared Marshall store (not a local review-state file). Loads the configured readiness lenses, runs them against the release, and writes findings via record_finding; supports defer/accept/fix/re-open via resolve_finding. Use when the user says $release-readiness, is this release ready, readiness review, pre-release checklist, or asks about migration safety, tenant safety, or deploy readiness for a Marshall-tracked release."
---

# Release Readiness (Marshall)

Run the readiness lenses for a release and record what they find **in the shared
Marshall store** via the findings tools, instead of a repo-local `review-state.json` /
`release-state.json`. The store is the same across machines, people, and agents —
so a readiness review one person runs is visible to everyone working the release.

This is the Marshall-store port of `swarm-release-readiness` / `release-readiness`:
same lens mechanics and verdict rubric, but findings are durable store rows
(kind `readiness`) rather than a local file.

## The shared protocol, and what this skill binds

Lens config, the store lifecycle, the lens fan-out and synthesis (steps 4 & 5), the
severity gate, the verdict rubric, the output format, the post-review actions, and the
guardrails are shared with `$change-review` and live once in
**`../../references/review-protocol.md`**. **Read it — it carries the steps this
file does not repeat.** It is written against parameters; this skill binds them:

| Token | release-readiness |
| --- | --- |
| `{{KIND}}` | `readiness` |
| `{{VERDICT_BLOCKING}}` | **hold** |
| `{{VERDICT_FOLLOWUPS}}` | **ship-with-followups** |
| `{{VERDICT_CLEAR}}` | **ship** |
| `{{BLOCKER_RIDER}}` | `broken CI, or an inverted conservative security/deploy default` |
| `{{HOLD_RIDER}}` | `CI failing, or a fundamental migration/deploy mismatch` |

Scope conditionals: this review is **release-wide, not component-scoped** — use
`component_id` only when a finding is about one specific component, and the verdict
header carries no component suffix. It **does pre-filter** the lens set with
`lenses_applicable` before fanning out (Step 3).

> The verdict vocabulary is deliberately **not** change-review's. Readiness ships or
> holds a release; change review approves or requires changes to a component. Never
> report a readiness review as `approve` / `changes-required`.

## Store tools

- `mcp__marshall__release_get` — the release: components, existing findings,
  and the lens selection at `project.reviews.readiness.lenses`.
- `mcp__marshall__lenses_applicable` — pre-filter, run **between** the
  selection and `lenses_get` (Step 3); never fan out the raw selection.
- `mcp__marshall__lenses_get` — the applicable lens definitions.
- `mcp__marshall__record_findings` / `mcp__marshall__resolve_findings`
  — **the defaults**: a whole pass of writes (Step 6), or of resolutions, in one atomic call.
- `mcp__marshall__record_finding` / `mcp__marshall__resolve_finding`
  — singular fallbacks, for a genuine one-off after the pass.

Both resolve tools are driven from the shared protocol's **Post-review actions**.

## Config

Selection and definitions come from the store, per the shared protocol's **Lens config**
(`project.reviews.readiness.lenses`; empty selection → stop, and set them with
`set_release_lenses`).

`.claude/release-config.json` is still read for non-lens fields only — `wrap.mode`
(informational; verdict language matches deploy vs tag). Lifting the rest of
release-config into the store is roadmapped separately.

## Review process

### Step 1 — Resolve the release + load the store state

Resolve the release version (ask if ambiguous — don't guess). Then
`mcp__marshall__release_get { release }` to load:
- the components (ids, titles, refs) — for `component_id` scoping,
- the **existing findings** — so this run reconciles against them (Step 6), and
- the **lens selection** at `project.reviews.readiness.lenses` — the slugs to run (Step 3).

### Step 2 — Gather release context

```bash
git log <release-base>..HEAD --oneline      # commits on the release branch
git diff <release-base>..HEAD --name-only   # changed files
```

Read `CHANGELOG.md` (the "Unreleased"/active section) and any migration/config
files the lenses care about. Know what changed before forming a view.

### Step 3 — Resolve lenses from the store, then pre-filter the fan-out

1. From the Step-1 `release_get`, take `project.reviews.readiness.lenses`. If empty,
   **stop**: no readiness lenses are selected for this release (set them with
   `set_release_lenses`). Never review with an empty lens set.
2. **Pre-filter against the diff before spawning anything.** The fan-out is one
   subagent per lens, so a lens that cannot possibly apply to these changed files
   costs a whole subagent to conclude "not applicable". Ask the store instead:

   ```
   mcp__marshall__lenses_applicable {
     slugs: <the selected slugs>,
     changed_paths: <the changed files from Step 2>
   }
   ```

   It returns `applicable` (fan these out) and `skippable` (safe to drop). The
   store is **conservative by construction**: a lens with no `applies_to`, or one
   carrying a coarse project-kind token (`all` / `app` / `package`), is always
   applicable. Only a lens whose `applies_to` is *entirely* file-scoping globs
   with none matching any changed path comes back skippable — so a relevant lens
   is never dropped. An unknown slug fails loud with `lens_not_found`.

   **Trust the verdict; do not second-guess it in either direction.** Never skip a
   lens the store called applicable, and never re-add one it called skippable
   because it "feels relevant" — the conservatism is already in the query. Report
   the narrowing (`fanning out N of M lenses; skipped: <slugs>`) so a surprising
   skip is visible rather than silent, and if `changed_paths` is empty or unknown,
   pass nothing and fan out everything.

   Expect **no narrowing** when the catalog's `applies_to` still uses coarse
   kind-tokens — every lens comes back applicable. That is the pre-filter working
   correctly against un-enriched data, not a failure; make the call regardless, so
   the narrowing lands the moment the catalog carries real globs.
3. `mcp__marshall__lenses_get { slugs: <the applicable slugs> }` to fetch the
   definitions. Any `lens_not_found` → surface it verbatim and stop. There is no
   `~/.claude` fallback and no silent skip.

### Steps 4 & 5 — Run the lenses, then synthesise

Follow **`../../references/review-protocol.md` → "Running the lenses"**: one
subagent per **applicable** lens (the `applicable` set from Step 3, not the raw
selection) dispatched in a single message, each returning structured candidate findings
(never recording them itself), then one cross-lens synthesis pass using each lens's
`related:` array. Give each subagent the release **context** from Step 2 — commit log,
changed files, `CHANGELOG.md`, relevant migration/config files.

### Step 6 — Reconcile against the store, then record the pass in ONE call

Reconcile each fresh finding against the existing readiness findings loaded in Step 1,
per the shared protocol's **Recording semantics**:

- **Semantic match to an existing `open` or `deferred` readiness finding** (same
  underlying issue — match on summary/component, not the `ref`) → **do not record
  again**. Surface it as already-tracked, carrying its existing status and id.
- **Match to an `accepted` or `fixed` finding** → suppress (already resolved),
  unless the issue has genuinely regressed — then record a new one and say so.
- **No match** → it goes in the batch (below). Use `component_id` only when the
  finding is about a specific component of this release.

Then write the **whole surviving set in a single call**:

```
mcp__marshall__record_findings {
  release,
  findings: [
    { kind: "readiness", ref, severity, summary, rationale?, evidence?, component_id? },
    ...
  ]
}
```

**Batch it — do not loop `record_finding` per finding.** A readiness pass across
six lenses is one round trip, not one per finding, and the ack is minimal
(`{ recorded, findings: [{ id, ref, kind, severity, status, component_id }] }`)
instead of a full release document per write. `release` is passed once at the top
level; every finding in the batch belongs to it. Use `record_finding` only for a
genuine one-off after the pass.

### After Step 6

Report per the shared protocol's **Output format** using this skill's vocabulary
(`hold` / `ship-with-followups` / `ship`), then handle any
defer/accept/fix/re-open/verify/list request per its **Post-review actions**, filtering
to `kind: "readiness"`.

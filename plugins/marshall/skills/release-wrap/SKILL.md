---
name: release-wrap
description: "Wrap a release against the Marshall store — deploy mode (hand off ready-for-deploy) or tag mode (hand off ready-to-ship for a tagged Composer package): run change-review + readiness (findings land in the store), fill the CHANGELOG, gate on unresolved high findings. Use when the user says /release-wrap, finish the release, we're ready to close out <release>, or all components are merged, what now."
---

# Release Wrap (Marshall)

Drive the wrap of a release **against the shared Marshall store**, in order: confirm
every component is merged → change-review each component → fill the CHANGELOG →
readiness review → honor the high-finding gate → hand off **ready-for-deploy**
(deploy mode) or **ready-to-ship** (tag mode).
The store is the same across machines, people, and agents, so the wrap one person
runs is visible to everyone working the release.

This is the Marshall-store port of the file-based `release-wrap`: same wrap ordering,
but **the store is the state**. Review progress is read from the release's
findings (`mcp__marshall__record_finding` / `mcp__marshall__resolve_finding`), not a local
`review-state.json` / `release-state.json`. This skill *composes* the review
skills — it does not duplicate their lens logic.

It drives **both** wrap modes. The reviews, the CHANGELOG fill, and the high
gate are identical either way; only Step 2's CHANGELOG mechanics and Step 5's
hand-off differ. See **Which mode — read `wrap.mode` first**.

## How it talks to the store

- `mcp__marshall__release_get` — read the release: every component with its
  server-derived work-state (`open | in_progress | proposed | merged`), the
  **existing findings** (`kind: change` and `kind: readiness`), and the deploy
  progression. This is the state — there is no local wrap file to read. When all
  components are `merged`, the release sits in the **`wrapping`** derived phase;
  that is the precondition for this skill.
- `mcp__marshall__release_status` — the live coordination picture: which components are
  still held, and which have **drifted** (a hold that went quiet and silently
  reopened). Use it to catch a component that looks done but isn't truly merged.
- `mcp__marshall__release_changelog` — emit the release's CHANGELOG section
  **from store data**, grouped Added / Changed / Fixed under the release theme.
  Read-only. This is what Step 2 writes.
- `mcp__marshall__record_findings` / `mcp__marshall__resolve_findings`
  (and their singular siblings) — driven by the composed review skills, not called
  directly here. The wrap **reads** the findings they produce to drive the gate.
- `mcp__marshall__set_component_state` — only the composed `$release-topic` flow
  moves components to `merged`. This skill does not advance work-state; it reads it.

(If the MCP server isn't connected, stop and say so — there is no local fallback
for the wrap state, the findings, *or* the lenses.)

## Which mode — read `wrap.mode` first

`wrap.mode` decides how Step 2 writes the CHANGELOG and who Step 5 hands off to.
Resolve it **before Step 0** and say which one you are driving:

- **`deploy`** — the release ships by merging and deploying. Step 2 stamps
  today's date; Step 5 hands off to `$release-deploy`'s deploy flow
  (`set_deploy_step`: merging → deploying → smoke → monitor → done).
- **`tag`** — the release ships as a **tagged package** (a Composer package,
  where Packagist auto-syncs on the tag). There is nothing to deploy and no
  production URL to smoke. Step 2 leaves the CHANGELOG heading **undated**;
  Step 5 hands off to `$release-deploy`'s tag flow (`set_ship_step`:
  merging → dating → tagging → releasing → done).

Read it store-first from `release_get`'s resolved `config.wrap.mode` (the lifted
release-config plane, deep-merged `defaults ← project ← release`), falling back
to `.claude/release-config.json` for a repo that hasn't been migrated. If the two
disagree, **say so and ask** — do not silently prefer one; a wrong mode here
either stamps a date the ship step owns or skips one the deploy needs.

Everything before Step 2 and everything in Steps 3–4 is **mode-independent**:
same all-merged precondition, same lenses, same findings, same high gate.

## Config

Non-lens fields, read store-first with the local `.claude/release-config.json`
as the back-compat fallback (lens *selection* always lives in the store, at
`project.reviews.*.lenses`):

- `wrap.mode` — `deploy` or `tag`; see above.
- `wrap.changelog_path` — the CHANGELOG to fill.
- `default_branch` — the diff base the composed reviews use.

`tag.*` is **not** consulted in either mode. The tag itself is operator-supplied
evidence at ship time (`set_ship_step { tag }`), never read from config.

Neither is `wrap.include_upgrading_md`. Whether a release needs UPGRADING notes
is **derived from the store**, not configured — see Step 2's tag-mode branch.

## The store is the state (no local file)

Unlike the file-based wrap, this one keeps **no** `review-state.json`,
`release-state.json`, or `deploy-state.json`. Which phase the wrap is in is
derived every time from the store:

- **components** — `release_get`, all `merged`? (else: components still in flight).
- **change findings** — any `kind: change` finding still `open`? (phase 2 incomplete).
- **CHANGELOG** — does `<wrap.changelog_path>` still hold the placeholder for this
  release? (phase 3 not done). In **tag mode** the UPGRADING section (when any
  component is `breaking`) lands in Step 2's *same commit* as the CHANGELOG fill,
  so a filled CHANGELOG implies UPGRADING landed too — there is no separate
  UPGRADING derivation to check.
- **readiness findings** — any `kind: readiness` finding still `open`? (phase 4 incomplete).
- **high gate** — any `high`-severity finding (either kind) `open` *or* `deferred`?
  (not ready to hand off, in either mode).

Note the CHANGELOG check is **placeholder-based, not date-based**, precisely so it
works in both modes: a wrapped tag-mode release is correctly still undated (its
ship step stamps it), so "has a date" would misread a finished wrap as unfinished.

The skill is fully resumable: invoked mid-wrap (a new chat, a later day), re-read
the store and continue from the first unsatisfied precondition. Never trust prior
conversation memory of "where we were" — re-read the store.

## Procedure

Announce which step the skill is entering and why; the user can interrupt at any
step boundary.

### Step 0 — Confirm the release is wrappable

1. Resolve the release version (ask if ambiguous — don't guess).
2. `mcp__marshall__release_get { release }`. Confirm **every component's state is
   `merged`**. If any is `open | in_progress | proposed`, **stop**: list the
   unfinished components and tell the user to land them first (via
   `$release-topic` → merge → `set_component_state merged`).
3. `mcp__marshall__release_status { release }` to catch **drift** — a hold that went
   quiet and reopened a component that looks done. A drifted component is not
   truly merged; resolve it before wrapping.
4. Resolve `wrap.mode` (see **Which mode**) and state which progression this wrap
   is driving. Both are supported; this is a branch, not a gate.

### Step 1 — Change review, per component

For each component in the release, compose **`$change-review`** against that
component's diff. It records `kind: change` findings (scoped with `component_id`)
in the store via `record_finding`, reconciling against what's already there.

- Run them one component at a time (or dispatch in parallel if the user wants),
  and let each review record its own findings — this skill does not record.
- After the pass, `release_get` and walk the user through every `open`
  `kind: change` finding. For each, drive a resolution **through the review
  skill's modes** (which call `resolve_finding`): **fix** (make the change, then
  mark fixed), **defer** (with rationale), or **accept** (no fix planned).
- A `high` change finding left `open` or `deferred` will block Step 4's gate —
  surface that now so the user resolves it deliberately, not at the gate.

### Step 2 — CHANGELOG wrap

Steps 1 and 2a are the same in both modes; **2b forks on `wrap.mode`**.

1. **Ask the store for the section — don't hand-assemble it.**
   `mcp__marshall__release_changelog { release }` returns the whole
   section already grouped into `### Added` / `### Changed` / `### Fixed` by each
   component's `branch_type`, under the release theme, in the house format.
   Generate-at-wrap is the point: the wrap writes the CHANGELOG in **one commit**,
   which is why component PRs no longer edit it and no longer conflict on it.
   Do not walk the components yourself to rebuild what the store already emits.
2. **(2a — both modes) Fill the body.** Open `<wrap.changelog_path>` and replace
   the `_To be filled in during release wrap-up._` placeholder with the generated
   section. Then **edit the generated prose** — the store knows every component's
   title and type, not the story of each change. Sharpen bullets from the merged
   PRs: named feature in **bold**, behavior + rationale in plain prose. Add a
   `### Removed` group by hand if the release needs one; the generator emits only
   Added/Changed/Fixed. Never *drop* a generated bullet — a component that shipped
   belongs in the log even if its bullet needs rewriting.
3. **(2b — forks on `wrap.mode`) The heading, and UPGRADING.**

   **Deploy mode** — stamp the heading now:
   `## <release> - <today's date YYYY-MM-DD>`, replacing `## <release> - unreleased`.
   No UPGRADING.md: deploy notes live in the release PR body / in-app changelog,
   not an UPGRADING block.

   **Tag mode** — **leave the heading `## <release> - unreleased`. Do not stamp a
   date here.** `$release-deploy`'s tag flow owns dating: its `dating`
   step stamps the heading and commits it, deliberately ordered *before*
   `tagging` so the tag never points at a commit whose CHANGELOG still says
   "unreleased". A date written at wrap time is a date written before the merge
   it is supposed to describe — if the ship slips a day, the tag, the CHANGELOG,
   and the GitHub Release disagree. That three-way drift is exactly what the
   ordering exists to prevent, so **wrap must not pre-empt it**.

   Then decide UPGRADING — **derive the answer from the store, don't read a
   config flag.** `release_get` carries each component's `breaking` boolean
   (captured by `$release-plan` regardless of wrap mode):
   - **any component with `breaking: true`** → write an `UPGRADING.md` section
     for this release, one entry per breaking component: what changed, and the
     exact change a consumer must make. A tagged package's consumers upgrade by
     reading this; the CHANGELOG says *what*, UPGRADING says *what to do*. Mark
     the same bullets `**BREAKING:**` in the CHANGELOG so the two agree.
   - **no breaking components** → no UPGRADING section. Say so explicitly rather
     than writing an empty one.

   If a component is `breaking: true` but the release is only a patch/minor bump,
   **stop and raise it** — that is a SemVer problem the readiness lenses
   (`semver-guardian`) should also catch, and it is cheaper to resolve before the
   tag than after Packagist has synced it.
4. Commit `docs(changelog): fill in <release> release wrap-up` (in tag mode this
   commit carries the UPGRADING section too, and leaves the heading undated).

### Step 3 — Readiness review

Compose **`$release-readiness`**. It runs the readiness lenses against the
release and records `kind: readiness` findings via `record_finding`, reconciling
against the store.

- After it returns, `release_get` and walk every `open` `kind: readiness` finding
  with the user, driving each to **fix / defer / accept** through the readiness
  skill's modes (which call `resolve_finding`).
- If readiness surfaces anything larger than a small fix, **stop** and tell the
  user — it likely needs to go back through change-review on a component, not a
  patch at wrap time.

### Step 4 — Honor the readiness gate

**Mode-independent — this is the same gate in both modes.** Re-read the store
(`release_get`). The release is **not ready to hand off** while **any
`high`-severity finding — `kind: change` or `kind: readiness` — is `open` or
`deferred`.** This mirrors the server-side gate that blocks the cut-over: a
deferred high is still an unmitigated high, and the store returns the same
`deploy_blocked` for a tag-mode `set_ship_step` as for a deploy-mode
`set_deploy_step`. An unresolved high blocks a tag exactly as it blocks a deploy.

- If any high is `open`/`deferred`: list them (id, ref, kind, summary, status) and
  **refuse to proceed**. Each must be resolved to a terminal status — `fixed`
  (addressed) or `accepted` (explicit, owned risk acceptance) — via the composing
  skill's mode (`resolve_finding`). Re-check after each resolution.
- `medium`/`low` findings do **not** block; surface any still open/deferred so the
  user ships with eyes open.

### Step 5 — Hand off

There is **no explicit store "ready" flag.** Readiness is a *derived
precondition*, the conjunction of:

1. every component `merged` (Step 0),
2. CHANGELOG entry filled for this release (Step 2) — plus, in tag mode, the
   UPGRADING section if any component is `breaking`,
3. no `high` finding `open` or `deferred` (Step 4 gate clear).

When all three hold, declare the release ready and hand off to
**`$release-deploy`**, naming **which progression it will drive**:

- **deploy mode** → **ready-for-deploy**. One-line summary: merge the release PR
  into `<default_branch>`, watch the deploy, smoke-check, monitor.
- **tag mode** → **ready-to-ship**. One-line summary: merge the release PR into
  `<default_branch>`, stamp the CHANGELOG date, tag, publish the GitHub Release,
  and let Packagist sync. Say explicitly that **the date is still unstamped and
  the ship's `dating` step owns it** — otherwise the next session sees an
  undated heading and "helpfully" stamps it early, which is the drift Step 2
  avoided.

State that the deploy skill **re-checks these same preconditions** against the
store before it merges, so nothing is taken on trust across the handoff.

Do not merge, deploy, or tag automatically. The user invokes
`$release-deploy` when ready.

## Guardrails

- **Resolve `wrap.mode` before Step 0, and never mix the two progressions.** A
  tag-mode release has no smoke or monitor step; a deploy-mode release has no tag
  and no UPGRADING block. Getting this wrong writes the wrong artifact into a
  release that is about to become public.
- **Never cut the tag from here.** Wrap prepares and gates; the tag and the
  GitHub Release are operator-run at ship time via `$release-deploy`,
  which records them as evidence. Never run `git tag`, `git push --tags`, or
  `gh release create` in a wrap.
- **In tag mode, never stamp the CHANGELOG date.** The ship's `dating` step owns
  it, ordered before `tagging` so the tag cannot point at a commit whose
  CHANGELOG says "unreleased". Stamping it at wrap time re-introduces exactly the
  manifest/CHANGELOG/tag drift that ordering prevents. An undated heading after a
  finished tag-mode wrap is **correct**, not an oversight to fix.
- **UPGRADING is derived from `breaking`, not from config.** Read the components'
  `breaking` flags out of `release_get`; do not consult
  `wrap.include_upgrading_md` or invent a store flag for it. No breaking
  components means no UPGRADING section — say so rather than writing an empty one.
- **The store is the source of truth** — derive every phase from `release_get`,
  not from conversation memory. Do not create a local wrap/review/readiness/deploy
  state file.
- **The CHANGELOG section is generated, then edited — never hand-assembled from
  scratch.** `release_changelog` emits the grouped section from store data; the
  wrap's job is to sharpen the prose (and, in deploy mode, stamp the date), in one
  commit. Rebuilding it by walking components by hand is how the log drifts from
  what actually shipped.
- **Compose, don't duplicate.** This skill records no findings itself; change
  findings are `$change-review`'s job (`kind: change`), readiness findings are
  `$release-readiness`'s (`kind: readiness`). It only *reads* findings to drive
  the gate and resolutions.
- **The high gate is hard, and it is the same gate in both modes.** An `open` *or*
  `deferred` high blocks the hand-off — a deferred high is still unmitigated. Only
  `fixed` / `accepted` clear it. Refuse to declare the release ready while any high
  is unresolved; never work around the gate.
- **All components merged is a precondition, not a goal to force.** If a component
  isn't `merged` (or has drifted per `release_status`), stop and send the user back
  to land it — don't wrap a half-merged release.
- **Readiness is derived, not stored** — ready-for-deploy in deploy mode,
  ready-to-ship in tag mode. Never invent a store flag for either; state it as the
  precondition `$release-deploy` re-checks.
- The store enforces the finding lifecycle. Resolutions go through the composing
  skills' modes; surface `invalid_finding_transition` verbatim rather than working
  around it.

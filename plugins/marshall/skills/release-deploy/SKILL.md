---
name: release-deploy
description: "Drive the final cut-over of a release against the shared Marshall store — deploy mode (merge the release PR, watch the deploy, smoke-check production, monitor the window, tag the merge commit, via set_deploy_step) or tag mode (merge, date, tag, GitHub Release, Packagist, via set_ship_step) — recording every step on the store's record so it is resumable across sessions and machines. Use when the user says /release-deploy, deploy the release, ship <release>, tag the release, or cut over to prod."
---

# Release Deploy (Marshall)

The final cut-over — merge → watch → smoke → monitor — driven against the shared
Marshall store instead of a repo-local `deploy-state.json`. The store's **Deploy
record is the single source of truth** for where the deploy is: `release_get`
tells you the step, `set_deploy_step` advances it. That is what makes this
resumable across sessions, machines, and agents — and what stops a re-run from
re-shipping prod.

## How it talks to the store

- `mcp__marshall__release_get` — read the release + its **deploy** block (the
  authoritative `step`, `smoke_ok`, `monitor`, `verdict`). Read it on **every**
  invocation; never trust prior conversation memory for where the deploy is.
- `mcp__marshall__set_deploy_step` — **deploy mode.** Start (`step: merging`)
  or advance one legal step: `deploying → smoke → monitor → done`. The store enforces
  one deploy per release, the forward-only order, and the readiness gate — you only
  supply the next step plus the evidence each step below names. It also accepts
  `tag` / `release_url`, so a deployed release records the provenance tag it left
  in the repo (Step 5).
- `mcp__marshall__set_ship_step` — **tag mode.** The same progression for a
  release that ships as a tagged package rather than a deploy:
  `merging → dating → tagging → releasing → done`. Same one record, same readiness
  gate, same `invalid_transition` on a skipped or reversed step. See **Tag mode** below.

If the MCP server isn't connected, **stop and say so** — the store's Deploy
record is the only source of truth for where the deploy is; never drive a deploy
from conversation memory or a local file.

If `set_deploy_step` returns `deploy_blocked`, the readiness gate is refusing the
deploy because the release has unresolved high-severity findings — surface them
and stop; resolve them via `$release-wrap` (or `resolve_finding`) first. If it
returns `invalid_transition`, you tried to skip a step — re-read `deploy.step` and
continue from there.

## Which mode — read `wrap.mode` first

`wrap.mode` in `.claude/release-config.json` decides which progression this skill
drives, and the two are **mutually exclusive** — one record per release:

- **`deploy`** → the cut-over flow below, driven by `set_deploy_step`.
- **`tag`** → the ship flow in **Tag mode**, driven by `set_ship_step`.

Resolve the mode before anything else and say which one you are driving. Never
mix the two tools on one release: a tag-mode release has no smoke/monitor step,
and a deploy-mode release has no `dating`/`tagging`/`releasing` step.

**Both modes still leave a tag behind.** The difference is what the tag *does*: in
tag mode the tag **is** the ship (Packagist resolves it), so it gets its own step;
in deploy mode the merge is the ship and the tag is provenance, recorded as
evidence on `done` (Step 5). Neither mode ships without one.

## Config

Reads `.claude/release-config.json` (tracked) for `repo`, `default_branch`,
`wrap.mode`, and — in deploy mode — the `deploy` block:
- `deploy.provider` — `laravel-cloud` (watch the cloud deploy) or `none`/`manual`
  (auto-deploy is OFF; the operator performs the deploy by hand and you record the
  steps as they confirm). Default-safe to manual.
- `deploy.production_url`, `deploy.smoke_check_path`, `deploy.monitor_window_minutes`.

## Resume — read the store, never memory

On invocation, `release_get { release }` and read `deploy.step`:

- **no deploy record** → start at the Merge step.
- `merging` → the deploy is started but not merged; resume at Merge (check whether
  the PR is already merged before acting — see below).
- `deploying` → the merge happened and the deploy is in flight; **do NOT merge
  again and do NOT re-trigger the deploy** — resume by watching/polling status.
- `smoke` → resume at the smoke check (or, if `smoke_ok` is `false`, you are at a
  rollback decision — see **Smoke failure**).
- `monitor` → resume the monitor window from `deploy.monitor` (compute elapsed from
  the recorded window start; do not restart the clock).
- `done` → already shipped; report and stop.

> The deploy is the one step with an irreversible external side effect. Every
> action below is gated on `deploy.step` precisely so a resumed or re-dispatched
> run never re-merges or re-deploys what already happened.

## Preflight — deploy mode (refuse on failure)

1. `wrap.mode == deploy` and `deploy.production_url` is set. (If `wrap.mode == tag`,
   go to **Tag mode** instead of refusing.)
2. HEAD is on the release branch; working tree clean.
3. The release PR exists, is not a draft, is `MERGEABLE`/`CLEAN`, and its checks
   are green (`gh pr view --json isDraft,mergeable,mergeStateStatus,statusCheckRollup`).
4. No topic PRs are still open into the release branch.
5. Readiness handed off: ideally invoked after `$release-wrap`. The store-side
   gate is the real backstop — `set_deploy_step` will refuse with `deploy_blocked`
   if any high finding is unresolved — but warn if wrap wasn't run.

## The flow

### Step 1 — Gate first, then merge (start the deploy)

1. Show the plan (merge PR #N into `<default_branch>`, watch the deploy, smoke
   `<production_url><smoke_check_path>`, monitor `<window>` min) and wait for an
   explicit `yes`.
2. **Trip the readiness gate BEFORE the irreversible merge.** `set_deploy_step {
   release, step: 'merging' }` — this creates the one deploy record and runs the
   gate. If it returns `deploy_blocked`, **stop and do not merge**: the release has
   unresolved high findings; surface them and route to `$release-wrap`. The
   merge auto-deploys on `laravel-cloud`, so the gate must clear *before* the
   merge, not after. (Idempotent on resume; if `deploy.step` is already
   `deploying`+, the merge already happened — skip to Step 2.)
3. **Merge (idempotent).** `gh pr view <N> --json state,mergeCommit`. If already
   `MERGED` (a prior run, or the user did it by hand), use the recorded
   `mergeCommit.oid`. Otherwise — only now that the gate has cleared — surface
   `gh pr merge <N> --merge --delete-branch` for the **user** to run (human-
   initiated; do not run it yourself) and wait for "merged".
4. Advance with the merge evidence: `set_deploy_step { release, step: 'deploying',
   merged_by, merge_sha: <oid> }`. The deploy is now in flight — Step 2.

### Step 2 — Watch the deploy (now at `deploying`)

Do not re-merge or re-trigger — `deploy.step` is `deploying`; the merge already
fired the deploy.
- **`provider: laravel-cloud`** — the cloud auto-deploys on push to the default
  branch. Watch via the Laravel Cloud dashboard/CLI and capture the deploy URL
  (recorded on the smoke write in Step 3). Do not declare done on the merge alone
  — the deploy is what reaches users.
- **`provider: none`/`manual`** — auto-deploy is OFF: tell the operator to perform
  the deploy and confirm when it is live.
- **On resume at `deploying`** — just continue watching/polling until the deploy
  reports complete, then proceed to smoke.

### Step 3 — Smoke check

1. `curl -sS -o /dev/null -w "%{http_code} %{time_total}" <production_url><smoke_check_path>`.
2. **Pass** (HTTP 200, latency < 5s): `set_deploy_step { release, step: 'smoke',
   smoke_ok: true, deploy_url }`.
3. **Fail** (non-200, error, or > 5s): advance to `smoke` carrying the failure, but
   **no further**: `set_deploy_step { release, step: 'smoke', smoke_ok: false,
   verdict: 'rollback-needed', deploy_url }`, then go to **Smoke failure**. The
   `verdict` makes the rollback decision durable in the store/audit; leaving the
   step at `smoke` (not `done`) keeps the derived phase honest — `deploying`, not
   `shipped`.

### Step 4 — Monitor window

The store has **no `monitor → monitor` transition**, so the window is written
exactly twice: once on entry (the resume anchor) and once on completion (the full
evidence). Do not attempt a per-check store write — it returns `invalid_transition`.

1. **Enter the window once:** `set_deploy_step { release, step: 'monitor', monitor:
   { started_at: <now>, window_minutes: <window> } }`. This is the resume anchor.
2. Poll the smoke endpoint every 60s, accumulating each check **in memory**. On
   resume mid-window, recompute the remaining time from the recorded
   `monitor.started_at` so the window length is honored across interruptions (the
   individual pre-interruption checks are not durable — only the window clock and
   the final set are).
3. Surface (don't auto-poll) the Pulse / error-tracker / logs URLs the operator
   should also watch.
4. **A failing check during the window** is a rollback decision; it cannot mutate
   the `monitor` row in place (no self-transition), so **report it and stop** — do
   not advance to `done` (the deploy didn't pass). Surface **Smoke failure**; the
   record stays at `monitor`, unshipped.
5. **On completion with all checks passing:** tag first (Step 5), then close out
   with `set_deploy_step { release, step: 'done', verdict: 'shipped', tag:
   'v<version>', monitor: { started_at, window_minutes, checks: [<the full
   accumulated set>], completed_at: <now> } }` — the accumulated checks and the
   tag are persisted here, in the single legal `monitor → done` write, and the
   release derives `shipped`.

### Step 5 — Tag the merge commit (before `done`)

A deploy-mode release ships by merging, not by tagging — so nothing forces a tag
to exist, and without one a version's provenance lives only in this store. Tag it,
so the repo can answer "what was v0.21.0" on its own.

1. On the **default branch**, tag the deploy's own `merge_sha` — not `HEAD`, which
   has usually moved on:
   `git tag -a v<version> <merge_sha> -m '<version> — <theme>' && git push origin v<version>`
2. Record it on the `done` call above. **It has to be that call**: `done` is
   terminal, so there is no later advance to carry the evidence.
3. **Only on a shipped verdict.** A `rollback-needed` release gets no tag — a tag
   claiming a version that was rolled back is worse than no tag. Tag the patch
   release that fixes it instead.
4. If the push fails (protected ref, wrong remote), **still record `done`** with
   the verdict, and leave `tag` unset rather than reporting one that does not
   exist — the store never verifies it. Push the tag afterwards; it is a repo fact
   the store simply does not carry for that release.

### Step 6 — Report

When `deploy.step == done`: summarize merge time, deploy duration, smoke result,
monitor checks, the production + dashboard URLs, and the operator follow-ups
(error rate, exceptions, visual regression).

## Smoke failure — the rollback decision

A smoke fail is a human decision; the skill stops being mechanical. The record
stays at `smoke`/`monitor` with `smoke_ok: false` and `verdict: rollback-needed` —
deliberately **not** advanced to `done`, because `done` derives `shipped` and this
deploy did not ship; the recorded verdict makes the rollback decision visible in
the store and audit without faking a shipped state. Surface:

```
SMOKE FAILED on <url>: HTTP <status>, <latency> (or error)
The deploy is live but the check failed. Options:
  1. Investigate (env var, migration, cache, asset build) — logs/Pulse/Sentry URLs.
  2. Roll back:
     - revert the merge: git revert -m 1 <merge_sha> && push (the cloud redeploys);
     - or roll back via the Laravel Cloud dashboard to the prior commit.
Tell me which path; I'll surface the exact commands.
```

If migrations ran in the deploy, **say so** and warn that a revert may not undo
them. Do not attempt to reverse migrations. There is no auto-rollback.

## After the deploy

When the deploy reaches `done`/`shipped`, the release is shipped. If this skill is
driving a release component's lifecycle, mark it merged and release its claim per
`$release-topic` step 5–6. The release's derived phase is now `shipped`
(from `deploy.step === 'done'`).

## Tag mode — the ship path (`wrap.mode == tag`)

A release that ships as a **tagged package** (Packagist auto-syncs on the tag)
has no deploy to watch and no production URL to smoke. Its progression is
`merging → dating → tagging → releasing → done`, driven by
`mcp__marshall__set_ship_step`. Everything the deploy flow
guarantees still holds: one record per release, forward-only legal steps, the
same readiness gate, and evidence recorded at each step.

**The irreversible steps are OPERATOR-run.** The store records the ship; it does
not execute it. Never run `git tag`, `git push --tags`, or `gh release create`
yourself — surface the exact command, wait for the operator to confirm, then
record what they did as evidence.

### Resume — read `deploy.step` from the store

Same rule as deploy mode: `release_get { release }`, read the ship record's
`step`, and continue from there. `tagging`+ means **a tag may already be pushed**
— check `git ls-remote --tags origin <tag>` before acting, and never re-tag.

### The flow

1. **Gate, then merge.** `set_ship_step { release, step: "merging" }` creates (or
   idempotently resumes) the record and trips the readiness gate. A
   `deploy_blocked` means unresolved high findings — stop, surface them, route to
   `$release-wrap`. Only once it clears, surface
   `gh pr merge <N> --merge --delete-branch` for the **operator** to run.
2. **Date the CHANGELOG.** Stamp the release heading with today's date and commit,
   then record it: `set_ship_step { release, step: "dating", merged_by,
   merge_sha: <oid>, changelog_date: <YYYY-MM-DD> }`. Dating before tagging is
   what stops the tag from pointing at a commit whose CHANGELOG still says
   "unreleased" — the three-way manifest/CHANGELOG/tag drift this ordering exists
   to prevent.
3. **Tag.** Surface `git tag <tag> && git push origin <tag>` for the operator.
   When they confirm, record it: `set_ship_step { release, step: "tagging", tag }`.
   This is the irreversible step — Packagist syncs off it.
4. **Publish the GitHub Release.** Surface `gh release create <tag> --title ...
   --notes-file ...` (notes from the dated CHANGELOG section). When they confirm,
   record it: `set_ship_step { release, step: "releasing", release_url }`.
5. **Close it out.** `set_ship_step { release, step: "done", verdict: "shipped" }`.
   The release derives `shipped`. If the ship went wrong and the operator is
   backing it out, record `verdict: "rollback-needed"` instead and stop — do not
   fake a shipped verdict.

### Tag-mode guardrails

- **Never skip or reverse a step.** `set_ship_step` returns `invalid_transition`
  — re-read the record's `step` and continue from there rather than forcing it.
- **Never re-tag or re-release.** `tagging`/`releasing` in the record means it
  already happened; a pushed tag is public the moment Packagist sees it.
- **Record evidence, don't execute.** `merged_by`, `merge_sha`, `changelog_date`,
  `tag`, `release_url` are reported by the operator and stored verbatim — the
  store does not verify them, so do not invent or guess a value.
- **The readiness gate is the same gate.** `deploy_blocked` blocks a tag exactly
  as it blocks a deploy.

## Guardrails

- **Read `deploy.step` from the store every time; never act from memory.** The
  store is the source of truth across sessions, machines, and agents.
- **Never re-merge or re-trigger a deploy that already happened.** Gate every
  side-effecting action on `deploy.step`; `deploying`+ means it is in flight.
- **Do not auto-merge, auto-rollback, or auto-retry a smoke check.** Those are
  human decisions; the skill prepares, records, and surfaces.
- **A failed smoke stays at `smoke`/`monitor`, not `done`.** Don't fake a shipped
  verdict on a deploy that didn't ship — and don't tag it either.
- **Tag the `merge_sha`, not `HEAD`.** By the time the monitor window closes the
  default branch has usually moved past the release, and a tag on the wrong commit
  is worse than none: it answers "what was this version" incorrectly, forever.
- **Surface store errors verbatim** — `deploy_blocked` (resolve high findings
  first), `invalid_transition` (re-read the step), `lease_lost` — never work
  around them.

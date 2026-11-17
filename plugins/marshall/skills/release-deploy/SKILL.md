---
name: release-deploy
description: "Complete a release cut-over through the shared Marshall store, then finish the project's declared artifact publications and Desktop rebuild. Supports production deployment with smoke and monitoring, or tagged package shipping. Use for release-deploy, deploying or shipping a release, and resuming unfinished delivery after cut-over."
---

# Release Deploy (Marshall)

The final cut-over — merge → watch → smoke → monitor — driven against the shared
Marshall store instead of a repo-local `deploy-state.json`. The store's **Deploy
record is the single source of truth** for where the deploy is: `release_get`
tells you the step, `set_deploy_step` advances it. That is what makes this
resumable across sessions, machines, and agents — and what stops a re-run from
re-shipping prod.

The workflow also completes the project's declared delivery steps after cut-over:
plugin publication and a Desktop rebuild where the project ships those artifacts.
Read the project's runbook before starting and include those steps in the plan.
In deploy mode, explicit autonomous approval covers the named merge, publication,
tag and rebuild steps without another confirmation. It does not waive checks or
authorize rollback.

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

- `mcp__marshall__release_update` — write the release's **deploy summary** when
  the deploy is reported (Step 6, and tag mode's close-out). The release has shipped
  by then; the store still takes it.
- `mcp__marshall__stop_raise { release, project, kind, note }` — only when a runner run
  started this session: leave a stop on the release instead of asking. See
  **Started by a run**.

If the MCP server isn't connected, **stop and say so** — the store's Deploy
record is the only source of truth for where the deploy is; never drive a deploy
from conversation memory or a local file.

If `set_deploy_step` returns `deploy_blocked`, the readiness gate is refusing the
deploy because the release has unresolved high-severity findings — surface them
and stop; resolve them via `$release-wrap` (or `resolve_finding`) first. If it
returns `untriaged_findings`, the project requires every finding triaged
(`config.require_triage`) and the findings in `blocking` are still `open` — surface
them and stop; fix, accept or defer each one via `$release-wrap` (or
`resolve_finding`), then start again. If it returns `unsettled_parts`, a part of
the release is neither merged nor cancelled — the release is still being built.
`blocking` names each part (`id`, `slug`, `title`, `state`, and `archived`: an
archived part still counts). Surface them and stop; land or cancel each one, then
start again. If it
returns `invalid_transition`, you tried to skip a step — re-read `deploy.step` and
continue from there.

If it returns `merge_needs_person`, this is an **autonomous run** (the release was
built by a dispatch run that is still open, or you hold a live autonomous claim on
one of its parts), the release PR's merge to main is `person`, and no person has
approved the release. **Stop and do not merge**: say that a person must click
**Approve merge** on the release page in Marshall (or merge it themselves), naming
`merge_to_main_source` and the `deciding_part` when there is one. Nothing was
written; start again once the release's `autonomy.approval` in `release_get` is set.
A **supervised** deploy — a person driving it from their terminal — keeps today's
flow: their "deploy" in chat is the go-ahead, and it never waits for a web approval,
with one exception. **While a runner run is open on the release, the person who
opened it is bound too:** their own deploy from a terminal gets `merge_needs_person`
like the run's agent would, because the store cannot tell it from the run's. Say so,
and name the two ways on: **Approve merge** on the release page, or **Stop run**
there first and deploy by hand.
The other autonomy and kill-switch refusals (`worker_paused`, `lease_lost` after a
stop, `autonomy_disabled`, `looser_than_release`, `not_authorized`) are
`$release-topic`'s **Autonomy — the claim's mode and the refusals**: stop,
name what the body says, never retry in a loop.

## Started by a run

A release can be **run**: Marshall opens a runner run on it, and once the release is
wrapped (and, when its merge to main is `person`, approved) the person's Mac starts
this skill in its own tab. Nobody is watching that tab. Everything below still holds
— the store's record decides every step — and this section adds what is different.

**How you know.** The line that started this session names a **run member**: a
26-character id. Read `mcp__marshall__release_get { release, view: "full" }` — always
the full view: the summary view, and an actor whose default view is the summary,
carries no `dispatch_runs` and no `stops` — and look under `dispatch_runs` for a
run with `kind: "runner"` and `state: "active"` whose `members` hold one with that
`id` and `step: "deploy"`. Only then was this deploy **started by a run**. A line
that names no member, or a member that is not there, is a person's own deploy: never
take a run's member as yours.

**The run is the go-ahead, within what the store allows.** Step 1's plan needs no
approval in chat under a run: the run's opener started it. The store still decides —
every refusal below is answered as written, and the merge goes only to the head a
person or the wrap approved.

**Never ask at the keyboard.** Every place this skill would ask a person, wait for
one, or hand them a command is a stop on the release instead:
`mcp__marshall__stop_raise { release, project, kind, note }` — `project` the release's
project as `release_get` names it — **once per stop, then end the turn.** The run
parks the deploy on the stop and resumes it when a person clears it. The `note` is
all the person gets: plain text, at most 2000 characters, no pasted logs or diffs,
never a credential, saying what you need from them. If the raise fails, say so in
one line and end the turn anyway. The stops:

| Where the deploy would ask | `kind` |
| --- | --- |
| the release PR's head is not the approved head (below) | `escalation` |
| `deploy_blocked` or `untriaged_findings` | `unfixable_finding` |
| `deploy.provider` is `none` or `manual`: a person performs the deploy | `escalation` |
| the smoke check fails, or a check fails in the monitor window | `escalation` |
| a tag-mode step the operator runs (the tag, the GitHub Release) | `escalation` |

- **The approved head.** Merge only with `--match-head-commit <head>`, where `<head>`
  is the `head_sha` of the release's `autonomy.approval` when it names one, otherwise
  the release's `wrapped_head`. Read the PR's head first (`gh pr view <N> --json
  headRefOid`): when it is not that commit, the release moved after it was approved
  or wrapped — merge nothing, raise the stop, and end the turn. With neither an
  approval head nor a `wrapped_head` (a wrap from an older plugin), merge as Step 1
  says.
- **Under a run, Step 1's merge is yours:** once `merging` clears, run `gh pr merge
  <N> --merge --delete-branch --match-head-commit <approved head>` yourself and
  verify the merge commit.
- **`merge_needs_person` raises nothing.** The release waits for a person's Approve
  merge, already on Needs you. Name `merge_to_main_source` and end the turn; the
  run's approval park resumes the deploy.
- **`unsettled_parts` raises nothing.** The release is being built again, and the
  run sees it itself. Name the parts in `blocking` and end the turn.
- **`worker_paused` raises nothing.** Say who paused it and when, then end the turn;
  the run resumes it.
- **A failed smoke is never rolled back by you.** Record it exactly as Step 3
  says — `set_deploy_step { release, step: 'smoke', smoke_ok: false, verdict:
  'rollback-needed', deploy_url }` — then raise the stop with what failed, whether
  migrations ran, and the rollback commands from **Smoke failure**, and end the turn.
  A failing check in the monitor window is the same stop, with the record left at
  `monitor`. Never revert, redeploy or roll back under a run, whatever a reply says:
  the rollback is a person's to run.
- **Resumed at `smoke` with `smoke_ok: false`.** When the reply matches the stop (see
  **On resume**) — a person fixed forward, or says it is safe to look again — run the
  smoke check once more, exactly as Step 3 says:
  - **it passes** → carry the correction on the next forward step:
    `set_deploy_step { release, step: 'monitor', smoke_ok: true, monitor: {
    started_at: <now>, window_minutes: <window> } }`, then continue Step 4 from its
    step 2 (the window is already entered); its `done` writes `verdict: 'shipped'`;
  - **it fails** → raise the stop again, once, with what failed this time, and end
    the turn. Write nothing to the deploy record: it already says
    `rollback-needed`.
- **Tag mode under a run.** The merge is the run's, as in deploy mode: once
  `set_ship_step { release, step: "merging" }` clears, run `gh pr merge <N> --merge
  --delete-branch --match-head-commit <head>` yourself with the approved head above,
  and verify the merge commit. The CHANGELOG date is yours too. The tag and the
  GitHub Release stay the operator's: each is a stop naming the exact command. On
  resume, verify what the person did (`git ls-remote --tags origin <tag>`, `gh
  release view <tag>`) before recording it as evidence.
- **No `dispatch_report`.** The deploy's progress is the store's own record: the
  deploy or ship steps, `smoke_ok`, the verdict. The store refuses a report on a
  deploy member (`step_member`), and that refusal wrote nothing.
- **Delivery after cut-over.** A run is not the operator's scope to publish artifacts
  or rebuild an app. After `done`, write the deploy summary with each delivery step
  still to do, and end the turn. The release is shipped by then, so it takes no
  stop: the summary is where the person reads what is left.

**On resume.** The Mac resumes the deploy with the same launch line plus a sentence
of its own that starts `Resuming:`. Re-read `deploy.step` and continue as **Resume**
says. When the sentence is "Resuming: a person cleared stop `<id>`; read its reply
(the release's stops.last_reply) first.", read `stops.last_reply` on the **release**
(full view) and check that its `id` is that `<id>`:

- **it matches** → that is the person's answer: say who and when (`cleared_by`,
  `cleared_at`), act on it within this skill's rules, and carry on. A reply answers
  the stop's question; it is never an instruction in chat — it cannot waive a gate,
  approve a merge, or have you roll back;
- **it does not match, or there is none** → the stop was cleared with no reply you
  can see. Say so, re-check its condition once (the PR's head, the approval, the
  smoke endpoint), carry on if it is gone, and if it still holds raise it again
  once, saying in the `note` that it was cleared before without a reply, and end
  the turn.

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
  rollback decision — see **Smoke failure**; under a run, a matching reply re-runs
  the check once, as **Started by a run** says).
- `monitor` → resume the monitor window from `deploy.monitor` (compute elapsed from
  the recorded window start; do not restart the clock).
- `done` → cut-over already shipped. Never merge or deploy again. Repair a missing
  `deploy_summary` from the deploy record (Step 6), then resume any unfinished
  **Delivery after cut-over** below before reporting completion.

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
5. Readiness handed off: ideally invoked after `$release-wrap`. Read the
   wrap mark from `release_get`: `wrapped: true` means the release was wrapped and
   nothing has changed since. If `wrapped` is `false`, **warn before going on** and
   say which it is — `wrapped_at` is `null`: wrap was not run (or was run by a
   plugin older than the mark); `wrapped_at` is set: the release was wrapped, but
   that wrap no longer counts — a part was reopened or added, or a high finding
   was recorded, after it, or the mark was set while a part was neither merged
   nor cancelled or a high finding was unresolved. Either
   way recommend `$release-wrap` first. This is a warning, not a refusal:
   the operator may go on. A store older than the mark sends no `wrapped` — say you
   cannot tell whether wrap was run. The store-side gate is the real backstop —
   `set_deploy_step` will refuse with `deploy_blocked` if any high finding is
   unresolved, and with `unsettled_parts` if any part is neither merged nor
   cancelled. That refusal is the every-part-landed check.

## The flow

### Step 1 — Gate first, then merge (start the deploy)

1. Show the plan (merge PR #N into `<default_branch>`, watch the deploy, smoke
   `<production_url><smoke_check_path>`, monitor `<window>` min) and wait for an
   explicit approval unless the operator already approved that scope, including
   an explicit autonomous run.
2. **Trip the readiness gate BEFORE the irreversible merge.** `set_deploy_step {
   release, step: 'merging' }` — this creates the one deploy record and runs the
   gate. If it returns `deploy_blocked`, **stop and do not merge**: the release has
   unresolved high findings; surface them and route to `$release-wrap`. If it
   returns `untriaged_findings`, **stop and do not merge** either: the project
   requires every finding triaged and the ones in `blocking` are still `open`;
   route to `$release-wrap` to fix, accept or defer them. If it returns
   `unsettled_parts`, **stop and do not merge**: the parts in `blocking` are
   neither merged nor cancelled, so the release is not finished; surface them, and
   land or cancel each one before starting again. If it returns
   `merge_needs_person`, **stop and do not merge** either: an autonomous run waits
   for a person's **Approve merge** on the release page (see **How it talks to the
   store**). The
   merge auto-deploys on `laravel-cloud`, so the gate must clear *before* the
   merge, not after. (Idempotent on resume; if `deploy.step` is already
   `deploying`+, the merge already happened — skip to Step 2.)
3. **Merge (idempotent).** `gh pr view <N> --json state,mergeCommit`. If already
   `MERGED` (a prior run, or the user did it by hand), use the recorded
   `mergeCommit.oid`. Otherwise — only now that the gate has cleared — surface
   `gh pr merge <N> --merge --delete-branch --match-head-commit <verified-head>`
   for the **user** to run and wait for "merged". When the operator explicitly
   authorized autonomous merging, run that exact-head command yourself and verify
   the resulting merge commit. When the release carries a person's approval
   (`autonomy.approval` in `release_get`) that names a `head_sha`, that is the
   `--match-head-commit` value: the head the person approved. With no approval head,
   the release's `wrapped_head` — the head the wrap approved — is. A PR whose head has
   moved since then fails the merge — stop and ask for a fresh approval (or a new
   wrap) rather than merging the newer head.
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
5. **Before closing out, replay any gate outbox.** `done` makes the release
   read-only, and a shipped release refuses gate records for good — so records a
   build could not write must land while the release is still open. Look in
   `$(git rev-parse --path-format=absolute --git-common-dir)/marshall/gate-outbox/`
   for a file named after any part of this release. For each file, send each line,
   in file order, as one `mcp__marshall__record_gate` call (a line is the call's whole
   argument object), then read the part's `gate_records` back to see them. A line that is
   refused is fixed and sent again on its own — never re-send a file's other lines:
   recording is append-only and a repeat adds a duplicate. If the call fails as an
   unknown tool, the connection predates the deploy: reconnect the Marshall MCP
   server and try again. Do not advance to `done` with a line still unsent; move the
   replayed files aside rather than deleting them until the monitor window has
   closed. No file there → nothing to do.
6. **On completion with all checks passing:** tag first (Step 5), then close out
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

**Write that summary to the release**, so it outlives this terminal:
`mcp__marshall__release_update { release, deploy_summary: <text>, return: "minimal" }`.
Plain text, a few short paragraphs, at most 4000 characters: when it merged and as
which commit, how the deploy went and how long it took, the smoke result, the
monitor window (how many checks, how long, anything that was not clean), the tag,
and what is left for the operator to follow up. It is reported, not verified. The
release is shipped and read-only by now; this write is still accepted. A store
older than the release record ignores the field: the release it returns carries no
`deploy_summary` — say so and carry on.

A deploy that did not reach `done` — a smoke failure waiting on the rollback
decision — has no deploy summary yet. Write it when the record does reach `done`.

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

A person who fixed forward instead clears the rollback decision with one more smoke
check: on a pass, the next forward step carries the correction —
`set_deploy_step { release, step: 'monitor', smoke_ok: true, monitor: { started_at,
window_minutes } }` — then continue Step 4 from its step 2 (the window is already
entered), and its `done` writes `verdict: 'shipped'`. On a fail the record stays as
it is.

Under a run there is nobody to tell you which path: raise the stop **Started by a
run** names, with this text as its `note`, and end the turn. A resume with the
person's reply re-runs the check once, as that section says.

## After the deploy

When the deploy reaches `done`/`shipped`, the release is shipped. There is no part
left to mark merged here: the store refused to start the deploy while any part was
unsettled (`unsettled_parts`). A part reopened after the start does not stop the
deploy; land or cancel it on its own. The release's derived phase is now `shipped`
(from `deploy.step === 'done'`).

### Delivery after cut-over

The store's terminal `done` records the cut-over. It does not prove that plugin
users received new skills or that a local Desktop app was rebuilt. Complete the
delivery steps declared in this project's runbook, using existing publication
approval or the operator's explicit autonomous scope. If that scope is missing,
prepare the artifacts and ask for the specific publication action still needed.

For a project that publishes the Marshall plugins and Workspace:

1. Work from a clean, current `main`. Land any source changes there before
   publishing. Read both vendor manifests and inspect both artifact repositories;
   a shared skill change reaches Claude and Codex. Publish both changed artifacts
   with `php artisan srm:publish-plugin claude <claude-checkout>` and
   `php artisan srm:publish-plugin codex <codex-checkout>`. Bump each changed
   artifact's source version before rendering; an unchanged artifact needs a
   successful `--check`, not a new version just to repeat the publish.
2. Review each generated diff, commit and merge its artifact PR, push its own
   `v<version>` tag, and verify the remote tag's peeled commit. Run the publisher's
   `--check` for both vendors and the project's plugin-drift workflow. A local
   render or an unpushed tag is not publication. On resume, inspect existing PRs
   and remote tags first; never move a published tag or duplicate a completed
   publish. Update local installs when requested and report any session restart
   still needed.
3. Rebuild Marshall Workspace from `main` using the runbook's build command.
   Record the source commit, exact app bundle path and executable hash, and verify
   the bundle carries the binary just built. Give the app path and an `open`
   command in the completion message. Do not terminate active app sessions to
   replace or relaunch a build; report any relaunch still needed.
4. Update `deploy_summary` with each vendor's published version, artifact PR,
   remote tag and check result, plus the Workspace build evidence. Preserve the
   cut-over facts already recorded. Report delivery complete only when every
   declared step has evidence; otherwise name the precise remaining step.

Projects without these artifacts have no Marshall plugin or Workspace delivery
step. Follow their own runbook rather than introducing unrelated publications.

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
   `$release-wrap`. An `untriaged_findings` means the project requires every
   finding triaged and some are still `open` — stop the same way. An
   `unsettled_parts` means a part in `blocking` is neither merged nor cancelled —
   stop, surface it, and land or cancel it first. A `merge_needs_person` means an
   autonomous run waits for a person's **Approve merge** on the release page — stop
   the same way. Only once it clears, surface
   `gh pr merge <N> --merge --delete-branch` for the **operator** to run (with
   `--match-head-commit <head_sha>` when the release's approval names one).
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
   backing it out, record `verdict: "rollback-needed"` instead — do not fake a
   shipped verdict. Either way, step 6 follows.
6. **Write the deploy summary** — on either verdict, once the record is at `done`:
   `mcp__marshall__release_update { release, deploy_summary: <text>, return: "minimal" }`
   — when it merged and as which commit, the CHANGELOG date, the tag, the published
   release, and what is left to follow up; on `rollback-needed`, say that it was
   backed out and why. Same rules as Step 6 of the deploy flow.

### Tag-mode guardrails

- **Never skip or reverse a step.** `set_ship_step` returns `invalid_transition`
  — re-read the record's `step` and continue from there rather than forcing it.
- **Never re-tag or re-release.** `tagging`/`releasing` in the record means it
  already happened; a pushed tag is public the moment Packagist sees it.
- **Record evidence, don't execute.** `merged_by`, `merge_sha`, `changelog_date`,
  `tag`, `release_url` are reported by the operator and stored verbatim — the
  store does not verify them, so do not invent or guess a value.
- **The readiness gate is the same gate.** `deploy_blocked`, `untriaged_findings`,
  `unsettled_parts` and `merge_needs_person` block a tag exactly as they block a
  deploy.

## Guardrails

- **Read `deploy.step` from the store every time; never act from memory.** The
  store is the source of truth across sessions, machines, and agents.
- **Never re-merge or re-trigger a deploy that already happened.** Gate every
  side-effecting action on `deploy.step`; `deploying`+ means it is in flight.
- **Merge only within the operator's approved scope.** Explicit autonomous
  approval permits execution; otherwise surface the merge command for the user.
  Do not auto-rollback or auto-retry a failed smoke check.
- **A failed smoke stays at `smoke`/`monitor`, not `done`.** Don't fake a shipped
  verdict on a deploy that didn't ship — and don't tag it either.
- **Tag the `merge_sha`, not `HEAD`.** By the time the monitor window closes the
  default branch has usually moved past the release, and a tag on the wrong commit
  is worse than none: it answers "what was this version" incorrectly, forever.
- **Surface store errors verbatim** — `deploy_blocked` (resolve high findings
  first), `untriaged_findings` (triage the open findings first), `unsettled_parts`
  (land or cancel the parts first), `merge_needs_person` (a person approves the
  release first), `invalid_transition` (re-read the step), `lease_lost` — never work
  around them.
- **An autonomous run waits for a person; a supervised one does not.** The release's
  merge to main follows its policy only for an autonomous run, and a person driving
  the deploy is never sent to the web for an approval — unless they opened a runner
  run on the release that is still open: then Approve merge, or Stop run first.
- **Under a run, ask nothing at the keyboard.** Each wait on a person is one release
  stop, then the end of the turn; a smoke failure is recorded and stopped on, never
  rolled back.

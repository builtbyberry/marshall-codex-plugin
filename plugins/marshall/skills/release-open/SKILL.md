---
name: release-open
description: "Open a release session against the shared Marshall store: confirm the release is seeded, cut the release branch, scaffold the CHANGELOG, open the draft release PR, and optionally (on a yes) link the release to a GitHub milestone, the store's only post-hoc tracker link. Use when the user says /release-open, start release, cut release branch, or let's start <release>."
---

# Release Open (Marshall)

Open a release session the right way: **confirm the release exists in the shared
Marshall store first**, then do the git/PR mechanics — cut the release branch,
scaffold the CHANGELOG entry, push, and open the draft release PR. The store is
the state; there is no local `release-state.json`/`release-plan.json`. The
release's phase derives automatically from its components (once they exist and at
least one is unmerged it resolves to `open`; an all-closed collection imports with
every component already `merged`, so it derives `wrapping`), so there's nothing to
write to "open" it — this skill's job is the git/PR mechanics plus confirming the
release is seeded.

## How it talks to the store

- `mcp__marshall__release_get` — confirm the release is seeded (its components are what
  makes the phase resolve). If it's missing, seed it first — `$release-init`
  (native `release_create`) or a tracker import — then retry.
- `mcp__marshall__release_update` — **OPTIONAL, opt-in only**: when the operator says
  yes (step 9), link the release to a collection in its tracker. Never called
  without an explicit yes.

  **Two spellings of one link, and passing both fails.** `collection` is the
  general one: the id of a collection on whatever tracker the project resolves to
  — a milestone on GitHub, a Project or a Cycle on Linear — as an opaque
  **string**. The store reads the URL from the tracker itself, so there is no way
  to hand-write one, and no need to. `milestone_number` is the GitHub-shaped
  legacy field, unchanged: an integer, with `tracker_url` derived as
  `https://github.com/<repo>/milestone/<n>`. Either accepts `null` to unlink.

  Two answers are not failures and must be reported as-is rather than retried:
  a collection whose **kind has no page of its own** (a Linear Cycle) returns a
  `warning` and leaves the release unlinked — that is honest, and nothing is
  invented to fill it — while `tracker_unavailable` means **nothing was written
  at all**, so the other fields in that same call are untouched and the fix is to
  try again.

If the MCP server isn't connected, **stop and say so** — the store is the only
source of truth for whether the release exists; don't proceed from memory.

The branch/CHANGELOG/PR mechanics are plain git + `gh` — they don't touch the
store. Config comes from `.claude/release-config.json` (tracked, read from the
current checkout): `repo`, `default_branch`,
`versioning.release_branch_pattern`, `wrap.mode`, `wrap.changelog_path`.

## Procedure

1. Resolve the release version-or-slug (ask if ambiguous — don't guess). Refuse
   if `.claude/release-config.json` is missing.
2. **Ensure the release is in the store.** `mcp__marshall__release_get { release }`.
   - **Found** → it's seeded; continue.
   - **Not found** → seed the release first, then retry. Native:
     `$release-init` (`release_create`). Tracker-seeded: import the
     collection that backs it. **The import path differs by tracker** — GitHub can
     import from the console (`php artisan srm:import-release <repo> <milestone>`
     on the server) *or* the web picker; a tracker with no console importer, such
     as Linear, imports from the web picker at `/releases/import` only, because `srm:import-release` reads through
     the `gh` CLI and takes an `owner/name` argument. Stop — do **not** seed it
     from this skill; seeding is `$release-init` or import.
3. **Preflight (refuse on failure — do not auto-fix).** In order, stop on the
   first failure with a clear message:
   1. Working tree is clean: `git status --porcelain` is empty.
   2. Current branch is `<default_branch>`.
   3. `<default_branch>` is up to date with origin: `git fetch origin` then
      compare.
   4. Resolve the release branch from `versioning.release_branch_pattern` (e.g.
      `release/v0.7.0`) and verify it does **not** already exist locally or
      remotely (`git rev-parse --verify` fails, `git ls-remote --exit-code
      origin <branch>` fails).
4. **Theme.** Ask for a one-line theme for the release (it becomes the CHANGELOG
   intro and the PR subtitle). Accept `_TBD_` if the user can't articulate it
   yet, and remind them to fill it in at wrap time.
5. **Cut the branch.** `git switch -c <release-branch>`.
6. **Scaffold the CHANGELOG.** Insert immediately after the `# Changelog` header
   in `<wrap.changelog_path>`:
   ```markdown
   ## <release-label> - unreleased

   <theme paragraph>

   ### Added

   _To be filled in during release wrap-up._

   ### Changed

   _To be filled in during release wrap-up._
   ```
   The wrap phase adds any missing sections; only include `### Fixed` /
   `### Removed` now if the user expects them.
7. **Commit + push.**
   ```
   git add <wrap.changelog_path>
   git commit -m "chore(release): scaffold <release-label> changelog entry"
   git push -u origin <release-branch>
   ```
8. **Open the draft release PR.** Title `release: <release-label> — <theme>`,
   base `<default_branch>`, head `<release-branch>`, `--draft`. The body explains
   that topic branches target this branch (not `<default_branch>`) and carries
   the wrap-status checklist. With `wrap.mode = deploy` the final checklist item
   is the deploy step:
   ```
   - [ ] All topic PRs merged
   - [ ] Multi-expert review run
   - [ ] CHANGELOG filled
   - [ ] Readiness review run
   - [ ] Deploy executed and smoke + monitor passed
   ```
   (In `tag` mode the last item is "Ready for merge + tag" instead.)
9. **Optional — link the release to a collection in its tracker (ASK; never
   automatic).** The release detail screen's "View in tracker" link is sourced from
   the release's `tracker_url`; a natively-created release has none until one is
   linked.

   **Ask on any tracked project** — one with a `tracker_kind` (or unset on a
   deployment that still resolves to the configured default) — **and** only when
   `release_get` shows no `tracker_url` yet. On GitHub the project also needs a
   `repo`, since a milestone lives in one.

   You are reading the raw column here, which is the one thing server-side callers
   are told not to do: while `per_project_tracker_resolution` is off, a project
   whose column reads `linear` still resolves to GitHub. **Guessing wrong is now
   loud rather than silent** — the store resolves the driver itself and an id that
   tracker does not hold comes back as `collection_missing`, naming the mistake
   instead of writing a GitHub milestone number onto a project that is not
   GitHub-backed. So read the column to decide *what to ask for*, and let the
   store settle *which tracker it is*.

   When it applies, **ask** the operator: "Link this release to its collection in
   <tracker>? (create a new one / use an existing one / skip)". Default to
   **skip** — never create or link without an explicit yes.
   - **Create new (GitHub only)** → `gh api repos/<repo>/milestones -f
     title="<release-label>"`, capture its `number`, then
     `mcp__marshall__release_update { release, milestone_number: <number> }`.
     Note: the milestone starts **empty** — native components are store-only, not
     GitHub issues — so it's a tracker home for the release, not an issue list.
     There is no create-a-collection path for other trackers; make it in the
     tracker's own UI first.
   - **Existing** → `mcp__marshall__release_update { release, collection:
     "<id>" }`. The id is opaque and the store matches it two ways, so ask for
     whichever the operator actually has: **the collection's id**, or **the URL of
     the collection's page** (paste the Linear Project URL straight from the
     browser). Only an address the tracker itself reports will match — a made-up
     one fails with `collection_missing` rather than being stored. On GitHub,
     `milestone_number: <number>` remains the equivalent call; do not pass both.
   - **Skip** → leave it unlinked; the UI simply omits the link. It can be linked
     later with the same `release_update` call.

   If the answer comes back with a `warning` that the collection has **no page of
   its own** (a Linear Cycle), that is the honest outcome, not a retry: report the
   release as unlinked and move on. Never offer to hand-write a URL to fill it.
   If the release is **already linked** (`tracker_url` present), don't ask —
   report it as-is.
10. **Report.** Print the new branch name, the PR URL, whether a tracker link was
    made (or skipped, or does not apply to this tracker), and the next-step hint:
    `Run $release-graph to verify
    the dependency graph, then $release-next`.

## Guardrails

- **Never seed the release from here.** If `release_get` comes back empty, seed it
  with `$release-init` (native `release_create`) or a tracker import — the
  console importer for GitHub (`php artisan srm:import-release <repo> <milestone>`),
  the web picker at `/releases/import` for a tracker with a driver behind it —
  then retry; this skill
  does only the git/PR mechanics.
- Preflight failures are hard stops, not warnings to work around. Don't
  auto-stash, don't reset, don't force-push.
- If the release branch already exists, stop — don't reuse or overwrite it.
- If `gh pr create` reports a PR already exists for this branch, surface that
  PR's URL and continue rather than opening a duplicate.
- Don't write any "open" state to the store — the `open` phase derives from the
  release having components (ReleasePhaseResolver). This skill only does git/PR.
- **Tracker linking is opt-in, and it only exists for GitHub.** Never create a
  GitHub milestone or call `release_update { milestone_number }` without an explicit
  yes (step 9). Skip is the default, and an already-linked release is left
  untouched. On a project tracked by anything else, don't ask at all — the field is
  an integer milestone number and has no non-GitHub reading.

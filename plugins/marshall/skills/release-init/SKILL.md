---
name: release-init
description: "Bootstrap a project and release directly in the shared Marshall store — born-in-the-store, no import. Resolve-or-create the workspace project, create the release (theme, version-or-slug, out_of_scope), and offer an optional external-tracker link; on a project whose tracker resolves, release_create also creates the release's collection there and links it. Use when the user says /release-init, bootstrap a release in the store, create a project and release in Marshall, start a release from scratch, or init a release without a GitHub milestone."
---

# Release Init (Marshall)

Bootstrap a release the Marshall-native way: **create the project and release
directly in the shared store** through its write-path tools. The operator names a
theme and a version-or-slug and walks away with a live release in Marshall.

It is the **born-in-the-store** path: it calls `project_create` / `release_create`
directly, so the release exists in Marshall the moment you finish — no import. The
alternative is to let the release enter Marshall from a tracker instead (a GitHub
milestone, a Linear Project or Cycle) via the import seam below. Marshall *augments*
external trackers, it doesn't replace them, and the store remains the source of truth.

**Born in the store no longer means invisible to the tracker** (v0.24.0). On a
project whose tracker RESOLVES, `release_create` also creates the release's
collection there — a Linear Project, a GitHub milestone — and stores the link. You
make no tracker call and answer no extra question; it is a server-side effect of the
same `release_create` you were already making. On an untracked project nothing
changes and there is no tracker round-trip at all.

Two things to tell the operator when it applies:

- **The release comes back already linked**, so the step-9 "link this to a
  collection?" question in `$release-open` will not apply to it.
- **A tracker failure does not fail the init.** The release is created with a null
  link and the store logs it. Say so plainly rather than retrying — re-running
  `release_create` is refused on the slug, and creating a second collection by hand
  is the one thing repair exists to avoid.

**Linear needs one thing set first.** Its API requires a team on every create, and
Marshall will not choose one — so a Linear-tracked project needs `tracker_team` set
to the team's **UUID** (not the key its UI shows, e.g. not `BUI`) or the collection
create is refused with a named error. See operator-runbook §5.8.

It is **create-only and additive**: it never edits or deletes, and re-running
against a release that already exists **resumes** rather than duplicating.

## How it talks to the store

- `mcp__marshall__project_list` — **every** project in the workspace
  (takes **no arguments**), archived ones included and flagged `archived: true`.
  Deliberately broader than `release_next`, which surfaces only projects with unshipped
  startable work: it also shows a project whose releases have **all shipped**, and an
  **empty** project with no releases at all — exactly the two a fresh init would
  otherwise re-create.
- `mcp__marshall__project_create` — resolve-or-create the workspace project;
  reused, not duplicated, when one already matches. The external-tracker link
  (`repo` + `tracker_kind`) lives **here** and is **optional** — a project does not
  require a GitHub repo.
- `mcp__marshall__release_get` — probe whether the release already exists under the
  project, so a re-run **resumes** instead of creating a second one.
- `mcp__marshall__release_create` — create the release under the project
  (step 6 names the fields).

Both creates are workspace-scoped and fail-closed — no cross-workspace create,
no existence leak — matching the rest of the write path.

**If the write-path tools aren't available** (an older store, pre plan-write-path),
`project_create` / `release_create` won't be exposed by the connected MCP server.
**Stop and point at the import seam** rather than improvising: build the collection
in the tracker (a GitHub milestone + issues, a Linear Project or Cycle) and import
it. **The two trackers import differently** — GitHub can go through the console,
`php artisan srm:import-release <repo> <milestone>` on the server, or the web
picker; Linear has **no console equivalent** (`srm:import-release` reads through the
`gh` CLI and takes an `owner/name` argument) and imports from the web picker at
`/releases/import`. Do not try to fabricate the project/release any other way — the
store is the only place they can be born.

## Procedure

1. **Gather the release inputs** (ask; don't guess):
   - **Project** — the workspace project name (and optionally the external
     tracker link `repo` + `tracker_kind`, which stays optional).
   - **Theme** — a one-line theme for the release (becomes the CHANGELOG intro
     and PR subtitle downstream). Accept `_TBD_` and remind the operator to fill
     it in at wrap.
   - **Version-or-slug** — e.g. `v0.5.0` or `payments-revamp`.
   - **Out of scope** — what this release explicitly will *not* cover (optional).
2. **Preflight: confirm the write path exists.** If the connected Marshall MCP server
   does not expose `project_create` / `release_create`, stop and surface the
   import fallback above (`php artisan srm:import-release`). This is a graceful
   refusal, not an error to work around.
3. **Survey the workspace before creating anything.**
   `mcp__marshall__project_list {}` (no arguments) and read the
   result back to the operator.
   - **A project already matches** — same repo, or a name that is plainly the same
     thing ("Marshall" vs "marshall-release-manager") → **reuse it**. Confirm the
     slug with the operator and carry it forward; do not create a near-duplicate.
     `project_create` de-duplicates on its own terms, but it cannot tell that two
     *differently named* projects are the same project — only the operator can, and
     only if you show them the list.
   - **A match exists but is `archived: true`** → say so explicitly. The operator
     almost certainly wants it **restored**, not shadowed by a fresh copy:
     `$release-admin` (`unarchive_project`). A second live project pointing
     at the same repo is the worst outcome here, because both then look correct.
   - **No match** → continue; this is a genuinely new project.
4. **Resolve-or-create the project — and offer the optional external-tracker
   link here.**
   `mcp__marshall__project_create { name: "<project>", repo?: "<owner/repo>",
   tracker_kind?: "github | linear | jira" }`.
   - The external-tracker link lives on the **project**: `repo` (the container —
     `owner/name` on GitHub; a tracker with no container concept, such as Linear,
     doesn't need one) plus `tracker_kind`. Ask whether to link one; make clear it
     is **skippable** and that the store is the source of truth — `project_create`
     itself stores the link and makes no tracker API call, and there is no
     bidirectional sync at any point. If the operator skips, omit `repo` /
     `tracker_kind`.
   - **Answering `tracker_kind` here decides what the NEXT step does**, so it is no
     longer only a label. Once the project's tracker resolves, the `release_create`
     in step 6 will create the release's collection on it, and every later
     `component_create` will file an issue. That is the point of setting it — but say
     so while asking, rather than letting the operator discover it from the response.
   - **`tracker_kind` accepts three names; only two have a driver behind them.**
     The store validates against `github | linear | jira`, but a stored `jira`
     resolves to the fail-closed no-op driver — the project reads no tracker at all,
     and there is no Jira import. Offer `jira` as a **label** if the operator wants
     the project annotated, and say plainly that it wires nothing up. Two further
     conditions apply to `linear`, and neither is visible from this skill:
     `tracker_kind` is consulted at all only while the deployment's
     `per_project_tracker_resolution` flag is **on** (with it off every project gets
     the configured default driver, whatever the column says), and `linear` resolves
     to the real driver only while `linear_tracker` is on. Both ship **off**, and
     both are server-side environment settings — whoever runs the Marshall
     deployment turns them on, which on hosted Marshall is not the operator you
     are talking to. So record the intent here, name the two flags if they ask,
     and do not report `tracker_kind: linear` as wired up on the strength of
     setting it.
   - It returns the project whether it already existed in the workspace or was
     just created. Report which happened ("reused existing project" vs "created
     project") so the operator knows nothing was duplicated.
5. **Probe for an existing release (idempotency / resume).**
   `mcp__marshall__release_get { project: <project>, release: "<version-or-slug>" }`.
   - **Found** → the release already exists. **Do not create a second one.**
     Report it as already live and hand off (its components/graph are the next
     step). This skill stays create-only, so it won't change the project's
     external link on a resume — surface its current value as-is; to change it
     later, use the store's `project_update` tool.
   - **Not found** → continue to create it.
6. **Create the release.**
   `mcp__marshall__release_create { project: <project>, version:
   "<version-or-slug>", slug?: "<slug>", theme: "<theme>", out_of_scope:
   "<out_of_scope>" }`.
   `slug` is derived from `version` when omitted; `source` defaults to
   `native`. On success, report the created release.

   **On a tracked project this call also creates the collection.** Read
   `tracker_url` back off the response and report which happened, because the two
   outcomes need different things said:
   - **Linked** → name the collection in your report; step 9 of
     `$release-open` will have nothing left to ask.
   - **Unlinked on a project you expected to be tracked** → the tracker refused and
     the store logged it. Say so, and say the release is fine — it exists, it is
     planned against, and the link is repaired deliberately (operator-runbook §5.9).
     **Do not re-run `release_create`**: it is refused on the slug, and creating a
     collection by hand is what leaves a release with two of them.
   - The likeliest cause on Linear is a missing or key-shaped `tracker_team`.
7. **Report.** Print the project (reused or created), the release version-or-slug
   and theme, whether an external link was attached, and the next step:
   `Run $release-plan to add components, then $release-graph to verify the
   dependency graph, and $release-open to cut the branch.`

## Guardrails

- **Create-only (this skill).** This skill births a project + release; it does
  not modify or remove them — a re-run resumes an existing release, never
  overwriting or duplicating it. Editing a created record later is a separate
  path: `mcp__marshall__project_update` (name, `repo`,
  `tracker_kind`, `slug`, and the release-config defaults) or
  `mcp__marshall__release_update`. Removing one is a separate path
  again — `$release-admin`, which archives (reversible) or hard-deletes a
  mis-created empty record.

  One sharp edge worth knowing before you patch a project: changing `repo` to a
  **different** value **clears the GitHub milestone link on every release** under it
  that holds one (`milestone_number` and `tracker_url` are nulled), because that
  `tracker_url` is derived from the repo and would otherwise silently re-point at
  an unrelated milestone. The response carries a `warning` naming the unlinked
  releases — surface it and re-link each one explicitly with
  `release_update { milestone_number }` (or `{ collection }`). Setting `repo` to the
  same value, or leaving it out, touches no links.

  A release linked to any **other** tracker is untouched: the wipe is scoped to
  links that really were repo-derived, and a Linear-sourced `tracker_url` came from
  the driver with a null `milestone_number`. Keeping that scope tight still matters
  even though `release_update { collection }` can now re-link any tracker: a link
  that survives beats one the operator has to notice was destroyed and rebuild.
- **Probe before you create.** Always `release_get` first. If the release exists,
  resuming is the correct outcome; creating a duplicate is a bug.
- **The store is the source of truth; the external link is optional.** Never
  require a GitHub repo or tracker ref to create a project or release, and never
  treat the external link as a fetch/sync — it's a stored reference only.
- **Fail closed on missing tools.** If `project_create` / `release_create` aren't
  exposed, do not improvise a project/release some other way — point at
  `php artisan srm:import-release` and stop.
- **This skill does not plan or branch.** Adding components is `$release-plan`;
  verifying the graph is `$release-graph`; cutting the release branch is
  `$release-open`. Init only bootstraps the project + release.
- Surface any store error verbatim (a workspace/auth problem, a validation
  failure). Don't paper over it.

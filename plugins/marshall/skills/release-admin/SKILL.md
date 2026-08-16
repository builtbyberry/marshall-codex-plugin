---
name: release-admin
description: "Archive, restore, permanently delete, or repair a missing tracker link on a Marshall project, release, or component — the corrective verbs you reach for when a record was mis-created, abandoned, has gone quiet, or never made it onto its tracker. Use when the user says $release-admin, archive <release>, hide this project, restore the archived component, un-archive, delete this empty release, clean up the release list, or the release came back unlinked / repair the tracker link."
---

# Release Admin (Marshall)

The **corrective** surface for the shared Marshall store. Every other release-*
skill moves work *forward* — plan, graph, claim, review, deploy. This one is what
you reach for when a record should stop being part of the forward path: it was
mis-created, it was abandoned, or it is finished and cluttering the active views.

It is deliberately **not** folded into a workflow skill. These verbs are not steps
in a release; they are the things you do when something went wrong. Burying
`hard_delete_release` inside `$release-plan` would make it a footnote in a
procedure nobody re-reads.

Two families, and the distance between them is the whole skill:

- **Archive / unarchive** — a **reversible** exit. The row and its audit trail are
  preserved; the record is only *hidden* from active views. Undo is one call.
- **Hard delete** — an **irreversible** row removal. No undo, no audit trail,
  nothing to restore. The store fences it hard (see below) so the only thing it
  can actually remove is a mis-created empty record.

**Archive is the default answer.** Reach for hard delete only when the record is
genuinely a mistake — a typo'd project, a release created against the wrong
version — and never as "tidying up".

## How it talks to the store

Read first:

- `mcp__marshall__project_list` — the workspace picture, **including
  archived projects** (flagged `archived: true`). What is already hidden, before you
  hide more — or what there is to restore.
- `mcp__marshall__release_get` — a direct fetch still returns an
  archived release/component, carrying its `archived` flag. This is how you
  inspect something the discovery scan no longer shows.
- `mcp__marshall__release_status` — live holds. A component with an
  active claim is someone's in-flight work; see the guardrails.

Archive (reversible, available to **any workspace member**). An archived record drops
out of the discovery scan (`release_next` / `release_status`); a direct `release_get`
still returns it. Both parents are **refused** with `cannot_archive`, naming the
blockers, while they hold an **active** child: a release, while any component is in
`open` / `in_progress` / `proposed`; a project, while any release is neither shipped
nor archived.

- `mcp__marshall__archive_component { component }` — by ULID. A
  component has no children, so this is **always allowed**.
- `mcp__marshall__archive_release { release, project? }` — by version-or-slug.
- `mcp__marshall__archive_project { project }` — by slug.

Unarchive (the exact inverses, also any workspace member):

- `mcp__marshall__unarchive_component { component }`
- `mcp__marshall__unarchive_release { release, project? }`
- `mcp__marshall__unarchive_project { project }`

Hard delete (**irreversible** — read the section below before calling any of these):

- `mcp__marshall__hard_delete_component { component }`
- `mcp__marshall__hard_delete_release { release, project? }`
- `mcp__marshall__hard_delete_project { project }`

Repair a tracker link that was never written (**owner-only**, safe to re-run):

- `mcp__marshall__repair_tracker_link { release, project? }`

If the MCP server isn't connected, **stop and say so.** These records live only in
the store; there is no local file to edit instead.

## Archive resolves bottom-up; unarchive resolves top-down

The archive guards are a containment rule, and they compose into an order. A
project refuses while it holds an active release; a release refuses while it holds
an active component. So:

**To archive**, work **upward** from the leaves — components, then the release,
then the project. `cannot_archive` names exactly what is blocking, so the error
*is* your worklist. Do not fight it; walk it.

**To restore**, work **downward** — unarchive the project, then the release, then
the components you actually want back. Unarchiving a parent does **not**
cascade to its children: a restored release still has its archived components
hidden, and that is usually what you want (restore the release, bring back only
the components that still matter).

## Procedure

1. **Read before you write.** `project_list` for the workspace picture (what is
   archived already), `release_get` for the specific record. Never act from
   conversation memory — an archived record is invisible to the discovery scan, so
   "I don't see it" is not evidence it doesn't exist.
2. **Name the target precisely and read it back to the operator.** A project slug,
   a release version-or-slug, a component ULID. If the version is ambiguous across
   projects, pass `project` to disambiguate rather than guessing.
3. **Confirm — explicitly, and scaled to the blast radius.**
   - **Archive / unarchive** → confirm the target, note that it is reversible and
     name the inverse call.
   - **Hard delete** → confirm *in the operator's own words* that they understand
     there is no undo. Never infer a hard delete from a vague instruction like
     "get rid of it" — ask whether they mean archive (almost always) or delete.
4. **Call the tool.** One record per call; there is no batch form and you should
   not simulate one by looping without re-confirming.
5. **Report what actually changed**, including which views it left or re-entered
   ("hidden from `release_next`; a direct `release_get` still returns it"), and for
   an archive, the exact call that undoes it.

## Repairing a tracker link

The third corrective verb, and the only one that reaches outside the store. On a
project whose tracker resolves, `release_create` also creates the release's
collection there and each `component_create` files an issue — and **a tracker
failure never blocks planning**, so the record lands with its link null and the
store logs it. This is the way back from that, and it is the reason the promise is
a contract rather than a shrug.

**Reach for it when** a release you expected to be tracked came back unlinked, or a
component's issue was never filed. Do **not** re-run `release_create` or
`component_create` to "try again" — the store refuses the duplicate slug, and on
Linear a second attempt makes a second record rather than refusing.

`mcp__marshall__repair_tracker_link { release: "<version>", project?: "<slug>" }`

**It resolves, creates, or refuses — and never guesses.** It records an id the store
can already prove, files what is provably missing, and refuses anything it would
have to decide. In particular it will **not** adopt a collection or issue because
the name matches: `collection_exists_unlinked` names the candidate and stops. That
is not timidity — Linear's collections read reaches teams the grant is not a member
of, so a name match is not evidence of ownership. Adopt deliberately instead, with
`release_update { collection: <id-or-url> }` or `component_update { external_ref }`.

**Owner-only**, refused with `not_authorized` otherwise, on the same reasoning as
hard delete: it spends the workspace's tracker credential and can create records in
it.

**Re-run it when the response says `resumable: true` — not merely when it carries
`remaining`.** Repair commits each link as it lands and stops at its own deadline, so a
release with many unlinked components needs more than one pass. But `remaining` is the
INVENTORY of what is still unlinked, and some of it never becomes linkable: a component
that has already merged is skipped as `component_already_merged`, because auto-close
fires on the transition INTO merged and that is behind it, so an issue filed now would
stay open forever. **Tell the operator the way out rather than stopping there** — reopen
the component if the merge was premature, or file the issue by hand and link it with
`component_update { external_ref }`. Retrying on `remaining` is a loop with no exit;
`resumable` is the retry signal, and when it is false read the reason on each skip and
say what it asks for. Running it again creates nothing twice, and a release with
nothing left to repair makes no tracker calls at all. Report `created` separately
from anything resolved — the operator's first question is always whether something
new appeared in their tracker.

The full refusal table and the diagnostic steps are operator-runbook §5.9.

## Hard delete: what the server refuses, and why you should not re-check it

The three `hard_delete_*` tools are fenced **server-side on two independent axes**.
This section is here so an operator reading the skill knows what to expect from a
refusal — **not** so the skill can pre-check it.

**Axis 1 — OWNER-ONLY.** Refused with `not_authorized` unless the caller is a
workspace **owner**. Ordinary members can archive freely and cannot hard-delete at
all.

**Axis 2 — EMPTY-ONLY.** Refused with `cannot_delete`, **naming what references
it**, unless the record is genuinely empty:

| Tool | Refuses unless |
| --- | --- |
| `hard_delete_component` | **nothing depends on it** — no other component is blocked by it. Its own outgoing `blocked_by` edges are removed with it. |
| `hard_delete_release` | it has **zero components, zero findings, and no deploy record**. |
| `hard_delete_project` | it has **zero releases**. |

Between the two axes, the only thing these tools can remove is a **mis-created,
empty record**. Anything that carries real history is unreachable by them — which
is the design, and the reason the verbs are safe to surface at all.

**Do not duplicate these guards client-side.** Do not count a release's components
before calling, do not check whether the operator is an owner, do not pre-walk the
dependency graph. The guard already lives in the right place — on the server, in
one transaction, where it cannot race. A second copy in this skill would be a copy
that **drifts**: the server tightens a rule, the skill keeps enforcing the old one,
and the two disagree about what is deletable. Call the tool and let it refuse.

**When it refuses, surface the error verbatim and stop.** `cannot_delete` names
the blockers — that is a genuine finding about the record's state, not an obstacle
to route around. The correct next move is almost always to archive instead.

## Guardrails

- **Archive is the default; hard delete is the exception.** If the operator has
  not clearly said "permanently delete", they mean archive. When in doubt, archive
  — it is reversible, so the wrong call costs one undo instead of the record.
- **Never work around a refusal.** `cannot_archive` and `cannot_delete` are
  fail-loud guards naming real blockers. Walking the blocker list is correct;
  archiving children *purely* to unblock a parent delete is laundering the guard —
  ask the operator first.
- **Check for live holds before archiving a component.** An active claim means
  someone is working it right now. `release_status` shows the holder; archiving it
  out from under them hides work in flight. Confirm, and prefer
  `$release-unclaim` first if the hold is genuinely stuck.
- **Archiving is not cancelling, and neither is deleting.** A component abandoned
  *as work* should move to the `cancelled` work-state via
  `mcp__marshall__set_component_state` — that keeps it visible as a
  deliberate cut and correctly **strands** its dependents rather than silently
  freeing them. Archiving only hides the row. Use `cancelled` for "we decided not
  to do this", archive for "this no longer needs to be on screen".
- **Unarchive does not cascade.** Restoring a parent leaves its archived children
  hidden. Restore each level you actually want back, and say so in the report.
- **One record per call, each behind its own confirmation.** No bulk sweeps.
- **Surface every store error verbatim** — `not_authorized`, `cannot_delete`,
  `cannot_archive`, a workspace-scope failure. Don't paper over it or retry blindly.

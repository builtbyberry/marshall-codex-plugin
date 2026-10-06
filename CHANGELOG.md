# Changelog

All notable changes to the Marshall Codex plugin.

This file is hand-authored and is **not** rendered by the publisher. The plugin's
version is set at the source in `builtbyberry/swarm-release-manager` and rendered
into `plugins/marshall/.codex-plugin/plugin.json`; the heading and git tag here must
match whatever that render declares.

## 1.13.0 — 2026-10-06

A wrap leaves a mark, and the deploy reads it.

### Changed

- **`release-wrap` sets the wrap mark at the hand-off.** The call that writes the wrap
  summary now also sends `wrapped: true`, and the store stamps when (`wrapped_at`). The
  mark is what moves a release's next step from "Wrap the release" to "Deploy the
  release" in Marshall Workspace and on the release page. The skill sets it only when
  the release is declared ready and never clears it: the store stops counting a wrap by
  itself once a part is reopened or added, or a high finding is recorded, after it. The
  skill checks that the release it gets back reads `wrapped: true`, and says why when it
  does not.
- **`release-deploy` warns when a release is not wrapped.** Its preflight reads `wrapped`
  from `release_get` and, when it is `false`, says which case it is — wrap was never run,
  or a wrap was run and no longer counts — and recommends `release-wrap` first. It is a
  warning, not a refusal; the store's check for unresolved high findings is still the
  gate.

Needs a store that has deployed agent-sight. Against an older store the field is ignored
and the skills say so and carry on. A release wrapped with 1.12.0 or older has a summary
and no mark, and reads as not wrapped until it is wrapped again.

## 1.12.0 — 2026-10-02

The build loop leaves evidence, and a finished release keeps its record.

### Changed

- **`release-build` records its three gates.** When the plan survives its pressure-test
  (step 3), when each new test has been watched failing (step 5) and when the fixes have
  been independently verified (step 8), the skill writes a gate record on the part with
  `record_gate`: passed or waived, the commit, and structured evidence. On a resume or
  land-only entry it reads the records and treats a recorded gate as run, where before it
  could only declare the gate void.
- **A gate that ran is never left unrecorded.** A refused record is corrected, then
  recorded as a waiver that carries the evidence; if the store cannot take it at all, it
  is kept in a local gate outbox in the main checkout's git directory and replayed later.
  Before a part is proposed the skill writes any of the three records still missing.
- **A merge the store refuses is a stop, never a waiver.** A project can require gate
  records before a part is merged. `release-build` checks before it merges, stops and
  names the missing gate, and never waives its own way past the refusal.
- **`release-build` writes a part's landing facts.** Once the pull request is open it
  writes the part's closing summary and pull request; the run that sets the part merged
  writes the merge commit, and a resumed run fills a merge commit an earlier run left
  blank.
- **`release-wrap` writes the wrap summary** when it hands off, and **`release-deploy`
  writes the deploy summary** when it reports — including on a resume that finds the
  deploy done with no summary, and in tag mode on either verdict.
- **`release-deploy` replays any gate outbox before it records a deploy done.** A shipped
  release takes no more gate records, so records a build could not write go in while the
  release is still open.

Needs a Marshall store that has deployed proof-of-work (2026-10-02). Against an older
store the skills fall back to the outbox for gate records and say plainly when a summary
or landing fact was not kept; nothing stops or loops.

## 1.11.0 — 2026-09-25

The skills say where they run, and reuse the worktree they are in.

### Changed

- **`release-topic` and `release-build` report their location on every claim and
  heartbeat** — the agent (`codex`), the Mac's hostname and the absolute worktree
  path — so Marshall Workspace can show who is working a part, on which Mac, in which
  folder. An older store ignores the new fields.
- **They reuse the checkout that is already there.** Started on the part's topic
  branch (for example in a worktree Marshall Workspace created), the skill says
  `Reusing worktree <path> on <branch>` and does not add another; a branch that exists
  but is checked out nowhere is attached without `-b`; a branch checked out in another
  worktree is a stop that names that path.
- **One claim rule for fresh, continued and lapsed work.** A lapsed or released part is
  re-claimed (the fence bumps); a revoked one stops; one someone else holds stops with
  `Held by <name> on <machine> via <agent> — stopping.`

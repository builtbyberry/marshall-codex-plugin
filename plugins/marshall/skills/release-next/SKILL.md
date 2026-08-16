---
name: release-next
description: "Recommend the next startable release work from the Marshall store — across every release in flight, or within one. Use when the user says /release-next, what is next, what should I work on, or I have a time budget."
---

# Release Next (Marshall)

Recommend 1–3 startable components, reading the **shared Marshall store** through its
MCP tools instead of a repo-local `release-plan.json`. This is read-first; it
never claims work.

It is the proof of the lift — startability is computed *server-side* from the
dependency graph and live claims, so two people (or an agent and a human) on
different machines see the same truth.

**Several releases in flight is normal**, not an edge case: claims are held per
*component*, so teammates on different releases never contend. So "what should I
work on?" is answerable without naming a release first — scope the question to
whatever the user actually gave you.

## How it talks to the store

- `mcp__marshall__release_next` — startable work, ranked by what it unblocks
- `mcp__marshall__release_status` — who holds what + drift
- `mcp__marshall__release_get` — the full release document

If those tools aren't available (the MCP server isn't connected), fall back to
the `marshall` CLI: `marshall next --release <version> --json`. Same data, secondary path
— but it is **per-release only**, with no cross-release scan, so on that path you
do have to ask the user which release.

## Procedure

1. **Scope it from what the user said. Never ask for a release they didn't name.**
   - Named a release → `{ release: "<version-or-slug>" }`. Add `project` only to
     disambiguate the same version across projects.
   - Named a project → `{ project: "<slug>" }` — its unshipped releases.
   - Named nothing ("what should I work on?") → `{}` — every unshipped release in
     the workspace. This is the default for an open-ended ask.
2. Call `mcp__marshall__release_next`.
3. Render the result:
   - `startable` non-empty → recommend the top 1–3 (already ranked).
   - `startable` empty → report what's blocking. Read `releases[]` for the
     per-release breakdown — *which* release is stuck and why — not just the
     merged `blocked_summary`, which cannot say where the problem is.
   - Tool error → surface it verbatim. Do not paper over it.

## Reading the response

- `startable[]` — ranked. Each carries its `release` (`{version, slug, project}`)
  and `unblocks` (how many components it frees).
- `blocked_summary` — counts by reason, merged across the scope
  (e.g. `{ "unverified": 1 }`, `{ "blocked": 2 }`).
- `releases[]` — one entry per release considered, each with its own `startable`
  count and `blocked_summary`.
- `scope` — `release:<version>` | `project:<slug>` | `workspace`.
- `release` — the version when you named one, else `null`.

**Ranking across releases is a proxy, not gospel.** `unblocks` is counted within
each release's *own* graph, so unblocking 5 in a 40-component release is not the
same currency as unblocking 3 in a 4-component one. When the list spans releases,
weigh the ranking against what is actually near shipping, and say that you are —
the server has no basis for that judgement, so it does not pretend to.

## Errors

Surface them verbatim. Each is recoverable in a specific way:

- `release_ambiguous` — the key matched more than one release. `candidates[]`
  names each one's `project` + `slug`; retry with `project` set to a candidate's
  project and `release` set to its slug — that pair is unique. (`project` alone is
  enough when only one candidate is in it.) Never retry with the same bare key.
- `release_not_found` — nothing matched. Ask; don't guess another key.
- `project_not_found` — that project isn't in this workspace.
- An auth/connection problem — report it. Don't work around it.

## Output

For each recommendation (already ranked by what it unblocks):

- tracker ref + title (e.g. `#42 Audit trace CLI`)
- **its release** — whenever the list spans more than one. A cross-release list is
  useless if the reader can't tell what belongs where.
- why it's startable now (no unmet blockers, graph verified, unheld)
- what it unblocks (its position on the critical path)

End with:

- `start <ref>` to begin work — claim it with `mcp__marshall__claim_component`
- to take more than one, claim each with `$release-topic`, or dispatch a whole
  wave concurrently with `$release-parallel`

## Guardrails

- Do not claim, heartbeat, or release here — recommending is read-only. The claim
  lifecycle is a deliberate next step.
- Do not invent startability. If `release_next` returns nothing, the answer is
  "nothing is startable, here's why" — never relax the server's verdict.
- If a graph is `unverified`, say so plainly: that release needs `$release-graph`
  before work is safe to start (the store's fail-safe default).
- Scanning covers **unshipped** releases only — a shipped release has no work left
  to recommend. Naming one explicitly still reports on it.

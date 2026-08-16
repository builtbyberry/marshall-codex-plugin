---
name: release-graph
description: "Declare a release's dependency graph in the Marshall store so components become startable. Use when the user says /release-graph, map dependencies, build the dependency graph, or why is nothing startable."
---

# Release Graph (Marshall)

Map the blocked-by dependencies between a release's components and write them to
the shared Marshall store. Until this runs, components sit at the store's fail-safe
`unverified` default and **nothing is startable** — this is what turns the graph
on.

## How it talks to the store

- `mcp__marshall__release_get` — read the release's components (ids, titles, refs).
- `mcp__marshall__set_release_graph` — write the edges + verify the graph.

(Fallback if MCP isn't connected: `marshall` CLI is read-only for the graph today;
prefer the MCP tool.)

## Procedure

1. Resolve the release version (ask if ambiguous — don't guess).
2. `mcp__marshall__release_get { release }` to load the components.
3. Determine the **blocked-by** edges. Derive them from the issue bodies /
   acceptance criteria / "depends on" references, and **confirm the proposed
   edges with the user** before writing — the graph gates all work, so it's worth
   a beat. Each edge is `{ blocked: <component id>, blocker: <component id> }`
   using the `id` (ULID) from `release_get`.
4. Call `mcp__marshall__set_release_graph { release, edges }`. Pass `edges: []` for a
   release whose components have no inter-dependencies (this still verifies it).
5. On success it returns the updated release; report which components are now
   startable (roots) vs blocked. On `invalid_graph`, surface it verbatim — the
   store rejects self-edges, cross-release edges, and cycles, and writes nothing.

## Guardrails

- Setting the graph **replaces** the release's edges and marks every component
  `known`. Don't run it with a partial edge set you haven't confirmed.
- Don't invent dependencies to make something startable — the graph must reflect
  real blockers. If unsure whether two components depend on each other, ask.
- A cycle is a planning error, not a runtime state; if the store reports one,
  fix the edges with the user rather than forcing it.

After this, use `$release-next` to see what's startable, then `$release-topic`.

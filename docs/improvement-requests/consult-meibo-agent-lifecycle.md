---
title: "Consult the meibo directory for agent lifecycle (pause/kill switch) and fleet identity"
status: proposed
originator: kikan / meibo initial spec (contract C14)
target_repo: shinzui/shikigami
contracts: [C14, C5]
created_at: 2026-07-07
---

# Improvement Request: Consult `shinzui/meibo` for agent lifecycle and fleet identity

## Status

**Proposed.** Design-only request authored from the Kikan C14 ratification (2026-07-07).
Implementation is gated on `shinzui/meibo` shipping its service and `meibo.v1` topic; the
seam can be built earlier behind a config/stub, the same pattern used for the shomei and
kikan-en gates.


## Planning Coverage

Tracking intention: `intention_01kyeb9jn6evntbk13tey07n1c`.

This request already has planning coverage in
[MasterPlan 4: Identity and trust, grants, outbound auth, and agent lifecycle control](../masterplans/4-identity-and-trust-grants-outbound-auth-and-agent-lifecycle-control.md)
and [Plan 23: Agent lifecycle control with Meibo principals](../plans/23-agent-lifecycle-control-with-meibo-principals.md).
Plan 23 retains its original historical intention in frontmatter; the intention above tracks
this improvement-request inventory without replacing that lineage.

## Context

Kikan ratified **`shinzui/meibo`** (名簿) as the organizational directory (contract **C14** in
`kikan:docs/architecture/evolution/contracts.md`): every agent is a first-class **principal**
(`agent_…` id, `@handle`, profile, owner, lifecycle `active | paused | deactivated`), and for
agents **`paused` is the portfolio-wide kill switch**.

The 2026-07-07 kikan serving validation found the gaps this closes in shikigami today: agent
declarations are Dhall files loaded per-process at startup with **silent skip of unparseable
manifests** (`Cli/Commands/Worker.hs` `loadAgents`); there is **no enable/disable/pause
concept** in the runtime (disabling an agent means deleting the file and restarting every
consumer process); there is no registry to list deployed agents or their load status; and
cross-repo references (`kanmon`'s `inboundBindsTo = ["shikigami/retention-agent"]`) are
validated against nothing.

## The Request

1. **Lifecycle consult (the kill switch).** Before firing any trigger (scheduler, stream
   consumer, event consumer) and before dispatching any sink, the runtime checks the agent's
   lifecycle in a **local cached directory view** built from `meibo.v1` (or the meibo read API
   with revalidation). `paused`/`deactivated` ⇒ skip the run / skip the sink, recording an
   attributable skipped outcome on the session (parallel to the permission-gate denial path).
   Per C14's change rule, this is a cache read — **no hot path blocks on meibo synchronously**,
   and a meibo outage fails open to the last-known lifecycle.
2. **Join declarations to principals.** An agent's Dhall `name` joins to its meibo `agent_…`
   principal by handle. On load, the runtime reconciles: declared-but-no-principal and
   principal-but-no-declaration both become visible, listable states (this also gives
   `kanmon`'s `inboundBindsTo` something to validate against).
3. **Surface load status.** Replace the silent skip of unparseable manifests with a recorded
   per-agent load state (loaded / failed(reason) / no-manifest) queryable alongside the
   principal — the data a fleet page renders.
4. **Attribute runs to principals.** Kioku sessions record the agent's principal id (today the
   free-text agent name), so run history joins the directory without string matching.

## Out of scope here

The shikigami HTTP API package (agents/runs/approvals — a separate serving-tier request), the
kikan-en `checkAction` swap (EP-10, already tracked), and cost/model capture on sessions
(separate gap). This request is only the directory consult and identity join.

## Acceptance sketch

- Pausing `agent_…` in meibo stops schedule/stream/event fires and sink dispatch for that
  agent after cache refresh, with skipped outcomes recorded; reactivating resumes it — no
  process restarts, no file deletions.
- `agents/broken.dhall` produces a visible failed-load state instead of a silent skip.
- A run's kioku session carries the agent principal id; a fleet listing can join declarations,
  principals, load states, and recent runs without heuristics.

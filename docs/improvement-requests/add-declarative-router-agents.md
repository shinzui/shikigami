---
type: Improvement Request
title: Add declarative router agents
description: Declare specialist expertise and route work through durable, typed delegation.
timestamp: "2026-07-30T00:42:00Z"
generated:
  by: process:codex
  at: "2026-09-21T18:03:06Z"
requestId: IR-3
status: completed
completedAt: "2026-08-23T20:39:18Z"
resolution: Completed by mori://shinzui/shikigami/masterplans/8-declarative-router-agents and child plans 40 through 42.
origin: mori://shinzui/kikan
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-21T18:03:06Z"
    document_timestamp: "2026-09-21T18:03:06Z"
    scope: catalog-metadata
    outcome: approved
    context: Audited lifecycle status and plan coverage against the current plans, master plans, Git history, and repository tree; did not re-review the request's design.
    provider: openai
    model: gpt-5.6-sol
    effort: high
---

# Improvement Request: Add Declarative Router Agents

## Status

**Completed.** MasterPlan 8 and plans 40 through 42 delivered the declaration vocabulary,
lifecycle-aware candidate catalog, replay-safe typed routing, and durable delegation on
2026-08-23.


## Planning Coverage

Tracking intention: `intention_01kyeb9j20e8prwv62v7mzp574`.

This request is tracked by [MasterPlan 8: Declarative router agents](../masterplans/8-declarative-router-agents.md)
and its child ExecPlans:

- [Plan 40: Declare specialist expertise and router policy](../plans/40-declare-specialist-expertise-and-router-policy.md)
- [Plan 41: Resolve lifecycle-aware router candidate catalogs](../plans/41-resolve-lifecycle-aware-router-candidate-catalogs.md)
- [Plan 42: Execute replay-safe typed routing and delegation](../plans/42-execute-replay-safe-typed-routing-and-delegation.md)


## Context

Shikigami can run declared agents and its workflow runtime can spawn and await delegated
child runs with durable lineage. Today, however, that mechanism is not a router abstraction:

- `schema/Agent.dhall` has `name`, `description`, `trigger`, `behavior`, and `sinks`, but no
  declared expertise or router policy;
- the shipped delegation proof is reached through a hard-coded `research-supervisor` task
  branch;
- plan 35 will add `delegates`, a delegation budget, cycle prevention, partial collection,
  and a Flow delegation capability, but its candidate set is still a list of agent names;
- nothing presents an allow-listed specialist catalog to a router, validates a semantic
  route decision, records why a specialist was chosen, or distinguishes “no match” from a
  failed child run.

Those responsibilities belong in Shikigami. Mori may address one named entry agent when a
repository pattern matches, but Mori must not carry a topic-to-specialist map or perform
semantic selection.


## The Request

Add an additive declaration and runtime contract for a **router agent**.

### 1. Specialist expertise declarations

Extend agent declarations with routing-facing expertise metadata, defaulting to an empty
list so existing manifests remain valid. Each expertise entry must have a stable key and a
human/model-readable description; aliases or evidence hints may be included when useful.

Conceptually:

```dhall
, expertise =
  [ Expertise::{
    , key = "opentelemetry"
    , description = "Tracing, metrics, propagation, semantic conventions, and hs-opentelemetry"
    , aliases = [ "otel", "trace-context", "spans" ]
    }
  ]
```

Expertise is routing metadata, not authorization to use tools or sinks.

### 2. Router declaration

Add an optional router policy to the agent declaration. `None` preserves an ordinary
agent. `Some policy` declares that this agent routes work among the candidates named by the
plan-35 `delegates` allow-list.

The policy must bound fan-out and define explicit behavior for no-match and ambiguous
decisions. It must not accept candidate agent names from an inbound trigger payload.

Conceptually:

```dhall
, delegates =
  [ "opentelemetry-practice-reviewer"
  , "event-sourcing-practice-reviewer"
  , "security-practice-reviewer"
  ]
, routing = Some RouterPolicy::{
  , maxSelections = 2
  , minimumConfidence = RouterConfidence.Medium
  , onNoMatch = NoMatchPolicy.ReturnUnresolved
  }
```

### 3. Typed routing boundary

Expose a replay-safe routing capability to router behaviors. It must:

1. Resolve only the router's declared `delegates`.
2. Build a candidate catalog from those agents' names, descriptions, expertise, and current
   lifecycle availability.
3. Give the router behavior the original input plus that catalog.
4. Accept a typed `RouteDecision` rather than an unstructured agent name.
5. Validate every selected target against the allow-list, lifecycle state, fan-out bound,
   and plan-35 delegation budget before any child is spawned.
6. Delegate and await through plan 35's general Flow capability, preserving the existing
   parent/child workflow and Kioku session lineage.

A route decision must represent at least:

```json
{
  "outcome": "matched",
  "selections": [
    {
      "agent": "opentelemetry-practice-reviewer",
      "expertise": ["opentelemetry"],
      "confidence": "high",
      "rationale": "The ADR changes trace propagation and pins hs-opentelemetry."
    }
  ]
}
```

The other outcomes are `no-match` and `ambiguous`. A runtime/delegation failure is separate
from all three and must never be converted into a semantic no-match.

The route decision and resolved candidate-catalog version must be journaled under a stable
Flow step label. Replaying a router workflow reuses the decision and deterministic child
runs; it must not silently select a different specialist because manifests or model output
changed after the original step.

### 4. Lifecycle and observability

Before presenting or invoking a candidate, consult the active/paused lifecycle source
requested by `docs/improvement-requests/consult-meibo-agent-lifecycle.md`. Until that
integration lands, a local enabled/disabled declaration may be used as a clearly documented
interim source; the router must not claim it verified Meibo state when it did not.

Record routing observability with the parent session: candidate names, selected names,
expertise keys, confidence, rationale, catalog/declaration versions, and the reason a
candidate was excluded. Do not put full changed documents into logs.


## Relationship to Existing Plans

- **Plan 33** owns the additive schema-evolution pattern and the general `enabled` field.
- **Plan 35** owns `delegates`, the durable tree-wide budget, allow-list enforcement, cycle
  prevention, Flow delegation, and partial child-result handling.
- **This request** owns expertise discovery, the router declaration, typed semantic route
  decisions, candidate/lifecycle resolution, replay-safe decision recording, and route
  observability.

If plans 33 and 35 have not landed, implement them first or incorporate this request into
their compatible schema/runtime work. Do not create a second delegation mechanism.


## Acceptance

Accepted when deterministic fixtures prove:

1. An `architecture-practice-router` can inspect its declared candidate catalog and route an
   OpenTelemetry-shaped input to `opentelemetry-practice-reviewer`.
2. The selected child is a normal delegated Shikigami run with parent session, parent
   workflow, depth, and budget lineage.
3. A classifier-produced name not present in `delegates` is rejected before enqueue.
4. A declared but paused/disabled specialist is excluded or refused with a visible reason.
5. `no-match` and `ambiguous` return typed router outcomes and spawn no unauthorized child.
6. A cross-domain input may select more than one specialist but never exceed
   `maxSelections` or the durable delegation budget.
7. Replaying the same router workflow reuses its recorded decision and child workflow ids;
   no duplicate child runs are created.
8. Existing non-router manifests validate unchanged, and an ordinary agent cannot gain
   routing authority merely because an inbound payload names candidate agents.


## Out of Scope Here

- Repository watching, practice-adoption relationships, or reference-change fan-out. Mori
  owns those graph and automation concerns.
- The domain-specific definition of an architecture-practice verdict.
- A global marketplace that lets a router select every registered agent. Candidate sets are
  explicit and local to the router declaration.
- Tool and sink authorization; expertise metadata is not a Shomei permission.
- Automatic source edits or merge gating.


## References

- `kikan:docs/use-cases/006-specialist-review-of-architecture-decisions.md`.
- `schema/Agent.dhall` and `shikigami-api/src/Shikigami/Api/Agent.hs` — current declaration
  surface.
- `docs/plans/9-multi-agent-delegation-primitive.md` — shipped durable primitive and current
  hard-coded proof limitation.
- `docs/plans/35-delegation-as-a-first-class-declared-capability.md` — prerequisite
  declarative delegation, allow-list, budget, and Flow capability.
- `docs/improvement-requests/consult-meibo-agent-lifecycle.md` — lifecycle lookup required
  before routing to a specialist.

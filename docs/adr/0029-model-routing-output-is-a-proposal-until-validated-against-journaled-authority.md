# 0029. Model routing output is a proposal until validated against journaled authority

Date: 2026-08-23

Status: accepted


## Context

A semantic router needs model judgment, but a provider response is untrusted text. It can name an
undeclared or unavailable agent, claim expertise the candidate did not declare, use stale catalog
identity, fall below the router's confidence floor, exceed its fan-out limit, or encode an
impossible mixture of matched, no-match, and ambiguous fields. Executing that response directly
would make the model an authorization system.

Durable replay creates a second hazard. Re-reading declarations or lifecycle state and invoking the
provider on every resume can change both the candidate universe and the selected children for one
workflow id. Logging the prompt or complete model-facing values to explain the choice would expose
trigger bodies and candidate descriptions beyond their owning journal.


## Decision

**A route becomes executable only after its exact candidate catalog and raw versioned decision are
journaled and the decoded decision validates completely against that catalog and the router's
declared policy.**

The Flow routing capability maps each closed `RouteLabel` to two static workflow labels. It first
journals the complete `CandidateCatalog`, then evaluates the original payload through an injected
runtime and journals the raw JSON value. Strict decoding rejects extra or outcome-incompatible
fields. Validation checks decision version, catalog version, distinct non-empty selections,
declaration and lifecycle availability, expertise claims, confidence, and fan-out before producing
executable authority. `matched`, `no-match`, and `ambiguous` are a closed sum; only `matched` can
delegate.

Provider, decoder, validation, delegation-budget, and child failures remain operational failures.
They are not converted into no-match or ambiguous results. A matched batch independently preflights
the recorded catalog and delegates only through ADR-0023's governed spawn boundary. No-match and
ambiguous return structured parent results and create no child.

The first registered call site owns `route-catalog-architecture-practice` and
`route-decision-architecture-practice`. ADR-0027 permits these labels to enter the clean unreleased
v1 body directly after verifying that no durable population or external consumer exists. After v1,
new routing call sites follow ADR-0012's patch discipline.

Routing traces contain bounded identifiers and decisions: parent session/workflow, catalog version
and lifecycle source, candidate and exclusion names, outcome, selected names and expertise,
confidence, rationales capped at 512 characters, and an error category. They never contain the
trigger payload, candidate descriptions, changed-document bodies, provider prompt, credentials, or
tool configuration.


## Alternatives rejected

**Execute any syntactically valid provider response.** Syntax does not establish declaration,
lifecycle, expertise, confidence, catalog freshness, or fan-out authority.

**Rebuild the catalog or reevaluate the model on resume.** One workflow id could select different
children after a deployment or lifecycle refresh, violating replay.

**Journal only the final selected names.** Operators and validators could not prove which excluded
or available candidates the decision was made against, and stale-provider output would be harder to
detect.

**Treat invalid output or child failure as no-match.** This erases an operational failure as a
successful semantic judgment and prevents truthful retry and alerting.

**Put routing IO directly in a Flow body.** Unjournaled external work may repeat on replay and would
widen every Flow with ambient IO and store access. The capability interpreter retains those effects
at the process boundary.


## Consequences

Replaying a route returns the recorded catalog and raw decision before either runtime closure can
run, so declaration, lifecycle, or evaluator changes cannot move its child identities. New decision
schema versions require an explicit decoder and validation path; unknown versions fail closed.

Every registered route call site consumes two durable static labels and must be added to the checked
workflow inventory. Model-facing fields remain deliberately richer than trace fields: the journal
holds the authoritative replay values, while telemetry exposes only bounded operational evidence.


## References

* [`docs/masterplans/8-declarative-router-agents.md`](../masterplans/8-declarative-router-agents.md)
  — coordinates declarations, catalogs, and execution.
* [`docs/plans/42-execute-replay-safe-typed-routing-and-delegation.md`](../plans/42-execute-replay-safe-typed-routing-and-delegation.md)
  — implementation and acceptance evidence.
* [ADR 0012](0012-a-declared-workflow-body-only-grows-behind-a-patch.md) — post-v1 workflow shape
  evolution.
* [ADR 0013](0013-flows-reach-the-world-only-through-capabilities.md) — Flow capability isolation.
* [ADR 0023](0023-delegation-is-governed-at-the-child-spawn-boundary.md) — batch preflight,
  reservation, and child-spawn authority.
* [ADR 0027](0027-the-first-release-establishes-one-clean-durable-baseline.md) — the clean-v1 reset
  exception.
* [ADR 0028](0028-a-router-catalog-is-a-bounded-snapshot-of-declared-authority.md) — catalog
  authority and lifecycle snapshot rules.
* `mori://shinzui/keiro` — the durable workflow and journal API used by the capability interpreter.

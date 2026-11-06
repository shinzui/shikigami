# 116. Watchdog observation preserves completeness and detector boundaries

Date: 2026-11-05

Status: Accepted (design; implementation remains in plans 109–113)

## Context

MasterPlan 19 composes owner observations, liveness classification and model-assisted
scope assessment. A bounded active-population page cannot establish absence of a
related execution or approval. Liveness progress also does not establish that work
has returned to scope. Treating either as a negative finding would produce false
alerts or repeatedly reopen drift episodes.

## Decision

Owner reads expose bounded metadata and explicit completeness. Failed or truncated
reads are unknown; disappearance from a page alone never closes an episode.
Coverage is scoped and advances under a retained sweep claim. Retries recover the
claim and original page outcome before recomputing or coalescing findings.

Liveness and drift are separate detection families. Clearing one family leaves
the other unchanged. The ledger owns sealed findings; journals contain explicit
read views. Drift proposals pass an input-bound pure validator before becoming
sealed assessments because the registered program result validator sees only its
output. A committed result replays without a provider call; an uncommitted result
may require another conservatively accounted attempt.

The watchdog follows ADR 0115: operator configuration grants spending, a trigger
enrolls the independent root, and the Drift label explicitly selects root
accounting. Installing a declaration grants neither observation nor spending.
Existing workflow versioning rules apply: the patch-false interpreter writes no
watchdog labels.

## Alternatives rejected

Inferring absence from one page conflates missing evidence with a terminal owner
fact. Clearing all episodes on progress conflates activity with scope alignment.
A declaration-level allowance conflicts with the existing operator-owned observer
boundary. Promising exactly one transport call across a lost journal append hides
uncertain spending.

## Consequences

Plans 109–113 must prove bounded incomplete reads, episode-family isolation,
retained outcome recovery, overlap handling and accounting refusal before provider
IO. These are design requirements, not claims of runtime qualification.

See [MasterPlan 19](../masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md)
and [ADR 0115](0115-evaluation-spend-is-a-root-enrolled-at-the-trigger-and-accounted-slots-refuse-without-one.md).

## Initial observation boundary

The Watchdog module root owns a domain concept under ADR 0075: observing active
work and describing evidence. Owner verticals retain their metadata projections;
Watchdog composes those projections and grants no objective or session command.

The implemented grant is an opaque, non-Generic value bound to the admitted
identity. It has no JSON decoder or public record fields. A principal-free
snapshot retains admitted scope, windows and budget; restoration checks current
enablement and the exact configured identity without replacing the retained
policy. Compatibility names and verified principals remain distinct modes.
Omitted operator configuration returns WatchdogDisabled. This is the implemented
vocabulary/grant boundary only; sweep and runtime qualification remain open.

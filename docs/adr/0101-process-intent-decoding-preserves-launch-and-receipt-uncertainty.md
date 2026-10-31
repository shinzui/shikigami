# 0101. Process intent decoding preserves launch and receipt uncertainty

Date: 2026-10-31

Status: accepted

## Context

ProcessStore owns launch intent, the single committed launch grant and retained
invocation/receipt facts. The supervisor can recover those facts without a live
worker or current model authority. An unreadable record cannot become a missing
registration, a replacement launch or evidence that descendants have settled.

Its direct and registered-origin JSON readers still used SQL refinement.
ProcessRouting also retained an unrestricted numeric format despite its producer
and validator supporting only one. This routing is shared by file receipt
publication and must preserve its accepted execution/input coordinates.

## Decision

ProcessStore statements retain typed Either row values. A read traverses the
complete optional result inside the transaction, condemns on FromJSON failure
and returns WorkspaceBindingConflict without parser/source text. Direct and
registered-origin inspectors preserve optional absence separately. Reservation,
launch request, invocation observation, refusal and receipt persistence propagate
that result before successful mutation. A joined invalid workspace origin is
also a data refusal.

The supervisor maps those data refusals to SupervisorUnresolved. SQL/connection
failures retain SupervisorUnavailable. Factual recovery cannot choose a provider
directory or acknowledge an accepted attempt from unreadable retained facts.
The Git reservation's process-collision check propagates the process owner's
refusal instead of treating it as absence.

ProcessRoutingFormat is closed at ProcessRoutingV1, with exact numeric-one JSON
and toEncoding. Unsupported/fractional formats refuse during decoding. Process
and file producers use that value; the redundant numeric validity guard is
removed. Valid routing bytes and all execution/input/next-step coordinates remain.
A supported format supplies no launch or receipt authority.

Original claim/generation, boot/invocation identity, conditional launch transition,
absolute deadline, cgroup settlement/output evidence, receipt comparisons and
fresh action checks remain their existing owners. Row decoding does not replace
those business/physical consistency checks or infer a terminal result.

## Alternatives rejected

Treating bad intent as Nothing can grant another launch. Leaving it in the
availability path disguises retained-data failure. Returning Left without
condemnation can commit an earlier freeze or receipt. Inferring completion from
collector availability or a missing record invents physical settlement. An
unchecked numeric routing format admits unsupported metadata through decoding.

## Consequences

Positive registration/inspection precedes malformed-record and unsupported-routing
controls. Launch/factual methods refuse while the common barrier remains. A
freeze observed within the transaction rolls back on the bad read. Invalid joined
origins refuse before directory restoration. The accepted-supervisor fixture
starts once, loses acknowledgement and retains an uncertain accepted attempt.
Corrupt facts then prevent recovery/acknowledgement and another launch; no late
receipt is invented. A separate SQL-failure control remains unavailable.

These are database and existing instrumented supervisor fixtures on macOS. They
do not qualify a real Linux systemd invocation, containment profile or complete
independent service recovery. Other workspace stores and the complete scalar/
identity audit remain open. Valid workflow labels/order/effects/codecs are
unchanged; no patch is needed. First-release Haskell callers adopt the typed
inspectors and closed routing format.

## References

- [ADR-53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md)
- [ADR-54](0054-execution-attempts-own-dispatch-fences-and-generation-wakes.md)
- [ADR-90](0090-execution-and-session-json-corruption-is-a-transactional-domain-refusal.md)
- [ADR-100](0100-git-intent-decoding-preserves-unresolved-publication-and-origin.md)
- [Plan107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md)

# 0034. Review resolutions enter as verified durable envelopes

Date: 2026-08-26

Status: accepted


## Context

A practice-review resolution changes durable adjudication memory. Its `resolver` field is supplied
JSON, while the identity on an AgentRun names the reviewer agent that executes the command. Neither
value proves which human or approved workflow authorized the state transition.

Authorization cannot be repeated during workflow replay. External identity state may change or be
unavailable after the command is admitted, and raw credentials must not be written into a run job
or journal. A Kizashi acknowledgement is delivery state for an attention item, not authority to
alter the review that produced it.


## Decision

Practice-review resolutions enter only as a versioned
`AuthorizedPracticeReviewResolution` envelope. A specialized ingress boundary validates the raw
resolution, asks an injected authorizer to authenticate a human or approved artifact, requires the
verified subject to equal `resolution.resolver`, and accepts only canonical `mori://` or
`activity://` source references.

The resulting receipt contains the authority kind, verified subject, source reference,
authorization time, and a deterministic UUIDv5 bound to the validated resolution. It contains no
token or raw submission evidence. The complete envelope is recorded in the addressed RunJob;
replay revalidates its deterministic receipt without contacting the authorizer again.

The specialist Flow strictly distinguishes a raw review trigger from this envelope. Bare
resolution JSON, unknown top-level fields, altered receipts, subject mismatches, invalid sources,
and envelopes that decode ambiguously are refused before review-memory or sink effects.


## Alternatives rejected

**Trust `resolution.resolver`.** Rejected because a self-asserted field is not authentication.

**Use the AgentRun identity as resolver authority.** Rejected because it identifies the reviewer
agent, not the command submitter.

**Call the authorizer inside the workflow body.** Rejected because replay could observe a different
answer and repeat an external security operation.

**Treat Kizashi acknowledgement as approval.** Rejected because acknowledging delivery or closing
an attention item cannot adjudicate the evidence-bearing review.


## Consequences

Ingress implementations need a real authentication/approved-artifact adapter and must use the
specialized enqueue function. Once admitted, the authorization decision is immutable, auditable,
credential-free, and replay-safe. Resolution workflows support accepted, rejected, narrowed, and
superseded outcomes through the same boundary.

Generic addressed messages cannot claim resolution authority merely by adopting the resolution
payload shape. Changing receipt fields or authorization policy requires a new version rather than
silently reinterpreting journaled commands.


## References

* [`docs/plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md`](../plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md)
  — implementation and conformance evidence.
* [ADR 0031](0031-practice-review-adjudication-is-a-logical-memory-transition.md) — the durable
  state transition this boundary protects.
* [ADR 0033](0033-recorded-agent-principals-key-durable-state.md) — why the executing agent's
  recorded principal cannot stand in for a resolver.


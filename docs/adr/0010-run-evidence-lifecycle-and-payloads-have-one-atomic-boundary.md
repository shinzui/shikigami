# 0010. Run-evidence lifecycle events and queryable payloads share one atomic boundary

Date: 2026-08-19

Status: accepted


## Context

A sanctioned agent run has two different persistence needs. Its phase is a
monotonic state machine whose legal transitions must remain replayable and
checked. Its evidence payload contains Baikai `ModelCallEvidence`, immutable
review/profile bindings, child closure, observations, and every compliance
reason an operator or later verifier needs to query by run id.

Those values cannot all live in the aggregate event codec. Baikai deliberately
publishes `ModelCallEvidence` with `ToJSON` but no `FromJSON`: a consumer may
preserve the provider observation exactly, but cannot claim it can reconstruct
the typed evidence from arbitrary stored JSON. Embedding that value in a Keiro
event would make historical stream hydration depend on a decoder the upstream
contract does not provide.

Storing lifecycle and payloads independently is unsafe in the other direction.
An event append followed by a separate projection write admits a crash where
the aggregate is sealed but its calls and verdict are absent. Writing the SQL
row first admits the inverse: an operator sees a terminal verdict that the
checked aggregate never accepted.


## Decision

**The generated `RunEvidence` Keiro stream is the sole lifecycle authority, and
each accepted lifecycle event updates the operator-facing run and call rows in
the same PostgreSQL transaction. Rich evidence remains encode-only JSON in that
transactional projection.**

Concretely:

* The Keiro aggregate stores only small lifecycle events keyed by
  `RunEvidenceId` and run correlation id. `transitionEvidence` and durable
  persistence select the same generated command and transducer.
* `runCommandWithSqlEvents` appends the event and upserts
  `shikigami.run_evidence` plus `shikigami.run_evidence_calls` atomically.
* One run row stores phase, verdict, the complete reason list, immutable binding,
  observations, and call counts. The primary-key run-id query is the operator
  surface.
* Call rows are keyed by `(run_id, call_id)`. Replaying the same Shikigami call
  correlation id replaces the same row, while Baikai's separately generated
  call id and `supersedes` provenance remain inside the preserved evidence.
* Retry, fallback, continuation, and child relations have explicit relationship
  and related-call columns. `source_run_id` distinguishes a delegated child's
  call after it is folded into the parent's closure.
* A repeated command after a process loses a committed response converges only
  when the queried row already has the requested phase and the same aggregate
  identity. A different identity or phase remains a rejection.
* The operator projection is queried directly with Hasql. It is not registered
  as a Kioku read model, so there is no read-model registry identity or
  reconciliation obligation for this table pair.


## Alternatives rejected

**Put full Baikai evidence in lifecycle events.** Keiro must decode and replay
every historical event. Inventing a local decoder for an intentionally
encode-only upstream record would create a second, weaker Baikai contract and
make stream availability depend on it forever.

**Keep only SQL rows and hand-write lifecycle checks.** That duplicates the
checked Keiro state machine and bypasses its generated behavior obligations,
replay witnesses, evolution gate, and terminal-state semantics.

**Append events and update rows in separate transactions.** Idempotent upserts
repair duplicates, not a permanently missing write after the workflow has
advanced. The two facts must commit or roll back together.

**Create a Kioku read model for the operator query.** The query is a small
transactional projection updated at the command boundary, not a separately
replayable projection consumer. Registering it would add reconciliation and
shape-version machinery without improving its atomicity or recovery story.


## Consequences

The `runEvidence` event stream stays compact and replayable even if Baikai adds
new evidence fields. The SQL `evidence` JSONB column preserves those additive
fields without pretending Shikigami can decode the upstream record, and plan 52
can serve the stored JSON when it constructs and signs an attestation.

Projection schema and phase/verdict words are durable operator contracts. A
future change adds migrations rather than editing the applied migration, and a
lifecycle change still goes through the Keiro DSL evolution gate.

The in-transaction callback holds Kiroku's append serialization lock while it
writes one run row and the current call set. That cost is accepted for atomicity;
the callback performs only bounded upserts and no network IO.

Evidence call collection before a lifecycle transition remains an application
concern. Once a transition is accepted, however, its event, verdict, reasons,
bindings, observations, and every collected call become one indivisible durable
fact.


## References

* `docs/plans/51-run-evidence-aggregate-and-compliance-roll-up.md` — implementation,
  mutation matrix, restart proof, and migration evidence.
* `domain/shikigami-run-evidence.keiro` — checked lifecycle authority.
* `docs/workflow-versioning.md` — durable evolution rules for Shikigami
  workflows and step-shaped state.
* [ADR-0001](0001-declare-only-what-the-runtime-executes.md) — generated
  specifications describe executed runtime behavior.
* [ADR-0006](0006-the-attestation-payload-encoding-is-a-wire-format.md) — the
  downstream canonical attestation encoding over stored evidence.
* `mori://shinzui/baikai/packages/baikai` — encode-only call-evidence vocabulary.
* `mori://shinzui/keiro/packages/keiro` — transactional command runner and
  checked event stream.


## Implementation evidence — 2026-09-07

The catalog-aware runCommandWithCatalogProjections now replaces runCommandWithSqlEvents at this boundary. A validated generated catalog fences both the atomic lifecycle/payload write and generated read-model query. Rich evidence remains LiveOnly with Preserve targets: rebuild preview is non-destructive and cannot reconstruct missing rich payloads. SQL-fault rollback, fences, restart convergence and read-only audit are tested. Review metadata is supplied by the sanctioned caller; ordinary agent execution does not fabricate a review binding.

See [Plan 65](../plans/65-migrate-shikigami-to-the-keiro-0-15-cohort-and-the-idiomatic-v2-record-model.md) and [ADR 0038](0038-runtime-startup-and-maintenance-share-validated-owners.md).

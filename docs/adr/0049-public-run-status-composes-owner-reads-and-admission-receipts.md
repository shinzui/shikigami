# 0049. Public run status composes owner reads and admission receipts

Date: 2026-10-25

Status: accepted

## Context

HTTP acceptance precedes workflow creation. Keiro owns workflow lifecycle and
journal steps; Kioku owns session results. A completed workflow can contain a
permanent agent failure, so its completion alone does not establish success.

## Decision

Gather acceptance and disposition facts from the Shikigami ledger, workflow and
step facts through exported Keiro operations, and the recorded session through
Kioku. Keep the join and classification in core, shared by HTTP and operator JSON.
Capture the existing Kiroku store in the server's status-reader seam; these owner
APIs need the full handle, not only its Hasql pool. No request opens another store.

The closed lifecycle is accepted, running, succeeded, failed, or cancelled.
Cancellation and workflow failure take precedence. Running/suspended instances
remain running. Completed instances succeed only when the complete step records
StepProduced (). Other completed instances fail with behavior_failed. With no
instance, an explicit dead-letter receipt or drain refusal supplies terminal truth;
otherwise the accepted resource remains accepted. Store/read-model errors become
unavailable responses, never failed lifecycle values. Bound summaries to 2000
characters and failure reasons with boundedBehaviorDetail.

Reads of non-HTTP runs must verify the agent in ingest-job. Run history is an
acceptance index, ordered by accepted_at descending and run_id ascending, rather
than a page of repeated live joins. It uses the shared Relay keyset engine.

## Alternatives rejected

Private SQL over Keiro or Kioku violates ownership and couples upgrades to hidden
schemas. Treating workflow completion as success misreports permanent failures.
Queue/DLQ inspection is not a durable status model. Returning live status on every
history row multiplies the workflow/session reads by page size.

## Consequences

A worker records explicit Dead outcomes outside workflow bodies and best effort;
this changes no journal step. The HTTP contract and normal execution path are
implemented, but MasterPlan 15 remains open for automatic queue exhaustion.
Keiro 0.18 automatically dead-letters exhausted messages before the handler, so
that outcome cannot reach this hook. A real drain reproduction proves zero handler
calls, one DLQ entry, and an accepted public lifecycle. The latest released 0.21
API also lacks a terminal callback. A supported owner-level disposition callback
covering both continuous and bounded consumers is required before claiming complete
closure; a cohort change must use a released compatible version.

## References

[ExecPlan 91](../plans/91-expose-agent-run-status-and-history-over-http.md),
[ADR 0021](0021-operator-verbs-wrap-the-owning-library.md),
[ADR 0048](0048-http-run-acceptance-and-queue-send-commit-as-one-fact.md),
[dependency cohort](../dependency-cohort.md), and
[FRIC-7](../friction-log/7-automatic-pgmq-exhaustion-bypasses-the-domain-disposition-hook.md).
The owning implementation is `mori://shinzui/keiro`, project-relative
`keiro-pgmq/src/Keiro/PGMQ/Job.hs` (artifact-level URI pending).

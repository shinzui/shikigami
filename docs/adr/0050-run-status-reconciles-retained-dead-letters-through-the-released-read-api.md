# 0050. Run status reconciles retained dead letters through the released read API

Date: 2026-10-26

Status: accepted; supersedes ADR 0049's exclusion of DLQ reconciliation

## Context

Automatic retry exhaustion and codec failures can dead-letter an HTTP-accepted
job before a workflow exists. The explicit handler receipt cannot observe these
outcomes. Waiting for a new Keiro callback is unnecessary: the released PGMQ
read API supports JSON containment filters, and Keiro documents the DLQ wrapper's
original_message_id and dead_letter_reason fields.

## Decision

When a status lookup finds acceptance but no workflow, refusal or existing
terminal receipt, reconcile the matching dead-letter entry. Use the exported
PGMQ read statement with original_message_id equal to the ledger's recorded
queue_message_id, a batch limit of one and a zero-second visibility timeout.
Write the bounded reason and first-observation timestamp to the Shikigami ledger
in the same transaction. Repeat reads use that receipt. Provision both the run
queue and its DLQ before accepting requests, including server-only deployments.

The lookup leaves the DLQ entry available to operators and never leases unrelated
entries. PGMQ increments the matching DLQ row's read count; this is an intentional
reconciliation side effect. Failure rolls back that read and the receipt. A
missing or temporarily leased entry proves no outcome and leaves status accepted.
Malformed evidence and storage failures return unavailable, never a guessed failure.
Workflow and session classification otherwise remains as specified in ADR 0049.
No durable workflow body changes and no dependency upgrades are required.

Operators must retain DLQ entries until their HTTP run status has been read and
the dead_lettered receipt verified. Before archive, redrive or purge, reconcile
the corresponding accepted runs using the HTTP client or operator JSON command.
These destructive operator actions do not enforce the retention policy themselves;
direct cleanup before reconciliation can destroy the only pre-workflow evidence.
After reconciliation, cleanup cannot erase the ledger's failure fact. Redrive can
create a workflow; its authoritative lifecycle then takes precedence as before.
The receipt timestamp is when failure was first observed, not a reconstructed
transport death time. This retention condition is part of the operating contract.

The operator JSON command resolves an accepted workflow id through the ledger
when no journal exists. Its workflow and session are null, and its lifecycle uses
the same status reader. Existing text output keeps its workflow-oriented behavior.

## Alternatives rejected

A new callback would add an upstream release dependency without being necessary.
Generic readDlq leases inspected rows for 30 seconds and cannot select the original
queue id; a point-filtered read avoids leasing unrelated entries. Inferring failure
from an absent main-queue row is unsound. Private SQL over queue/framework tables
is excluded. Unreleased non-destructive inspection APIs are not a deployable dependency.

## Consequences

Polling closes automatic exhaustion without another background process. The
query returns at most one row, but its JSON filter can scan a DLQ backlog; the
result limit is not a database-work bound. Ordinary DLQ retention and maintenance
remain necessary. Concurrent operator inspection can delay reconciliation until
its lease expires. Persisted receipts survive archive, purge and process restart.

## References

[ADR 0049](0049-public-run-status-composes-owner-reads-and-admission-receipts.md),
[plan 91](../plans/91-expose-agent-run-status-and-history-over-http.md), and
[operator retention procedure](../operations/operator-cli.md).
The owning sources are `mori://shinzui/keiro`, project-relative
`keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`, and `mori://shinzui/pgmq-hs`,
project-relative `pgmq-hasql/src/Pgmq/Hasql/Statements/Message.hs`
(artifact-level URIs pending).

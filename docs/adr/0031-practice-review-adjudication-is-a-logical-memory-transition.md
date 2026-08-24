# 0031. Practice-review adjudication is a logical memory transition

Date: 2026-08-24

Status: accepted


## Context

Architecture-practice reviews outlive the workflow execution that produced them. A specialist
first records an evidence-bearing verdict, and a later authorized command accepts, rejects,
narrows, or supersedes it. Retries may occur in a different workflow instance, and two human
commands may race to resolve the same provisional verdict.

The generic Flow memory capability cannot make that transition authoritative. It derives memory
ids from workflow identity, so separate workflows do not converge on one logical record. Its
`supersedes` option records lineage on the new Kioku row but deliberately does not retire the old
row. Kioku retirement is a separate command against the old aggregate. Treating lineage as
retirement would permit both the provisional verdict and its resolution to remain active.

A resolution is also insufficient recall content by itself. It records the human outcome and
resulting applicability, but the evidence and claims that later reviews should reuse or avoid
repeating remain in the verdict.


## Decision

**Practice-review persistence uses a review-specific capability whose logical identity and
record-then-retire protocol are independent of workflow identity.**

A provisional row has a deterministic Kioku `MemoryId` derived from its `ReviewId`. A resolved row
has a deterministic `MemoryId` derived from its `ResolutionId`. Both mappings use a frozen UUIDv5
namespace and pinned test vectors. The Keiro workflow step name identifies the operation; it does
not identify the review data.

Kioku content is a versioned, validated envelope. A provisional envelope contains the verdict. A
resolved envelope contains both the same verdict and its validated resolution. Stable tags repeat
lookup metadata, but decoding and revalidation of the envelope remain authoritative. Active recall
uses an exact shared practice scope and separates accepted or narrowed guidance, rejected
do-not-repeat evidence, pending verdicts, superseded outcomes, and malformed-row diagnostics.

Adjudication records the deterministic resolved candidate first and then retires the provisional
row with Kioku's separate supersession command. A newer review uses the same protocol against the
prior active conclusion. If another candidate already retired the prior row, the loser rereads the
recorded winner, retires itself under that winner, and returns a typed conflict naming the winner.
No content, tags, or rows are deleted or overwritten.

The capability owns four static operation labels behind the permanent patch id
`shikigami-practice-review-memory-v1`. Those labels are added to the production AgentRun workflow
only when the registered specialist Flow first calls the capability. The module and isolated test
workflow may exist before that integration, but the production effect row, interpreter, patch
branch, and checked declarations must land together.


## Alternatives rejected

**Use the generic Flow `rememberWith` operation.** Its workflow-derived id is replay-safe only
inside one workflow identity, and its `supersedes` field creates lineage without retiring the old
aggregate.

**Use the provisional `ReviewId` for every state.** Kioku memories are immutable aggregates. A
resolution under the same id would be changed semantic content and correctly conflict rather than
overwrite the verdict.

**Store only `PracticeReviewResolution` in the resolved row.** Later recall would know the human
outcome but lose the evidence and claim graph that gives guidance or rejection its meaning.

**Retire the provisional before recording the resolution.** A crash between the commands would
leave no active conclusion. Recording the deterministic candidate first makes the incomplete state
recoverable by replay.

**Leave a losing race candidate active after returning a conflict.** Active recall could then
observe two contradictory rules. Retiring the loser preserves audit history without making it
guidance.

**Declare the production labels before a Flow uses them.** This would claim runtime behavior that
cannot execute and violate ADR 0001. The first registered caller owns the workflow-versioned
integration.


## Consequences

Retries from the same or different workflow instance converge on the same logical rows. A crash
after candidate creation can replay the retirement, and a competing command converges on one
active winner. The immutable supersession chain remains a complete operator audit trail.

Recall never treats rejected or malformed content as positive guidance. Applicability is evaluated
from validated domain values; tags are indexing aids rather than an alternate contract. The first
release adds no Shikigami table, migration, or direct SQL.

The transition spans two Kioku aggregate commands rather than one transaction. Correctness depends
on deterministic candidate ids, idempotent commands, loser cleanup, and tests that exercise the
race against PostgreSQL. Callers must already have authenticated and authorized a resolution;
this capability owns persistence, not the process boundary.

The future specialist Flow must preserve the patch's legacy branch and declare exactly the four
static labels when it installs this capability. Until then, production workflows cannot call it.


## References

* [`docs/plans/45-persist-and-adjudicate-architecture-practice-reviews.md`](../plans/45-persist-and-adjudicate-architecture-practice-reviews.md)
  — implementation plan and acceptance proof.
* [`docs/plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md`](../plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md)
  — owner of production Flow and AgentRun integration.
* [ADR 0001](0001-declare-only-what-the-runtime-executes.md) — declarations must describe an
  executable runtime path.
* [ADR 0012](0012-a-declared-workflow-body-only-grows-behind-a-patch.md) — production workflow body
  additions require a checked patch branch.
* [ADR 0013](0013-flow-bodies-reach-the-world-only-through-capabilities.md) — registered Flows reach
  persistence only through narrow capabilities.
* [ADR 0015](0015-a-kioku-write-answers-on-two-layers-and-a-journaled-step-keeps-its-bytes.md) — Kioku
  store failures and domain refusals have different dispositions.
* `mori://shinzui/kioku/packages/kioku-core` — released record, supersession, scoped-read, and chain
  APIs used by the transition.

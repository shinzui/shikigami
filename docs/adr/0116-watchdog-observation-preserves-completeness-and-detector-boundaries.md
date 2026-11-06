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

## Bounded metadata pages

Owner-local Observation modules project permitted JSON fields before decoding;
watchdog composition does not load owner snapshots, instructions or results.
The execution owner extracts only an objective-scope coordinate from its retained
snapshot and never selects the snapshot body. Each corrupt row keeps its key and
a typed refusal. Owner relationships carry completeness, and truncation produces
unknown metadata and an unclean pass rather than evidence of inactivity.

Coverage retains its scope, exhausted populations and rotating next kind. A
one-subject page visits every kind; exhausted kinds remain exhausted until the
pass ends. PassIncomplete distinguishes a finished traversal with refusals from
accepted complete coverage. Scope changes start a new traversal. Session discovery
also follows retained assignment-reference bindings before the first checkpoint
publishes a session id into the objective graph.

The metadata page is one read-only repeatable-read transaction with statement and
lock timeouts. A PostgreSQL timeout aborts the page; it returns no advanced cursor
and the next transaction can recover. Root and process metadata are read in that same snapshot. Public Keiro waiting
facts have separate bounded reads and observation instants.

## Exact waiting facts and child progress

Approval observations require an immutable approval-owner review-to-parent link,
matching public parent and child headers, and an exact review-filtered pending
timer with the fixed structured approval payload. Unassociated timers cannot
establish a wait. Suspended parents without a known association remain unknown;
the native coordinator checkpoint listener is explicitly known to wait for a
checkpoint. Production association publication belongs to guarded workflow
integration in plan 112, while plan 109 introduces the projection and migration.
No generic timer or child-result scan is permitted.

The metadata transaction uses at most fifteen statements. Public reads have a
separate allowance of 32 parent headers, 32 child headers and 32 exact timer
lookups, each bounded to two seconds. Page bytes remain capped after supplements.
Expired permission, approval or process deadlines do not yield live waiting facts;
their references remain evidence. Root cancellation and exhaustion never exclude
subjects or spend their root's resources.

A worker message does not retain its execution id until recording a result.
Observation links live work through the retained child workflow id and execution
snapshot run coordinate. Session activity marks include child execution activity.
The execution owner separately reports bounded historical sampling and complete
current activity; long settled histories alone do not imply incomplete activity.
Live/uncertain operation and attempt overflow remains unknown.

## Deterministic classifier boundary

The classifier uses only the journaled observation time and frozen prior mark.
Terminal owner facts precede incomplete relationships; incomplete evidence yields
ObservationUnknown and cannot close an episode. First/changed marks precede waits,
persistent uncertainty, the independent coordinator rule and ordinary stuck work.
Observed retains the exact prior used, enabling the ledger to reject stale inputs.
Material summaries exclude sweep identity, evidence revisions and elapsed time,
while retaining lapsed deadline kinds, owner epoch, root controls, uncertainty and
the optional drift category.

## Input-bound drift assessment

The implemented program has a fixed catalog maximum of sixteen subjects and a
lower configured bound retained in its typed input. The untrusted proposal names
canonical subject keys and evidence indexes within each subject's supplied
references. The pure validator requires exact subject cardinality, resolves those
indexes, checks category/rationale bounds and alone mints an opaque assessment.
Owner identifiers need no orphan model-schema instances. Goal and criteria prose
remain untrusted input. The new Drift slot is explicitly root-accounted; no
registered production Flow invokes it until plan 112's guarded integration.

## Optional drift cadence and retained policy

Drift cadence settings are an optional pair. Omission disables drift; a positive
interval and catalog-bounded subject budget are admitted together and retained
in the grant snapshot. Historical snapshots missing the optional budget decode
as disabled. A mark change never bypasses the minimum assessment interval.
The selector receives only liveness-eligible subjects and chooses one oldest due
objective with a bounded deterministic batch. Failed/incomplete observations
produce no assessment.

The assessment seal retains its full input commitment. Its downstream adapter
checks the same goal, revision and reference input before deriving cadence facts.
Cadence receipts return the first accepted write and refuse stale timestamps or
changed bindings. Check persistence and drift episode persistence must be one
EP-4 transaction. The ordinary resource owner retains unmeasured token usage;
a lost result append cannot refund the earlier attempt.

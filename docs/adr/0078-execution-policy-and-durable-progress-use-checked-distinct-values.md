# 0078. Execution policy and durable progress use checked distinct values

Date: 2026-10-30

Status: accepted

## Context

Harness policy ceilings and execution progress used interchangeable Int/Integer
fields. Most range checks lived in record validators, so hand-constructed values
could bypass them. Pending receipts already had a decoder bound of one million,
but recovery incremented the primitive after admission and could publish a value
that its reader rejected.

These are operational domain values. Raw HarnessOverrides numbers belong to the
explicit Dhall/JSON configuration boundary; the resolved HarnessPolicy and durable
ExecutionState are domain records, despite having persisted JSON representations.

## Decision

Use seven private checked policy types: ModelTurnLimit, RepairLimit,
ContextByteLimit, RecentMessageMinimum, PermissionLifetime, RecoveryAttemptLimit
and SummaryTokenLimit. Preserve their existing individual bounds and numeric JSON.
Refine overrides once; zero summary tokens still explicitly disables summaries.
Keep cross-field/format/tool-list checks at the owning policy validator. Native
model options, byte comparisons and clocks unwrap only at their actual adapters.

Use distinct private ModelTurnCount, RepairCount and PendingReceiptCount values
for durable progress. Their bounds are respectively 0..10000, 0..10 and
0..1000000. Count/ceiling comparisons name the applicable units. Constructors and
JSON parsers reject invalid values. No Num, Integral, IsString or Generic instance
exposes an unchecked construction or arithmetic path.

Prepare checked increments and decrements inside the pre-inline guard before
publishing application state, native events, resource accounting or queue work.
A full pending-receipt count refuses recovery as ExecutionPolicyRefused. Preserve
ADR-53's late rollback exceptions for failures after tentative writes. Generated
command integers remain explicit boundary representations; no DSL declarations,
step labels, step order, fold fingerprints or binding conversions change.

## Alternatives rejected

Leaving validated record fields primitive permits accidental substitution and
unchecked hand construction. A shared unscoped numeric wrapper does not separate
turns, repairs, bytes and durations. Clamping full receipt capacity conceals a
retained obligation; publishing the increment creates unreadable state.

## Consequences

Valid full-record JSON and encoded numeric bytes remain stable, including omitted
zero pending receipts and optional summaries. Invalid retained progress now fails
at decode. Compiler clients prove policy/count separation and constructor
abstraction after positive controls. Existing model, repair, summary, recovery,
late-receipt and workspace cases exercise their consumers.

A synthetic boundary fixture seeds only the application's pending-receipt field
after a real accepted attempt becomes uncertain. Recovery must refuse without
changing execution metadata, either attempt, accounting, payloads, queue state or
the native stream version. It does not claim a million real outstanding receipts
or edit framework journals. The stream observation uses public getStream and
StreamInfo.version rather than querying framework-owned tables.

This decision covers these policy/progress values. The complete scalar/identity
census and final packaged/runtime qualification remain separate acceptance gates.

## References

[ADR-53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md),
[ADR-77](0077-attempt-counters-and-call-ceilings-retain-their-scopes.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
and [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).

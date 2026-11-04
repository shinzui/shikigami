# Plan 85 acceptance

Qualified 2026-11-04 UTC on candidate
`73ce5be0af8bc81f6daae68f2064a743743dc643` (controller implementation
`9c3cc615abbd036fb3404463e09fc23f54829706`), against baseline
`1a7d5ebd2b4a7eca058fe61726807b38076fe6e8`.

[Plan 85](../../plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md)
is complete. Qualification used macOS arm64, GHC 9.12.4, disposable PostgreSQL
databases, the production objective/session/execution owners and key-free
deterministic model providers. No live vendor call or repository delivery trial
is claimed.

## Observable acceptance

| Boundary | Evidence |
| --- | --- |
| Whole-proposal authority | Fifteen `AdaptiveProposalSpec` cases cover bounded small/large organizations, whole graph refusal, withdrawn dependencies, role-scoped model permissions, hierarchy cycles, root/cutoff binding and exact completion constraints. |
| Real checkpoint owner | Eleven PostgreSQL `AdaptiveDeliverySpec` cases cover atomic graph/manifests/receipts, conflicts, protected replay before live policy, corruption, revocation, exhausted roots, unprojected native sessions, bounded inspection and generation-owned publication/cutoff wakes. |
| Native adaptive cycle | Five `AdaptiveWorkflowSpec` cases run the actual registered Flow, accepted typed program, native worker children and owner. They cover one worker plus finding-driven same-session correction; lost validation acknowledgement with one retained worker and actual specialist-model escalation; a local coordinator integrating two descendants under an expanded live catalog; pure direct work without a worker session; and same-session transfer through retained fence/ownership receipts. |
| Actual-call accounting | Five `DecisionExecutionSpec` cases verify internal typed nodes spend individual root attempts, committed results replay, root exhaustion stops further dispatch, retained timeout/call limits narrow later runtimes, and cancellation retains unknown spending while releasing confirmed local occupancy. Native adaptive scenarios assert exact decision/local/worker model-attempt totals. |
| Useful overlap | The actual typed Flow fixture holds a decision provider and worker provider behind independent barriers. It records their start/end intervals and asserts positive overlap before either finishes. The parent remains suspended while an unrelated workflow advances and a due observation timer fires. |
| Capacity and fairness | Nine `ExecutionCapacitySpec` cases cover shared limits, positive configuration/headroom, draining after a reduction, exact claim ownership, unrelated-root admission within one round, two OS processes competing for global capacity, and two OS processes competing for one root slot while global capacity is two. The root race retains exactly one actual attempt and settles exactly one spend. |
| Completion | Native scenarios retain the exact fixture artifact and owner-verified combined user-journey check, propose matching revisions, then use the authorized owner's acceptance. Worker success and artifact-free prose remain observations. Active/unknown root work, pending execution receipts and unsettled native mailboxes block acceptance. |
| Compatibility | Three `WorkflowInputSpec` cases cover atomic first-input/patch admission, concurrent producers, historical bare input, existing empty snapshots and terminal refusal. Broad suites also pass old agent/conversation replay and synchronous decision recovery. The native gate accepts only new patch guards and the new family. |

The session/workspace source tests refuse reserved, wrong-root, wrong-epoch and
ambiguous workspace discovery. The adaptive handoff uses real retained owner and
session state with an explicit deterministic fence contract fixture. Physical
filesystem/process containment and real repository artifacts are independently
owned qualifications; this evidence does not replace them. Plan 84/96 provider
qualification remains applicable, and plan 86 owns their integrated adaptive
repository consumer and live trial. Recurrence remains plan 87's scope.

## Reproduction and results

Run from the repository root. PostgreSQL suites own disposable databases.
Run the broad PostgreSQL and worker commands sequentially with the documented
thread bound (FRIC-51).

```bash
nix develop --no-write-lock-file -c cabal build all
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-server-test --test-show-details=direct
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-show-details=direct
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c cabal test shikigami-workers-test --test-show-details=direct
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c cabal test shikigami-agent-test --test-show-details=direct
nix develop --no-write-lock-file -c just migration-schema-isolation
nix develop --no-write-lock-file -c just haskell-conventions
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c just keiro-gate 1a7d5ebd2b4a7eca058fe61726807b38076fe6e8
```

All checks pass. Package results are 706 core unit, 572 core PostgreSQL, 291
worker, 105 server and 37 agent cases (1,711 total). The agent suite ran alongside
core unit tests in the recorded qualification. Haskell conventions also pass
their thirteen checker controls. Generated conformance passes 183 controls.

[Workflow check](workflow-check.json) records twelve explicit Language 6 members,
zero errors and zero warnings. Regeneration leaves the committed core tree
unchanged. [Native diff](workflow-diff.json) records exactly three additive
findings: `WorkflowEvolutionGuardAdded` for
`shikigami-adaptive-delivery-v1`, `WorkflowEvolutionGuardAdded` for
`shikigami-worker-objective-children-v1`, and `DeclarationAdded` for
`AdaptiveDelivery`. `breaking` and `adoptionBaseline` are both false.
The [aggregate replay-impact report](workflow-replay-impact.json) is
`replay-neutral`. No first-release reset exception is used.

ADRs [0108](../../adr/0108-adaptive-decisions-commit-with-authoritative-checkpoints.md),
[0109](../../adr/0109-runtime-capacity-admission-shares-accepted-attempt-fences.md),
[0110](../../adr/0110-accepted-typed-decisions-account-for-every-transport-call.md)
and [0111](../../adr/0111-adaptive-delivery-carries-native-admission-and-reference-only-seeds.md)
retain the durable contracts. FRIC-51 is accepted with bounded sequential test
concurrency; FRIC-52 and FRIC-53 are resolved by the native association and atomic
first-input fixes. Runtime execution/advance defaults remain one, and internal
typed nodes serialize within their wrapper's physical permit.

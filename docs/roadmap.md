# Shikigami roadmap

Refreshed 2026-11-06 UTC against implementation checkpoint `6d3a7076`, Cabal manifests,
MasterPlan registries, child Progress/Outcomes, request metadata and retained
qualification evidence, including plan 86 native recovery, watchdog/proposal acceptance
and plan 124 Shikumi adapter ownership. Recorded acceptance
applies to its named candidate and environment; plan 84 retains separate host
and native operator-recovery results.
See the [HTML roadmap](artifacts/roadmap.html),
[engineer onboarding map](artifacts/shikigami-engineer-onboarding.html) and
[adaptive delivery guide](artifacts/adaptive-autonomous-objectives.html).

## Watchdog delivery (2026-11-06)

The independent active-work watchdog is implemented under
[MasterPlan 19](masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md):
[109](plans/109-observe-active-work-through-bounded-lock-free-reads-under-a-watchdog-grant.md) owns bounded observation,
[110](plans/110-classify-stuck-work-deterministically-and-coalesce-findings-into-episodes.md) owns classification and episodes,
[111](plans/111-assess-drift-with-a-registered-typed-decision-over-bounded-evidence.md) owns typed Drift,
[112](plans/112-run-the-watchdog-as-a-scheduled-flow-agent-with-its-own-principal-allowance-and-sinks.md) owns scheduled advisory execution,
and [113](plans/113-make-the-watchdog-observable-and-qualify-ir-19.md) owns inspection, telemetry and
[eight-case qualification](evidence/plan-113/acceptance.md) for
[IR-19](improvement-requests/supervise-active-work-with-an-independent-watchdog-agent.md).
Native and live-model watchdog trials remain additional evidence.

## Unrequested-work admission and machine-daemon planning

[MasterPlan 20](masterplans/20-propose-unrequested-work-from-observed-activity-under-governed-standing-policies.md)
and [IR-21](improvement-requests/propose-unrequested-work-from-observed-activity.md)
are complete through plans 114–118. Observer allowances, pure pre-filtering, typed
assessment and durable human acceptance create linked objectives. Only an explicit
revocable standing policy can fund and dispatch a coordinator automatically.
[Nine deterministic acceptance cases](evidence/plan-118/acceptance.md) pass; live
channel/model behavior and the optional native admitted-objective trial remain
separate evidence. See [user guidance](user/unrequested-work.md) and
[operator setup](operations/unrequested-work.md).

[MasterPlan 21](masterplans/21-execute-governed-work-through-enrolled-machine-daemons.md)
plans machine enrollment, local command policy, retained receipts and partition
fencing. All five children (119–123) are not started; IR-20 remains proposed.
Watchdog schedules and proposal admission do not implement recurring objective
mandates (87) or multi-machine execution.

## Current delivery boundary

Implemented, with plan 74's reopened failure-path qualification still outstanding:
typed Flow decisions and actual-attempt evidence (plans 73–76),
authenticated HTTP agent discovery and idempotent run acceptance/status/history
(plans 88–91), root resource accounting (81), immutable assignment model selection
(82) and protected durable Skill operation/transcript recovery (83). Continuing
workers retain ordered assignments, results, events and governed command mechanics
under completed plan 84, including follow-up compaction/replay and native
operator handoff recovery. Plan 96 is complete: configured durable
workers have governed repository allocation, edit/process/Git tools, independent
process fencing, integration and successor recovery. Its full 25-case native
Linux matrix includes real objective ownership, lost acknowledgements, supervisor
and controller restart, successor writes and former-owner refusal.

Authoritative objectives and checkpoint/ownership/scope providers are complete
(MasterPlan 17), as is optional provider-neutral external tracker synchronization
with the Rei adapter (MasterPlan 18). Plan 86 passes the full native repository,
recovery and refusal matrix; full autonomous coding delivery still needs a guarded live
adapter and its actual-model trial under production
authorization and approved live limits. Plan 85 completes validated
native adaptive coordination, actual typed-call accounting, shared capacity and
bounded inspection; its finite fixtures pass exact combined acceptance. Plan 84
completes continuing-worker consumer acceptance and IR-15.
Recurring supervision (87) is a separate optional phase. Provider qualification
and deterministic consumer evidence do not close actual-model acceptance.

The configured cohort selects Keiro 0.22, Baikai 0.10, Shikumi 0.5.1 and Kioku
0.12.0.2. MasterPlan 16's six-child Keiro upgrade is complete for its bounded
macOS profile; standalone plan 108's remaining domain audit is also complete.
Plan 80 has integrated structured TypeSafe answers, durable replay and public
complete/stream parity, with 15 real-adapter checks and three PostgreSQL cases.
Its broader wire/error matrix, Linux CLI qualification, deadline/output/confinement
gates and fresh immutable packaging remain open. The current export contains
382 runtime packages and six immutable repositories after plan 124 removes
Handan and its exclusive dependencies; Nix role dry runs do not
qualify installed binaries. See the [streaming checkpoint](evidence/baikai-execution/streaming-consumer-checkpoint.json),
[Keiro qualification](evidence/keiro-0.22/macos-final-qualification.json) and
[domain inventory](architecture/shikigami-domain-inventory.md). The
[dependency cohort](dependency-cohort.md) retains historical adoption evidence.

## Portfolio snapshot

This audit covers 21 coordinated MasterPlans (1–21) and 124 ExecPlan files.
Fourteen MasterPlans are complete: 1–5, 8, 11–12 and 15–20.
Seven coordination documents have remaining work, including the not-started
machine-daemon lane below.
Plan 97 is a superseded design, replaced by MasterPlan 17 and plans 98–102;
it is not a second objective implementation lane. Counts describe artifacts,
not feature readiness or effort percentages.

| MasterPlan | Current state | Remaining work |
| --- | --- | --- |
| [6](masterplans/6-operations-and-observability-run-shikigami-as-a-real-service.md) | 3 of 4 children complete; plan 31 in progress | Full service stack and drain proof |
| [7](masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md) | 3 of 5 complete | Plan 34 memory lifecycle and plan 12 MCP-specific integration |
| [9](masterplans/9-architecture-practice-review-flow.md) | 3 of 8 registered children complete; plans 46/62 in progress | Repairs 60/61, profile provisioning/guidance in 62, full conformance in 63, then live plan-46 acceptance |
| [10](masterplans/10-sanctioned-execution-attestation-for-agent-runs.md) | 3 of 4 complete | Plan 52 shared signed envelope, read API/verifier and live proof |
| [13](masterplans/13-compose-shikumi-decisions-in-durable-flows.md) | 3 of 4 complete; plan 74 M3 reopened | Reject unterminated successful streams and complete cancellation, evidence-write, retry and refusal qualification |
| [14](masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) | 5 of 7 complete; plan 86 native milestones pass | Guarded live adapter plus actual-model trial; recurrence (87 not started) |
| [21](masterplans/21-execute-governed-work-through-enrolled-machine-daemons.md) | 0 of 5 complete; all not started | Enrollment, local policy, machine-hosted operations, relay/partition fencing and qualification |

Recent completed work:

| Owner | Accepted delivery and limits |
| --- | --- |
| [MasterPlan 16](masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md) | Six children (92–95, 106–107): Keiro 0.22, fresh schema, guarded commands, native recovery, administrative CLI/HTTP/live inspection and Haskell/service practices; bounded macOS acceptance |
| [MasterPlan 17](masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md) | Five children (98–102): authoritative objectives, trusted providers, API/CLI, durable capabilities and no-Rei serving continuity; IR-13 complete |
| [MasterPlan 18](masterplans/18-integrate-durable-objectives-with-external-trackers-through-provider-neutral-contracts-and-rei.md) | Three children (103–105): provider-neutral tracker bindings, real Rei adapter and served synchronization/restart qualification; uncertain delivery requires exact attestation before settlement |
| [MasterPlan 19](masterplans/19-supervise-active-work-with-an-independent-watchdog-agent.md) | All five children (109–113) complete; scheduled advisory observation, scoped inspection, independent telemetry and eight-case deterministic IR-19 qualification |
| [MasterPlan 20](masterplans/20-propose-unrequested-work-from-observed-activity-under-governed-standing-policies.md) | All five children (114–118) complete; bounded observation, human acceptance, revocable standing-policy admission and nine-case deterministic IR-21 qualification |
| [Plan 124](plans/124-remove-handan-by-owning-the-shikumi-execution-adapter-in-shikigami.md) | Complete/streaming Shikumi adapter owned locally; Handan removed; committed-result replay and native immutable-role regression pass; plan 80 qualification remains separate |
| [Plan 84](plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) | Continuing-worker consumer acceptance complete; 1,703 package cases, 177 conformance controls and nine native ownership/restart cases including actual operator recovery; IR-15 complete; plans 85/86 remain separate |
| [Plan 85](plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md) | Adaptive coordinator, actual typed-call accounting, shared capacity and inspection complete; 1,711 package cases and 183 conformance controls; additive-only gate; [evidence](evidence/plan-85/acceptance.md); native repository/recovery matrix passes in plan 86; actual-model trial remains |
| [Plan 96](plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md) | All six milestones and 25 native Linux cases pass; IR-11 complete; plan 84 separately closes IR-15; integrated adaptive acceptance remains in plan 86 |
| [Plan 108](plans/108-complete-the-remaining-domain-scalar-identity-and-decoder-audit.md) | All milestones complete; 4,253 census keys resolved with zero pending dispositions or violations and 531 compiler controls; no new Linux runtime claim |

## Delivery order and gates

The 2026-11-06 Mina reconciliation closes two tracking discrepancies: bootstrap
plan 1 now exposes its three historically accepted milestones directly under
Progress, and provider plan 13 records the live-proof transfer already accepted
by MasterPlan 2 on 2026-09-21. That proof remains open in plan 52. MasterPlan 13
is genuinely unfinished because its child 74 was reopened on 2026-10-29; the
former all-complete summary was stale. Mina's percentages count checkboxes,
including prerequisite/planning work, and omit repair plans outside a registry;
they do not measure remaining effort.

For the next bounded closeout, finish plan 74 M3 and its core/PostgreSQL consumer
regressions. It needs no live credential or upstream release. Successful streams
are covered, but the current runner does not refuse normal completion with a
begun stream that never persisted a terminal. Keep the completed persistence and
Flow work; qualify that missing runner boundary before closing MasterPlan 13.

Before enabling production practice review, plans 60/61 must fix attention reservation
and resolver entitlement. Plan 62's M1 closeout/inventory reconciliation is delivered;
its actual profile provisioning and operator examples remain, followed by plan 63's full
conformance matrix. All four existing repair children are now visible in MasterPlan 9
before plan 46 closes. Production evidence acquisition still depends on
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`.

Then finish plan 31's composed service smoke, NixOS module and graceful-drain
acceptance for MasterPlan 6; immutable role builds alone do not close it.
MasterPlan 7 needs actual lifecycle/MCP implementation: start with plan 34 M0
and plan 12 M1's local fixtures, then resolve their exact upstream contracts and
qualify their full matrices. Those planning/foundation checkboxes are not
delivered lifecycle or MCP behavior.

MasterPlan 10 requires the shared contract at
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6`, then plan 52's
signing, rotation, bounded read API, offline verifier and conformance matrix.
The owning IR-5 and IR-6 requests were reread and remain proposed. Plan 52 now
credits implemented canonical bytes/digests, adopted provider evidence and current
workspace/API owners; its old Baikai/Kioku version blocker is removed. Baikai
IR-3 is completed. Shared golden/schema agreement and actual signed proof remain. Its live positive case also owns plan 13's
transferred provider proof.

For adaptive delivery, plans 84 and 85 are complete against the delivered provider
contracts; plan 86 is in progress and plan 87 is not started but eligible. The current
driver always blocks live mode, so configuration alone cannot close plan 86: implement
and qualify the guarded API/production-authority adapter before the approved actual-model
trial. Plan 87 now lists explicit recurring mandate, wake/watermark and stop/recovery
outcomes; delivered watchdog/proposal scheduling does not supply them. Plan 96 owns actual
repository process fencing;
MasterPlan 17 owns authoritative objective/assignment state, trusted associations
and checkpoint/ownership/scope providers. Plan 84's
[consumer acceptance matrix](evidence/plan-84/acceptance.md) combines those real
providers with governed Flow/Skill/operator mechanics, continuing compaction and
replay, and native administrative recovery. IR-15 is complete. Plan 85 owns
validated adaptive coordination and shared capacity; plan 86 passes
[native repository/recovery qualification](evidence/adaptive-delivery/native-qualification.md)
and retains its actual-model trial; plan 87 adds explicitly admitted
recurring mandates. The objective API/CLI and native/durable capabilities remain
complete under plans 98–102; provider and consumer evidence retain their own
named candidates and environments.

MasterPlan 16 completed the Keiro 0.22 first-release upgrade under ADR 0027 and
[ADR 0106](adr/0106-the-keiro-upgrade-closes-on-a-bounded-macos-profile.md).
Its revised acceptance uses fresh provisioning and same-build recovery rather
than a populated legacy upgrade or cross-build replay. Preserve late-write
rollback protections and protected live-only payloads. Administrative inspection
is delivered by plan 106; plan 108 closes the separately deferred domain census.
The macOS upgrade acceptance does not claim Linux runtime or a cold Nix build.

Plan 31 has delivered immutable role builds and installed assets, but its full
process-compose/NixOS/graceful-drain scope remains open. Plan 79's installed
reporter qualification is partial; the last recorded live workload is blocked
on integration services. Plan 80 delivers HTTP providers and foreground launches;
background CLI response promotion remains gated on deadlines, bounded retained
output and descendant confinement. The released cancellation fix is adopted and
both vendor adapters pass inherited-group cancellation on Darwin. Structured
judgments and streaming pass deterministic public HTTP and durable replay tests;
the remaining plan 80 matrix and fresh immutable-role qualification stay open.
These historical live-service observations have not been re-probed by this audit.

Plan 52 still depends on the shared envelope contract at
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` and live-provider proof.
Memory plan 34 and MCP plan 12 now define staged contract/fixture gates; follow
their current plans rather than the older recommendation to decompose them again.
Read-only Kubernetes observation (77) and external jobs (78) are separate planned
surfaces, not prerequisites for every autonomous workload.

## Open implementation and qualification work

| Plan | Current state and remaining gate |
| --- | --- |
| [8](plans/8-conversational-agent-loop-bound-to-danwa.md) | Implementation landed; legacy live Danwa validation remains |
| [12](plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md) | Not started; staged MCP provider/catalog and external contract gates |
| [31](plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md) | In progress; packaging slice landed, full stack and drain proof remain |
| [34](plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md) | Not started; staged memory contracts/fixtures and bounded recall/retention gates |
| [46](plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md) | In progress; plans 60–63 gate truthful closeout |
| [48](plans/48-add-a-portable-one-off-repository-agent-harness.md) | Partial portable harness; mutable/command slices remain; separate from durable plan 96 |
| [52](plans/52-signed-attestation-read-api-and-uc-8-conformance.md) | Not started; shared signed envelope and live-provider proof |
| [60](plans/60-harden-practice-review-attention-reservation-and-specialist-failure-boundaries.md) | Not started; atomic attention/outbox and specialist failure boundaries |
| [61](plans/61-enforce-practice-review-resolver-entitlement-and-harden-the-authorization-envelope.md) | Not started; resolver entitlement and credential handling |
| [62](plans/62-make-the-practice-review-closeout-and-operator-documentation-true.md) | M1 documentation reconciliation accepted; profile provisioning and operator guidance remain |
| [63](plans/63-extend-practice-review-conformance-to-the-claimed-end-to-end-matrix.md) | Not started; complete claimed conformance matrix |
| [77](plans/77-add-a-read-only-k8s-observe-capability-provider-for-durable-agents.md) | Not started; bounded read-only Kubernetes provider |
| [78](plans/78-run-external-operations-from-durable-flows-through-idempotent-shiki-jobs.md) | Not started; external executor, authorization and crash contracts |
| [79](plans/79-qualify-local-agent-execution-and-prioritize-production-readiness.md) | Partial packaging qualification; live workload/fault/human-wait gates remain |
| [80](plans/80-configure-model-providers-and-agent-launches-through-baikai.md) | In progress; HTTP/foreground, structured judgments and streaming delivered at recorded checkpoints; remaining wire/error matrix, Linux CLI, deadline/output/confinement and fresh immutable-role qualification |
| [86](plans/86-qualify-integrated-adaptive-autonomous-delivery.md) | In progress; native repository/recovery/refusal milestones pass, actual-model trial remains |
| [87](plans/87-supervise-recurring-objectives-from-current-durable-checkpoints.md) | Not started; recurring mandate admission and current-checkpoint supervision |
| [119](plans/119-enroll-machines-and-hold-outbound-daemon-sessions-with-revocable-identities.md) | Not started; machine enrollment, revocable identities and outbound daemon sessions |
| [120](plans/120-enforce-local-machine-policy-over-typed-bound-commands-with-a-retained-ledger.md) | Not started; local policy over typed bound commands and retained ledgers |
| [121](plans/121-host-workspace-operations-on-the-machine-with-local-deadlines-and-retained-receipts.md) | Not started; machine-hosted workspace operations, local deadlines and receipts |
| [122](plans/122-place-assignments-on-machines-and-relay-durable-commands-with-absence-and-partition-fencing.md) | Not started; placement, relay, absence/partition fencing and recovery |
| [123](plans/123-make-machines-observable-to-operators-and-qualify-ir-20-across-severable-machines.md) | Not started; machine inspection and severable-machine qualification |

## Improvement-request lifecycle and implementation coverage

Lifecycle below mirrors request metadata checked on 2026-11-06: eleven completed,
five in progress, one accepted and four proposed. Some request prose still
predates provider acceptance; current child outcomes and parent registries supply
the implementation boundary.
Completed implementation slices do not close requests with remaining acceptance
gates; the owning plans and parent completion matrix define those gates.

| Request | Recorded lifecycle | Current coverage |
| --- | --- | --- |
| [IR-1](improvement-requests/consult-meibo-agent-lifecycle.md) | completed | Plan 23 |
| [IR-2](improvement-requests/authorized-cross-cluster-diagnostic-tools.md) | proposed | Cross-cluster scope remains proposed; plan 77 is narrower |
| [IR-3](improvement-requests/add-declarative-router-agents.md) | completed | MasterPlan 8 |
| [IR-4](improvement-requests/add-architecture-practice-review-flow.md) | in-progress | Plans 43–45 complete; plan 46 and plans 60–63 remain |
| [IR-5](improvement-requests/governed-agent-evolution.md) | proposed | No accepted implementation lane |
| [IR-6](improvement-requests/support-a2a-cross-runtime-agent-interoperability.md) | proposed | No accepted implementation lane |
| [IR-7](improvement-requests/attest-sanctioned-agent-execution.md) | in-progress | Plans 49–51 complete; plan 52 remains |
| [IR-8](improvement-requests/expose-addressed-agent-runs-over-http.md) | completed | MasterPlan 15 complete |
| [IR-9](improvement-requests/key-agent-continuity-by-meibo-principal.md) | completed | Plan 54 |
| [IR-10](improvement-requests/expose-agent-run-status-over-http.md) | completed | MasterPlan 15 complete |
| [IR-11](improvement-requests/provide-governed-mutable-repository-workspaces.md) | completed | Plan 96 complete: full 25-case native matrix includes real objective ownership, successor writes, old-owner refusal and restart recovery |
| [IR-12](improvement-requests/compose-shikumi-decisions-in-durable-flows.md) | completed | MasterPlan 13 complete |
| [IR-13](improvement-requests/support-optional-major-task-tracking.md) | completed | Plans 98–102 complete: no-Rei restart/continuity and explicit integrated acceptance qualified; workspace qualification and adaptive/recurring acceptance remain separate |
| [IR-14](improvement-requests/record-durable-model-tool-turns-and-compose-harness-policies.md) | in-progress | Plans 83/84 complete; integrated UC-1 recheck remains in plan 86 |
| [IR-15](improvement-requests/support-continuing-worker-sessions.md) | completed | Plan 84 complete: continuing follow-ups, compaction/replay, governed controls and real native ownership/restart acceptance |
| [IR-16](improvement-requests/support-adaptive-durable-orchestration.md) | in-progress | Plan 85 complete; plan 86 native repository/recovery milestones pass, actual-model acceptance remains |
| [IR-17](improvement-requests/select-governed-models-for-agent-runs.md) | in-progress | Plans 82–85 qualify selection, continuation, escalation and decision permissions; integrated delivery remains in plan 86 |
| [IR-18](improvement-requests/support-recurring-objective-supervision.md) | accepted | Plan 87 not started |
| [IR-19](improvement-requests/supervise-active-work-with-an-independent-watchdog-agent.md) | completed | MasterPlan 19 / plans 109–113 complete; deterministic scheduled acceptance, scoped inspection and independent telemetry |
| [IR-20](improvement-requests/execute-governed-work-through-machine-daemons.md) | proposed | MasterPlan 21 / plans 119–123 define a delivery lane; all children not started, no machine-daemon runtime |
| [IR-21](improvement-requests/propose-unrequested-work-from-observed-activity.md) | completed | MasterPlan 20 / plans 114–118 complete; bounded observation, human acceptance and standing-policy admission with deterministic qualification |

## Review disposition

| Review | Historical outcome | Current disposition |
| --- | --- | --- |
| REV-1 — Plan 46 closeout | Changes requested | Open; plan 62 M1 accepted, provisioning/guidance and plan 63 conformance remain |
| REV-2 — Attention reservation | Changes requested | Open; plans 60 and 63 not started |
| REV-3 — Attention migration | Approved | Approval stands; advisory index work is in plan 60 |
| REV-4 — Resolution authorization | Changes requested | Open; plan 61 not started |
| REV-5 — Specialist Flow | Commented | Advisory work remains in plans 60 and 62 |
| REV-6 — Capability ports | Approved | Approval stands; advisory work remains in plans 60 and 62 |
| REV-7 — User guide | Changes requested | Open; plan 61 entitlement and plan 62 operator guidance remain |
| REV-8 — Improvement-request corpus | Changes requested | Resolved locally by plan 64 on 2026-09-21; historical review outcome is unchanged |

## Status maintenance

Keep child Progress/Outcomes, parent registry and summary documents consistent.
Mark completion only when acceptance evidence supports it. Historical reviews
remain evidence about their reviewed revision; later fixes change disposition,
not the original review outcome. Maintain generated OKF indexes through the
bundle recipes. Keep both roadmap representations aligned, including counts,
diagram states, filters and remaining gates. Runtime tests were inspected as
documentation evidence and were not rerun by this documentation pass.

# Shikigami roadmap

Refreshed 2026-11-03 against source checkpoint `616f1c24`, Cabal manifests,
MasterPlan registries, child Progress/Outcomes, request metadata and retained
qualification evidence. Recorded acceptance applies to its named candidate and
environment; this documentation pass does not rerun runtime qualification.
See the [HTML roadmap](artifacts/roadmap.html),
[engineer onboarding map](artifacts/shikigami-engineer-onboarding.html) and
[adaptive delivery guide](artifacts/adaptive-autonomous-objectives.html).

## Current delivery boundary

Implemented: typed Flow decisions and actual-attempt evidence (plans 73–76),
authenticated HTTP agent discovery and idempotent run acceptance/status/history
(plans 88–91), root resource accounting (81), immutable assignment model selection
(82) and protected durable Skill operation/transcript recovery (83). Continuing
workers retain ordered assignments, results, events and governed command mechanics
under plan 84, which remains in progress. Plan 96 is complete: configured durable
workers have governed repository allocation, edit/process/Git tools, independent
process fencing, integration and successor recovery. Its full 25-case native
Linux matrix includes real objective ownership, lost acknowledgements, supervisor
and controller restart, successor writes and former-owner refusal.

Authoritative objectives and checkpoint/ownership/scope providers are complete
(MasterPlan 17), as is optional provider-neutral external tracker synchronization
with the Rei adapter (MasterPlan 18). Full autonomous coding delivery still needs
plan 84's remaining consumer acceptance, validated adaptive coordination (85)
and integrated qualification/live coding proof (86). Recurring supervision (87)
is a separate optional phase. Provider qualification does not close those consumers.

The configured cohort selects Keiro 0.22, Baikai 0.10, Shikumi 0.5.1 and Kioku
0.12.0.2. MasterPlan 16's six-child Keiro upgrade is complete for its bounded
macOS profile; standalone plan 108's remaining domain audit is also complete.
Plan 80 has integrated structured TypeSafe answers, durable replay and public
complete/stream parity, with 15 real-adapter checks and three PostgreSQL cases.
Its broader wire/error matrix, Linux CLI qualification, deadline/output/confinement
gates and fresh immutable packaging remain open. The current export contains
387 runtime packages and seven immutable repositories; Nix role dry runs do not
qualify installed binaries. See the [streaming checkpoint](evidence/baikai-execution/streaming-consumer-checkpoint.json),
[Keiro qualification](evidence/keiro-0.22/macos-final-qualification.json) and
[domain inventory](architecture/shikigami-domain-inventory.md). The
[dependency cohort](dependency-cohort.md) retains historical adoption evidence.

## Portfolio snapshot

This audit covers 18 coordinated MasterPlans (1–18) and 108 ExecPlan files.
Thirteen MasterPlans are complete: 1–5, 8, 11–13 and 15–18.
The five active coordination documents are below.
Plan 97 is a superseded design, replaced by MasterPlan 17 and plans 98–102;
it is not a second objective implementation lane. Counts describe artifacts,
not feature readiness or effort percentages.

| MasterPlan | Current state | Remaining work |
| --- | --- | --- |
| [6](masterplans/6-operations-and-observability-run-shikigami-as-a-real-service.md) | 3 of 4 children complete; plan 31 in progress | Full service stack and drain proof |
| [7](masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md) | 3 of 5 complete | Plan 34 memory lifecycle and plan 12 MCP-specific integration |
| [9](masterplans/9-architecture-practice-review-flow.md) | 3 of 4 complete; plan 46 partial | Safety and closeout plans 60–63, then plan 46 acceptance |
| [10](masterplans/10-sanctioned-execution-attestation-for-agent-runs.md) | 3 of 4 complete | Plan 52 shared signed envelope, read API/verifier and live proof |
| [14](masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) | 3 of 7 complete; plan 84 in progress | Remaining worker consumer acceptance, adaptive coordination, integrated proof and optional recurrence |

Recent completed work:

| Owner | Accepted delivery and limits |
| --- | --- |
| [MasterPlan 16](masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md) | Six children (92–95, 106–107): Keiro 0.22, fresh schema, guarded commands, native recovery, administrative CLI/HTTP/live inspection and Haskell/service practices; bounded macOS acceptance |
| [MasterPlan 17](masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md) | Five children (98–102): authoritative objectives, trusted providers, API/CLI, durable capabilities and no-Rei serving continuity; IR-13 complete |
| [MasterPlan 18](masterplans/18-integrate-durable-objectives-with-external-trackers-through-provider-neutral-contracts-and-rei.md) | Three children (103–105): provider-neutral tracker bindings, real Rei adapter and served synchronization/restart qualification; uncertain delivery requires exact attestation before settlement |
| [Plan 96](plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md) | All six milestones and 25 native Linux cases pass; IR-11 complete; full IR-15/adaptive acceptance remains separate |
| [Plan 108](plans/108-complete-the-remaining-domain-scalar-identity-and-decoder-audit.md) | All milestones complete; 4,253 census keys resolved with zero pending dispositions or violations and 531 compiler controls; no new Linux runtime claim |

## Delivery order and gates

Practice-review safety remains first: plans 60/61 fix attention reservation and
resolver entitlement; plans 62/63 make closeout and conformance truthful before
plan 46 closes. Production evidence acquisition still depends on
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`.

For adaptive delivery, finish plan 84 against the delivered provider contracts:
plan 96 owns actual repository process fencing; MasterPlan 17 owns authoritative
objective/assignment state, trusted associations and checkpoint/ownership/scope
providers. Plan 96's joint native evidence qualifies the real fence/ownership/
successor/restart boundary. Plan 84 and IR-15 remain open for their full consumer
acceptance; do not substitute provider evidence for that closeout. Plans 85/86
consume these contracts; plan 87 adds explicitly admitted recurring mandates.
The authenticated objective API, operator CLI, native Skill/conversation tools
and typed Flow effects are implemented (plans 98–101). Plan 102 qualifies
serving-process continuity and explicit integrated completion; IR-13 is completed.

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
| [62](plans/62-make-the-practice-review-closeout-and-operator-documentation-true.md) | Not started; provisioning/operator path and closeout |
| [63](plans/63-extend-practice-review-conformance-to-the-claimed-end-to-end-matrix.md) | Not started; complete claimed conformance matrix |
| [77](plans/77-add-a-read-only-k8s-observe-capability-provider-for-durable-agents.md) | Not started; bounded read-only Kubernetes provider |
| [78](plans/78-run-external-operations-from-durable-flows-through-idempotent-shiki-jobs.md) | Not started; external executor, authorization and crash contracts |
| [79](plans/79-qualify-local-agent-execution-and-prioritize-production-readiness.md) | Partial packaging qualification; live workload/fault/human-wait gates remain |
| [80](plans/80-configure-model-providers-and-agent-launches-through-baikai.md) | In progress; HTTP/foreground, structured judgments and streaming delivered at recorded checkpoints; remaining wire/error matrix, Linux CLI, deadline/output/confinement and fresh immutable-role qualification |
| [84](plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) | In progress; real objective and workspace providers now qualified; full continuing-worker consumer acceptance remains |
| [85](plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md) | Not started; validated adaptive coordination |
| [86](plans/86-qualify-integrated-adaptive-autonomous-delivery.md) | Not started; combined artifacts, actual checks and live finite coding proof |
| [87](plans/87-supervise-recurring-objectives-from-current-durable-checkpoints.md) | Not started; recurring mandate admission and current-checkpoint supervision |

## Improvement-request lifecycle and implementation coverage

Lifecycle below mirrors request metadata checked on 2026-11-03: eight completed,
six in progress, one accepted and three proposed. Some request prose still
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
| [IR-14](improvement-requests/record-durable-model-tool-turns-and-compose-harness-policies.md) | in-progress | Plan 83 complete; follow-up/integrated acceptance remains in 84/86 |
| [IR-15](improvement-requests/support-continuing-worker-sessions.md) | in-progress | Plan 84 partial; IR-11/13 provider boundaries qualified, full consumer acceptance remains |
| [IR-16](improvement-requests/support-adaptive-durable-orchestration.md) | in-progress | Plan 81 complete; adaptive/integrated plans 85/86 remain |
| [IR-17](improvement-requests/select-governed-models-for-agent-runs.md) | in-progress | Plan 82 complete; later adaptation/integration remains |
| [IR-18](improvement-requests/support-recurring-objective-supervision.md) | accepted | Plan 87 not started |

## Review disposition

| Review | Historical outcome | Current disposition |
| --- | --- | --- |
| REV-1 — Plan 46 closeout | Changes requested | Open; plans 62 and 63 not started |
| REV-2 — Attention reservation | Changes requested | Open; plans 60 and 63 not started |
| REV-3 — Attention migration | Approved | Approval stands; advisory index work is in plan 60 |
| REV-4 — Resolution authorization | Changes requested | Open; plan 61 not started |
| REV-5 — Specialist Flow | Commented | Advisory work remains in plans 60 and 62 |
| REV-6 — Capability ports | Approved | Approval stands; advisory work remains in plans 60 and 62 |
| REV-7 — User guide | Changes requested | Open; plans 61 and 62 not started |
| REV-8 — Improvement-request corpus | Changes requested | Resolved locally by plan 64 on 2026-09-21; historical review outcome is unchanged |

## Status maintenance

Keep child Progress/Outcomes, parent registry and summary documents consistent.
Mark completion only when acceptance evidence supports it. Historical reviews
remain evidence about their reviewed revision; later fixes change disposition,
not the original review outcome. Maintain generated OKF indexes through the
bundle recipes. Keep both roadmap representations aligned, including counts,
diagram states, filters and remaining gates. Runtime tests were inspected as
documentation evidence and were not rerun by this documentation pass.

# Shikigami roadmap

Refreshed 2026-10-29 against the working tree (audit started at `ac971c3`), Cabal
manifests, domain declarations and plan Progress/Outcomes. Existing uncommitted
plan refinements are included as design context; they do not imply implementation.
See the [HTML roadmap](artifacts/roadmap.html),
[engineer onboarding map](artifacts/shikigami-engineer-onboarding.html) and
[adaptive delivery guide](artifacts/adaptive-autonomous-objectives.html).

## Current delivery boundary

Implemented: typed Flow decisions and actual-attempt evidence (plans 73–76),
authenticated HTTP agent discovery and idempotent run acceptance/status/history
(plans 88–91), root resource accounting (81), immutable assignment model selection
(82) and protected durable Skill operation/transcript recovery (83). Continuing
workers retain ordered assignments, results, events and governed command mechanics
under plan 84, which remains in progress. Pure repository catalog admission is
implemented under plan 96; it does not allocate worktrees or permit mutation.

Full autonomous coding delivery remains gated on real workspace fences (96),
objective/checkpoint providers (MasterPlan 17), validated adaptive coordination
(85), integrated qualification (86), and optional recurring supervision (87).
The default operator host refuses commands requiring those missing providers.
Fixtures prove consumer mechanics, not full production delivery.

The configured cohort is Keiro 0.18 at the October 6 snapshot. MasterPlan 16's
0.22 upgrade is planned, with no completed implementation milestone. See
[dependency cohort](dependency-cohort.md) and the
[domain inventory](architecture/shikigami-domain-inventory.md).

## Portfolio snapshot

This audit covers the 17 coordinated MasterPlans (1–17) and 102 ExecPlan files. Ten MasterPlans are complete:
1–5, 8, 11–13 and 15. The seven remaining coordination documents are below.
Plan 97 is a superseded design, replaced by MasterPlan 17 and plans 98–102;
it is not a second objective implementation lane. Counts describe artifacts,
not feature readiness or effort percentages.

| MasterPlan | Current state | Remaining work |
| --- | --- | --- |
| [6](masterplans/6-operations-and-observability-run-shikigami-as-a-real-service.md) | 3 of 4 children complete; plan 31 in progress | Full service stack and drain proof |
| [7](masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md) | 3 of 5 complete | Plan 34 memory lifecycle and plan 12 MCP-specific integration |
| [9](masterplans/9-architecture-practice-review-flow.md) | 3 of 4 complete; plan 46 partial | Safety and closeout plans 60–63, then plan 46 acceptance |
| [10](masterplans/10-sanctioned-execution-attestation-for-agent-runs.md) | 3 of 4 complete | Plan 52 shared signed envelope, read API/verifier and live proof |
| [14](masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md) | 3 of 7 complete; plan 84 in progress | Real providers, adaptive coordination, integrated proof and optional recurrence |
| [16](masterplans/16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md) | 0 of 4 complete | Plans 92–95: released solve, migration, guarded commands, patterns and replay rollout |
| [17](masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md) | 0 of 5 complete | Plans 98–102: authoritative objectives, trusted providers, API/CLI, durable capabilities and no-Rei qualification |

## Delivery order and gates

Practice-review safety remains first: plans 60/61 fix attention reservation and
resolver entitlement; plans 62/63 make closeout and conformance truthful before
plan 46 closes. Production evidence acquisition still depends on
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`.

For adaptive delivery, continue the real-provider contracts alongside plan 84:
plan 96 owns actual repository process fencing; MasterPlan 17 owns authoritative
objective/assignment state, trusted associations and checkpoint/ownership/scope
providers. Plan 99 consumes the real fence for positive handoff qualification.
Do not close plan 84 or IR-15 from deterministic adapter evidence. Plans 85/86
consume these contracts; plan 87 adds explicitly admitted recurring mandates.
No objective CLI or HTTP endpoint is shipped yet.

MasterPlan 16 independently owns the Keiro 0.22 upgrade. Retain the current
cohort, late-write rollback protections, queue upcasters and protected live-only
payloads until its replacement contracts and old/new replay proof pass.

Plan 31 has delivered immutable role builds and installed assets, but its full
process-compose/NixOS/graceful-drain scope remains open. Plan 79's installed
reporter qualification is partial; the last recorded live workload is blocked
on integration services. Plan 80 delivers HTTP providers and foreground launches;
background CLI response promotion remains gated on released cancellation support.
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
| [80](plans/80-configure-model-providers-and-agent-launches-through-baikai.md) | HTTP/foreground delivered; background CLI response qualification remains |
| [84](plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) | In progress; real checkpoint/workspace providers and runtime qualification remain |
| [85](plans/85-adapt-durable-delivery-through-validated-coordinator-decisions.md) | Not started; validated adaptive coordination |
| [86](plans/86-qualify-integrated-adaptive-autonomous-delivery.md) | Not started; combined artifacts, actual checks and live finite coding proof |
| [87](plans/87-supervise-recurring-objectives-from-current-durable-checkpoints.md) | Not started; recurring mandate admission and current-checkpoint supervision |
| [92](plans/92-resolve-the-released-keiro-0-22-cohort-and-rehearse-the-composed-migration.md) | Not started; 0.22 solve and composed migration |
| [93](plans/93-adopt-guarded-catalog-commands-and-qualify-current-dsl-consumer-contracts.md) | Not started; guarded commands and DSL consumer contracts |
| [94](plans/94-adopt-current-runtime-lifecycle-patterns-and-bounded-operator-inspection.md) | Not started; runtime lifecycle and bounded operator integration |
| [95](plans/95-close-the-runtime-pattern-audit-and-qualify-the-keiro-0-22-rollout.md) | Not started; old/new replay, artifacts and rollout closure |
| [96](plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md) | In progress; pure admission landed, durable workspaces/mutation/fencing remain |
| [98](plans/98-persist-authoritative-objectives-and-conditional-commands.md) | Not started; authoritative objective persistence and conditional commands |
| [99](plans/99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md) | Not started; trusted associations and actual checkpoint/ownership/scope providers |
| [100](plans/100-expose-governed-objective-inspection-through-the-api-and-cli.md) | Not started; governed objective API/CLI inspection |
| [101](plans/101-make-objective-capabilities-durable-for-agents-and-conversations.md) | Not started; durable objective capabilities for agents/conversations |
| [102](plans/102-qualify-no-rei-objective-continuity-and-close-ir-13.md) | Not started; integrated no-Rei continuity and request closeout |

## Improvement-request lifecycle and implementation coverage

Lifecycle below mirrors the request metadata reconciled on 2026-10-29.
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
| [IR-11](improvement-requests/provide-governed-mutable-repository-workspaces.md) | in-progress | Plan 96 in progress: pure catalog admission only |
| [IR-12](improvement-requests/compose-shikumi-decisions-in-durable-flows.md) | completed | MasterPlan 13 complete |
| [IR-13](improvement-requests/support-optional-major-task-tracking.md) | accepted | MasterPlan 17 accepted: plans 98–102 not started; plan 97 superseded |
| [IR-14](improvement-requests/record-durable-model-tool-turns-and-compose-harness-policies.md) | in-progress | Plan 83 complete; follow-up/integrated acceptance remains in 84/86 |
| [IR-15](improvement-requests/support-continuing-worker-sessions.md) | in-progress | Plan 84 partial; real providers gate completion |
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
| REV-8 — Improvement-request corpus | Changes requested | Resolved locally by plan 64 on 2026-09-21; Mori still lacks conventional plan-artifact URI coverage |

## Status maintenance

Keep child Progress/Outcomes, parent registry and summary documents consistent.
Mark completion only when acceptance evidence supports it. Historical reviews
remain evidence about their reviewed revision; later fixes change disposition,
not the original review outcome. Maintain generated OKF indexes through the
bundle recipes. Runtime tests were inspected as documentation evidence and were
not rerun by this documentation pass.

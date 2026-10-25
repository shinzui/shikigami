# Shikigami roadmap

Portfolio audit date: 2026-09-21; IR-12 and IR-13 added 2026-09-26; IR-12 completed 2026-10-25.

Architecture and delivery decision view: [HTML roadmap](artifacts/roadmap.html).

The 2026-09-21 portfolio audit reconciled `docs/reviews`, `docs/improvement-requests`,
`docs/masterplans`, and `docs/plans` against their progress records, Git history, and the
repository tree. The request table records IR-12 completion on 2026-10-25; portfolio counts remain the historical audit snapshot. A plan
is complete only when its own outcomes and evidence support completion. A review outcome remains
historical evidence about its `reviewedSha`; the disposition below says whether later work has
answered it.

## Portfolio snapshot

| Corpus | Complete or resolved | In progress or open | Not started or proposed |
| --- | ---: | ---: | ---: |
| MasterPlans | 8 | 4 | 0 |
| ExecPlans | 60 | 3 | 8 |
| Improvement requests | 3 | 2 | 8 |
| Change-requesting reviews | 1 resolved | 4 open | — |

The completed MasterPlans are 1 through 5, 8, 11, and 12. The active coordination documents are:

| MasterPlan | Current state | Remaining work |
| --- | --- | --- |
| [6 — Operations and observability](masterplans/6-operations-and-observability-run-shikigami-as-a-real-service.md) | 3 of 4 children complete | Plan 31: deployable service stack |
| [7 — Platform feature completion](masterplans/7-platform-feature-completion-egress-schema-memory-lifecycle-delegation.md) | 3 of 5 children complete | Plan 34: memory lifecycle; plan 12: MCP declarations/runtime |
| [9 — Architecture-practice review flow](masterplans/9-architecture-practice-review-flow.md) | Core implementation landed; closeout is not trustworthy yet | Plans 60 through 63, then close plan 46 |
| [10 — Sanctioned execution attestation](masterplans/10-sanctioned-execution-attestation-for-agent-runs.md) | 3 of 4 children complete | Plan 52: signing, read API, verifier, UC-8 proof |

## Priority order

### Local qualification workload — 2026-10-06

[Plan 79](plans/79-qualify-local-agent-execution-and-prioritize-production-readiness.md)
has fresh successful Cabal build, regression, migration and workflow checks; four
immutable roles and installed reporter assets pass at `685a410`, and the live workload
is blocked. Use the corrected at-risk fixture revision for host deployment. The operator
confirmed that the required integration services are not running. Start PostgreSQL 18,
Shomei and Kikan-En first, then a test Kawa destination with a real response provider,
then test Danwa and Kizashi for durable human waits. [Plan 80](plans/80-configure-model-providers-and-agent-launches-through-baikai.md)
extends the existing Baikai builder to selectable HTTP/CLI transports and foreground
launches. HTTP and foreground launch integration are implemented; Codex/Claude batch login
for the reporter awaits an upstream released descendant-cancellation fix;
Anthropic API credentials are needed only when choosing Anthropic HTTP. Configure real trust and grants
before protected delivery. Kafka and Kubernetes are not prerequisites for this workload.

The [readiness report](evidence/local-qualification/readiness.md) records observed
failures, successful retries, remaining scenario gates and separate production gates.
This workload order does not enable practice review: plans 60/61 remain prerequisites
for that feature. IR-14 is next only when crash evidence or the selected workload
requires individual model/tool-turn recovery.

### P0 — Correctness and authorization defects

Implement [plan 60](plans/60-harden-practice-review-attention-reservation-and-specialist-failure-boundaries.md)
and [plan 61](plans/61-enforce-practice-review-resolver-entitlement-and-harden-the-authorization-envelope.md)
first. REV-2 identifies a replay path that can permanently reserve attention without an outbox
message. REV-4 identifies a resolution boundary that authenticates a subject without proving that
subject is entitled to resolve the review, and the credential wrapper still derives `Show`.
Both findings still exist in the current source.

### P1 — Make the practice-review feature's claims true

Implement [plan 62](plans/62-make-the-practice-review-closeout-and-operator-documentation-true.md)
and [plan 63](plans/63-extend-practice-review-conformance-to-the-claimed-end-to-end-matrix.md),
then revise and close [plan 46](plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md).
This closes REV-1 and REV-7, adds the missing profile provisioning/operator path, and makes the
claimed conformance matrix observable. IR-4 remains `in-progress` until this wave is complete.
The production evidence reader still depends on
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`, which remains proposed; keep the
fail-closed unresolved behavior until that contract ships.

### P2 — Make the runtime deployable and externally consumable

Implement [plan 31](plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md).
Its prerequisites are now complete, and it is the only unfinished child of MasterPlan 6. It also
unblocks the remaining portable-harness work in
[plan 48](plans/48-add-a-portable-one-off-repository-agent-harness.md).

In the same planning horizon, create a coordinated plan for IR-8 and IR-10: the public addressed-run
command and terminal run-status query must share one stable run identifier and lifecycle contract.
Do this before IR-11, because governed mutable workspaces need a supported way for Mori to start a
durable run and observe its terminal result.

### P3 — Finish sanctioned execution attestation

[Plan 52](plans/52-signed-attestation-read-api-and-uc-8-conformance.md) is the last child of
MasterPlan 10 and completes IR-7. Its local prerequisites are complete, but the shared envelope
contract at `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6` remains proposed and the
positive live-provider proof needs credentials. Prioritize cross-repository contract ratification;
do not freeze another local wire format while that shared decision is open.

### P4 — Feature breadth after the service boundary is stable

Resume [plan 34](plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md) and
[plan 12](plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md) selectively. Plan 34 can
start its distillation and shared-scope slices, but its bounded recall and retention work still
depends on `mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2`. Plan 12 can deliver its
schema and registry seam, but live MCP work remains blocked on the proposed Baikai, Shikumi, and
Kikan-En requests named in the plan.

IR-2 (cross-cluster diagnostics), IR-5 (governed evolution), and IR-6 (A2A interoperability) have
no accepted Shikigami delivery plan. Keep them proposed until a product decision accepts, rejects,
or sequences them; do not let their size obscure the correctness and service-boundary work above.

## Open ExecPlans

| Plan | Status | Recommendation |
| --- | --- | --- |
| [8 — Danwa conversation loop](plans/8-conversational-agent-loop-bound-to-danwa.md) | In progress; implementation landed, two legacy validation items remain | Re-verify against the current Danwa event path or explicitly supersede the old manual proof |
| [12 — Per-agent MCP servers](plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md) | Not started; partly locally startable, live path externally blocked | Split local schema/seam work from blocked runtime work before implementation |
| [31 — Deployable service stack](plans/31-deployable-service-stack-process-compose-packaging-and-configuration.md) | Not started; prerequisites complete | Start after P0/P1, before plan 48 |
| [34 — Memory lifecycle](plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md) | Not started; mixed local and external scope | Split or stage around the Kioku IR-2 dependency |
| [46 — Review orchestration](plans/46-orchestrate-review-delivery-and-end-to-end-conformance.md) | In progress; core landed, reviewed closeout has gaps | Close only after plans 60–63 |
| [48 — Portable repository-agent harness](plans/48-add-a-portable-one-off-repository-agent-harness.md) | In progress; 3 of 10 progress items complete | Resume after plan 31; align with IR-11 rather than inventing a second workspace contract |
| [52 — Signed attestation and UC-8](plans/52-signed-attestation-read-api-and-uc-8-conformance.md) | Not started; local prerequisites complete, shared contract open | Coordinate Kikan IR-6, then implement |
| [60 — Attention and specialist boundaries](plans/60-harden-practice-review-attention-reservation-and-specialist-failure-boundaries.md) | Not started | P0 |
| [61 — Resolver entitlement](plans/61-enforce-practice-review-resolver-entitlement-and-harden-the-authorization-envelope.md) | Not started | P0 |
| [62 — Truthful closeout and operator docs](plans/62-make-the-practice-review-closeout-and-operator-documentation-true.md) | Not started | P1 |
| [63 — Claimed conformance matrix](plans/63-extend-practice-review-conformance-to-the-claimed-end-to-end-matrix.md) | Not started | P1 |

## Improvement-request status

| Request | Status | Evidence or next decision |
| --- | --- | --- |
| IR-1 — Meibo lifecycle and fleet identity | Completed | Plan 23 |
| IR-2 — Cross-cluster diagnostics | Proposed | No accepted Shikigami plan |
| IR-3 — Declarative router agents | Completed | MasterPlan 8, plans 40–42 |
| IR-4 — Architecture-practice review flow | In progress | Plans 43–46 landed in part; plans 60–63 remain |
| IR-5 — Governed agent evolution | Proposed | No accepted Shikigami plan |
| IR-6 — A2A interoperability | Proposed | No accepted Shikigami plan |
| IR-7 — Sanctioned execution attestation | In progress | Plans 49–51 complete; plan 52 remains |
| IR-8 — Addressed runs over HTTP | Proposed | Needs coordinated plan with IR-10 |
| IR-9 — Principal-keyed continuity and attribution | Completed | Plan 54 |
| IR-10 — Terminal run status over HTTP | Proposed | Depends on IR-8's run identity |
| IR-11 — Governed mutable repository workspaces | Proposed | Sequence after IR-8/IR-10 and with plan 48 |
| IR-12 — Shikumi decisions in durable Flows | Completed | [MasterPlan 13](masterplans/13-compose-shikumi-decisions-in-durable-flows.md), plans 73–76: typed two-model composition, retained replay, durable attempts and patch-safe evolution |
| IR-13 — Optional major-task tracking without Rei | Proposed | Resolve task ownership, storage, and replay-safe mutation design before planning |

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

## Status maintenance rule

When an ExecPlan completes, update its parent MasterPlan registry and aggregate Progress in the
same change. When an improvement request changes lifecycle, update its frontmatter, Status prose,
bundle log, and review provenance together. Never rewrite a historical review outcome to describe
later work; add a new review or update this disposition ledger instead.

---
id: 7
slug: platform-feature-completion-egress-schema-memory-lifecycle-delegation
title: "Platform Feature Completion: Egress, Schema, Memory Lifecycle, Delegation"
kind: master-plan
created_at: 2026-07-08T20:13:36Z
intention: "intention_01kx1tyzqcerzv4ysbktgr9sw9"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T18:24:04Z
      mode: "update"
      note: "Reconciled status and progress during the 2026-09-21 portfolio audit"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T18:49:50Z
      mode: "update"
      note: "Reconcile delivered features, overlay ownership, current dependencies and prioritized remaining integration gaps."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T21:09:33Z
      mode: "update"
      note: "Refresh current code, completed prerequisites, shared ownership and genuine remaining acceptance; preserve historical decisions."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-06T21:35:46Z
      mode: "update"
      note: "Audit current identity, dual timer entry points and generic MCP execution compatibility; preserve outstanding release gates."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T18:49:50Z
      verdict: "comments"
      note: "Author self-review: remaining memory and MCP gates assigned; no runtime acceptance claimed."
---

# Platform Feature Completion: Egress, Schema, Memory Lifecycle, Delegation

This MasterPlan coordinates five feature streams. The registry owns child status;
child ExecPlans own implementation milestones. Refreshed against the working tree,
accepted ADRs and upstream release sources on **2026-11-06**, including a focused
compatibility audit at `69ac8b25`.

## Vision & Scope

Complete the platform's declared-agent surface with working channel egress, identity
and memory policy, governed delegation, memory lifecycle, and remote MCP tools.
Three streams have already shipped: channel egress, additive agent policy, and
one-shot delegation. The remaining outcomes are managed long-term memory and an
MCP provider integrated into the existing capability-overlay runtime.

The current schema already declares `ChannelEgress`, `identity`, `memory`, `enabled`,
`delegates`, `delegationBudget`, `capabilityOverlays`, routing, execution and harness
policy. The Haskell declaration lives in `shikigami-core/src/Shikigami/Agent/Decl.hs`,
not the old proposed `shikigami-api/src/Shikigami/Api/Agent.hs`. Principals, outbound
credentials, C11 sink grants, C13 per-action authorization, model/tool execution,
and overlay leases exist. This plan must consume those owners rather than recreate
them. See [writing agents](../user/writing-agents.md) and
[the dependency cohort](../dependency-cohort.md).

Memory is only partly managed. `Agent/Run.hs:recallActiveByScope` still calls the
unbounded `Recall.getActiveByScope` and applies `take` afterwards. The `Shared`
alternative has no runtime implementation. Conversation turns schedule Kioku L1
timers, but the worker's application fallback has no Kioku handler. There is no
general memory-retention worker. Flow memory does now support configurable
`RememberOptions`; the old assertion that every write hardcodes identical metadata
is false.

MCP is now an operator-provided capability, requested through
`capabilityOverlays : List Text`. It is **not** an agent-authored `mcpServers` field.
[MasterPlan 11](11-add-agent-scoped-capability-overlays-without-changing-base-capabilities.md)
completed the common declaration, catalog, registry, leases, tool loop and durable
pinning. Plan 12 retains only MCP-specific integration and acceptance.

This initiative does not own the Keiro/cohort upgrade
([MasterPlan 16](16-upgrade-shikigami-to-keiro-0-22-and-retire-superseded-runtime-workarounds.md)),
adaptive objectives and continuing workers
([MasterPlan 14](14-deliver-adaptive-autonomous-objectives-with-durable-workers.md)),
model-provider implementation, or production service deployment. Long-term Kioku
memory is distinct from the execution driver's accepted context summaries and
protected replay payloads; memory retention must not collect those stores.

## Decomposition Strategy

Keep the five original children and their paths for continuity. Plans 32, 33 and
35 remain Complete, with their recorded acceptance evidence. Plan 34 remains Not
Started: existing foundations and a planning refresh do not count as lifecycle
implementation. Plan 12 remains Not Started for its surviving MCP scope; common
work delivered by plans 56–59 is credited to those plans rather than duplicated.

The remaining work streams are independently verifiable: plan 34 proves bounded,
identity-correct memory and timer/retention behavior against PostgreSQL; plan 12
proves authorized remote observation tools and cleanup against a hermetic MCP
server and the real overlay/execution consumer. Neither depends on the other.

Relevant accepted decisions are [ADR 0011](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md)
(defaulted journal fields), [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md)
(real workflow guards), [ADR 0019](../adr/0019-a-loop-that-stops-stops-the-process.md)
(loop supervision), [ADR 0023](../adr/0023-delegation-is-governed-at-the-child-spawn-boundary.md)
(delegation), [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md)
(overlay ownership), [ADR 0031](../adr/0031-practice-review-adjudication-is-a-logical-memory-transition.md)
(review memory), [ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md)
(principal scopes and aliases), [ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md)
(fresh authorization), [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md)
(one timer dispatcher), and [ADR 0056](../adr/0056-context-summaries-are-accepted-accounted-model-operations.md)
(context summaries). The follow-up selects the missing durable contracts in
[ADR 0064](../adr/0064-memory-lifecycle-preserves-session-and-retention-ownership.md)
(memory/session/retention ownership) and
[ADR 0065](../adr/0065-mcp-provider-revisions-bind-the-approved-tool-contract.md)
(MCP approved binding). Both are accepted designs with implementation pending;
release and behavioral proof gates remain distinct from design decisions.

## Exec-Plan Registry

| # | Title / current scope | Path | Hard Deps | Soft Deps | Status |
|---|---|---|---|---|---|
| EP-1 | Channel egress through Kanmon | [Plan 32](../plans/32-channel-egress-sink-through-kanmon.md) | None | None | Complete (2026-08-23) |
| EP-2 | Identity, memory policy and enablement | [Plan 33](../plans/33-agent-schema-evolution-identity-memory-policy-and-enablement.md) | None | None | Complete (2026-08-20) |
| EP-3 | Memory lifecycle | [Plan 34](../plans/34-memory-lifecycle-distillation-retention-and-shared-scope.md) | EP-2 | None | Not Started |
| EP-4 | Declared one-shot delegation | [Plan 35](../plans/35-delegation-as-a-first-class-declared-capability.md) | None | None | Complete (2026-08-22) |
| EP-5 | MCP provider for capability overlays (historical filename retained) | [Plan 12](../plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md) | None | None | Not Started |

Statuses are Not Started, In Progress, Complete and Cancelled. Missing milestone
prerequisites do not imply the entire child is blocked. Historical plan 47 is an
accepted foundation, not the current dependency target. Plan 12 was originally C6
of `mori://shinzui/baikai/masterplans/6-mcp-support-across-the-agent-stack`; this local
MasterPlan remains its coordination parent.

## Dependency Graph

The remaining local hard edge is EP-2 → EP-3, already satisfied. EP-5 consumes the
completed overlay artifacts from plans 56–59, not a second schema pattern. There
is no EP-3 ↔ EP-5 hard edge and no cycle.

Start with plan 34 M0, implementing the selected policy/eligibility/merge fixtures and recording the producer release matrix. M1 integrates
Kioku firing with the existing bounded timer dispatcher after the outcome/effect-row
and AI-configuration proof. M2 and M3 require a released query contract satisfying
the exact ordering, partition and retention requirements, not merely a package
with a page API. M4 applies M0's pinned policy: sessions/distillation remain principal-scoped,
while Shared selects the exact global bucket for run learnings and explicit Flow
memory. Its local selector/replay fixtures can proceed while queries are released;
full acceptance requires M2. M3 then requires M4's accepted marker-writing
behavior; default execution order is M0 → M2 → M4 → M3, with M1 independently
eligible after its bounded-input/candidate release. Production
lifecycle acceptance requires all four implementation milestones.

Plan 12 M1 implements content-derived binding revisions, explicit name/schema
mapping and fake-lease tests without live MCP IO. Its M2–M4 require released transport and adapter contracts,
credential handling and discovery authorization. Reuse the local C13 authorizer;
do not wait for a request-status label to change before acknowledging code that
already exists. Conversely, C13's existence does not supply the missing MCP client.

Plans 92–95 and 82–85 are Complete. The selected cohort is Keiro 0.22,
Kioku 0.12.0.2, Baikai 0.10.0.0 and Shikumi 0.5.1.0/tools 0.4.2.1.
Current owner boundaries are available; only a newly needed API requires another
verified compatible release/solve/closure. Neither feature waits for an already
completed upgrade, and neither may silently alter dependency bounds.


## Integration Points

**Declaration and persisted policy — EP-2 defines, EP-3 consumes.**
`schema/Agent.dhall` and `Shikigami.Agent.Decl` retain default
`{ scope = AgentScope, recallLimit = 10, recordPolicy = OnSuccess }`, with checked
recall bounds 1–1000. Plan 34 must honor the policy across durable runs, Flow memory
and the memory-backed one-off path. Plan 56 owns `capabilityOverlays`; plan 12 adds
no endpoint/credential field to the agent and no second registry. Preserve default
JSON omission and old `lookup-agent` bytes.

**Memory identity and authorization — plan 54 defines, EP-3 extends.**
`Memory/Access.hs`, `Memory/Scope.hs` and `Memory/AliasStore.hs` own the current
single memory space, recorded principal and accepted legacy aliases. Plan 34's
selector must consume admitted identity, never resolve or key by the current
agent name. Shared recall is the exact global bucket inside the authorized space,
not namespace-wide recall. The child owns the early two-principal/two-space proof
and preserves principal-scoped sessions and distillation. Shared never publishes
private conversational history implicitly. Metadata retention requires the reserved automatic-learning marker plus the
space/type/scope predicate. Unmarked history, review, explicit Flow and distilled
memories remain protected; keep counts apply per physical scope.

**Current identity and module contracts — both children consume.**
[ADR 0087](../adr/0087-agent-values-retain-checked-meaning-and-separate-compatibility-scopes.md)
replaced compatibility-name sanitization with the exact-name v2 commitment.
Plan 34 preserves that scope and explicit verified-principal aliases; it must not
revive the old sanitizer as a fallback. Both children retain checked domain values
and [ADR 0075](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md)'s
module ownership checks. Plans 107/108 are delivered foundations, not new prerequisites.

**Timer dispatch, AI and maintenance — EP-3 extends existing owners.**
`shikigami-workers/src/Shikigami/Trigger/Timer.hs:runTimerPass` owns the bounded
claim/drain boundary; `Trigger/Scheduler.hs` routes application timers. Plan 34
adds a Kioku handler, not a competing generic poller. The standalone scheduler also
calls `runSchedulerTimerWorker`, which drains the same table: EP-3 must supply the
same recognized-owner routing and limits there. Mixed-owner regression includes
adaptive cutoff timers as well as schedules, approvals, observations and idle timers.
Kioku owns its fire outcomes,
retry/defer/dead-letter semantics and writes. Worker startup owns validated
`AIRuntime` and memory context supply. Retention has a finite per-pass work budget
and independent enablement so it can run without spending model credentials.
With live distillation enabled, the shared drain handles one row per pass with a
30-second AI callback bound and a 60-second heartbeat threshold; the disabled-AI
fast path retains 100 rows. Consume completed plan 94's runtime contract and requalify this deliberate throughput change.

**MCP catalog, provider and tool binding — plans 56–59 define, EP-5 consumes.**
`Capability/Overlay.hs`, `Catalog.hs`, `Provider.hs` and `Tools.hs` own immutable
public descriptors, exact-revision lookup, leases and final names. Model-visible
names remain `overlay__<capability-id-with-dashes>__<logical-tool-name>`; an upstream
`mcp__*` adapter name must be mapped explicitly without changing the remote call
name or authorization coordinates. Plan 12 owns discovery/schema-drift rejection
and the MCP-specific proof. Dynamic discovery must not mutate an accepted catalog
or change a pinned tool's schema/revision silently. The approved binding commits names, schemas, descriptions, endpoint binding and
limits into an existing-format capability revision using `versionedDigest`; no new
generic descriptor codec is needed. Existing execution schema digests remain in use.
Observation-only MCP uses the generic overlay lease path. The separate
`DurableAdapter` installation path currently requires governed workspace admission;
MCP does not gain that requirement merely by being durable. Tool-menu description
currently acquires generic leases too: plan 12 qualifies authorization and cleanup
on that path, and selective acquisition on pending-tool dispatch.

**External action authority — existing C13 owner, EP-5 integrates discovery.**
`Action/Authorization.hs` and `Capability/Provider.hs` already check connection and
each exact tool invocation. Plan 12 must put `DiscoverCapabilityTools` immediately
before discovery IO, verify revocation between stages, and resolve secrets only
at the operator composition root. Kikan-En uses verified immutable published source commit
`16704290d527d413568bfa40c983f5c3604c35c8`; native roles already build.
The MCP-extended closure and discovery consumer still need their own qualification.

**Durable execution and replay — existing workflow/execution owners, both consume.**
Any change under `Agent/` or `Flow/` follows [workflow versioning](../workflow-versioning.md)
and the checked `domain/` declarations. Keeping names stable is insufficient:
new steps and changed memory-target semantics need a real compatibility decision
and patch where required. Plan 12 must exercise `Execution/Tools.hs` as well as the
legacy behavior attempt; it must not write another completion/tool loop. Durable
MCP acceptance is observation-only under ADR 0025. Mutating remote tools need a
separate accepted idempotency/recovery contract and are outside this delivery.

## Progress

2026-11-06: three of five children are Complete. Memory lifecycle and MCP remain
Not Started; prerequisite/planning checkboxes have been removed from their implementation
progress. Existing declarations, principal/alias state, shared timer, C13 connection/
invocation checks, overlays and accepted model/tool execution are delivered foundations.
Current code still has unbounded fallback/alias reads, no lifecycle retention/policy
owner or Kioku timer route, and no MCP provider.

Start with plan 34 M0 and plan 12 M1's local contracts/fixtures. Exact newest-first,
conditional-retention and bounded distillation owner behavior still gate the affected
runtime milestones; current generic Kioku pages are insufficient. Released MCP transport/
adapter/discovery authority still gate live integration. No runtime qualification was
performed for this refresh; the selected source and release metadata were inspected.

## Surprises & Discoveries

The audit holes now have selected remedies and explicit closure evidence:

| Hole | Selected remedy and owner | Proof required to close it |
|---|---|---|
| Unbounded recall and incorrect alias ordering | Plan 34 M2: bounded exact-scope metadata, at most 64 aliases, deterministic top-N merge and selected-content fetch | Query-plan bounds, newest alias beats older principal, tie/dedup cases, 65th alias refuses before partial recall |
| Competing timer/implicit AI design | Plan 34 M1: one shared claimed-row callback, host AIRuntime, owner outcomes, one-row live-AI pass and 30-second callback limit | Real mixed-owner timer pass, deferred/denied/timeout/crash paths, bounded L1/L2/L3 input and watermark behavior |
| Retention can delete review evidence or starve maintenance | Plan 34 M3: reserved automatic-learning marker, per-physical-scope keep set, fixed-cutoff checkpoint, 500-row/30-second pass budget | Review/legacy/Flow exclusions, crash between archive/checkpoint, tied cursors, concurrent inserts and failing-candidate parking |
| Shared scope can merge conversations or retarget replay | Plan 34 M0/M4: pinned policy behind a real patch; shared learnings only; sessions/transcripts/distillation stay private | Two principals/two spaces, automatic versus explicit write policy, manifest edit while parked, old and new workflow branches |
| Remote MCP catalog can change a pinned tool | Plan 12 M1/M2: explicit native/logical map and canonical content-derived binding revision; no live refresh | Object-order stability, schema-change rejection, unapproved tools unavailable, exact old revision retained |
| MCP echo does not prove authorization/recovery/cleanup | Plan 12 M2–M4: fresh connect/discovery-page/invoke checks, finite protocol ceilings, acquisition-owned partial cleanup and current execution integration | Revocation between stages, timeout/cancellation/abort, accepted-result replay without server, pending binding mismatch, unsupported-mode refusal |
| Upstream status hides missing delivery | Plan 34 M0 and plan 12 M1 own exact producer contract matrices; plan 92 owns accepted cohort/migrations | Tagged source and public API evidence, producer fixtures and accepted consumer solve; request metadata alone never closes a gate |

This table addresses the design holes. Rows close only with implementation proof.
No new child plan is needed: memory and MCP each retain one accountable owner.
The initial historical findings were unbounded `getActiveByScope`/candidate reads,
principal-first alias truncation, review MemoryPattern overlap, stale MCP schema
instructions and partial upstream delivery; those observations remain valid until
implementation replaces them.

Release/source check on 2026-11-06: Hackage and peeled tags confirm selected
Kioku 0.12.0.2 (`5a62c3ef29cad50543f7bae97126e0431225998d`), Baikai 0.10.0.0
(`03140cf60381ac154ebfa86d3bb2208d7df8626c`) and Shikumi 0.5.1.0/tools 0.4.2.1
(`7b96ecf06364b37de44b15c4f58b2528b5a3e0f5`). The selected tool/provider
descriptors have no MCP modules. Baikai's preferred version is now 0.10.1.0,
which this refresh does not adopt. Selected Kioku distillation still limits candidates
after `getActiveByScope`, so its exact bounded-read/retention handoffs remain open.
Baikai MCP IR-2 and Shikumi MCP IR-1 remain proposed; Kioku IR-2 is in progress.

Canonical upstream gates are
`mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2`,
`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-2`,
`mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-1`, and
`mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-3`.
Mori registrations can lag their owners; this audit read the owner files and
released code as well as registry metadata.

## Decision Log

- 2026-11-06 focused audit: Apply the existing v2 compatibility-identity and
  module-ownership contracts, cover both timer-drain entry points and adaptive
  cutoff timers, and make the generic MCP menu/dispatch lease behavior explicit.
  These are corrections against current owners, not new architecture decisions.

- 2026-10-28 follow-up: Resolve the review holes in ADRs 0064/0065 and the child
  contracts. Select private sessions/distillation with shared learnings, marker-only
  retention, bounded alias merging and checkpointed maintenance, one-row live-AI
  timer passes, and content-derived MCP binding revisions. Record explicit acceptance
  rows and upstream handoffs rather than leaving these as design questions.

- 2026-10-28: Retain five children and three accepted completions. Rewrite the two
  unfinished children around current owners; no additional child is needed because
  each remaining outcome is still independently verifiable.
- 2026-10-28: Apply ADRs 0025/0036/0038 and plan 12's 2026-08-22 scope amendment in
  the actual coordination and implementation sections. Remove the obsolete schema,
  fifth-timer-loop, fixed-provider and blanket-authorization-blocker instructions.
- 2026-10-28: Treat bounded reads, timer integration, shared-session policy and MCP
  discovery/replay as explicit acceptance gates. Coordinate dependency changes with
  plan 92; do not make the entire upgrade a prerequisite for independent local work.
- 2026-07-08 (historical): Split egress, declaration, lifecycle and delegation;
  register pre-existing MCP plan 12 here, preserving its upstream lineage. Fix the
  memory-policy defaults and prefer a single declared recall scope over a union.
  Name-keyed scope and MCP-schema implementation details are superseded above.
- 2026-07-22/30 (historical): Establish shared loader, authenticated HTTP, bounded
  policy values, global delegation budget, configuration and workflow prerequisites;
  track upstream memory/MCP contracts explicitly. Those foundations mostly landed;
  their original package numbers and proposed signatures are not current targets.

## Outcomes & Retrospective

Egress, defaulted schema policy and governed one-shot delegation satisfy their
recorded child acceptance. The platform also gained principal-based state, fresh
external-action authorization, overlays and durable model/tool execution outside
this initiative. Those deliveries reduce remaining work but do not complete memory
lifecycle or MCP. ADRs 0064/0065 already select the required design; this refresh updates
current dependencies and remaining implementation instructions without creating new ADRs.
Implementation, missing upstream releases and final integration remain; no row is
closed by the planning change alone.

## Revision Notes

- 2026-11-06 focused audit at `69ac8b25`: Verified the remaining work against code,
  current ADRs and release metadata; added missing identity, standalone scheduler,
  adaptive timer and generic-versus-governed execution acceptance. Completed
  children retain their historical acceptance; runtime suites were not rerun.

- 2026-11-06: Reconcile the selected cohort/immutable Kikan-En closure and completed runtime/accepted execution; keep exact owner API and MCP integration gates while removing inflated planning/foundation progress.

- 2026-10-28 follow-up: Address the identified holes with selected designs, bounded
  defaults, error/recovery contracts, an explicit closure table and ADRs 0064/0065;
  cascade those decisions into the two unfinished children.

- 2026-10-28: Reconciled code, ADRs, newer plans and released upstream contracts;
  replaced duplicated milestone checkboxes with a coordination snapshot; narrowed
  MCP to its surviving overlay-provider scope; cascaded the refresh into plans 34
  and 12 and added prioritized gaps and milestone acceptance gates.
- 2026-09-21: Reconciled plans 32 and 33 as Complete; three of five children complete.
- 2026-07-22/30: Added portfolio foundations and upstream contracts to the original
  July decomposition. Current dependencies above supersede that historical wave order.

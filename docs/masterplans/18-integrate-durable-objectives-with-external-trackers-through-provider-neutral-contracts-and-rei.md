---
id: 18
slug: integrate-durable-objectives-with-external-trackers-through-provider-neutral-contracts-and-rei
title: "Integrate durable objectives with external trackers through provider-neutral contracts and Rei"
kind: master-plan
created_at: 2026-10-29T13:15:36Z
intention: "intention_01m63wqywcefjaq53cvzhtvqcv"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-29T13:15:36Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-30T03:15:57Z
      verdict: "approved"
      note: "Reviewed and refreshed dispatch ownership, destination routing and audited attestation; ready subject to unchanged prerequisites."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-30T03:15:57Z
      mode: "update"
      note: "Clarify shared dispatch and evidence-based delivery attestation; preserve planning status and hard dependencies."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-02T10:34:54Z
      mode: "implement"
      note: "Verified MasterPlan 17 completion and began provider-neutral tracker implementation"
---

# Integrate durable objectives with external trackers through provider-neutral contracts and Rei

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope


A user links a durable Shikigami objective to an existing Rei intention, receives attributable progress and completion summaries there, observes external edits as explicit proposals, and resolves conflicts or uncertain deliveries without losing local evidence or restarting accepted work. An unlinked objective continues to work with Rei absent. This advances the [declared-agent vision](../../README.md) and [UC-1](../use-cases/adaptive-autonomous-delivery.md): human planning may live elsewhere while autonomous execution retains authoritative checkpoints.

This follows [MasterPlan 17](17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md); it does not change that plan’s no-Rei completion gate. The user selected a provider-neutral contract with a concrete Rei adapter and authorized creation of intention `intention_01m63wqywcefjaq53cvzhtvqcv` using `mina ci --json`. Include bindings, explicit field ownership, authenticated imports, transactional publication, delivery receipts, polling/reconciliation, API/CLI controls, and qualification against a real disposable Rei API process. The first Rei mapping imports note guidance as an instructions proposal and lifecycle changes as reviewable proposals; its title is retained as external display metadata. It publishes bounded progress/evidence summaries as Rei actions.

Exclude replacing Shikigami’s execution store, direct writes to Rei’s database, universal webhook ingestion, automatic Rei intention creation, automatic remote completion/reopening, and arbitrary bidirectional field mirroring. Completion remains an evidence-validated Shikigami command; a Rei completion is an external fact, not local acceptance. These exclusions preserve each domain’s lifecycle rather than pretending that arbitrary trackers satisfy checkpoint semantics.


## Decomposition Strategy


Three work streams produce independently testable behavior. EP-1 owns the provider-neutral binding, import and publication state machine, proved against deterministic strong and weak providers. EP-2 implements and qualifies the real Rei protocol, including its weaker write-retry capability. EP-3 exposes operator controls and proves the complete linked-objective user journey. A single ExecPlan would hide the producer/adapter interface and the distinct live-provider gate; splitting inbound and outbound engines would duplicate binding, mapping, conflict and receipt ownership.

Local ADRs 0022, 0026, 0047, 0067 and 0068 were inspected; [ADR 0069](../adr/0069-external-trackers-propose-objective-changes-and-retain-delivery-uncertainty.md) records the new authority boundary. Upstream `mori://shinzui/rei/okf/adrs/concepts/ADR-53` and `mori://shinzui/rei/okf/adrs/concepts/ADR-62` establish client failure channels and the v2 API. No generic external tracker framework is assumed.

Mori locates the owning project at `mori://shinzui/rei`. Source inspected at revision `515c6c0c6dd0527eb7184825d8bb75acdbde68ec`: project-relative `rei-api-contract/src/Rei/Intention/Api.hs`, `rei-api-contract/src/Rei/Intention/Wire.hs`, `rei-api/src/Rei/Intention/WriteHandler.hs` and `rei-api-client/src/Rei/Client.hs` (artifact-level source URIs pending). The current source serves `/api/v2`, including `GET /intentions/:id`, `GET /intentions/:id/actions`, `GET /actions/:id` and authenticated `POST /intentions/:id/actions`. `IntentionReadModelView` includes `streamPosition`, title, note guidance and status. `RecordActionRequest` has no client operation key; `recordActionH` generates a new action ID for each call. Reads use asynchronously updated projections. Source versions are evidence of a checkout, not proof of a published package or deployed endpoint. Shikigami’s existing `/v1/agent-actions` sink path and “no HTTP API” comments do not describe this contract.

Upstream decisions were discovered through Mori: `mori://shinzui/rei/okf/adrs/concepts/ADR-62` defines the v2 bounded API and scoped cursors; `mori://shinzui/rei/okf/adrs/concepts/ADR-53` defines the typed client and its separate domain-result and transport-failure channels. Read these records and the named sources again at implementation. Rei intentions and Shikigami objectives retain distinct identities and lifecycles.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|---|---|---|---|---|
| EP-1 | Persist provider-neutral bindings and synchronization receipts | [103-persist-provider-neutral-objective-tracker-bindings-and-synchronization-receipts.md](../plans/103-persist-provider-neutral-objective-tracker-bindings-and-synchronization-receipts.md) | MasterPlan 17 Complete | None | Complete |
| EP-2 | Adapt Rei intentions and actions | [104-adapt-rei-intentions-and-actions-to-objective-tracker-contracts.md](../plans/104-adapt-rei-intentions-and-actions-to-objective-tracker-contracts.md) | EP-1 | None | Complete |
| EP-3 | Expose and qualify external synchronization | [105-expose-and-qualify-recoverable-external-objective-synchronization.md](../plans/105-expose-and-qualify-recoverable-external-objective-synchronization.md) | EP-1, EP-2 | None | Not Started |

Whole-child dependencies require Complete. Status values are Not Started, In Progress, Complete and Cancelled. Planning can precede prerequisites; implementation cannot.


## Dependency Graph


MasterPlan 17 Complete → EP-1 Complete → EP-2 Complete → EP-3 Complete.

EP-1 consumes the delivered objective transaction and authorization owner. EP-2 requires EP-1’s capability contract and receipt state machine; EP-3 requires both the store and qualified production adapter. EP-2 milestone 1 first exercises one read and one action through the real Rei API and shared engine before adding further scenarios. EP-3’s final gate repeats this through the public Shikigami controls. No child depends on later adaptive coordination or recurring supervision plans. The real Rei process is required acceptance, not an optional fixture substitute; ordinary failure injection additionally uses a controlled proxy and deterministic providers.


## Integration Points


**Types, mapping and transaction ownership — EP-1 owns.** `shikigami-core/src/Shikigami/Objective/Tracker/Types.hs`, `Provider.hs`, `Command.hs`, `Store.hs` and `Catalog.hs` define the shared contracts. EP-2 implements `Provider`; EP-3 calls `Command`. Existing `Objective/Capability.hs` remains the only objective mutation owner. EP-1 adds the shared transaction seam, objective commit publication hook, generic configuration, migrations, domain registration and protected records. Public commands retain their original payloads and fingerprints; additive tracker provenance is runtime metadata.

**Field ownership — EP-1 owns, EP-2 maps.** Local criteria, assignments, owners, authority, pending effects, budgets and completion stay Shikigami-owned. A binding may designate external instructions as proposal input; local edits remain legal and create visible divergence against the last accepted import base. Initial linking never overwrites content. Cancellation is a separately authorized proposal; reopening a remote record cannot revive a terminal local objective. EP-3 presents before/after values and expected revisions. Outbound summaries never write inbound fields and carry source objective/revision/receipt markers to prevent feedback loops.

**Delivery and worker composition — EP-1 owns the dispatch state machine and semantic receipts; EP-2 owns process wiring.** The objective transaction enqueues one immutable publication per eligible binding and revision with a protected bounded payload. A dedicated integration-event destination routes through the existing outbox publisher; extend its dispatcher rather than starting a competing unfiltered publisher. EP-2 implements `shikigami-workers/src/Shikigami/Objective/Tracker/Worker.hs`, routing in `Flow/SinkOutbox/Publisher.hs`, polling and `Workers/Config.hs` composition. EP-1 implements those decisions in `Tracker/Dispatch.hs`, exercised by deterministic providers; EP-2 injects Rei into that same executor. Route both the publish callback and the post-success reconciliation callback by destination. The current publisher calls legacy sink reconciliation for every successful row, including what will become quarantined tracker rows; EP-2 must prove mixed-batch isolation. A transport row consumed into quarantine is not a delivered receipt. Legacy sink messages continue through their existing handler.

**Rei adapter — EP-2 owns.** `shikigami-core/src/Shikigami/Objective/Tracker/Rei.hs` wraps the typed client from `mori://shinzui/rei/packages/rei-api-client` without importing Rei core or server. Manager/token lifetimes stay at process boundaries. The current append-action API has no idempotency key, so unknown sends are quarantined and reconciled without automatic resend. HTTP/CLI control hosts reuse this adapter; no shelling out to mina or rei in production.

**Reconciliation evidence — EP-1 owns the command and receipt schema; EP-2 supplies remote verification; EP-3 exposes it.** A typed `attest-delivery` command identifies the publication, attempt, exact remote receipt, retained verified payload digest, expected receipt revision and a bounded reason. It requires explicit operator reconciliation permission and records the authenticated actor. Attestation can establish attribution only after a provider read verifies resource and payload; it cannot invent a receipt, prove non-application or authorize resend. Inspection distinguishes provider proof from operator-attested delivery. Unknown outcomes remain visible when evidence is insufficient. Suppressing future publication never rewrites an Unknown receipt as unsent.

**Public controls and qualification — EP-3 owns.** Add authenticated `/objectives/:id/trackers` resources, operator CLI, documentation, `tests/objective-trackers/run.sh` and qualification fixtures. EP-2 owns the real Rei disposable-server test launcher reused by EP-3. Neither harness may silently select the user’s default Rei server or credentials. Multi-provider neutrality is proven with a second deterministic provider, while Rei interoperability is proved with its actual server.

**Compatibility and durable context.** EP-1 owns protocol versions and keeps readers for retained work; EP-2 pins adapter capability revisions; EP-3 documents migration and failure recovery. Update ADR 0069 with implementation evidence, and distill any changed decisions at completion. No child weakens MasterPlan 17 or claims exactly-once delivery from a local receipt alone.


## Progress

2026-11-02: EP-1 and EP-2 are Complete. [Plan 103 evidence](../evidence/plan-103/qualification.json) accepts the provider-neutral engine; [plan 104 evidence](../evidence/plan-104/qualification.json) accepts the pinned real Rei adapter, supervised polling, mixed outbox routing, 17 live fault cases, complete build, four-package regression and 177 native conformance checks. Rei's weak append capability retains Unknown without resend. EP-3 is the next eligible child and owns public controls plus full served interoperability. MasterPlan 17's independent no-Rei acceptance remains intact.


## Surprises & Discoveries

2026-11-02: EP-1 required separate objective/tracker projection ownership on the same ObjectiveLifecycle source; both group fences and callbacks now share one append transaction. Connection incarnation labels alone cannot detect endpoint/account edits, so retained target fingerprints prevent redirection and configuration permits historical incarnations for read-only recovery. ADR 0069 records these shared constraints.


The existing ReiAction sink claims Rei has no HTTP API and posts to `/v1/agent-actions`; Mori-discovered source now exposes a v2 API. The current action handler generates a fresh remote action ID on every request, while its request type has no idempotency key. This prevents safe automatic replay after an ambiguous send and determines EP-2’s quarantine requirement. The real disposable-server adapter qualification now passes, including lost responses and fresh dispatcher processes. Public-entrypoint qualification remains EP-3’s gate.


## Decision Log


- Decision: Keep authoritative execution state local and use external changes as explicit proposals.
  Rationale: External planning lifecycles cannot substitute for ownership fencing, accepted execution identity or integrated acceptance.
  Date: 2026-10-29

- Decision: Use three sequential children with Rei as the first concrete adapter and a second deterministic provider for neutrality tests.
  Rationale: Separate the shared state machine, real protocol evidence and supported user entry points without duplicating ownership.
  Date: 2026-10-29

- Decision: Qualify the actual weaker Rei retry contract, with unknown writes quarantined and no automatic remote lifecycle transitions.
  Rationale: Current action creation generates IDs server-side and cannot promise deduplication across lost acknowledgements; remote completion has its own domain policy.
  Date: 2026-10-29


- Decision: Keep delivery execution in EP-1 and make evidence-based attestation a shared command consumed by EP-2 and EP-3.
  Rationale: Deterministic conformance must exercise the production state machine, and a real lost response must have a supported recovery path without inventing proof or retrying an append. Destination routing includes post-success reconciliation as well as dispatch.
  Date: 2026-10-29


## Outcomes & Retrospective


(To be filled during and after implementation; no runtime acceptance is claimed.)


## Revision Notes

2026-10-29: Reviewed all three children against the working tree and the Mori-located Rei source. Retained decomposition and whole-plan prerequisites; clarified shared execution ownership, mixed-outbox routing and audited delivery attestation, cascading acceptance to plans 103–105 and ADR 0069. No implementation or live interoperability is claimed.

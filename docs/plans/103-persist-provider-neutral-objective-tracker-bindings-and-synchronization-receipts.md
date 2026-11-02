---
id: 103
slug: persist-provider-neutral-objective-tracker-bindings-and-synchronization-receipts
title: "Persist provider-neutral objective tracker bindings and synchronization receipts"
kind: exec-plan
created_at: 2026-10-29T13:15:58Z
intention: "intention_01m63wqywcefjaq53cvzhtvqcv"
master_plan: "docs/masterplans/18-integrate-durable-objectives-with-external-trackers-through-provider-neutral-contracts-and-rei.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-29T13:15:58Z
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
      note: "Begin binding/provider contracts against delivered objective owner"
---

# Persist provider-neutral objective tracker bindings and synchronization receipts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture


An objective can retain explicit links to external planning records, stage external edits for an authorized decision, and atomically record outbound progress without making a network call inside the objective transaction. A developer can prove that concurrent local edits are not overwritten, identical inbound observations do not duplicate commands, and uncertain outbound effects remain visible. This is EP-1 of the parent MasterPlan; no production Rei call or public tracker route exists until later children.


## Progress


- [x] Milestone 1 (2026-11-02): versioned provider capabilities, nominal bounded coordinates, protected snapshots, explicit binding/field policy and disabled-by-default connection configuration compile. All 21 new pure mapping/authority cases pass; the full core run exposed two configuration inventories, now updated for the new setting.
- [x] Milestone 2 (2026-11-02): real objective/import decisions, protected receipts and immutable publications share checked append transactions. All 11 initial PostgreSQL cases pass, including rollback, receipt replay, concurrent resource admission, local divergence/rebase and corruption refusal. The broader run passes 660 core and 529 PostgreSQL cases.
- [x] Milestone 3 (2026-11-02): final qualification passes 22 tracker unit and 34 PostgreSQL cases, complete build, migration isolation and convention checks. The committed-candidate native gate passes 177 conformance checks, 11 additive findings and one understood fold-surface warning; replay is neutral. [Acceptance evidence](../evidence/plan-103/qualification.json) retains the exact boundary.

Implementation baseline `6d816d5ed49292ff48f985e066d787a1ac146a41`; MasterPlan 17 is Complete. All three milestones are Complete. The delivered domain layout is `domain/shikigami/objective.keiro`; the new tracker member is `domain/shikigami/objective-tracker.keiro`. Network reads precede a fresh admission and checked commit; publication projection and the objective projection are fenced together. The shared dispatcher passes initial strong/weak provider qualification, including quarantine, safe server-key replay, claim loss, revocation, ordering and audited attestation; The four-package regression run passes 660 core, 533 PostgreSQL, 103 server and 280 worker cases. Final focused qualification passes 22 tracker unit cases and 34 PostgreSQL cases, including a real child-process exit/reconnect, checkpoint invalidation, current revocation, expired keys, cross-binding isolation and exact late acknowledgement. The complete build, convention checks and migration isolation pass. The native gate passes at candidate `9b34e4e5`: 177 conformance checks, no breaking findings and neutral replay. The additive technical event leaves old objective folding and registers unchanged; regenerated fold fingerprints invalidate native snapshots automatically.


## Surprises & Discoveries

A connection incarnation label alone cannot detect an operator changing its endpoint or account in place. Bindings and publications additionally retain a target digest; reads, sends and reconciliation compare it with the current configuration. Old and new incarnations may coexist in configuration so old evidence can still be reconciled.


The checked catalog requires one writer per target. Tracker tables therefore have their own `objective_tracker_writer` projection and preserved group, sourced from the existing ObjectiveLifecycle aggregate. Live command composition merges both generated projection sets before the checked append, so both group fences and both handlers run in one transaction. A technical `RecordTrackerTransition` event retains tracker changes without advancing the semantic objective revision. No workflow journal step changes.

A source advance that changes only display metadata must retain a reviewable replacement for an already pending instructions proposal; merely superseding it would lose unapplied guidance. Observation diagnostics separately retain older positions and equal-position equivocation. Remote outages retain diagnostics without fabricating a new snapshot.


## Decision Log

- Decision: Keep separate objective/tracker projection ownership on the same aggregate source and use an actor-pinned callback in the existing objective command owner for proposal application.
  Rationale: Keiro rejects multiple independent owners for a target, while both group fences and both writes must share the accepted objective transaction. Existing public command payloads/fingerprints remain unchanged.
  Date: 2026-11-02


- Decision: Default imports to proposals and use local exact-revision commands for application.
  Rationale: External identity and source version prove neither local permission nor integrated completion.
  Date: 2026-10-29

- Decision: Declare remote retry capabilities and retain unknown outcomes independently of the transport queue.
  Rationale: A second provider must not inherit guarantees that only a stronger provider implements.
  Date: 2026-10-29


## Outcomes & Retrospective


Completed 2026-11-02. The provider-neutral engine retains explicit bindings and proposals, authenticated stable command receipts, atomic objective/publication commits, immutable attempts and independent delivery truth. Deterministic strong and weak providers exercise the same production executor. A real process exit proves receipt/publication recovery without a provider call; current permission, stale bases, checkpoint invalidation, rollback, unknown ordering, endpoint/account replacement and evidence-based attestation are qualified.

[Qualification](../evidence/plan-103/qualification.json) records the full regression run, final 22/34 focused cases and the 177-check native gate. ADR 0069 records projection ownership, target fingerprints and uncertainty semantics. There was no new qualifying friction and no entry logged under this child. Production Rei and public/operator controls remain owned by plans 104 and 105; this completion does not claim those gates.


## Context and Orientation


This is a follow-up to [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md), which must be Complete before implementation starts. Its planned `shikigami-core/src/Shikigami/Objective/Types.hs`, `Command.hs`, `Capability.hs`, `Store.hs`, `Catalog.hs`, `Acceptance.hs` and `Association.hs` own objective identity, versioned commands, authority, receipts and accepted execution links. At planning baseline `1bfe303ab9f6756eecbfc3bca254e9a9492acdad` those objective modules are planned, not implemented. Reconcile their delivered interfaces before editing; do not implement a parallel objective store. A tracker binding links one objective to one resource in an operator-configured external connection. A proposal is retained external input awaiting an authorized local decision. An observation is what the external read actually returned, not proof that no newer remote write exists. A delivery intent is immutable outbound work; a receipt records its known outcome. An unknown outcome means the remote write may have happened.

The seven-package boundaries remain: domain and provider interfaces in `shikigami-core`, HTTP contracts in `shikigami-api`, handlers/operator commands in `shikigami-server`, process composition and loops in `shikigami-workers`, typed public client in `shikigami-client`, SQL in `shikigami-migrations/sql-migrations/manifest`. Existing reference files are `shikigami-core/src/Shikigami/Sink/Intent.hs` (atomic outbox enqueue), `Sink/Delivery.hs` (delivery ledger), `Sink/ReiAction.hs` (legacy sink), `shikigami-workers/src/Shikigami/Flow/SinkOutbox/Publisher.hs` (the shared outbox dispatcher), `shikigami-core/src/Shikigami/Runtime.hs` (catalog registration), and `domain/shikigami.keiro-workspace` (checked declarations). Register new modules and test groups in their Cabal files and suite `Main.hs`; never edit generated modules by hand.

Relevant decisions: [ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) separates enqueue from delivery; [ADR 0026](../adr/0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md) keeps credentials opaque; [ADR 0047](../adr/0047-public-api-authentication-is-a-verifier-at-the-vertical-mount.md) separates authentication and resource authorization; [ADR 0067](../adr/0067-objective-checkpoints-use-assignment-scoped-preconditions.md) makes instruction changes invalidate assignments; [ADR 0068](../adr/0068-objective-creation-has-authority-before-association.md) preserves creation without external association. [ADR 0069](../adr/0069-external-trackers-propose-objective-changes-and-retain-delivery-uncertainty.md) fixes this initiative’s authority and uncertainty boundaries. Follow [workflow versioning](../workflow-versioning.md) if a workflow body changes; this design uses command transactions and background delivery and requires no new agent journal step.


## Plan of Work


### Milestone 1 — Binding and provider contracts

`shikigami-core/src/Shikigami/Objective/Tracker/Types.hs` owns versioned `TrackerConnectionId`, `TrackerBindingId`, binding revision, connection incarnation, external resource identity, mapping revision, `TrackerObservation`, `ImportProposal`, `PublicationIntent` and `PublicationReceipt`. A connection incarnation identifies one configured remote account/installation; replacing the server or account creates a new incarnation rather than reusing source versions. Credentials never enter these values. One external resource has at most one active binding per connection incarnation; one objective may have several bindings, but at most one designated inbound authority for each mapped field. Existing `LinkExternal` references stay passive until explicit binding admission validates the connection, resource and permissions.

`Tracker/Provider.hs` owns a closed provider interface: describe the immutable capability revision, read one bound resource, publish one retained intent, and reconcile one unknown publication. Reads return a bounded snapshot plus source version/digest or a typed missing/denied/unavailable result. Publish returns acknowledged with remote receipt, definitely-not-sent, definitive rejection, conflict, or unknown. Reconciliation returns proved-applied, proved-not-applied or still-unknown. Capability declarations distinguish ordered observations, remote conditional writes, server idempotency keys and receipt lookup; advertising one requires a conformance test. Expired keys or unavailable lookup never justify a resend. No provider changes objective state directly.

`Tracker/Command.hs` and `Tracker/Store.hs` own binding admission, observation retention, proposal decisions, durable delivery states and reconciliation. Commands use authenticated actors and stable operation keys. Applying a proposal calls the existing objective command owner with exact expected objective revision and current permission; objective change, decision receipt and resulting publication intents commit together through a supported shared transaction interface. A later implementation must expose that interface within the objective owner if necessary, never nest independently committing transactions or write its tables from an adapter.

Add generic configuration under `shikigami-core/src/Shikigami/App/Config.hs` and `App/Config/Load.hs`: disabled by default, named connections, immutable provider contract revision, endpoint/account identity, opaque credential reference, bounded polling and publication policy. A passive external link grants no network access. An objective owner explicitly admits a binding under connection-use policy; external account identity never becomes an objective principal. Retain a binding revision on pause, mapping changes and detach. Do not permit binding replacement while unresolved outbound attempts could target the old resource; keep the old binding in reconciliation-only mode instead.

The mapping policy identifies fields, directions and source authority. Local execution state is never imported. For first binding, retain the remote baseline and local objective revision without mutation. Each later observation creates at most one proposal per changed mapped value/version, with the original local base, remote position and digest. A provider lacking ordered revisions cannot enable automatic import. This initial release has no automatic import for any provider: applying a proposal always requires an authenticated authorized command. Completion requests can only propose acceptance; the normal evidence contract decides it. External deletion, access loss or reopening never cancels, deletes or reopens a local objective implicitly. Add `shikigami-core/test/Shikigami/ObjectiveTrackerSpec.hs`; milestone acceptance includes wrong connection/resource scope, unauthorized bind, unsupported mapping, version/digest mismatch and no-authority-from-link cases.

### Milestone 2 — Atomic decisions and publications

Add `domain/shikigami/objective-tracker.keiro`, generated catalog members and the additive `objective-tracker-sync` migration. Store bindings, versioned observations, protected proposal payloads, command receipts, publication payloads, attempts and independent delivery receipts. EP-1 owns registration in `domain/shikigami.keiro-workspace` and `Runtime.hs`. Objective state and its publication intent must share the objective command’s append/projection transaction, including commands from tools and checkpoint providers; do not rely on an API wrapper or a post-commit callback. Existing command receipts must not be changed to include new fields. Emit only allowlisted progress/evidence/status summaries for revisions whose relevant exported facts changed; never export hidden instructions, credentials, unrestricted artifacts or model context.

The durable key for publication includes binding identity/revision, objective revision, event kind and format. Store its complete immutable request before dispatch, even if the mapping later changes. Local objective completion remains committed when external delivery fails. Binding pause/detach suppresses fresh sends and fresh imports but retains accepted receipts and unknown reconciliation. Authorization checks at dispatch use current connection and objective export permission; a revoked grant cannot send protected content from a previously queued payload.

Apply/reject commands for proposals include a stable operation key, binding revision, proposal identity and exact expected objective revision. Under one transaction recheck current permissions, binding, the latest retained remote observation and the unchanged local import base. Refuse stale proposals rather than silently replacing their expected revision. A changed remote observation supersedes an unapplied proposal. An operator resolves a conflict by an explicit new decision retaining both source observations and the new local base. Receipt lookup precedes revision validation for identical authorized retries. Tests in `shikigami-core/test-postgres/Shikigami/ObjectiveTrackerStoreSpec.hs` prove crash after commit, rollback before commit, duplicate observation, stale local edit and revocation races, using the real objective command owner.

### Milestone 3 — Recovery and provider conformance

Implement `shikigami-core/src/Shikigami/Objective/Tracker/Dispatch.hs` as the shared provider-injected executor for attempt admission, dispatch, outcome persistence and reconciliation. The deterministic providers below call this production executor; plan 104 supplies process scheduling and the Rei implementation without reimplementing its retry rules.

Add `Tracker/Conformance.hs` in test support or the existing test tree: run the same contract cases against two deterministic providers, one with server-key deduplication and one with append-only non-idempotent writes. Define the application receipt states `Pending`, `Attempting`, `Delivered`, `Rejected`, `Conflict`, `Unknown` and `Suppressed`. Before network dispatch persist the exact attempt and binding fence; an expired attempt claim becomes Unknown unless a remote idempotency guarantee permits the original request to be safely replayed. A local lease alone never proves a request was not sent. Persist delivered remote ID and digest before transport acknowledgement. Crash after remote acknowledgement but before receipt persistence must remain recoverable as Unknown, never Pending.

Unknown work is quarantined from automatic transport retry, retaining its payload and attempt. Returning transport success to retire a quarantined outbox row only acknowledges quarantine; the independent delivery receipt remains Unknown and public inspection must show that. For ordered non-idempotent publication, an unknown earlier attempt blocks later sends for that binding; other bindings continue. Proven-applied reconciliation retains the remote receipt. Proven-not-applied allows a new actual attempt under the original logical operation only if no earlier request can still arrive; an empty eventually consistent read is insufficient. Otherwise remain Unknown. Operator acknowledgement may suppress further publication with an audited reason but cannot claim delivery or non-application. Do not introduce a force-resend control for uncertain effects. Suppressing future publication is separate from outcome certainty: an existing Unknown receipt stays Unknown and retains the ordering barrier until reconciled.

Define `attest-delivery` in the closed command sum now, rather than leaving plan 104’s recovery path to an ad hoc operator procedure. Its immutable request includes publication and attempt IDs, connection incarnation, exact remote receipt ID, retained provider-verification evidence and payload digest, expected receipt revision and bounded reason. Reconciliation first fetches and retains remote resource/payload verification outside the transaction. The attestation transaction rechecks that evidence against the original request and current receipt, authenticates the actor with explicit operator reconciliation permission, and atomically retains the attestation and Delivered receipt with evidence kind `operator-attested`. Provider-proved delivery has a distinct evidence kind. A marker, free-text reason or operator role alone is insufficient; attestation cannot assert non-application or authorize retry. Test unauthorized actors, wrong resource/digest/incarnation, stale receipt revisions, absent verification, conflicting reuse of an operation key and identical replay after acknowledgement loss.

Ordered source positions must never decrease within a connection incarnation. Equal position with different bytes is a visible conflict; lower positions are ignored with retained diagnostics. Advances with identical mapped fields update the observation watermark without issuing another objective command. Our outbound action echoes do not create new import proposals. Polling retains bounded work and resumes by binding; it does not assume webhook delivery or a global monotone feed. Acceptance includes rebinding with a stale worker, projection lag, pause/revocation, unknown blocked ordering, cross-binding isolation, and unchanged behavior with tracking disabled.


## Concrete Steps


Run from the Shikigami repository root. Save `git rev-parse HEAD` as the implementation baseline before edits. Use the development environment and selected dependency cohort consistently; if a local project is needed, follow `docs/dependency-cohort.md` and record the exact project and build directory in acceptance evidence.

```bash
nix develop --no-write-lock-file
cabal build all
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-server-test shikigami-workers-test --test-show-details=direct --test-options='--num-threads=1'
```

For declared schema changes create an additive migration, register it in the manifest and regenerate:

```bash
just new-migration objective-tracker-sync
cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace --out shikigami-core/src
just migration-schema-isolation
```

Only the child owning a new migration runs `new-migration`; later children create separately named additive migrations if needed. At a coherent committed candidate run:

```bash
just keiro-gate IMPLEMENTATION_BASELINE
git diff --check
```

Replace `IMPLEMENTATION_BASELINE` with the saved revision. Expected results are zero exit codes, registered new tests, and no unexplained breaking compatibility findings. No passing result is claimed at planning time. Use Mori for dependency source discovery and verify authoritative registry releases and upstream tags before selecting new bounds or pins.

Every implementation commit uses Conventional Commits and these trailers:

```text
MasterPlan: docs/masterplans/18-integrate-durable-objectives-with-external-trackers-through-provider-neutral-contracts-and-rei.md
ExecPlan: docs/plans/103-persist-provider-neutral-objective-tracker-bindings-and-synchronization-receipts.md
Intention: intention_01m63wqywcefjaq53cvzhtvqcv
```


## Validation and Acceptance


The new pure and PostgreSQL suites must demonstrate one objective receipt and publication intent per logical operation; no automatic completion from external status; exact-revision refusal on local/external conflict; no secret payload export; strong-provider replay convergence and weak-provider uncertainty without duplicate dispatch. Applying an instructions proposal must invalidate existing worker checkpoints through ADR 0067. Pass the existing objective and worker-session suites as regression coverage. This slice is accepted with deterministic providers; real Rei interoperability belongs to plan 104 and is not claimed here.


## Idempotence and Recovery


Keep durable protocol readers and apply additive migrations. Retain binding generations, observation bases, attempts and receipts beyond workflow collection; initially do not compact them. Pause publication without deleting queued payloads or unknown evidence. Never reset an external source position after restore without a new connection incarnation and explicit reconciliation. Back up objective, tracker, outbox and receipt state together. No network call may hold the objective transaction open.


## Interfaces and Dependencies


Hard prerequisite: [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md) Complete. This plan owns the contracts and transaction seams described above; [plan 104](104-adapt-rei-intentions-and-actions-to-objective-tracker-contracts.md) supplies the production provider, and [plan 105](105-expose-and-qualify-recoverable-external-objective-synchronization.md) supplies public commands. The existing Keiro outbox and checked catalog are located through `mori://shinzui/keiro`; use public APIs as demonstrated by `Sink/Intent.hs`, never framework-table SQL. No Rei package dependency is introduced here.


## Revision Notes

2026-10-29: MasterPlan 18 review clarified shared dispatch ownership and the supported evidence-based attestation path, including negative and replay acceptance. The whole-child prerequisites and planning-only status remain unchanged.

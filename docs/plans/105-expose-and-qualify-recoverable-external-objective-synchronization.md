---
id: 105
slug: expose-and-qualify-recoverable-external-objective-synchronization
title: "Expose and qualify recoverable external objective synchronization"
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
      at: 2026-11-02T12:39:15Z
      mode: "implement"
      note: "Implement authenticated tracker controls and full served Rei qualification after both prerequisite children are accepted."
---

# Expose and qualify recoverable external objective synchronization

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture


A user can link an objective to an existing Rei intention, inspect what will be shared, review and apply external instruction proposals, and see or reconcile delivery failures through authenticated API and CLI controls. A reproducible two-service runner proves that local progress continues through Rei outages and that external completion cannot bypass local evidence requirements.


## Progress


- [x] Milestone 1 (2026-11-02): authenticated routes, typed client and configured-operator CLI use the shared owner. Two served HTTP cases and 40 tracker PostgreSQL cases pass, including durable queued reads, revocation, typed replay/conflict responses, scoped Relay pages beyond 100 retained records and explicitly granted caller reconciliation.
- [x] Milestone 2 (2026-11-02): real server/worker/CLI qualification passes binding, proposals/application/rejection, independent lifecycle, concurrent edits, outage recovery, both Shikigami process restarts, lost response and exact attestation without a second POST. Expanded cases pass queued caller revocation with zero provider reads, pending-export suppression, missing remote access with retained evidence and identical remote ID in another connection/incarnation. Native checkpoint conflict is additionally covered by the shared production-provider case; the final runner repeats it.
- [x] Milestone 3 (2026-11-02): user/operations docs, generated OpenAPI, 17-page profile validation, dependency closure, ADR distillation and final compatibility gates pass. Candidate `bfeb1565` builds completely and passes 177 native conformance checks with no findings and neutral replay.

Implementation baseline `6881da43`. Both prerequisite children are Complete with retained native and real-server evidence. The first two milestones pass. Network-request admission uses a preserved control queue in the existing command target: local commands remain synchronous and idempotent; Bind, Observe, Reconcile and Verify requests are durably admitted before workers perform provider reads. Additive migration 0037 owns its columns; existing receipts and catalog membership remain unchanged.


## Surprises & Discoveries


Rei wire status strings are lowercase while its typed Haskell constructors are capitalized; production uses the typed client, and the Python qualification compares the actual lowercase wire value. Rei allows reopening a completed intention but refuses reopening an abandoned intention with `intention-is-abandoned`; the fixture exercises abandonment after its append scenarios rather than inventing an unsupported lifecycle command.

The inherited public objective view deliberately omits instructions. Tracker binding inspection supplies an explicitly bounded local preview and full-document digest so proposal review can compare before/after without changing that original metadata contract.


## Decision Log


- Decision: Show local execution status, external observed status and synchronization state separately.
  Rationale: A completed objective can have an undelivered summary, and a completed Rei intention can lack valid local completion evidence.
  Date: 2026-10-29


- Decision: Store queued provider-read controls alongside receipts in the existing preserved tracker command target, sharing its operation primary key.
  Rationale: Native compatibility treats rebuild-group membership changes as breaking. Additive columns retain catalog identity and enforce one operation namespace without a new writer or read fence.
  Date: 2026-11-02

## Outcomes & Retrospective


Implementation and real served qualification are complete; complete build, final 40 tracker PostgreSQL/two tracker HTTP cases, no-Rei continuity, Hurl, schema and documentation gates pass. The final code candidate `bfeb1565` passes all 177 native conformance checks with no findings and neutral replay. [Retained qualification](../evidence/plan-105/qualification.json) records exact scope and transcripts. No friction entry was needed for routine implementation debugging. The concrete Rei source pin remains the selected compatibility tuple, not a claim of a Hackage release or a cold Nix build.


## Context and Orientation


This is a follow-up to [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md), which must be Complete before implementation starts. Its planned `shikigami-core/src/Shikigami/Objective/Types.hs`, `Command.hs`, `Capability.hs`, `Store.hs`, `Catalog.hs`, `Acceptance.hs` and `Association.hs` own objective identity, versioned commands, authority, receipts and accepted execution links. At planning baseline `1bfe303ab9f6756eecbfc3bca254e9a9492acdad` those objective modules are planned, not implemented. Reconcile their delivered interfaces before editing; do not implement a parallel objective store. A tracker binding links one objective to one resource in an operator-configured external connection. A proposal is retained external input awaiting an authorized local decision. An observation is what the external read actually returned, not proof that no newer remote write exists. A delivery intent is immutable outbound work; a receipt records its known outcome. An unknown outcome means the remote write may have happened.

The seven-package boundaries remain: domain and provider interfaces in `shikigami-core`, HTTP contracts in `shikigami-api`, handlers/operator commands in `shikigami-server`, process composition and loops in `shikigami-workers`, typed public client in `shikigami-client`, SQL in `shikigami-migrations/sql-migrations/manifest`. Existing reference files are `shikigami-core/src/Shikigami/Sink/Intent.hs` (atomic outbox enqueue), `Sink/Delivery.hs` (delivery ledger), `Sink/ReiAction.hs` (legacy sink), `shikigami-workers/src/Shikigami/Flow/SinkOutbox/Publisher.hs` (the shared outbox dispatcher), `shikigami-core/src/Shikigami/Runtime.hs` (catalog registration), and `domain/shikigami.keiro-workspace` (checked declarations). Register new modules and test groups in their Cabal files and suite `Main.hs`; never edit generated modules by hand.

Relevant decisions: [ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) separates enqueue from delivery; [ADR 0026](../adr/0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md) keeps credentials opaque; [ADR 0047](../adr/0047-public-api-authentication-is-a-verifier-at-the-vertical-mount.md) separates authentication and resource authorization; [ADR 0067](../adr/0067-objective-checkpoints-use-assignment-scoped-preconditions.md) makes instruction changes invalidate assignments; [ADR 0068](../adr/0068-objective-creation-has-authority-before-association.md) preserves creation without external association. [ADR 0069](../adr/0069-external-trackers-propose-objective-changes-and-retain-delivery-uncertainty.md) fixes this initiative’s authority and uncertainty boundaries. Follow [workflow versioning](../workflow-versioning.md) if a workflow body changes; this design uses command transactions and background delivery and requires no new agent journal step.

Mori locates the owning project at `mori://shinzui/rei`. Source qualified at revision `c109222db550537ec998ecc6fc1866cc7a35e29a`: project-relative `rei-api-contract/src/Rei/Intention/Api.hs`, `rei-api-contract/src/Rei/Intention/Wire.hs`, `rei-api/src/Rei/Intention/WriteHandler.hs` and `rei-api-client/src/Rei/Client.hs` (artifact-level source URIs pending). The current source serves `/api/v2`, including `GET /intentions/:id`, `GET /intentions/:id/actions`, `GET /actions/:id` and authenticated `POST /intentions/:id/actions`. `IntentionReadModelView` includes `streamPosition`, title, note guidance and status. `RecordActionRequest` has no client operation key; `recordActionH` generates a new action ID for each call. Reads use asynchronously updated projections. Source versions are evidence of a checkout, not proof of a published package or deployed endpoint. Shikigami’s existing `/v1/agent-actions` sink path and “no HTTP API” comments do not describe this contract.

Upstream decisions were discovered through Mori: `mori://shinzui/rei/okf/adrs/concepts/ADR-62` defines the v2 bounded API and scoped cursors; `mori://shinzui/rei/okf/adrs/concepts/ADR-53` defines the typed client and its separate domain-result and transport-failure channels. Read these records and the named sources again at implementation. Rei intentions and Shikigami objectives retain distinct identities and lifecycles.

`shikigami-core/src/Shikigami/Objective/Tracker/Types.hs` owns versioned `TrackerConnectionId`, `TrackerBindingId`, binding revision, connection incarnation, external resource identity, mapping revision, `TrackerObservation`, `ImportProposal`, `PublicationIntent` and `PublicationReceipt`. A connection incarnation identifies one configured remote account/installation; replacing the server or account creates a new incarnation rather than reusing source versions. Credentials never enter these values. One external resource has at most one active binding per connection incarnation; one objective may have several bindings, but at most one designated inbound authority for each mapped field. Existing `LinkExternal` references stay passive until explicit binding admission validates the connection, resource and permissions.

`Tracker/Provider.hs` owns a closed provider interface: describe the immutable capability revision, read one bound resource, publish one retained intent, and reconcile one unknown publication. Reads return a bounded snapshot plus source version/digest or a typed missing/denied/unavailable result. Publish returns acknowledged with remote receipt, definitely-not-sent, definitive rejection, conflict, or unknown. Reconciliation returns proved-applied, proved-not-applied or still-unknown. Capability declarations distinguish ordered observations, remote conditional writes, server idempotency keys and receipt lookup; advertising one requires a conformance test. Expired keys or unavailable lookup never justify a resend. No provider changes objective state directly.

`Tracker/Command.hs` and `Tracker/Store.hs` own binding admission, observation retention, proposal decisions, durable delivery states and reconciliation. Commands use authenticated actors and stable operation keys. Applying a proposal calls the existing objective command owner with exact expected objective revision and current permission; objective change, decision receipt and resulting publication intents commit together through a supported shared transaction interface. A later implementation must expose that interface within the objective owner if necessary, never nest independently committing transactions or write its tables from an adapter.


## Plan of Work


### Milestone 1 — Supported API and CLI controls

Create `shikigami-api/src/Shikigami/Objective/Tracker/Api.hs`, `shikigami-server/src/Shikigami/Objective/Tracker/Handler.hs` and `shikigami-server/src/Shikigami/Server/Command/ObjectiveTrackers.hs`. Extend the objective vertical from plan 100, `shikigami-client/src/Shikigami/Client.hs`, `Server/App.hs` and `Server/Command.hs`. Mount under existing objective authentication and resource checks. Use the project’s typed response/error and Relay pagination conventions; defaults are 20 and maximum 100, command bodies at most 1 MiB, protected summary replies at most 16 KiB.

Expose `/objectives/:id/trackers` for admitted bindings, binding inspection and commands. Nested paged observations, proposals and deliveries expose independent histories. Closed commands include bind, pause, resume, detach, observe, apply-proposal, reject-proposal, resolve-conflict, reconcile-delivery and attest-delivery, each with stable operation key and expected binding/local revisions as applicable. Bind requires explicit connection, resource ID and reviewed field policy; it never treats a passive link as authorization. Any requested network observation or reconciliation is queued through the durable owner, so HTTP timeouts do not silently repeat side effects. Return 202 for newly queued work, 200 for retained operation status/replay, 409 for stale versions, and bounded 403/404 errors without leaking inaccessible resources. Both application commands and connection-use policy must authorize the caller. Missing or unavailable providers are explicit 503 responses, not a fallback to legacy sinks.

Add `shikigami objectives trackers bind|inspect|proposals|deliveries|command` as adapters over the same owner, using the configured operator identity. A command file carries the closed command request; no flag impersonates an agent or external user. `inspect` displays local objective revision/status, external observed position/status, last successful observation, pending/conflicted proposal count and delivery states separately. Expose `attest-delivery` through the same command-file path with publication/attempt identity, expected receipt revision, exact remote receipt, retained verification reference/digest and bounded reason. Require explicit operator reconciliation permission in addition to resource access. Display provider-proved and operator-attested deliveries separately; refuse unverified, mismatched or stale evidence and test identical command replay. Automated reconciliation that finds only a matching marker must remain Unknown until this authorized decision succeeds. Provide before/after previews and evidence references for proposal decisions; external text is untrusted task input, never an instruction to change runtime authority. Never expose credentials or remote internal error bodies. Test anonymous access, another objective owner, revoked membership, connection-use denial, wrong incarnation and stale command replay.

### Milestone 2 — Real linked-objective qualification

Add `tests/objective-trackers/run.sh` and fixtures under `fixtures/qualification/objective-trackers/`, reusing plan 104’s disposable Rei launcher and the isolation approach in `tests/hurl/run.sh`. Honor `SHIKIGAMI_CABAL_PROJECT`; never discover a production Rei endpoint from default environment. Exercise the served Shikigami API, CLI and actual workers against real stores and the real Rei server. The second deterministic provider remains a separate neutrality test, not a substitute for this run.

Create an ordinary objective through the native path and a Rei intention as explicit test setup; bind them without overwriting either. Record progress and observe exactly one attributable Rei action and its local Delivered receipt. Change Rei note guidance and poll until its source position is visible. Show a proposal while local instructions remain unchanged; explicitly apply it at the current local revision, then prove an old worker checkpoint conflicts. Race a local instruction edit against another proposal: expect Conflict and retained evidence, not last-write-wins. Reject a proposal and verify repeated observations do not repropose the identical rejected version. An own outbound action changes Rei stream position without producing an import loop.

Complete the Rei intention and verify the objective stays open until its independent integrated acceptance succeeds. Cancel or reopen externally and verify only an explicit authorized local decision affects work. Stop Rei, commit more local progress, restart both services and recover pending publications. Drop a real action response after commit and prove quarantine, no second POST and eventual evidence-based reconciliation through the public controls: first retain Unknown when a marker is insufficient, then submit a verified receipt attestation as the authorized operator and recover the same Delivered receipt after losing that command’s acknowledgement; test revocation before dispatch and a paused binding with accepted outstanding facts. Delete or lose access to the remote record without deleting local evidence. Bind another connection with the same textual remote ID and prove incarnation isolation. Finish by running MasterPlan 17’s no-Rei qualification with tracking disabled.

The runner emits objective/binding IDs, source positions, receipt IDs, counts of actual action POSTs and the final independent statuses. Required facts are: applied instructions invalidate old checkpoints; stale proposals conflict; external completion does not complete locally; lost acknowledgement produces Unknown with one remote action; successful reconciliation retains the original publication; unlinked/no-Rei work passes unchanged. No real repository fence qualification is claimed.

### Milestone 3 — Documentation and closure

Write `docs/user/objective-trackers.md` and `docs/operations/objective-trackers.md`, extend plan 104’s Rei-specific operations page, and update `docs/user/README.md`, `docs/operations/operator-cli.md`, `docs/operations/configuration.md` and `docs/architecture/shikigami-domain-inventory.md` with actual delivered behavior. Maintain profiled user-document metadata/index/log through existing tooling. Explain explicit field ownership, initial linking, proposal conflicts, connection identity, legacy ReiAction isolation, projection lag, unknown writes and the absence of automatic remote lifecycle transitions. Include a provider implementation checklist grounded in the executable conformance suite: supported capabilities, identity, ordering, retry proof and bounded evidence.

Record the selected released dependency tuple or the remaining deployment/package prerequisite; never call the feature production-qualified solely from an unpublished checkout. Distill durable findings into ADR 0069 and follow-up ADRs only where decisions changed; triage friction under each child. Update this MasterPlan’s registry and outcomes with the real command transcript. Keep MasterPlan 17’s original acceptance and IR-13 boundary intact; this follow-up owns integration, not a retroactive expansion of IR-13.


## Concrete Steps


Run from the Shikigami repository root. Save `git rev-parse HEAD` as the implementation baseline before edits. Use the development environment and selected dependency cohort consistently; if a local project is needed, follow `docs/dependency-cohort.md` and record the exact project and build directory in acceptance evidence.

```bash
nix develop --no-write-lock-file
cabal build all
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-server-test shikigami-workers-test --test-show-details=direct --test-options='--num-threads=1'
```

No new schema is expected here. If implementation proves one necessary, allocate a separately named additive migration and regenerate:

```bash
just new-migration objective-tracker-controls
cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace --out shikigami-core/src
just migration-schema-isolation
```

Only the child owning a new migration runs `new-migration`; later children create separately named additive migrations if needed. At a coherent committed candidate run:

```bash
just keiro-gate IMPLEMENTATION_BASELINE
git diff --check
```

Replace `IMPLEMENTATION_BASELINE` with the saved revision. Expected results are zero exit codes, registered new tests, and no unexplained breaking compatibility findings. No passing result is claimed at planning time. Use Mori for dependency source discovery and verify authoritative registry releases and upstream tags before selecting new bounds or pins.

Run the supported-entrypoint and compatibility checks after implementing the runner:

```bash
cabal test shikigami-api-test shikigami-server-test --test-show-details=direct
cabal run shikigami -- objectives trackers --help
cabal run shikigami-openapi
bash tests/objective-trackers/run.sh
bash tests/objective-tracking/run.sh
just hurl
just user-docs-validate
```

Both objective runners must exit zero on isolated resources, and the tracker runner must report the distinct states listed in milestone 2. The no-Rei runner is delivered by plan 102; it does not exist at this planning baseline.

Every implementation commit uses Conventional Commits and these trailers:

```text
MasterPlan: docs/masterplans/18-integrate-durable-objectives-with-external-trackers-through-provider-neutral-contracts-and-rei.md
ExecPlan: docs/plans/105-expose-and-qualify-recoverable-external-objective-synchronization.md
Intention: intention_01m63wqywcefjaq53cvzhtvqcv
```


## Validation and Acceptance


Every required milestone 2 scenario runs through supported API/CLI/worker paths, with real Rei for interoperability and fault proxies for ambiguous outcomes. Handler tests cover typed response codes and resource isolation, and the OpenAPI document matches served routes. Passing mocks alone cannot close this plan. Documentation must describe the actual Rei limitation: actions cannot be automatically resent after an uncertain result. The original objective feature remains independently usable without an external tracker.


## Idempotence and Recovery


CLI/API commands use immutable keys and expose retained operations after timeout. Applying a stale proposal requires an explicit new reviewed decision; changing an expected revision in place is a key conflict. Pause/detach retains history and unknown reconciliation. The fixture cleans up only disposable resources it owns and reports failures rather than hiding them in teardown. No force-delivered or force-resend command is introduced. Preserve all historical protocol decoders on rollout and retain credentials outside payloads and logs.


## Interfaces and Dependencies


Hard prerequisites: [plan 103](103-persist-provider-neutral-objective-tracker-bindings-and-synchronization-receipts.md) and [plan 104](104-adapt-rei-intentions-and-actions-to-objective-tracker-contracts.md) Complete, transitively MasterPlan 17 Complete. This child owns public schema, CLI and final qualification; all commands call `Objective/Tracker/Command.hs`, all objective writes call the existing objective owner, and all real Rei calls use `Objective/Tracker/Rei.hs`. It does not add an alternative synchronization engine or new provider dependency. Relevant public source is `mori://shinzui/rei/packages/rei-api-contract`; exact upstream ADR references are recorded in Context and Orientation.


## Revision Notes

2026-10-29: MasterPlan 18 review clarified shared dispatch ownership and the supported evidence-based attestation path, including negative and replay acceptance. The whole-child prerequisites and planning-only status remain unchanged.

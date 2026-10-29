---
id: 104
slug: adapt-rei-intentions-and-actions-to-objective-tracker-contracts
title: "Adapt Rei intentions and actions to objective tracker contracts"
kind: exec-plan
created_at: 2026-10-29T13:15:58Z
intention: "intention_01m63wqywcefjaq53cvzhtvqcv"
master_plan: "docs/masterplans/18-integrate-durable-objectives-with-external-trackers-through-provider-neutral-contracts-and-rei.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-29T13:15:58Z
---

# Adapt Rei intentions and actions to objective tracker contracts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture


An explicitly linked Rei intention can supply observed planning changes and receive an objective progress summary through the real v2 HTTP API. The adapter preserves Rei identity and lifecycle, returns typed failures, and leaves a lost action acknowledgement visibly unresolved rather than creating a duplicate. A disposable Rei server and actual HTTP client prove the contract before public controls are added.


## Progress


- [ ] Milestone 1: verified client/server compatibility and one read/action roundtrip through a disposable real Rei API prove the shared provider contract.
- [ ] Milestone 2: production adapter, bounded polling and routed outbox delivery pass conformance and fault tests, including unknown action recovery.
- [ ] Milestone 3: real-server restart/lag/revocation tests and legacy-sink isolation pass; compatibility evidence and capability limits are documented.

Planning only. Hard prerequisite: plan 103 Complete.


## Surprises & Discoveries


The current source’s action endpoint has no idempotency key and generates a new action ID per request. The existing Shikigami ReiAction path is not the v2 API. These facts constrain implementation; they are not reasons to simulate stronger guarantees.


## Decision Log


- Decision: Bind an existing Rei intention, poll its versioned read model, and publish summaries as actions; do not create or complete intentions automatically.
  Rationale: This supplies useful two-way coordination without equating distinct lifecycles or relying on unsupported repeat-safe creation.
  Date: 2026-10-29


## Outcomes & Retrospective


(To be filled during implementation, with exact tested revisions and retained limitations.)


## Context and Orientation


This is a follow-up to [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md), which must be Complete before implementation starts. Its planned `shikigami-core/src/Shikigami/Objective/Types.hs`, `Command.hs`, `Capability.hs`, `Store.hs`, `Catalog.hs`, `Acceptance.hs` and `Association.hs` own objective identity, versioned commands, authority, receipts and accepted execution links. At planning baseline `1bfe303ab9f6756eecbfc3bca254e9a9492acdad` those objective modules are planned, not implemented. Reconcile their delivered interfaces before editing; do not implement a parallel objective store. A tracker binding links one objective to one resource in an operator-configured external connection. A proposal is retained external input awaiting an authorized local decision. An observation is what the external read actually returned, not proof that no newer remote write exists. A delivery intent is immutable outbound work; a receipt records its known outcome. An unknown outcome means the remote write may have happened.

The seven-package boundaries remain: domain and provider interfaces in `shikigami-core`, HTTP contracts in `shikigami-api`, handlers/operator commands in `shikigami-server`, process composition and loops in `shikigami-workers`, typed public client in `shikigami-client`, SQL in `shikigami-migrations/sql-migrations/manifest`. Existing reference files are `shikigami-core/src/Shikigami/Sink/Intent.hs` (atomic outbox enqueue), `Sink/Delivery.hs` (delivery ledger), `Sink/ReiAction.hs` (legacy sink), `shikigami-workers/src/Shikigami/Flow/SinkOutbox/Publisher.hs` (the shared outbox dispatcher), `shikigami-core/src/Shikigami/Runtime.hs` (catalog registration), and `domain/shikigami.keiro-workspace` (checked declarations). Register new modules and test groups in their Cabal files and suite `Main.hs`; never edit generated modules by hand.

Relevant decisions: [ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) separates enqueue from delivery; [ADR 0026](../adr/0026-outbound-sink-credentials-stay-opaque-and-http-policy-lives-at-the-process-boundary.md) keeps credentials opaque; [ADR 0047](../adr/0047-public-api-authentication-is-a-verifier-at-the-vertical-mount.md) separates authentication and resource authorization; [ADR 0067](../adr/0067-objective-checkpoints-use-assignment-scoped-preconditions.md) makes instruction changes invalidate assignments; [ADR 0068](../adr/0068-objective-creation-has-authority-before-association.md) preserves creation without external association. [ADR 0069](../adr/0069-external-trackers-propose-objective-changes-and-retain-delivery-uncertainty.md) fixes this initiative’s authority and uncertainty boundaries. Follow [workflow versioning](../workflow-versioning.md) if a workflow body changes; this design uses command transactions and background delivery and requires no new agent journal step.

Mori locates the owning project at `mori://shinzui/rei`. Source inspected at revision `515c6c0c6dd0527eb7184825d8bb75acdbde68ec`: project-relative `rei-api-contract/src/Rei/Intention/Api.hs`, `rei-api-contract/src/Rei/Intention/Wire.hs`, `rei-api/src/Rei/Intention/WriteHandler.hs` and `rei-api-client/src/Rei/Client.hs` (artifact-level source URIs pending). The current source serves `/api/v2`, including `GET /intentions/:id`, `GET /intentions/:id/actions`, `GET /actions/:id` and authenticated `POST /intentions/:id/actions`. `IntentionReadModelView` includes `streamPosition`, title, note guidance and status. `RecordActionRequest` has no client operation key; `recordActionH` generates a new action ID for each call. Reads use asynchronously updated projections. Source versions are evidence of a checkout, not proof of a published package or deployed endpoint. Shikigami’s existing `/v1/agent-actions` sink path and “no HTTP API” comments do not describe this contract.

Upstream decisions were discovered through Mori: `mori://shinzui/rei/okf/adrs/concepts/ADR-62` defines the v2 bounded API and scoped cursors; `mori://shinzui/rei/okf/adrs/concepts/ADR-53` defines the typed client and its separate domain-result and transport-failure channels. Read these records and the named sources again at implementation. Rei intentions and Shikigami objectives retain distinct identities and lifecycles.

`shikigami-core/src/Shikigami/Objective/Tracker/Types.hs` owns versioned `TrackerConnectionId`, `TrackerBindingId`, binding revision, connection incarnation, external resource identity, mapping revision, `TrackerObservation`, `ImportProposal`, `PublicationIntent` and `PublicationReceipt`. A connection incarnation identifies one configured remote account/installation; replacing the server or account creates a new incarnation rather than reusing source versions. Credentials never enter these values. One external resource has at most one active binding per connection incarnation; one objective may have several bindings, but at most one designated inbound authority for each mapped field. Existing `LinkExternal` references stay passive until explicit binding admission validates the connection, resource and permissions.

`Tracker/Provider.hs` owns a closed provider interface: describe the immutable capability revision, read one bound resource, publish one retained intent, and reconcile one unknown publication. Reads return a bounded snapshot plus source version/digest or a typed missing/denied/unavailable result. Publish returns acknowledged with remote receipt, definitely-not-sent, definitive rejection, conflict, or unknown. Reconciliation returns proved-applied, proved-not-applied or still-unknown. Capability declarations distinguish ordered observations, remote conditional writes, server idempotency keys and receipt lookup; advertising one requires a conformance test. Expired keys or unavailable lookup never justify a resend. No provider changes objective state directly.

`Tracker/Command.hs` and `Tracker/Store.hs` own binding admission, observation retention, proposal decisions, durable delivery states and reconciliation. Commands use authenticated actors and stable operation keys. Applying a proposal calls the existing objective command owner with exact expected objective revision and current permission; objective change, decision receipt and resulting publication intents commit together through a supported shared transaction interface. A later implementation must expose that interface within the objective owner if necessary, never nest independently committing transactions or write its tables from an adapter.


## Plan of Work


### Milestone 1 — Prove the real protocol before expansion

Create `shikigami-core/src/Shikigami/Objective/Tracker/Rei.hs` using `Rei.Client` from the typed API client and `shikigami-core/test-postgres/Shikigami/ObjectiveTrackerReiSpec.hs`. Before choosing dependencies, use Mori to locate current source, verify package versions on the authoritative registry and upstream release tags, and record the selected contract/client/server tuple. The inspected checkout reports client 0.2.0.0, but that is not a release selection. If the required pair is unpublished, use the repository’s documented local-source cohort process for qualification and state the packaging gate explicitly; never silently lift bounds or invent an endpoint. Keep Rei core/server out of Shikigami production dependencies.

Add `tests/objective-trackers/with-rei.sh`: build or accept an explicit tested Rei server binary, provision a disposable database and service identity, select an unused loopback port, start the real server and its projection workers, and publish isolated connection configuration to the test process. Use the upstream fixture setup discovered through `mori://shinzui/rei`, project-relative `rei-api/test/hurl/run-isolated.sh` and `rei-api/test-client/run.sh` (artifact-level URIs pending), as the verified starting point. The launcher owns and cleans up only its resources; it must not read the user’s normal Rei endpoint or credentials. Record server commit/version and configuration fingerprint without tokens. A mock is not a fallback for this milestone.

Run one existing-intention read and one authenticated action creation through EP-1’s retained publication path. The test creates the intention as setup, verifies `streamPosition` and later the returned action ID through the real read API with bounded projection-lag polling. Capture the exact response codecs and two failure channels. Missing live capability or setup must leave the milestone unaccepted with a concrete reason, not a passing fake. Accept the milestone only after the shared engine recognizes the real receipt and an unauthorized request is refused.

### Milestone 2 — Mapping, dispatch and uncertainty

The immutable adapter revision `rei-v2-objectives/1` identifies the supported wire/mapping behavior. Bind a configured connection incarnation and explicit intention ID; do not derive endpoints from model text or fetched links. Read the bounded intention metadata using the typed client. Normalize `streamPosition` as an ordered observation token scoped to that intention and connection incarnation, with a canonical digest of mapped fields. It represents projected source state, not linearizable freshness. Equal-position divergent data conflicts; lower positions cannot roll back accepted state. Serialize bounded polls per binding so restart and concurrent polls cannot overwrite a newer observation.

Map Rei title to external display metadata, `noteGuidance` to an optional instructions proposal, and lifecycle status to an external-status observation. A missing note guidance value is an explicit clear proposal only if that mapping is enabled; it never silently clears instructions. Rei completed may offer a completion proposal with no fabricated acceptance evidence; abandoned may offer cancellation for authorized review; active/future cannot reopen a terminal objective. Criteria, deadlines, relationships and arbitrary properties are not silently translated. Rei completion policy remains owned by Rei. A stream-position advance caused solely by our own outbound action must not create an instructions proposal.

Publish only bounded allowlisted summaries using `recordAction`; include objective identity, revision and logical publication marker in the description as attribution, with a retained timestamp. The marker is not a server deduplication key. Leave `actor` unset unless the deployment has explicitly mapped and authorized a Rei performer; credential identity and Shikigami actor attribution remain distinct. Retain returned `actionId` and request digest. Never call the legacy `/v1/agent-actions` sink for this provider, and do not send completion through Rei’s complete command.

Advertise no server idempotency or conditional action-append capability. A connection failure, response loss, undecodable success or expired in-flight lease may follow a committed action: report Unknown and quarantine. Retry only reads and sends proven not dispatched; classify documented definitive rejections separately. A 5xx is not proof of non-commit without endpoint-specific evidence. Reconciliation with a known action ID verifies intention and payload through `getAction`. A bounded actions scan may find a candidate marker, but no match under projection lag proves nothing; a marker alone is not authoritative against forgery or multiple matches. Require authorized attestation of exact remote receipt and request attribution where the API cannot prove it, retain the attestation, or leave Unknown. Never automatically resend an ambiguous append.

Create `shikigami-workers/src/Shikigami/Objective/Tracker/Worker.hs` for bounded observation polling and provider dispatch, and extend the existing `Flow/SinkOutbox/Publisher.hs` router by destination. Each batch still has one publisher owner; legacy sinks retain their path. Wire the adapter into `Workers/Config.hs`, `Workers/Command/Worker.hs` and the existing supervision/health registry with explicit configuration. Shared HTTP manager and opaque credentials are constructed at process boundaries. Unknown tracker results retire transport retry into EP-1’s durable quarantine; they are never counted as delivered sync receipts. Paused/revoked bindings stop fresh network writes and preserve read-only reconciliation where authorized.

### Milestone 3 — Fault qualification and isolation

Run EP-1’s reusable conformance suite against the production adapter with a controlled proxy around a real disposable Rei server. Drop the action response after remote commit, restart Shikigami, and prove zero second POSTs, one remote action after projections catch up, and an Unknown receipt until validated reconciliation. Kill after local receipt commit and prove retry returns that receipt without network dispatch. Delay Rei projections; local success must not be converted to failure because a read is stale. Exercise 401, 403, 404, 409, 429, 5xx, malformed success, bounded pagination, access revocation, paused binding, endpoint replacement and a stale leased worker.

Record evidence in `docs/operations/objective-tracker-rei.md`: exact server/client tuple, supported mappings, projected-read limits, non-idempotent append semantics, recovery procedure and test transcript. Correct stale API-existence commentary in `Sink/ReiAction.hs` without silently rerouting legacy durable sink messages; migration of that sink protocol remains separate. Acceptance includes unchanged legacy sink tests and disabled-tracker behavior. No patch or dependency-bound exception is justified merely by this adapter.


## Concrete Steps


Run from the Shikigami repository root. Save `git rev-parse HEAD` as the implementation baseline before edits. Use the development environment and selected dependency cohort consistently; if a local project is needed, follow `docs/dependency-cohort.md` and record the exact project and build directory in acceptance evidence.

```bash
nix develop --no-write-lock-file
cabal build all
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-server-test shikigami-workers-test --test-show-details=direct --test-options='--num-threads=1'
```

Plan 103 owns the tracker migration; do not rerun its creation command. If a new additive schema change is necessary, choose its own migration name and regenerate:

```bash
just new-migration objective-tracker-rei
cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace --out shikigami-core/src
just migration-schema-isolation
```

Only the child owning a new migration runs `new-migration`; later children create separately named additive migrations if needed. At a coherent committed candidate run:

```bash
just keiro-gate IMPLEMENTATION_BASELINE
git diff --check
```

Replace `IMPLEMENTATION_BASELINE` with the saved revision. Expected results are zero exit codes, registered new tests, and no unexplained breaking compatibility findings. No passing result is claimed at planning time. Use Mori for dependency source discovery and verify authoritative registry releases and upstream tags before selecting new bounds or pins.

After implementing the isolated launcher, run:

```bash
bash tests/objective-trackers/with-rei.sh -- cabal test shikigami-core-postgres-test --test-show-details=direct --test-options='--pattern ObjectiveTrackerRei --num-threads=1'
```

The launcher must fail when no compatible real server is supplied or buildable. Expected evidence includes the server revision, created intention and action IDs, one remote action after lost acknowledgement, and an Unknown-to-reconciled transition with no second POST. Do not run against the intention created for planning.

Every implementation commit uses Conventional Commits and these trailers:

```text
MasterPlan: docs/masterplans/18-integrate-durable-objectives-with-external-trackers-through-provider-neutral-contracts-and-rei.md
ExecPlan: docs/plans/104-adapt-rei-intentions-and-actions-to-objective-tracker-contracts.md
Intention: intention_01m63wqywcefjaq53cvzhtvqcv
```


## Validation and Acceptance


Real Rei API reads and action writes pass; production mappings cannot mutate local execution-owned fields; action acknowledgement loss stays Unknown without replay; matched receipts recover after restart; projection lag does not cause duplicate writes or state rollback. The core/worker suites and the real-server proxy scenarios must pass. An honest unresolved Unknown is a passing failure-mode expectation, not successful delivery. Live tests use disposable data only. This child qualifies the provider, not public Shikigami API controls.


## Idempotence and Recovery


A pending intent retains its adapter revision and complete bytes. A retired adapter cannot be replaced silently for unfinished work. Never change the configured connection’s account or server identity in place; admit a new incarnation and reconcile the old one. Read-only retries are bounded. Action POST retries require proof of non-dispatch or non-application with no surviving request; otherwise preserve Unknown. Restart the isolated fixture from scratch safely, but never retry setup mutations against a non-disposable endpoint.


## Interfaces and Dependencies


Hard prerequisite: [plan 103](103-persist-provider-neutral-objective-tracker-bindings-and-synchronization-receipts.md) Complete. Consume its `Tracker/Provider.hs` interface and reuse the same conformance cases; do not add a Rei-only synchronization executor. Dependencies are `mori://shinzui/rei/packages/rei-api-client` and `mori://shinzui/rei/packages/rei-api-contract`, whose released compatibility must be checked before bounds are chosen. The production adapter belongs in core as a domain HTTP client, without Rei core/server imports; manager, credentials and loops remain at executable boundaries. [Plan 105](105-expose-and-qualify-recoverable-external-objective-synchronization.md) consumes the adapter and isolated launcher. Any upstream API enhancement is a separately recorded prerequisite with a canonical Mori handle, never an assumed new route.

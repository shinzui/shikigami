---
id: 98
slug: persist-authoritative-objectives-and-conditional-commands
title: "Persist authoritative objectives and conditional commands"
kind: exec-plan
created_at: 2026-10-29T00:19:50Z
intention: "intention_01m62265gjex4a0k54gsbwx4gs"
master_plan: "docs/masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-29T00:19:50Z
---

# Persist authoritative objectives and conditional commands

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

After this plan, Shikigami's own PostgreSQL store holds authoritative objectives: a goal with instructions, completion criteria, a bounded assignment graph, members and roles, accepted evidence, decisions and next actions, every change committed through one conditional command executor that returns an immutable receipt. A developer can run the PostgreSQL suite and watch two writers at one revision produce one accepted transition and one visible conflict, an identical retry after further progress return its original receipt, a crash between commit and acknowledgement leave exactly one receipt, and a real worker-session result project into the `ObjectiveVersion` shape that continuing workers already consume. Nothing is exposed over HTTP, the CLI, a model tool or the worker providers yet; those are plans 99–101 under [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md), which also records the vocabulary: IR-13's "major task" is this objective.


## Progress

- [ ] Milestone 1: `domain/shikigami-objective.keiro`, its generated modules, the additive `objective-checkpoints` migration and `Shikigami.Objective.Types`/`Command` compile, register in the shared catalog and pass `just migration-schema-isolation`.
- [ ] Milestone 2: one command executor in `Shikigami.Objective.Capability` and `Store` commits objective state, lifecycle event, protected payload and receipt atomically with in-transaction authorization; the conditional and idempotent cases in `ObjectiveStoreSpec` pass.
- [ ] Milestone 3: `Shikigami.Objective.Acceptance` and graph validation reject stale or incomplete completion, a real session result projects into `ObjectiveVersion`, and the concurrency and crash-window cases pass against a fresh database connection.

Planning baseline `3900c0e634d9b559e92a6989bb10f9943e0beab1`, inspected 2026-10-28. No implementation or test results are claimed.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: `Shikigami.Objective.Capability` is the single authenticated command admission owner and lands in this plan, not with the agent tools.
  Rationale: Plans 99 (providers), 100 (API and CLI) and 101 (tools and Flow) are all adapters over it; authentication first, receipt lookup second and optimistic revision validation third must exist exactly once.
  Date: 2026-10-28

- Decision: Distinguish an objective's access owner and overall completion from each assignment's owner.
  Rationale: `ObjectiveVersion.owner` is compared with a worker session's owner, so a worker-facing reference must resolve one assignment within the objective; one objective-wide worker identity cannot serve multiple workers.
  Date: 2026-10-28

- Decision: Each `ObjectiveAssignmentId` stores its own assignment revision, and a conflict is a property of the addressed assignment, with the objective-wide revision as an ordering base.
  Rationale: Sibling workers checkpoint concurrently as a matter of routine in UC-1; a whole-objective equality check would turn every such commit into a parent-authorized reconciliation. The consumer requires only an advancing receipt revision and matching owner, epoch and root.
  Date: 2026-10-28


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

An objective is a goal spanning executions. An assignment is a versioned piece of that goal with dependencies and a designated agent owner. A checkpoint is the authoritative current objective/assignment view, including accepted evidence and pending work. A revision is a monotonically increasing integer used to detect intervening changes. An owner epoch increments on handoff so a former owner cannot write with old authority. An operation key identifies one immutable command across retries; its fingerprint is a versioned digest of the complete semantic request. A receipt records the committed result of that command. These differ from a Keiro workflow journal, which records the steps of one execution, and from a Kioku memory session, which supplies recalled context.

The repository is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior, durable workflows and storage; `shikigami-api` owns HTTP contracts, `shikigami-client` their client, `shikigami-server` HTTP handlers and operator commands, `shikigami-workers` runtime composition, and `shikigami-migrations/sql-migrations/manifest` append-only migration ordering. Register new Haskell modules and tests in each package's Cabal file (`shikigami-core/shikigami-core.cabal` lists the `shikigami-core-test` and `shikigami-core-postgres-test` suites) and in each suite's `Main.hs`. Generated code under `shikigami-core/src/Shikigami/Generated/` comes from `domain/shikigami.keiro-workspace`; never edit it by hand. No `shikigami-core/src/Shikigami/Objective/` directory exists at the baseline.

The consumer this store must serve already exists. `shikigami-core/src/Shikigami/WorkerSession/Checkpoint.hs` defines `ObjectiveRef`, `ObjectiveVersion` (fields `revision`, `assignmentRevision`, `criteriaRevision`, `ownerEpoch`, `owner`, `active`, `rootId`, `cutoff`), `CheckpointIntent`, `CheckpointReceipt` and `CheckpointProvider{current,commit}`. `shikigami-core/src/Shikigami/WorkerSession/Workflow.hs` compares all of these before admitting new work. Note what it does and does not require: `matchesReceipt` accepts any receipt whose revision exceeds the intent's expected objective revision, and `shikigami-core/src/Shikigami/WorkerSession/Store.hs` `prepareCheckpoint` validates owner, epoch and resource root but never revision equality. The provider in plan 99 therefore defines conflict per addressed assignment, and this plan stores the per-assignment revision it needs. A resource root is the existing shared execution-budget record from [ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md); objective state references it and never copies its counters.

Follow the checked aggregate and protected payload pattern in `domain/shikigami-worker-session.keiro`, `shikigami-core/src/Shikigami/WorkerSession/Store.hs` and `shikigami-core/src/Shikigami/WorkerSession/Catalog.hs`: domain events and application rows commit together through Keiro's `runCommandWithCatalogProjections`, located through Mori in `mori://shinzui/keiro`, project-relative `keiro/src/Keiro/Projection.hs` (artifact-level URI pending), which commits inline projection handlers in the command append transaction and returns typed catalog/fence failures. A live-only projection means protected payload tables cannot be reconstructed from public lifecycle metadata; it must refuse destructive rebuilds rather than invent missing payloads. `shikigami-core/src/Shikigami/Runtime.hs` registers the common catalog at startup through `registerRuntimeCatalog`.

`shikigami-api/src/Shikigami/Caller/Api.hs` and `shikigami-server/src/Shikigami/Caller/Verifier.hs` supply `ApiCaller`; its identifier comes from the configured verifier, not request JSON, and the current verifier represents one configured bearer caller or anonymous access, not an issuer-backed directory. Objective access control must still support distinct caller identities and test them with a verifier fixture. The existing `http-auth-disabled` local development mode in `shikigami-core/src/Shikigami/App/Config.hs` must be preserved without being promoted to verified authority. `shikigami-core/src/Shikigami/WorkerSession/Capability.hs` shows how closed worker commands and `authorizeExact` over `InvokeCapabilityTool` (from `Kikan.En.Action`, `mori://shinzui/kikan-en`) obtain fresh exact authority.

Relevant decisions, found by scanning `docs/adr/` filenames and headings (the bundle is not profile-governed): [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) requires stable write identities for replay-safe effects; [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) forbids treating a lease or descriptor label as duplicate protection; [ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md) keys durable authority by recorded principal, not display name; [ADR 0047](../adr/0047-public-api-authentication-is-a-verifier-at-the-vertical-mount.md) separates authentication from resource authorization; [ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md) keeps budgets with the resource owner; [ADR 0061](../adr/0061-continuing-sessions-own-ordered-assignments-and-retained-receipts.md), [ADR 0062](../adr/0062-session-generations-await-governed-children-and-retain-checkpoint-intents.md), [ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md) and [ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md) establish retained receipts, fenced transfer and fresh exact authority that this store must be able to serve.

[Plan 84](84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) has implemented the consumer mechanics and is waiting on the real provider that plan 99 builds on this store; this plan does not touch plan 84's modules. [Plan 85](85-adapt-durable-delivery-through-validated-coordinator-decisions.md) will later submit integrated acceptance to the `Shikigami.Objective.Acceptance` contract defined here rather than keeping a second completion store.


## Plan of Work

### Milestone 1 — Declare the objective domain, its types and the closed command sum

Add `domain/shikigami-objective.keiro` to `domain/shikigami.keiro-workspace` as a checked aggregate with a protected payload, mirroring the worker-session declaration, and generate its lifecycle and read-model modules into `shikigami-core/src/Shikigami/Generated/`. Create the migration with `just new-migration objective-checkpoints`. Use schema-qualified `shikigami` tables for current objective state, assignment records, command receipts, protected payloads, run/conversation associations, retained coordination scopes and checkpoint source cursors; plan 99 fills the last three but their tables are allocated here so one migration carries the domain. Register the projection group in the shared generated catalog that `Runtime.hs` loads. Receipts and protected records must survive terminal workflow garbage collection.

Create `shikigami-core/src/Shikigami/Objective/Types.hs`. An objective has a stable `ObjectiveId`, access owner, explicit member roles, title, goal and instructions, `revision`, `instructionsRevision`, `criteriaRevision`, structured completion criteria, status, bounded decisions, assumptions and next actions, and optional typed external references (a Rei intention, an ExecPlan or an external protocol task; their lifecycles stay independent). Statuses are `Open`, `Blocked`, `Completed` and `Cancelled`; blocking is reversible, and completion or cancellation stop fresh progress admission while still allowing administrative access changes and reconciliation of already accepted effects. Completion is never inferred from a run status. An `ObjectiveAssignmentId` is distinct from a continuing session's per-message `AssignmentId`: it identifies a logical work item and stores its own assignment revision, instruction revision, dependencies, designated agent principal, owner epoch, state and references to its worker session and accepted result revisions. The assignment revision increments whenever any of those change and is the value `ObjectiveVersion.assignmentRevision` reports; sibling assignments advance the objective revision without touching it. A result reference includes the producing run/execution/session, an immutable result or payload digest, artifact identity and acceptance disposition; narrative notes are not acceptance evidence. Unresolved operations reference their owning execution/session records and stay visible until that owner reconciles them.

Define the access-principal sum here, distinguishing a verified API caller, a recorded agent identity and a trusted local operator. Never turn an arbitrary principal-shaped string into authority. Owners and explicit coordinators may manage assignments and propose acceptance; worker members may record progress only on assignments they own; read-only members inspect only permitted data; only owners or explicitly granted completers accept completion. Grants and revocations are versioned owner commands. An agent may create an objective only when operator policy grants creation, and creating one grants no access to existing objectives.

Create `shikigami-core/src/Shikigami/Objective/Command.hs` with the closed public sum `ReviseInstructions`, `ReviseCriteria`, `SetAssignments`, `RecordProgress`, `RecordEvidence`, `SetNextAction`, `SetBlocked`, `ProposeCompletion`, `AcceptCompletion`, `CancelObjective`, `GrantMember`, `RevokeMember`, `BindConversation` and `LinkExternal`, plus internal provider-only commands for checkpoint ingestion and ownership transfer that are unavailable as HTTP or model tags. Creation is its own operation with a uniqueness key scoped to the authenticated creator and operation key, so a retry cannot create a second objective. `SetAssignments` validates and commits the entire proposed bounded graph, rejecting duplicate identities, dangling dependencies and cycles, and cannot change an active session owner without the handoff protocol. Milestone 1 is accepted when the workspace scaffolds cleanly, the migration applies in the PostgreSQL test harness, `just migration-schema-isolation` exits zero and `cabal build all` succeeds with the new modules registered.

### Milestone 2 — One conditional command executor with receipts

Create `shikigami-core/src/Shikigami/Objective/Capability.hs` (authenticated command admission) and `shikigami-core/src/Shikigami/Objective/Store.hs` (conditional persistence). All writes pass this executor. Authenticate and authorize the caller first; then look up an existing receipt by deduplication key before optimistic revision validation. The key includes objective and operation identity; the fingerprint includes actor, command tag, semantic payload, expected revisions and owner epoch. An identical accepted retry returns the original receipt even after later progress; a changed payload under the same key conflicts. A new write locks and checks the objective revision, validates the whole transition, appends the checked lifecycle event, writes protected data and current rows and stores the receipt in one transaction. Check membership, role and revision inside that transaction so a concurrent revocation cannot race an authorized mutation. Obtain any external exact-action decision immediately before the boundary, without holding a database lock across a network call. On conflict return a typed result with no partial progress or evidence writes. Persist definitive non-commit outcomes so a conflicted operation can never later become accepted; connection loss produces uncertainty, not a manufactured negative receipt. Expose typed create, read, execute and read-receipt operations and typed errors for missing, denied, conflict, invalid evidence, unavailable and unresolved outcomes. Actor and run attribution come from trusted adapter context, never from model content.

Create `shikigami-core/src/Shikigami/Objective/Catalog.hs` for the projection handlers. Add `shikigami-core/test/Shikigami/ObjectiveSpec.hs` for pure validation and `shikigami-core/test-postgres/Shikigami/ObjectiveStoreSpec.hs` for the store. Milestone 2 is accepted when two writers at one revision yield one accepted transition and one typed conflict, an identical retry after progress returns the original receipt and IDs, a changed payload under a reused key conflicts, and evidence inserted in a rolled-back transaction is absent afterwards.

### Milestone 3 — Acceptance contract, graph validation and the consumer projection

Create `shikigami-core/src/Shikigami/Objective/Acceptance.hs`. `ObjectiveAcceptance` records the objective, instruction and criteria revisions, exact integrated artifact references, per-criterion check evidence, user-journey evidence where required, recorded limitations, the proposer and the approving authority. Automatic checks refer to retained verifier or run results, never a model-authored Boolean; a human-verifiable criterion requires an explicit authorized attestation. Completion rejects stale criteria, unmet required dependencies, unresolved relevant operations, missing or failing checks and mere child success, and stores acceptance and terminal status atomically. Historical evidence is retained, never rewritten, when an assignment changes.

Before any wider surface exists, prove one real worker-session result (a `WorkerSession` receipt from the existing store, written by the test) can be persisted as objective progress and projected into the existing `ObjectiveVersion` shape with the correct per-assignment revision. Add the remaining `ObjectiveStoreSpec` cases: a process loss after commit but before acknowledgement followed by a retry, graph cycles and dangling dependencies, stale owner epochs and invalid completion. Milestone 3 is accepted when those cases pass, every rejected command leaves state unchanged, and objective data remains readable after a fresh database connection.


## Concrete Steps

Run commands from the repository root, `/Users/shinzui/Keikaku/bokuno/shikigami`. Enter the development environment if needed:

```bash
nix develop --no-write-lock-file
```

Capture `git rev-parse HEAD` as the implementation baseline before edits and use that revision for the final gate. Confirm the project builds first:

```bash
cabal build all
```

The working session used for plans 83–84 also has `.dev/mp13.cabal.project` and `.dev/mp14-clean-dist` with isolated dependency paths; they are local conveniences, not portable prerequisites. If the checked-in project cannot resolve its co-developed dependencies, locate their owners with Mori, follow `docs/dependency-cohort.md`, and reconstruct a local project at the same selected revisions. Never copy another machine's absolute paths into committed configuration or change package bounds to bypass a failure. If you use the local project, apply it consistently to builds, tests and the gate, and record it in acceptance evidence:

```bash
cabal build --project-file=.dev/mp13.cabal.project --builddir=.dev/mp14-clean-dist all
```

Declare the domain, create the migration and regenerate:

```bash
just new-migration objective-checkpoints
cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace --out shikigami-core/src
just migration-schema-isolation
```

The migration command prints the created timestamped path and appends it to the manifest; do not run it twice for one change. The schema check must exit zero. The PostgreSQL suite applies migrations to disposable databases through `shikigami-core/test-postgres/Main.hs`; no production connection is needed.

After registering the new test groups, run focused checks while implementing and the complete suites at the milestone boundary:

```bash
cabal test shikigami-core-test shikigami-core-postgres-test --test-show-details=direct --test-options='--num-threads=1'
```

At a coherent commit, run the ordinary gate against the saved baseline:

```bash
just keiro-gate IMPLEMENTATION_BASELINE
git diff --check
```

`keiro-scaffold` inside the gate compares `shikigami-core/src` against the committed candidate, so commit the intended source and generated changes before using it as final evidence. Every commit follows Conventional Commits and ends with:

```text
MasterPlan: docs/masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md
ExecPlan: docs/plans/98-persist-authoritative-objectives-and-conditional-commands.md
Intention: intention_01m62265gjex4a0k54gsbwx4gs
```


## Validation and Acceptance

The persistence guarantee holds at its actual transaction boundary: objective state, evidence, lifecycle event and receipt all commit or none do. Two concurrent writers from one revision yield one accepted transition and one conflict. Creation retry and mutation retry return the original IDs after reconnect. Wrong-key payload reuse, graph cycles, stale owner epochs and invalid completion leave state unchanged. A real session receipt projects into `ObjectiveVersion` with the addressed assignment's own revision, and a sibling assignment's progress advances the objective revision without changing it. Required acceptance is the passing `shikigami-core-test` and `shikigami-core-postgres-test` suites with the new groups, a zero exit from `just migration-schema-isolation` and a gate report with no unexplained breaking findings. Record actual passing counts only after running them.


## Idempotence and Recovery

Migrations are additive, schema-qualified and manifest-ordered; never edit or rename an applied migration. Retain objective data, command outcomes, protected evidence and receipts beyond workflow journal collection, initially indefinitely; a deletion or compaction policy that preserves live and deduplication references is separate work. Do not rebuild live-only tables from incomplete event metadata. On a lost acknowledgement, retry the original command bytes and key: accepted receipts precede revision checks, while access checks still precede disclosure. A known stale conflict is resolved by a new explicit command against reread state, never by last-writer-wins. Rerunning the scaffold is safe; rerunning `just new-migration` for the same change is not.


## Interfaces and Dependencies

`Shikigami.Objective.Types` owns `ObjectiveId`, `ObjectiveAssignmentId`, the access-principal sum, versioned snapshots, receipts and evidence references. `Shikigami.Objective.Command` owns the closed command sum and the internal provider-only commands. `Shikigami.Objective.Capability` owns authenticated command admission; `Shikigami.Objective.Store` owns conditional persistence; `Shikigami.Objective.Catalog` owns projections; `Shikigami.Objective.Acceptance` owns completion. Plan 99 adapts the worker providers over these, plan 100 the HTTP and CLI envelope, plan 101 the native tool and Flow effect; none adds a second executor. Existing dependencies and the selected cohort are used unchanged: `mori://shinzui/keiro` for aggregates and `runCommandWithCatalogProjections`, `mori://shinzui/kiroku/packages/kiroku-store` and `mori://shinzui/kioku/packages/kioku-core` for the existing stores, and `mori://shinzui/kikan-en` for the exact capability action contract. Locate any further dependency API through Mori and read its source before use; verify registry releases and upstream tags before changing bounds or pins, because local registry metadata can lag. This plan has no hard prerequisite within MasterPlan 17.

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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T12:59:01Z
      verdict: "changes-requested"
      note: "Specify internal assignment-scoped checkpoint preconditions separately from public whole-objective revision equality; define instruction invalidation."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T13:05:53Z
      mode: "update"
      note: "Define assignment-scoped checkpoint preconditions, revision invalidation, shared configuration and atomic creator receipts/origins."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-30T19:12:51Z
      mode: "implement"
      note: "Implement objective domain, conditional persistence and acceptance with PostgreSQL qualification."
---

# Persist authoritative objectives and conditional commands

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

After this plan, Shikigami's own PostgreSQL store holds authoritative objectives: a goal with instructions, completion criteria, a bounded assignment graph, members and roles, accepted evidence, decisions and next actions, every change committed through one conditional command executor that returns an immutable receipt. A developer can run the PostgreSQL suite and watch two public-command writers at one revision produce one accepted transition and one visible conflict, an identical retry after further progress return its original receipt, a crash between commit and acknowledgement leave exactly one receipt, and a real worker-session result project into the `ObjectiveVersion` shape that continuing workers already consume. Nothing is exposed over HTTP, the CLI, a model tool or the worker providers yet; those are plans 99–101 under [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md), which also records the vocabulary: IR-13's "major task" is this objective.


## Progress

- [x] Milestone 1 (2026-10-30): objective domain, generated catalog/read model, additive migration `0031-objective-checkpoints.sql`, closed command types and default-deny shared configuration compile. `cabal build all`, 542 unit tests (including loader cases), migration application in the PostgreSQL harness and `just migration-schema-isolation` pass.
- [x] Milestone 2 (2026-10-30): one authenticated conditional executor atomically writes state, lifecycle, protected payload and receipt. The 377-case PostgreSQL suite passes, including 19 objective cases for public conflicts, retained negative outcomes, source-authentic sibling checkpoints, revocation, atomic creation/origins and rollback.
- [ ] Milestone 3: graph/acceptance validation, real worker result projection, terminal reconciliation and separate-process receipt recovery pass in the same 19 objective PostgreSQL cases. The final committed-candidate Keiro gate remains pending.

Planning baseline `3900c0e634d9b559e92a6989bb10f9943e0beab1`, inspected 2026-10-28. Implementation baseline: `86954e17d57099a7c48499402946bb4558752afa` (2026-10-30).

Implementation is present. The checked-in Cabal project resolves without the optional local project. The full suites have passed 542 unit cases and 377 PostgreSQL cases (19 new objective cases), including real worker result/checkpoint ingestion and separate-process acknowledgement loss. The final root-optional interface and package-formatting reconciliation are validated; only the committed-candidate Keiro gate remains.


## Surprises & Discoveries

The released checked lifecycle runner can reject a raced command before its projection handler executes. The store therefore performs a locked inspection, retains only definitive negative outcomes there, and repeats positive validation inside the checked append/projection transaction. Raced positive candidates return to inspection; they do not fabricate negative receipts.

Worker success and verifier success need separate retained dispositions. The existing worker result receipt authenticates produced output, but does not attest an objective criterion or user journey. Ordinary results now project as `ResultObserved`; automatic acceptance requires verifier-owned criterion/journey facts. This implements the plan's prohibition on completing from child success alone.


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


- Decision: Retain withdrawn assignment identities, index stable worker references, and bind evidence to assignment instruction/dependency revision and owner epoch as well as objective instruction/criteria revisions.
  Rationale: Prevent identity reuse and stale integrated acceptance, including instructions that change and later return to their original text; enable provider lookup without scanning objective payloads.
  Date: 2026-10-30

- Decision: Keep admitted access package-private and run source/fence verification outside locks, followed by a fresh exact action check and transactional membership/permission validation.
  Rationale: Public identity-shaped JSON cannot mint authority, and revocation or an unavailable external verifier cannot bypass receipt recovery.
  Date: 2026-10-30

## Outcomes & Retrospective

Implementation and runtime qualification are complete pending the final committed-candidate gate. No worker-provider, public API/CLI or model/Flow surface is enabled by this plan. FRIC-32 is resolved by formatter ownership exclusions. FRIC-33 is accepted: strict request-bundle validation still reports the same eight missing recommended metadata fields as the implementation baseline; its output compares byte-for-byte equal, and no historical review entries were invented.


## Context and Orientation

An objective is a goal spanning executions. An assignment is a versioned piece of that goal with dependencies and a designated agent owner. A checkpoint is the authoritative current objective/assignment view, including accepted evidence and pending work. A revision is a monotonically increasing integer used to detect intervening changes. An owner epoch increments on handoff so a former owner cannot write with old authority. An operation key identifies one immutable command across retries; its fingerprint is a versioned digest of the complete semantic request. A receipt records the committed result of that command. These differ from a Keiro workflow journal, which records the steps of one execution, and from a Kioku memory session, which supplies recalled context.

The repository is a Cabal multi-package Haskell service. `shikigami-core` owns domain behavior, durable workflows and storage; `shikigami-api` owns HTTP contracts, `shikigami-client` their client, `shikigami-server` HTTP handlers and operator commands, `shikigami-workers` runtime composition, and `shikigami-migrations/sql-migrations/manifest` append-only migration ordering. Register new Haskell modules and tests in each package's Cabal file (`shikigami-core/shikigami-core.cabal` lists the `shikigami-core-test` and `shikigami-core-postgres-test` suites) and in each suite's `Main.hs`. Generated code under `shikigami-core/src/Shikigami/Generated/` comes from `domain/shikigami.keiro-workspace`; never edit it by hand. No `shikigami-core/src/Shikigami/Objective/` directory exists at the baseline.

The consumer this store must serve already exists. `shikigami-core/src/Shikigami/WorkerSession/Checkpoint.hs` defines `ObjectiveRef`, `ObjectiveVersion` (fields `revision`, `assignmentRevision`, `criteriaRevision`, `ownerEpoch`, `owner`, `active`, `rootId`, `cutoff`), `CheckpointIntent`, `CheckpointReceipt` and `CheckpointProvider{current,commit}`. `shikigami-core/src/Shikigami/WorkerSession/Workflow.hs` compares all of these before admitting new work. Note what it does and does not require: `matchesReceipt` accepts any receipt whose revision exceeds the intent's expected objective revision, and `shikigami-core/src/Shikigami/WorkerSession/Store.hs` `prepareCheckpoint` validates owner, epoch and resource root but never revision equality. The provider in plan 99 therefore defines conflict per addressed assignment, and this plan stores the per-assignment revision it needs. A resource root is the existing shared execution-budget record from [ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md); objective state references it and never copies its counters.

Follow the checked aggregate and protected payload pattern in `domain/shikigami-worker-session.keiro`, `shikigami-core/src/Shikigami/WorkerSession/Store.hs` and `shikigami-core/src/Shikigami/WorkerSession/Catalog.hs`: domain events and application rows commit together through Keiro's `runCommandWithCatalogProjections`, located through Mori in `mori://shinzui/keiro`, project-relative `keiro/src/Keiro/Projection.hs` (artifact-level URI pending), which commits inline projection handlers in the command append transaction and returns typed catalog/fence failures. A live-only projection means protected payload tables cannot be reconstructed from public lifecycle metadata; it must refuse destructive rebuilds rather than invent missing payloads. `shikigami-core/src/Shikigami/Runtime.hs` registers the common catalog at startup through `registerRuntimeCatalog`.

`shikigami-api/src/Shikigami/Caller/Api.hs` and `shikigami-server/src/Shikigami/Caller/Verifier.hs` supply `ApiCaller`; its identifier comes from the configured verifier, not request JSON, and the current verifier represents one configured bearer caller or anonymous access, not an issuer-backed directory. Objective access control must still support distinct caller identities and test them with a verifier fixture. The existing `http-auth-disabled` local development mode in `shikigami-core/src/Shikigami/App/Config.hs` must be preserved without being promoted to verified authority. `shikigami-core/src/Shikigami/WorkerSession/Capability.hs` shows how closed worker commands and `authorizeExact` over `InvokeCapabilityTool` (from `Kikan.En.Action`, `mori://shinzui/kikan-en`) obtain fresh exact authority.

Relevant decisions, found by scanning `docs/adr/` filenames and headings (the bundle is not profile-governed): [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) requires stable write identities for replay-safe effects; [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md) forbids treating a lease or descriptor label as duplicate protection; [ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md) keys durable authority by recorded principal, not display name; [ADR 0047](../adr/0047-public-api-authentication-is-a-verifier-at-the-vertical-mount.md) separates authentication from resource authorization; [ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md) keeps budgets with the resource owner; [ADR 0061](../adr/0061-continuing-sessions-own-ordered-assignments-and-retained-receipts.md), [ADR 0062](../adr/0062-session-generations-await-governed-children-and-retain-checkpoint-intents.md), [ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md) and [ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md) establish retained receipts, fenced transfer and fresh exact authority that this store must be able to serve.

[Plan 84](84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) has implemented the consumer mechanics and is waiting on the real provider that plan 99 builds on this store; this plan does not touch plan 84's modules. [Plan 85](85-adapt-durable-delivery-through-validated-coordinator-decisions.md) will later submit integrated acceptance to the `Shikigami.Objective.Acceptance` contract defined here rather than keeping a second completion store.


The reviewed contracts are recorded in [ADR 0067](../adr/0067-objective-checkpoints-use-assignment-scoped-preconditions.md) (checkpoint preconditions and instruction invalidation) and [ADR 0068](../adr/0068-objective-creation-has-authority-before-association.md) (creation authority before association). These decisions now have their store implementation here; runtime-origin validators and production worker providers remain plan 99. [ADR 0070](../adr/0070-objective-receipts-and-integrated-acceptance-share-one-command-owner.md) records the shared command/receipt and integrated-acceptance boundary.

## Plan of Work

### Milestone 1 — Declare the objective domain, its types and the closed command sum

Add `domain/shikigami-objective.keiro` to `domain/shikigami.keiro-workspace` as a checked aggregate with a protected payload, mirroring the worker-session declaration, and generate its lifecycle and read-model modules into `shikigami-core/src/Shikigami/Generated/`. Create the migration with `just new-migration objective-checkpoints`. Use schema-qualified `shikigami` tables for current objective state, assignment records, command receipts, protected payloads, run/conversation associations, retained coordination scopes and checkpoint source cursors; plan 99 supplies runtime validators and consumers for the last three but their tables are allocated here so one migration carries the domain. Register the projection group in the shared generated catalog that `Runtime.hs` loads. Receipts and protected records must survive terminal workflow garbage collection.

Create `shikigami-core/src/Shikigami/Objective/Types.hs`. An objective has a stable `ObjectiveId`, access owner, explicit member roles, title, goal and instructions, `revision`, `instructionsRevision`, `criteriaRevision`, structured completion criteria, status, bounded decisions, assumptions and next actions, and optional typed external references (a Rei intention, an ExecPlan or an external protocol task; their lifecycles stay independent). Statuses are `Open`, `Blocked`, `Completed` and `Cancelled`; blocking is reversible, and completion or cancellation stop fresh progress admission while still allowing administrative access changes and reconciliation of already accepted effects. Completion is never inferred from a run status. An `ObjectiveAssignmentId` is distinct from a continuing session's per-message `AssignmentId`: it identifies a logical work item and stores its own assignment revision, instruction revision, dependencies, designated agent principal, owner epoch, state and references to its worker session and accepted result revisions. The assignment revision increments whenever any of those change and is the value `ObjectiveVersion.assignmentRevision` reports; sibling progress advances the objective revision without touching it. Every accepted `ReviseInstructions` also increments every existing assignment revision in the same transaction, even if instructions later return to their previous text. Objective status transitions likewise invalidate all assignment revisions, preventing a block/unblock cycle from reviving old intents. Assignment IDs and their revision counters are never reset or reused. Criteria changes remain detectable through `criteriaRevision`. Thus the unchanged `ObjectiveVersion` codec carries instruction invalidation through `assignmentRevision`; it needs no additional expected instruction field. A result reference includes the producing run/execution/session, an immutable result or payload digest, artifact identity and acceptance disposition; narrative notes are not acceptance evidence. Unresolved operations reference their owning execution/session records and stay visible until that owner reconciles them.

Define the access-principal sum here, distinguishing a verified API caller, a recorded agent identity and a trusted local operator. Never turn an arbitrary principal-shaped string into authority. Owners and explicit coordinators may manage assignments and propose acceptance; worker members may record progress only on assignments they own; read-only members inspect only permitted data; only owners or explicitly granted completers accept completion. Grants and revocations are versioned owner commands. An agent may create an objective only when operator policy grants creation, and creating one grants no access to existing objectives.

Add the shared objective-tracking configuration and loader fields in `shikigami-core/src/Shikigami/App/Config.hs` and `App/Config/Load.hs`: explicit enablement, a recorded local operator identity and administration policy, and default-deny agent creation policy keyed by recorded principal. Validate configuration without constructing worker providers. Include loader tests for defaults, invalid identity, explicit creation grants and disabled tracking. Plan 99 consumes these settings for provider wiring; plan 100 can build its API and operator CLI after this plan alone, without waiting for worker integration.

Create `shikigami-core/src/Shikigami/Objective/Command.hs` with the closed public sum `ReviseInstructions`, `ReviseCriteria`, `SetAssignments`, `RecordProgress`, `RecordEvidence`, `SetNextAction`, `SetBlocked`, `ProposeCompletion`, `AcceptCompletion`, `CancelObjective`, `GrantMember`, `RevokeMember`, `BindConversation` and `LinkExternal`, plus internal provider-only commands for checkpoint ingestion and ownership transfer that are unavailable as HTTP or model tags. Creation is its own operation with a uniqueness key scoped to the authenticated creator and operation key, so a retry cannot create a second objective. `SetAssignments` validates and commits the entire proposed bounded graph, rejecting duplicate identities, dangling dependencies and cycles, and cannot change an active session owner without the handoff protocol. Milestone 1 is accepted when shared configuration loader tests pass, the workspace scaffolds cleanly, the migration applies in the PostgreSQL test harness, `just migration-schema-isolation` exits zero and `cabal build all` succeeds with the new modules registered.

### Milestone 2 — One conditional command executor with receipts

Create `shikigami-core/src/Shikigami/Objective/Capability.hs` (authenticated command admission) and `shikigami-core/src/Shikigami/Objective/Store.hs` (conditional persistence). All writes pass this executor. Authenticate and authorize the caller first; then look up an existing receipt by deduplication key before optimistic revision validation. The key includes objective and operation identity; the fingerprint includes actor, command tag, semantic payload, expected revisions and owner epoch. An identical accepted retry returns the original receipt even after later progress; a changed payload under the same key conflicts. A new write locks the objective and selects preconditions from the closed command constructor, never from a caller-selected flag. Public mutations and ownership transfer require exact expected objective revision equality. Internal checkpoint ingestion instead requires equality of the addressed assignment revision, criteria revision, owner, epoch, root and active flag, plus an expected objective revision no greater than the current revision. Instruction and status changes invalidate the assignment revision as specified in milestone 1. Sibling progress may therefore commit from the same ordering base. Both paths validate under the same lock and allocate the next objective revision from the current stored revision, so checkpoint receipts exceed their ordering base. The executor validates the whole transition, appends the checked lifecycle event, writes protected data and current rows and stores the receipt in one transaction. Check membership, role and revision inside that transaction so a concurrent revocation cannot race an authorized mutation. Obtain any external exact-action decision immediately before the boundary, without holding a database lock across a network call. On conflict return a typed result with no partial progress or evidence writes. Persist definitive non-commit outcomes so a conflicted operation can never later become accepted; connection loss produces uncertainty, not a manufactured negative receipt. Expose typed create, read, execute and read-receipt operations and typed errors for missing, denied, conflict, invalid evidence, unavailable and unresolved outcomes. Actor and run attribution come from trusted adapter context, never from model content.

Creation authorizes a creator-level grant before any objective exists. Define a trusted optional creation origin in `Objective/Types.hs` containing the recorded run/execution or conversation-turn coordinates and accepted operation ID, or verified Flow workflow/generation/static-label coordinates; it is supplied by runtime adapters, never public JSON. Atomically commit the objective, creator membership, immutable receipt and origin link, keyed by creator and operation key. The receipt identifies that new objective for subsequent commands. This origin link does not rewrite a previously accepted run request or its fingerprint, grant access to other objectives, create worker slots, or widen an accepted tool binding. Plan 99 owns validation and lookup of runtime origins through their owning stores; plan 101 supplies the accepted operation context. Store-level tests use trusted fixtures until those adapters exist.

Create `shikigami-core/src/Shikigami/Objective/Catalog.hs` for the projection handlers. Add `shikigami-core/test/Shikigami/ObjectiveSpec.hs` for pure validation and `shikigami-core/test-postgres/Shikigami/ObjectiveStoreSpec.hs` for the store. Milestone 2 is accepted when two public-command writers at one revision yield one accepted transition and one typed conflict, an identical retry after progress returns the original receipt and IDs, a changed payload under a reused key conflicts, and evidence inserted in a rolled-back transaction is absent afterwards.

Milestone 2 also requires two internal sibling checkpoint commands from one objective ordering base to succeed with distinct increasing receipts, while two public commands from one revision still yield one conflict. An instruction-only update must reject a previously prepared checkpoint without advancing its source cursor; changing instructions back must not revive it. A retry of an already accepted checkpoint after an instruction change returns its original receipt subject to current authorization. Verify creation retry retains one objective, one origin link and one creator membership, and rollback leaves none of them.

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

The migration command prints the created numbered path and appends it to the manifest; do not run it twice for one change. The schema check must exit zero. The PostgreSQL suite applies migrations to disposable databases through `shikigami-core/test-postgres/Main.hs`; no production connection is needed.

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

The persistence guarantee holds at its actual transaction boundary: objective state, evidence, lifecycle event and receipt all commit or none do. Two concurrent public-command writers from one revision yield one accepted transition and one conflict. Creation retry and mutation retry return the original IDs after reconnect. Wrong-key payload reuse, graph cycles, stale owner epochs and invalid completion leave state unchanged. A real session receipt projects into `ObjectiveVersion` with the addressed assignment's own revision, and a sibling assignment's progress advances the objective revision without changing it. Required acceptance is the passing `shikigami-core-test` and `shikigami-core-postgres-test` suites with the new groups, a zero exit from `just migration-schema-isolation` and a gate report with no unexplained breaking findings. Record actual passing counts only after running them.


## Idempotence and Recovery

Migrations are additive, schema-qualified and manifest-ordered; never edit or rename an applied migration. Retain objective data, command outcomes, protected evidence and receipts beyond workflow journal collection, initially indefinitely; a deletion or compaction policy that preserves live and deduplication references is separate work. Do not rebuild live-only tables from incomplete event metadata. On a lost acknowledgement, retry the original command bytes and key: accepted receipts precede revision checks, while access checks still precede disclosure. A known stale conflict is resolved by a new explicit command against reread state, never by last-writer-wins. Rerunning the scaffold is safe; rerunning `just new-migration` for the same change is not.


## Interfaces and Dependencies

`Shikigami.Objective.Types` owns `ObjectiveId`, `ObjectiveAssignmentId`, the access-principal sum, versioned snapshots, receipts and evidence references. `Shikigami.Objective.Command` owns the closed command sum and the internal provider-only commands. `Shikigami.Objective.Capability` owns authenticated command admission; `Shikigami.Objective.Store` owns conditional persistence; `Shikigami.App.Config` and its loader own shared enablement, local operator identity and creation policy, delivered here in milestone 1. `Shikigami.Objective.Catalog` owns projections; `Shikigami.Objective.Acceptance` owns completion. Plan 99 adapts the worker providers over these, plan 100 the HTTP and CLI envelope, plan 101 the native tool and Flow effect; none adds a second executor. Existing dependencies and the selected cohort are used unchanged: `mori://shinzui/keiro` for aggregates and `runCommandWithCatalogProjections`, `mori://shinzui/kiroku/packages/kiroku-store` and `mori://shinzui/kioku/packages/kioku-core` for the existing stores, and `mori://shinzui/kikan-en` for the exact capability action contract. Locate any further dependency API through Mori and read its source before use; verify registry releases and upstream tags before changing bounds or pins, because local registry metadata can lag. This plan has no hard prerequisite within MasterPlan 17.


The concrete store also exposes `Capability.readObjectiveVersion` and `Store.referenceFor` for indexed worker-reference projection. `ObjectiveHost` supplies authenticated context, exact action authorization, origin/fence validation and retained verifier-result interpretation; its callbacks are trusted runtime configuration, never command fields. `EvidenceVerification` distinguishes `ResultObserved` from verifier-backed `CheckPassed`/`CheckFailed` and records the verified criterion and journey. A successful child result is progress only. Finite assignments may omit root/cutoff/session; projection into `ObjectiveVersion` requires an admitted root and cutoff. The provider ID is `shikigami-objective-v1` and its opaque key is indexed in assignment rows. `SHIKIGAMI_OBJECTIVES` (or YAML key `objectives`) loads a JSON object with `enabled`, optional `operator`, `administration` (`OwnObjectivesOnly` or `AdministerAll`) and default-empty `agentCreation` recorded principal IDs. Disabled HTTP authentication grants none of these identities.

## Revision Notes

2026-10-29: Separated checkpoint preconditions from public revision equality, specified instruction/status invalidation, moved shared configuration here and defined atomic creation origins.

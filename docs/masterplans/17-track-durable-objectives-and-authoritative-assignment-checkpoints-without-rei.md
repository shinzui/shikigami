---
id: 17
slug: track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei
title: "Track durable objectives and authoritative assignment checkpoints without Rei"
kind: master-plan
created_at: 2026-10-29T00:19:50Z
intention: "intention_01m62265gjex4a0k54gsbwx4gs"
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
      note: "Vision-aligned decomposition; resolve checkpoint version/precondition contract, agent creation bootstrap, and EP-3 configuration prerequisites."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T13:05:53Z
      mode: "update"
      note: "Apply review findings: distinct checkpoint preconditions, instruction invalidation, early shared configuration and autonomous objective creation; add ADRs 0067-0068."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-30T19:36:19Z
      mode: "update"
      note: "Record EP-1 implementation, shared store interfaces and remaining provider/API/tool qualification gates."
---

# Track durable objectives and authoritative assignment checkpoints without Rei

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Deliver [IR-13](../improvement-requests/support-optional-major-task-tracking.md): a user or authorized agent creates a durable objective, inspects its goal, completion criteria, assignments, evidence and next action, and continues it in a later run or conversation without a Rei endpoint or memory recall. A successful worker run records evidence; only explicit acceptance of the integrated result completes the objective. Concurrent updates either commit in order or return a visible conflict, and a retry after a lost acknowledgement returns the original receipt. The same initiative supplies the production objective/checkpoint, ownership and coordination-scope providers that continuing worker sessions already consume through fixtures, so [plan 84](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) can close its IR-13 completion gate.

IR-13 calls this record a "major task". This initiative names it an objective. [Plans 84–87](../plans/84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md), [UC-1](../use-cases/adaptive-autonomous-delivery.md), `ObjectiveRef` and `ObjectiveVersion` in `shikigami-core/src/Shikigami/WorkerSession/Checkpoint.hs` and ADRs 0061–0066 already use that word for exactly this record, and `Task` stays free for the A2A protocol task of [IR-6](../improvement-requests/support-a2a-cross-runtime-agent-interoperability.md), a caller-scoped delegation projection with its own lifecycle that may link to an objective but never shares its identity. Modules live under `shikigami-core/src/Shikigami/Objective/`, the HTTP vertical is `/objectives`, and the CLI group is `shikigami objectives`. An objective is a goal spanning executions. An assignment is a versioned piece of that goal with dependencies and a designated agent owner. A checkpoint is the authoritative current objective/assignment view, including accepted evidence and pending work.

After completion a user can create an objective over the authenticated API or CLI with Rei disabled; see an agent run and a conversation turn associated with it; watch a durable Skill or Flow record progress and evidence through a native tool whose authority comes from the runtime rather than from model text; restart the service and read the same revision, receipts and attribution from a later run; and complete the objective only through explicit authorized acceptance of the integrated result. Operators enable objective tracking explicitly and inspect bounded, redacted objective history.

This MasterPlan is an independently owned prerequisite of [MasterPlan 14](14-deliver-adaptive-autonomous-objectives-with-durable-workers.md), not one of its children. It must not wait for plan 84 to finish, because plan 84 is waiting for this provider. [Plan 96](../plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md) owns IR-11 repository workspaces and process fencing and is in progress; its `WorkspaceProvider` supplies the real fence proof that ownership transfer consumes here. Plans 85–87 keep adaptive decisions, integrated repository qualification and recurring mandates.

Excluded: adaptive orchestration, recurrence, offline replication, automatic Rei mirroring, an A2A wire mapping, a project-management product, real repository write fencing (plan 96) and any change to dependency bounds or pins. An optional typed Rei intention link is the whole Rei integration in this initiative; a Rei failure must never change objective state. [Plan 97](../plans/97-track-durable-tasks-and-authoritative-assignment-checkpoints-without-rei.md) was the single-plan draft of this work and is superseded by this MasterPlan and its children.


The vision in [README](../../README.md) and [UC-1](../use-cases/adaptive-autonomous-delivery.md) includes agents initiating useful work under declared authority. Accordingly, an authorized agent can establish its first objective without manual API setup. Ordinary finite objectives need no worker hierarchy; coordination, budgets, memory and recurring supervision retain their existing owners.

## Decomposition Strategy

Five children in three phases. Phase A is the provider slice: EP-1 persists authoritative objectives behind one conditional command executor, and EP-2 adds trusted run/conversation associations, the real `CheckpointProvider`, `OwnershipProvider` and `CoordinationAuthority` implementations, explicit conflict reconciliation and production wiring. Phase A alone closes plan 84's IR-13 completion gate, which is the critical path for MasterPlan 14: plans 85–87 cannot start until plan 84 is Complete, and plan 84 needs only the provider. Phase B adds the user-facing surfaces in parallel: EP-3 the authenticated HTTP vertical and CLI, EP-4 the durable native tool, Flow effect and conversation admission. Phase C is EP-5: the no-Rei continuity fixture, integrated-completion checks, documentation, IR-13 closure and ADR distillation.

The store (EP-1) is separate from the providers (EP-2) because the persistence guarantee is provable with PostgreSQL concurrency and crash-window tests before any worker consumer exists, and because EP-2 also edits owners outside the objective domain: `shikigami-core/src/Shikigami/AgentRun/Ledger.hs` for run acceptance and the `WorkerSession` modules for conflict reconciliation. The API (EP-3) is separate from agent capabilities (EP-4) because they have different authority sources (a verified API caller or recorded local operator versus a recorded agent principal with frozen tool bindings and workflow patch guards), different test surfaces (server contract versus replay and workflow-versioning deployment cases) and no shared code beyond the EP-1 command owner, so they proceed in parallel. Qualification (EP-5) is its own child because the runner needs the API, the tool path and the providers together, and because it owns the IR-13 lifecycle closure and consumer-plan wording that must not be claimed earlier.

Alternatives considered. One ExecPlan (plan 97) was rejected after review: five milestones across three packages, two consumer plans and shared wiring made it MasterPlan-scale, and its single Progress list hid that the plan 84 gate closes two milestones in. One child per IR-13 acceptance item was rejected because the items cut across the same modules. Folding the API into EP-2 was rejected because it delays the gate. Folding qualification into EP-4 was rejected because it would make EP-4 wait for EP-3.

Research against `3900c0e634d9b559e92a6989bb10f9943e0beab1` verified every module, recipe, symbol and ADR the children cite. The consumer contract is fixed: `CheckpointProvider{current,commit}` and `ObjectiveVersion` (revision, assignmentRevision, criteriaRevision, ownerEpoch, owner, active, rootId, cutoff) in `shikigami-core/src/Shikigami/WorkerSession/Checkpoint.hs`; `matchesReceipt` requires only that the receipt revision exceed the intent's expected revision; `Store.prepareCheckpoint` validates root, owner and epoch and a window of at most 100 events but never revision equality; `Integration.hs` turns `CheckpointConflict` into `EventsConflict` with no supersession path; `Workflow.hs` `currentAssignmentAuthority` requires an exact revision match at new-assignment admission; `Transfer.hs` defines `WorkspaceProvider{reconcile,admitWrite}`, `OwnershipProvider{transfer}` and `FenceProof`; `Capability.hs` defines `CoordinationAuthority{admit,reacquire}` and `authorizeExact` over `InvokeCapabilityTool`; production sets `coordination = Nothing` in `shikigami-workers/src/Shikigami/Workers/Config.hs` and `TransferServices sessions Nothing Nothing` in `shikigami-server/src/Shikigami/Server/Command/Workers.hs`; the API mounts only `health` and authenticated `agents`; no `Shikigami/Objective` directory exists. Mori discovery found no registered project that owns an agent-objective record (Rei is intention-bound, Keiei owns organization operating models, Kotei is CI/CD) and located `runCommandWithCatalogProjections` in `mori://shinzui/keiro`, project-relative `keiro/src/Keiro/Projection.hs` (artifact-level URI pending). Keiro's process manager was considered for cross-store checkpoint integration and rejected: ADR 0062 already fixes an in-process intent/receipt exchange, both stores share one database, and a subscription-driven saga would add a delivery hop without gaining atomicity.

Relevant local decisions, discovered by scanning `docs/adr/` filenames and headings (the bundle is not profile-governed): [ADR 0011](../adr/0011-defaulted-agent-fields-preserve-journal-codec-compatibility.md) for additive defaulted fields; [ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md) and [workflow versioning](../workflow-versioning.md) for real patch branches; [ADR 0013](../adr/0013-flow-bodies-reach-the-world-only-through-capabilities.md) for replay-safe effects with stable write identities; [ADR 0025](../adr/0025-capability-overlays-are-requests-for-additive-model-tools.md), under which a descriptor label is not deduplication; [ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md) for principal-keyed authority; [ADR 0047](../adr/0047-public-api-authentication-is-a-verifier-at-the-vertical-mount.md) for authentication separate from resource authorization; [ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md), under which budgets stay with the resource owner; [ADR 0057](../adr/0057-skill-parents-admit-frozen-assignments-and-await-execution-children.md) for frozen tool bindings and accepted operation context; [ADR 0058](../adr/0058-conversation-acceptance-and-wakes-retain-their-generation.md) for conversation turns owning their admission; [ADR 0061](../adr/0061-continuing-sessions-own-ordered-assignments-and-retained-receipts.md), [ADR 0062](../adr/0062-session-generations-await-governed-children-and-retain-checkpoint-intents.md), [ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md) and [ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md) for mailbox ownership, retained intents, fenced transfer and fresh exact authorization. Each child repeats the subset it depends on. Cross-plan decisions that deserve ADRs during implementation: objective ownership inside Shikigami, receipt-before-revision ordering under authentication, the mapping from objective assignment to session assignment, assignment-scoped conflict with explicit reconciliation, and integrated completion as the only terminal path.


The reviewed contracts are recorded in [ADR 0067](../adr/0067-objective-checkpoints-use-assignment-scoped-preconditions.md) (checkpoint preconditions and instruction invalidation) and [ADR 0068](../adr/0068-objective-creation-has-authority-before-association.md) (creation authority before association). These are accepted design decisions; implementation and acceptance evidence remain outstanding.

## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Persist authoritative objectives and conditional commands | [docs/plans/98-persist-authoritative-objectives-and-conditional-commands.md](../plans/98-persist-authoritative-objectives-and-conditional-commands.md) | None | None | In Progress |
| EP-2 | Supply trusted objective associations and the real checkpoint, ownership and scope providers | [docs/plans/99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md](../plans/99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md) | EP-1 | External plan 96 (real fence proof) | Not Started |
| EP-3 | Expose governed objective inspection through the API and CLI | [docs/plans/100-expose-governed-objective-inspection-through-the-api-and-cli.md](../plans/100-expose-governed-objective-inspection-through-the-api-and-cli.md) | EP-1; EP-2 M1 for its milestone 3 | None | Not Started |
| EP-4 | Make objective capabilities durable for agents and conversations | [docs/plans/101-make-objective-capabilities-durable-for-agents-and-conversations.md](../plans/101-make-objective-capabilities-durable-for-agents-and-conversations.md) | EP-1, EP-2 | None | Not Started |
| EP-5 | Qualify no-Rei objective continuity and close IR-13 | [docs/plans/102-qualify-no-rei-objective-continuity-and-close-ir-13.md](../plans/102-qualify-no-rei-objective-continuity-and-close-ir-13.md) | EP-2, EP-3, EP-4 | External plan 96 (real fence); plan 84 completion | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled. EP numbers identify rows here; the linked ExecPlan file ids are 98–102. A whole-child reference is a start gate: that child must be Complete before the dependent child begins. EP-3's dependency on EP-2 milestone 1 is a milestone gate: EP-3 milestones 1–2 need only EP-1, while EP-3 milestone 3 exercises the optional objective reference on run requests and `BindConversation` over HTTP, which EP-2 milestone 1 delivers. External plan 96 is a soft dependency everywhere: a labeled deterministic fence fixture stands in for its `WorkspaceProvider` until that provider is qualified, and no child claims real workspace fencing.


## Dependency Graph

```text
EP-1 (98) ---> EP-2 (99) ---------------> EP-4 (101) ---+
   |              |                                      |
   |              | milestone 1: trusted associations    +---> EP-5 (102)
   |              v                                      |
   +---------> EP-3 (100) -------------------------------+

EP-2 Complete closes the IR-13 completion gate on plan 84 (MasterPlan 14 EP-4).
Plan 96 supplies the real fence proof consumed by EP-2 transfer and EP-5;
a labeled fixture stands in until that provider is qualified.
```

EP-2 requires EP-1 because the providers are adapters over EP-1's command executor, types and receipts: `commit` is an internal objective command and `current` reads EP-1's current rows. EP-3 requires EP-1 because the HTTP command envelope wraps EP-1's closed command sum and the server calls EP-1's command owner; its milestone 3 additionally requires EP-2 milestone 1. EP-4 requires EP-1 for the command owner and EP-2 because the native tool derives authority from the retained coordination scope and the trusted run/conversation association that EP-2 persists. EP-5 requires EP-2, EP-3 and EP-4 because the runner drives the API, the tool path and the providers together.

EP-3 and EP-4 proceed in parallel once EP-2 is Complete; EP-3 milestones 1–2 can start as soon as EP-1 is Complete. No child waits on plan 84, plan 96 or plans 85–87. At EP-2 completion the implementer updates plan 84's Progress and the MasterPlan 14 registry and Progress with the real provider evidence; plan 84's IR-11 gate stays open until plan 96 is qualified, and only plan 84 runs the joint late-writer/restart test that closes both sides. Plans 85 and 87 consume the provider contract and `Shikigami.Objective.Acceptance` after EP-2; neither starts within this MasterPlan.


## Integration Points

EP-1 exposes `Objective.Capability.readObjectiveVersion` over indexed references and trusted `ObjectiveHost` callbacks for authenticated context, source/fence checks and retained verifier results. Finite assignments may omit a resource root and session; the version projection refuses until an admitted root/cutoff is bound. Worker results are observations, while automatic acceptance requires verifier-backed criterion and journey facts. EP-2 must supply real host callbacks before wiring providers. [ADR 0070](../adr/0070-objective-receipts-and-integrated-acceptance-share-one-command-owner.md) records this shared boundary.

**Objective types, closed command sum and command owner — EP-1 owns; EP-2, EP-3 and EP-4 adapt.** `shikigami-core/src/Shikigami/Objective/Types.hs` defines `ObjectiveId`, `ObjectiveAssignmentId`, the access-principal sum, versioned snapshots, receipts and evidence references. `Objective/Command.hs` defines the closed public sum (`ReviseInstructions`, `ReviseCriteria`, `SetAssignments`, `RecordProgress`, `RecordEvidence`, `SetNextAction`, `SetBlocked`, `ProposeCompletion`, `AcceptCompletion`, `CancelObjective`, `GrantMember`, `RevokeMember`, `BindConversation`, `LinkExternal`) plus the internal provider-only commands for checkpoint ingestion and ownership transfer. `Objective/Capability.hs` is the single authenticated command admission owner, `Objective/Store.hs` the conditional persistence and `Objective/Acceptance.hs` the completion contract. EP-2's providers call the internal commands and `BindConversation`; EP-3 wraps the public sum in the `format: 1` envelope with `operationKey`, `expectedRevision` and `command` (discriminant `tag`); EP-4's tool and Flow effect inject operation key and trusted actor and never accept them from model JSON. No adapter adds a second executor or a second authorization order.

**Assignment identity and the worker consumer records — EP-1 owns the fields; EP-2 owns the provider.** An `ObjectiveAssignmentId` is distinct from a continuing session's per-message `AssignmentId` and stores its own assignment revision, which is the `assignmentRevision` that `ObjectiveVersion` reports. Provider id `shikigami-objective-v1` binds the objective id and assignment id in an opaque digest indexed by `shikigami.objective_assignments.reference_key`; existing `ObjectiveRef` codecs stay intact. Conflict is defined per addressed assignment: a commit validates the assignment revision, criteria revision, owner and epoch, root and active flag, with instruction and status changes invalidating all assignment revisions, and treats the objective-wide revision as an ordering base that the receipt must still exceed. The early producer/consumer check, owned by EP-2 milestone 2, is that two sibling assignment checkpoints prepared from the same expected objective revision both commit without reconciliation, and that a lost acknowledgement followed by a retry returns the original receipt through `shikigami-core/src/Shikigami/WorkerSession/Integration.hs`.

**Command preconditions — EP-1 owns; EP-2 consumes.** Public commands and ownership transfer use exact expected objective revision equality. Internal checkpoint ingestion uses assignment-scoped equality and an objective revision ordering base, all checked by the same executor under the objective lock; the next revision is allocated from current state. EP-1 increments every assignment revision atomically on objective instruction or status changes, even if later reverted, preserving the existing checkpoint codec. EP-1 proves these rules at the store boundary; EP-2 proves them through the real session consumer.

**Creation before association — EP-1 owns persistence; EP-2 owns origin validation; EP-4 owns admission.** EP-1 defines creator-scoped authorization and atomic objective, creator-membership, origin-link and receipt persistence. EP-2 milestone 1 validates and resolves creation origins against accepted execution/turn/operation records. EP-4 admits a frozen creation scope without requiring an existing objective and permits subsequent commands only on receipt-backed created objectives within that scope, with fresh membership and exact authorization. It never rewrites run acceptance or widens a frozen tool menu. Future run associations and explicit conversation binding retain their existing admission rules. EP-5 qualifies first-objective creation and recovery through the real tool, in addition to API creation.

**Run request envelope and acceptance ledger — EP-2 owns; EP-3 and EP-4 consume.** The optional typed objective/assignment reference on fresh public run requests (`shikigami-api/src/Shikigami/AgentRun/Api.hs`), the application-owned envelope (`shikigami-core/src/Shikigami/Agent/RunJob.hs`) and `shikigami-core/src/Shikigami/AgentRun/Ledger.hs` commit permitted association, run acceptance and queue send together; the association joins the request fingerprint. EP-3 exercises it over HTTP in its server contract; EP-4 reads the accepted association when admitting tools. Old decoders, absent-objective behavior and old trigger JSON are preserved and never reinterpreted as trusted objective metadata.

**Retained coordination scope — EP-2 owns; EP-4 consumes.** `shikigami-core/src/Shikigami/Objective/Coordination.hs` implements `CoordinationAuthority{admit,reacquire}` from `shikigami-core/src/Shikigami/WorkerSession/Capability.hs`, persisting each admitted scope by fingerprint. EP-4's coordinator-run tool derives objective authority from that scope, which the existing `shikigami-worker-coordination-v1` branch already journals, so coordinator runs need no new journaled step.

**Operator configuration — EP-1 owns; EP-2, EP-3 and EP-4 consume.** EP-1 milestone 1 delivers the explicit objective-tracking setting in `shikigami-core/src/Shikigami/App/Config.hs` and its loader, the recorded local operator identity and administration policy, and default-deny agent creation policy. EP-3 milestones 1–2 therefore need no late EP-2 configuration. **Provider wiring — EP-2 owns.** EP-2 milestone 3 installs the providers in `shikigami-workers/src/Shikigami/Workers/Config.hs` and `shikigami-server/src/Shikigami/Server/Command/Workers.hs` using EP-1’s settings. A missing provider or authority refuses objective work; ordinary unassociated runs still work; disabling the feature never selects an older unsafe path.

**Workflow patch ids — EP-4 owns.** `shikigami-objective-tracking-v1` for agent runs and `shikigami-conversation-objective-tracking-v1` for conversations are reserved names, declared only where a new journaled step is unavoidable, in the owning `domain/` member, following [workflow versioning](../workflow-versioning.md) and ADR 0012. No other child declares a patch.

**Public paths — EP-3 owns.** `/objectives` under the existing authenticated mount, its request and response shapes, status codes, pagination (default 20, cap 100) and payload limits (1 MiB commands, 16 KiB model replies). A future A2A subtree mounts under its own base path and never reuses these identities.

**Shared process/schema wiring — each child owns its additions.** `domain/shikigami.keiro-workspace` and `domain/shikigami-objective.keiro` (EP-1), the migration manifest (EP-1 allocates `objective-checkpoints`; later children add additive migrations only when needed), Cabal and test inventories, `shikigami-core/src/Shikigami/Runtime.hs` catalog registration (EP-1), `shikigami-api/src/Shikigami/Api.hs` and `shikigami-server/src/Shikigami/Server/App.hs` (EP-3), `shikigami-core/src/Shikigami/Flow.hs`, `Agent/Workflow.hs`, `Agent/Conversation.hs` and `Workflow/Versioning.hs` (EP-4). Serialize edits to these files and never hand-edit `Generated/`.

**Acceptance ownership.** IR-13 acceptance 1 (no-Rei start, inspect, resume) is built by EP-3 and EP-4 and qualified by EP-5. Acceptance 2 (crash between objective update and journaled result) belongs to EP-4. Acceptance 3 (ordered result or visible conflict) belongs to EP-1 for the store and EP-2 for sibling and conflicting checkpoints. Acceptance 4 (no authority, attribution) belongs to EP-1 and EP-3. Acceptance 5 (coordinator restart after ownership change) belongs to EP-2 and is replayed by EP-5. Acceptance 6 (parent stays open until integrated acceptance) belongs to EP-1's acceptance contract and is demonstrated by EP-5. Plan 84's IR-13 gate cases (current reads, conflict-aware updates, stable deduplication, accepted evidence references, a stale checkpoint cannot restore an old owner) belong to EP-2. This is the completion matrix, not a claim of current implementation.


## Progress

2026-10-30: EP-1 implements the objective store, shared configuration and acceptance boundary; its final committed-candidate gate is pending. EP-2 through EP-5 remain unstarted. The real-provider gate on plan 84 remains open. The single-plan draft, plan 97, remains superseded. Cross-plan gates:

- [ ] Plan 84's IR-13 completion gate: closed when EP-2 is Complete and plan 84's Progress and the MasterPlan 14 registry carry the real provider evidence.
- [ ] IR-13 lifecycle: `in-progress` with this MasterPlan as `targetPlan`; `completed` only with EP-5 evidence.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Use constructor-selected preconditions in one executor, invalidate assignment revisions on instruction/status changes, and admit objective creation through a separate frozen creator scope. Move shared operator configuration to EP-1 so EP-3 retains its declared start gate.
  Rationale: Resolve the review without a new checkpoint codec, a second executor, manual first-objective setup or a hidden worker-provider dependency. ADRs 0067 and 0068 record the durable contracts.
  Date: 2026-10-29

- Decision: Keep authoritative objective state in Shikigami, using its checked domain-command and transactional projection pattern; memory stays supplementary context and Rei an optional external reference.
  Rationale: No registered project owns an agent-objective record (Rei is intention-bound, Keiei owns organization strategy, Kotei is CI/CD, Keiro supplies aggregates and process managers without a domain). A separate service would add a deployment and a distributed commit boundary without satisfying any requirement the existing store cannot. Keiro's process manager was rejected for checkpoint integration because ADR 0062 already fixes an in-process intent/receipt exchange on one database.
  Date: 2026-10-28

- Decision: Name the record `Objective` everywhere (modules, API path, CLI group, provider id, patch ids), not `Task`.
  Rationale: Plans 84–87, UC-1, the worker-session code and ADRs 0061–0066 already say "objective" for this record. `Task` is reserved for the A2A protocol task of IR-6, which is a caller-scoped delegation projection with its own lifecycle; it may link to an objective but never shares its identity, and its HTTP+JSON subtree mounts under its own base path. IR-13's "major task" is this objective.
  Date: 2026-10-28

- Decision: Replace plan 97 with this MasterPlan and five children, with the provider slice (EP-1, EP-2) ahead of the user-facing surfaces (EP-3, EP-4) and qualification last (EP-5).
  Rationale: Plan 84 is gated only on the provider, plans 85–87 cannot start until plan 84 is Complete, and the public API is not on that path. Separate children make the gate a registry event instead of a milestone buried in one plan, and let the API and the agent capabilities proceed in parallel.
  Date: 2026-10-28

- Decision: `Shikigami.Objective.Capability`, the single authenticated command admission owner, lands in EP-1 rather than with the agent tools.
  Rationale: Providers (EP-2), API and CLI (EP-3) and tools/Flow (EP-4) are all adapters over it. Authentication first, then receipt lookup, then optimistic revision validation must exist exactly once.
  Date: 2026-10-28

- Decision: Conflict is defined per addressed assignment, with the objective-wide revision as an ordering base; each `ObjectiveAssignmentId` carries its own revision, which is what `ObjectiveVersion.assignmentRevision` reports.
  Rationale: In UC-1 two workers checkpoint concurrently as a matter of routine. A whole-objective equality check would turn every such commit into a parent-authorized reconciliation. The consumer requires only an advancing receipt revision and matching owner, epoch and root, so a sibling's progress must not conflict a commit whose own assignment, the objective's instructions or criteria, its ownership and its status are unchanged.
  Date: 2026-10-28

- Decision: Distinguish an objective's access owner and overall completion from each assignment's owner.
  Rationale: `ObjectiveVersion.owner` is compared with a worker session's owner, so a worker-facing reference must resolve one assignment within the objective. One objective-wide worker identity cannot serve multiple workers.
  Date: 2026-10-28

- Decision: Expose objective mutations through one closed command service, a dedicated native durable tool and a replay-safe Flow capability, with runtime-owned operation keys, retained immutable requests and store receipts. General capability overlays stay observation-only.
  Rationale: Tool names and model-supplied identities confer no authority (ADR 0025, ADR 0066). One command owner keeps deduplication and authorization order identical across HTTP, CLI, tool and Flow.
  Date: 2026-10-28

- Decision: A definitive checkpoint conflict requires a retained non-commit result and explicit parent-authorized reconciliation; a transport timeout is not a conflict, and a pending intent is never silently replaced by a newly fetched version.
  Rationale: The original operation might already have committed. `WorkerSession/Store.hs` currently retains a conflicted intent with no supersession command, so EP-2 adds one rather than letting a legitimate conflict block progress or handoff permanently.
  Date: 2026-10-28

- Decision: Declare a workflow patch only where a new journaled step or a straddling shape change is unavoidable; `shikigami-objective-tracking-v1` and `shikigami-conversation-objective-tracking-v1` are reserved names, not commitments to declare both.
  Rationale: A coordinator run derives objective authority from the retained coordination scope that the existing `shikigami-worker-coordination-v1` branch already journals, so unassociated creation, worker-child and conversation admission can need a new step.
  Date: 2026-10-28

- Decision: Scope includes HTTP/CLI access, later-run and conversation continuity, explicit completion and the real IR-13 side of worker integration; it excludes adaptive orchestration, recurrence, offline replication, automatic Rei mirroring, an A2A mapping and real workspace fencing, and fails closed for workspace transfers until plan 96's provider exists.
  Rationale: IR-13 must not depend on later initiatives, and no child may fabricate a workspace provider.
  Date: 2026-10-28

- Decision: Follow the improvement-request lifecycle used by IR-11 and IR-15: IR-13 is `accepted` with this MasterPlan as `targetPlan` at planning, `in-progress` at the first implementation commit and `completed` only with EP-5 evidence.
  Rationale: Corpus convention; the index, log and roadmap change in the same commit as each transition.
  Date: 2026-10-28


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Revision Notes

2026-10-29: Resolved the review by separating public and checkpoint preconditions, invalidating assignment revisions on instruction/status changes, moving shared configuration into EP-1, and specifying autonomous creation before association. Ownership and acceptance cascaded to all children; no implementation is claimed.

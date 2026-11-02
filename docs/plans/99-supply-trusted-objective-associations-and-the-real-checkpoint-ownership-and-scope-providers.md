---
id: 99
slug: supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers
title: "Supply trusted objective associations and the real checkpoint, ownership and scope providers"
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
      note: "Checkpoint validation lacks a retained expected instructions revision; reconcile sibling commits with EP-1 revision equality and expose configuration prerequisites."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-29T13:05:53Z
      mode: "update"
      note: "Specify codec-preserving instruction invalidation, creation-origin validation and consumer acceptance; consume EP-1 configuration."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-02T02:51:11Z
      mode: "implement"
      note: "Implement trusted run association admission and compatible run envelopes."
---

# Supply trusted objective associations and the real checkpoint, ownership and scope providers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

After this plan, continuing worker sessions run against a real objective owner instead of fixtures. An agent run or a conversation can be associated with an objective at acceptance time, and that association is trusted because it commits together with run acceptance and queue send. The production `CheckpointProvider`, `OwnershipProvider` and `CoordinationAuthority` are implemented by provider `shikigami-objective-v1` over the store from [plan 98](98-persist-authoritative-objectives-and-conditional-commands.md), with conflict defined per addressed assignment so that sibling workers checkpoint concurrently without parent reconciliation. A legitimate conflict no longer blocks a session forever: a parent-authorized reconciliation command supersedes a definitively rejected intent. The observable result is the continuing-session integration suite passing against real session and objective stores, including a lost acknowledgement, two sibling checkpoints and a stale concurrent update, and the IR-13 completion gate on [plan 84](84-coordinate-continuing-worker-sessions-and-fenced-handoffs.md) being recorded as closed in plan 84 and [MasterPlan 14](../masterplans/14-deliver-adaptive-autonomous-objectives-with-durable-workers.md). This is EP-2 of [MasterPlan 17](../masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md).


## Progress

- [ ] Milestone 1: trusted run and conversation associations commit with run acceptance and queue send; forged or unauthorized associations enqueue nothing; old requests keep their fingerprint and codec path.
- [ ] Milestone 2: `CheckpointProvider` and `OwnershipProvider` are implemented by `shikigami-objective-v1` with assignment-scoped conflict; two sibling checkpoints from one expected objective revision both commit, and a lost acknowledgement followed by retry returns the original receipt.
- [ ] Milestone 3: explicit checkpoint-conflict reconciliation, `CoordinationAuthority` from retained scopes, production wiring using plan 98’s operator configuration pass `ObjectiveCheckpointSpec`; plan 84's Progress and the MasterPlan 14 registry record the real IR-13 provider evidence.

2026-11-02 UTC implementation checkpoint: the run-association portion of milestone 1 is implemented. `Objective.Reference` supplies the typed selector; `Objective.Association` validates current caller coordination permission and assigned-agent membership under the objective lock inside the acceptance ledger transaction. Association, acceptance and queue delivery commit together. The HTTP handler refuses anonymous development callers; existing unassociated requests retain their fingerprint and journal/queue bytes. Associated fingerprints use a separate namespace, and six concurrent admissions produce one send and one immutable receipt. Retry checks current permission before returning the retained receipt, including after assignment withdrawal; omitting the selector cannot downgrade authentication. A trigger-induced ledger insert failure after association and enqueue rolls all three back.

Acceptance evidence: 632 core tests, 32 API tests, 473 PostgreSQL tests, 280 worker tests and 96 server tests pass. The latest objective-store rerun passes all 28 cases, including the post-enqueue failure injection and concurrent association acceptance. `just keiro-gate HEAD` passes with 156 conformance checks and a neutral replay diff; Haskell conventions pass. ADR 0070 records the run-admission boundary. No workflow step or generated domain shape changed.

Milestone 1 remains incomplete: implement verified conversation bindings and per-turn association snapshots, creation-origin validation/lookup against accepted runtime records, and their acceptance tests. Then implement milestones 2 and 3; production providers, retained coordination scopes, explicit conflict reconciliation and plan 84's real-provider gate remain open. EP-3 milestone 3 and EP-4 retain their existing prerequisites.

Planning baseline `3900c0e634d9b559e92a6989bb10f9943e0beab1`, inspected 2026-10-28. Hard prerequisite: plan 98 Complete.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Conflict is defined per addressed assignment; the objective-wide revision carried in a `CheckpointIntent` is an ordering base that the receipt must exceed, not an equality check.
  Rationale: `matchesReceipt` only requires an advancing revision and `Store.prepareCheckpoint` only checks owner, epoch and root, so the provider may let a sibling's accepted progress pass while a change to the addressed assignment, the objective's instructions or criteria, its ownership or its status is a definitive conflict. Otherwise routine two-worker progress in UC-1 stalls on parent reconciliation.
  Date: 2026-10-28

- Decision: A definitive conflict requires a retained non-commit result and an explicit parent-authorized reconciliation command; a transport timeout is not a conflict and a pending intent is never silently replaced by a newly fetched version.
  Rationale: The original operation might already have committed. `WorkerSession/Store.hs` retains a conflicted intent with no supersession command today, so this plan adds one.
  Date: 2026-10-28

- Decision: Ownership transfer consumes a `FenceProof` from the trusted configured `WorkspaceProvider`; until plan 96's provider is qualified a deterministic fence fixture stands in and is labeled as such, and no workspace provider is fabricated.
  Rationale: String equality alone never proves a workspace stopped writing; the joint late-writer/restart test belongs to plan 84's completion.
  Date: 2026-10-28


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

An objective is a goal spanning executions; an assignment is a versioned piece of it with a designated owner; a checkpoint is the authoritative current objective/assignment view. A revision detects intervening changes; an owner epoch increments on handoff. An operation key identifies one immutable command across retries, and a receipt records its committed result. A fence is proof that earlier writes and their processes cannot continue, not an expired lease. A retained coordination scope is the accepted set of parent run, identity, memory session, resource root, delegation context, allowed worker slots and limits that a coordinator was admitted with.

Plan 98 supplies `shikigami-core/src/Shikigami/Objective/Types.hs`, `Command.hs` (public sum plus internal checkpoint-ingestion and ownership-transfer commands), `Capability.hs` (authenticated command admission), `Store.hs`, `Catalog.hs` and `Acceptance.hs`, and the `objective-checkpoints` migration whose tables include associations, retained scopes and checkpoint source cursors. Each `ObjectiveAssignmentId` stores its own assignment revision. Read plan 98's Interfaces and Dependencies before starting.

The consumer records are in `shikigami-core/src/Shikigami/WorkerSession/Checkpoint.hs`: `ObjectiveRef`, `ObjectiveVersion` (`revision`, `assignmentRevision`, `criteriaRevision`, `ownerEpoch`, `owner`, `active`, `rootId`, `cutoff`), `CheckpointIntent`, `CheckpointReceipt`, `CheckpointProvider{current,commit}` and `matchesReceipt`, which requires the receipt revision to exceed the intent's expected revision. `shikigami-core/src/Shikigami/WorkerSession/Integration.hs` retains an intent for at most 100 contiguous session events, calls the provider and advances the local cursor only after a matching receipt; it maps `CheckpointConflict` to `EventsConflict` with no supersession path. `shikigami-core/src/Shikigami/WorkerSession/Store.hs` `prepareCheckpoint` validates root, owner and epoch and retains a conflicted intent indefinitely. `shikigami-core/src/Shikigami/WorkerSession/Workflow.hs` `currentAssignmentAuthority` requires an exact revision match at new-assignment admission. `shikigami-core/src/Shikigami/WorkerSession/Transfer.hs` defines `WorkspaceProvider{reconcile,admitWrite}`, `OwnershipProvider{transfer}` and `FenceProof`; `shikigami-core/src/Shikigami/WorkerSession/Handoff.hs` retains settled fence evidence before asking the objective owner to transfer. `shikigami-core/src/Shikigami/WorkerSession/Capability.hs` owns the closed worker commands, `CoordinationAuthority{admit,reacquire}` and `authorizeExact` over `InvokeCapabilityTool`; `shikigami-core/src/Shikigami/WorkerSession/Tools.hs` and `shikigami-core/src/Shikigami/Flow/Workers.hs` are the native tool and journaled Flow interpreter over those commands.

Production has no objective-backed authority source today: `shikigami-workers/src/Shikigami/Workers/Config.hs` sets `coordination = Nothing`, and `shikigami-server/src/Shikigami/Server/Command/Workers.hs` constructs `TransferServices sessions Nothing Nothing`, that is unavailable checkpoint and ownership providers. `shikigami-core/src/Shikigami/App/Config.hs` and its loader own operator configuration.

Run acceptance lives in `shikigami-core/src/Shikigami/AgentRun/Ledger.hs`: `acceptRunRequest` commits acceptance and the queue send in one transaction. `shikigami-api/src/Shikigami/AgentRun/Api.hs` defines the public run request, `shikigami-server/src/Shikigami/AgentRun/Handler.hs` its handler and `shikigami-core/src/Shikigami/Agent/RunJob.hs` the versioned application input envelope. Conversations are indexed by their own owning index and participants are recorded agent identities.

[Plan 96](96-provide-governed-mutable-repository-workspaces-for-durable-agents.md) owns IR-11. Its milestone 1 landed `shikigami-core/src/Shikigami/Workspace/Catalog.hs`; its milestone 5 will implement `WorkspaceProvider.reconcile` and `admitWrite`. Plan 84's IR-11 gate stays open until that provider is qualified, and only plan 84 runs the joint late-writer and restart test.

Relevant decisions: [ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md) keys authority by recorded principal; [ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md) keeps budgets with the resource root; [ADR 0061](../adr/0061-continuing-sessions-own-ordered-assignments-and-retained-receipts.md) gives sessions ordered assignments and retained receipts; [ADR 0062](../adr/0062-session-generations-await-governed-children-and-retain-checkpoint-intents.md) fixes the intent/receipt protocol this provider implements; [ADR 0063](../adr/0063-handoffs-establish-epochs-only-after-fences-and-versioned-owner-receipts.md) requires fences and versioned owner receipts before a new epoch; [ADR 0066](../adr/0066-worker-commands-require-retained-scopes-and-fresh-exact-authority.md) requires retained scopes and fresh exact authority for every worker command. This plan supplies their missing objective provider without replacing those owners.


The reviewed contracts are recorded in [ADR 0067](../adr/0067-objective-checkpoints-use-assignment-scoped-preconditions.md) (checkpoint preconditions and instruction invalidation) and [ADR 0068](../adr/0068-objective-creation-has-authority-before-association.md) (creation authority before association). These are accepted design decisions; implementation and acceptance evidence remain outstanding.

## Plan of Work

### Milestone 1 — Trusted run and conversation associations

Create `shikigami-core/src/Shikigami/Objective/Association.hs`. Add an optional typed objective/assignment reference to fresh public run requests in `shikigami-api/src/Shikigami/AgentRun/Api.hs` and to the application-owned envelope in `shikigami-core/src/Shikigami/Agent/RunJob.hs`. Keep old decoders and absent-objective behavior, and include the association in new request fingerprints so an idempotency key cannot be replayed against another objective. Never reinterpret arbitrary old trigger JSON as trusted objective metadata. Update `shikigami-core/src/Shikigami/AgentRun/Ledger.hs` and `shikigami-server/src/Shikigami/AgentRun/Handler.hs` so permitted association, run acceptance and queue send commit together through the owning store transaction interfaces; there is no second queue and no post-enqueue best-effort attachment. Membership is rechecked at acceptance: an unauthorized association enqueues nothing.

For conversations, the authorized `BindConversation` command from plan 98 links an existing conversation and a recorded participant agent to the objective. Resolve the conversation through its owning index, reject unrelated participants, and retain binding revisions. A turn snapshots its association only at its own new admission; rebinding affects later turns, never accepted work. Run, session and conversation identities are links to objective state, not replacement objective IDs, and protected lookup and command execution recheck current membership even when a historical association exists. Milestone 1 is accepted when the core and worker cases pass: a permitted association, acceptance and queue send commit together; a forged objective reference in trigger text and an unauthorized association enqueue nothing; an old unassociated request still follows its original fingerprint and queue-codec path.

Also expose a trusted creation-origin validator and lookup in `Objective/Association.hs` for plan 101. Resolve recorded principal, accepted execution/turn and operation through their owning stores (or the retained Flow workflow/generation/static-label operation coordinates) before calling plan 98’s create transaction; do not trust a model-supplied run or operation. The immutable origin link written with creation attributes an objective created during an already running execution without changing that run’s admission fingerprint. Later commands from the same execution may target only a receipt-backed created objective allowed by its frozen creation scope, or an originally associated objective, and must recheck membership and exact authority. A future run uses the ordinary association-at-acceptance path; a future conversation turn uses explicit authorized `BindConversation`. Milestone 1 tests origin mismatch refusal, atomic origin persistence and retry lookup, without requiring the model tool from plan 101.

### Milestone 2 — The checkpoint and ownership providers

Create `shikigami-core/src/Shikigami/Objective/Checkpoint.hs` and `Objective/Ownership.hs`. Use provider id `shikigami-objective-v1` and encode the objective id and `ObjectiveAssignmentId` together in the opaque `ObjectiveRef` key; existing `ObjectiveRef` codecs stay intact. `current` returns the objective revision, the addressed assignment's revision, the objective's criteria revision, the assignment's owner and epoch, the admitted resource root and the effective current cutoff. Resolve resource and mandate authority through their owners and fail closed if unavailable or inactive. An ordinary finite objective needs no worker session or root; it becomes a coordination slot only after explicit admission binds the already accepted execution root. Retain root references; never reset a budget by minting a replacement during reattachment. `current` has no actor argument, so it must not become a public unchecked read: scope every provider callback to authenticated internal authority, and check the actor carried in an intent against retained session authority. A provider callback is not an authorization grant.

Implement `CheckpointProvider.commit` through plan 98's command transaction and internal ingestion command. Validate the retained session binding, parent actor, assignment mapping and the contiguous source event range, then validate the expected version against the addressed assignment: its assignment revision, criteria revision, owner and epoch, root and active flag, with instruction and objective-status invalidation carried by `assignmentRevision` as defined in plan 98. `ObjectiveVersion` has no instructions field: do not compare an invented expected value or read current instructions as though they were the retained expectation. The objective-wide revision in the intent is an ordering base: a sibling assignment's accepted progress advances it without conflicting this commit, and the receipt's revision must still exceed it so `matchesReceipt` accepts. A change to the addressed assignment, to objective-wide instructions or criteria, to its ownership or to objective status is a definitive conflict with a persisted non-commit outcome. Verify submitted events against the session owner's retained receipts; an event body from tool JSON is not evidence. Deduplicate `(sessionId, cursor)` ingestion as well as operation keys. Atomically retain result and evidence references, decisions and next actions and advance the objective-side source cursor. Treat worker results as reported progress pending acceptance. Return `CheckpointAccepted` only with the exact fingerprint and advancing revision `matchesReceipt` expects, and return the same receipt before version checks on an accepted retry, including when the local consumed cursor has not advanced.

Implement `OwnershipProvider.transfer` with the same receipt rules. Require a fence proof validated against the trusted configured workspace provider and the retained handoff record. Atomically change only the addressed assignment's owner and epoch, preserve evidence and increment the objective and assignment revisions. Milestone 2 is accepted when, with real session and objective stores, two workers with separate assignments retain one result each, commit, drop an acknowledgement, restart integration and converge to one objective revision/evidence update and one eventual cursor advance; two sibling checkpoints prepared from the same expected objective revision are both accepted without reconciliation; and a stale checkpoint cannot restore an old owner.

Milestone 2 must also prepare an intent, commit only `ReviseInstructions`, and prove the unchanged intent conflicts with no cursor or evidence write. Revert the instruction text and prove it still conflicts. Conversely, an already accepted intent retried after instruction changes must return its original receipt under current permission. Exercise these cases through `WorkerSession/Integration.hs`, alongside the two sibling commits, using the single command executor from plan 98.

### Milestone 3 — Reconciliation, coordination authority and production wiring

Add explicit checkpoint-conflict reconciliation to `shikigami-core/src/Shikigami/WorkerSession/Integration.hs`, `WorkerSession/Store.hs`, `WorkerSession/Capability.hs` and the session domain declaration `domain/shikigami-worker-session.keiro`, following [docs/workflow-versioning.md](../workflow-versioning.md) for any journaled-shape consequence. The objective owner must first retain a definitive rejected or non-committed outcome for the original operation. A new parent-authorized reconciliation command validates that proof, records supersession, clears or replaces the pending intent without advancing the consumed cursor, and prepares a new operation against freshly read authoritative state. Keep the original intent and rejection for audit. If the old result is accepted or unknown, recover its receipt or keep waiting; never supersede it. Changed instructions, owner or criteria require explicit revalidation of the retained events, not automatic acceptance under new meaning. Extend the closed worker tool and CLI command surface and compatibility readers for this transition.

Create `shikigami-core/src/Shikigami/Objective/Coordination.hs` implementing `CoordinationAuthority` from accepted objective/run associations, recorded delegation context, model permissions and operator-bounded worker slots. Persist each admitted scope by fingerprint and retain it as long as any run or session references it. `reacquire` returns that exact scope, while each fresh action checks current objective authority and versions. Replacing instructions, rotating a coordinator or compacting model context cannot replace the scope's root, reset limits, widen permissions or silently select another principal. New assignment admission after an objective revision change reads current versions and obtains a fresh explicit decision; a pending old operation keeps its original request.

Wire the real providers through `shikigami-workers/src/Shikigami/Workers/Config.hs`, shared runtime and catalog construction, and `shikigami-server/src/Shikigami/Server/Command/Workers.hs`. Consume plan 98’s objective-tracking enablement, local operator identity and creation policy from `shikigami-core/src/Shikigami/App/Config.hs` and its loader; this milestone adds provider wiring, not a second configuration owner. A missing provider or authority refuses the relevant work; ordinary unassociated runs still work; do not fabricate a workspace provider while plan 96's is absent.

Add `shikigami-core/test-postgres/Shikigami/ObjectiveCheckpointSpec.hs` with real session and objective stores, holding the milestone 1 association cases, the milestone 2 provider cases, and these: race an owner or criteria change on the addressed assignment with another checkpoint, observe a visible conflict and complete explicit reconciliation without losing accepted results; recreate the provider host and recover a retained coordination scope with unchanged root limits; prove different workers on one objective resolve different assignment owners and never share writable scope. Ownership tests use a trusted deterministic fence fixture only to qualify the objective-side contract and receipt recovery; they do not claim real workspace fencing. Milestone 3 is accepted when the suite and the worker and server suites pass, and plan 84's Progress and the MasterPlan 14 registry and Progress have been updated with the real evidence while plan 84's IR-11 gate is left open.


## Concrete Steps

Run commands from the repository root, `/Users/shinzui/Keikaku/bokuno/shikigami`, inside `nix develop --no-write-lock-file` if needed. Capture `git rev-parse HEAD` as the implementation baseline. Build and run the inherited suites before changing anything:

```bash
cabal build all
cabal test shikigami-core-test shikigami-core-postgres-test --test-show-details=direct --test-options='--num-threads=1'
```

If the checked-in project cannot resolve its co-developed dependencies, follow `docs/dependency-cohort.md` and plan 98's Concrete Steps for the local project convention; apply the same project to every invocation and record it in evidence. If the session domain declaration changes, regenerate and check isolation:

```bash
cabal run -v0 keiro-dsl -- scaffold domain/shikigami.keiro-workspace --out shikigami-core/src
just migration-schema-isolation
```

Allocate an additive migration with `just new-migration <name>` only if plan 98's tables prove insufficient; never edit an applied migration. Run focused checks while implementing and the affected suites at each milestone boundary:

```bash
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-server-test shikigami-workers-test shikigami-agent-test --test-show-details=direct --test-options='--num-threads=1'
```

At a coherent commit, run the gate against the saved baseline and check whitespace:

```bash
just keiro-gate IMPLEMENTATION_BASELINE
git diff --check
```

Gate reports must contain no unexplained breaking findings; do not weaken the gate or hide a declared step to make it pass. Every commit follows Conventional Commits and ends with:

```text
MasterPlan: docs/masterplans/17-track-durable-objectives-and-authoritative-assignment-checkpoints-without-rei.md
ExecPlan: docs/plans/99-supply-trusted-objective-associations-and-the-real-checkpoint-ownership-and-scope-providers.md
Intention: intention_01m62265gjex4a0k54gsbwx4gs
```

When milestone 3 is accepted, edit plan 84's Progress (its IR-13 completion gate) and the MasterPlan 14 Exec-Plan Registry and Progress in the same commit as the evidence, record the provenance revision on each edited plan with the exec-plan skill's `record-provenance.ts`, and leave plan 84's IR-11 gate and status untouched.


## Validation and Acceptance

This plan is the early and continuing integration proof: actual worker result and event producers feed the actual objective provider. A dropped acknowledgement followed by a local cursor-commit failure converges without duplicate progress. Stale updates cannot erase accepted results or restore an old owner. Two sibling assignments checkpoint from the same expected objective revision and both commit without parent reconciliation; a changed owner, criteria or instruction revision on the addressed assignment conflicts. Explicit rejected-intent reconciliation unblocks progress, while unknown outcomes keep their original intent. Different workers on one objective resolve different assignment owners and never share writable scope. Retained coordination scopes survive process restart and parent rotation without resetting root limits. Permitted run associations commit with acceptance and queue send; forged or unauthorized associations enqueue nothing. Fixture fence results qualify only the objective owner's transfer protocol. Required acceptance is the passing `ObjectiveCheckpointSpec` and the core, PostgreSQL, worker and server suites, plus the recorded plan 84 and MasterPlan 14 updates. Record actual passing counts only after running them.


## Idempotence and Recovery

Retry the original intent after a lost acknowledgement; accepted receipts are returned before version checks. A pending checkpoint is superseded only after a retained definitive non-commit proof; a timeout never supplies that proof. An accepted ownership transfer with a missing local acknowledgement finishes the original handoff with its saved receipt and fence, not a replacement session or root. One aggregate per objective serializes writes, so two workers committing at the same instant are ordered by the database rather than merged, and neither needs reconciliation unless the addressed assignment, objective-wide instructions or criteria, ownership or status actually changed underneath it. Disabling objective tracking must retain readers and reconciliation for accepted operations and must not drop associations or select an older unsafe path. Database backup and restore must include the objective tables and their event streams together.


## Interfaces and Dependencies

Hard prerequisite: plan 98 Complete (`Shikigami.Objective.Types`, `Command`, `Capability`, `Store`, `Catalog`, `Acceptance`, shared operator configuration and the `objective-checkpoints` migration). `Shikigami.Objective.Association` owns objective links to accepted runs and conversations; `Shikigami.Objective.Checkpoint` and `Shikigami.Objective.Ownership` implement the existing `CheckpointProvider` and `OwnershipProvider` records; `Shikigami.Objective.Coordination` implements the existing `CoordinationAuthority` contract. Keep the existing fingerprints and receipt matchers; any expanded durable protocol gets an explicit new version and a retained old reader. Consumers: plan 84 (closing its IR-13 gate), plan 100 (HTTP association cases in its milestone 3, which needs only this plan's milestone 1), plan 101 (tool authority from the retained scope and the accepted association), plans 85 and 87 (provider contract) and plan 102 (qualification). Soft dependency: plan 96's `WorkspaceProvider` for a real fence proof. Dependencies and cohort are unchanged; `mori://shinzui/keiro` supplies `runCommandWithCatalogProjections` and `mori://shinzui/kikan-en` the exact action contract.


## Revision Notes

2026-10-29: Made instruction invalidation explicit, added consumer regressions and creation-origin validation, and consumed configuration owned by plan 98.

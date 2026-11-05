---
id: 117
slug: admit-bounded-objectives-autonomously-under-explicit-revocable-standing-policies
title: "Admit bounded objectives autonomously under explicit, revocable standing policies"
kind: exec-plan
created_at: 2026-11-04T18:38:36Z
intention: "intention_01m6kxnhhjekdvwtpnm74m8d46"
master_plan: "docs/masterplans/20-propose-unrequested-work-from-observed-activity-under-governed-standing-policies.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-11-04T18:38:36Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-05T02:24:52Z
      mode: "implement"
      note: "Implementing standing policies, operator commands and the admission branch"
---

# Admit bounded objectives autonomously under explicit, revocable standing policies

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

After [plan 116](116-propose-work-through-a-stream-triggered-flow-with-durable-human-acceptance-and-trusted-origin-links.md) every unrequested proposal waits for a person. That is the right default, and [IR-21](../improvement-requests/propose-unrequested-work-from-observed-activity.md) asks for exactly one way past it: a *standing policy*, an explicit, bounded and revocable record installed by the configured local operator that names the principal it covers, the sources it may act on, the repositories and action classes it may choose, the coordinator agent that will do the work, the resource envelope of each admitted objective and of all of them together, how many admissions a window allows, and when the policy expires. This plan gives Shikigami that record, the commands that install, revoke and list it, and the admission branch of the `propose-work` Flow. When a proposal is covered by a live policy, the Flow reserves one full per-objective envelope from the policy's totals and one admission from its window, creates the objective under the proposer's own creation grant, enrolls a resource root for an independent coordinator run with the per-objective envelope, grants the coordinator its role, staffs the objective's single assignment, enqueues the coordinator run and records the admission pinned to the policy's digest. The objective's instructions stop at a reviewable artifact and forbid publication; the policy cannot grant the coordinator any workspace, sink or tool authority it does not already hold. Revoking the policy, or letting it expire, stops the next admission at the fresh read inside the reservation transaction, while work already admitted continues under its own objective, root and coordinator controls.

You can see it working in `cabal test shikigami-workers-test --test-options='-p AdmitProposal'`: with a policy installed, the fixture bug envelope produces one objective in `Open` with one `Pending` assignment owned by the coordinator, one root whose envelope equals the policy's per-objective envelope and whose cutoff is the admission instant plus the objective window, one queued coordinator run carrying the objective association and that root, one admission row pinned to the policy digest, and no sink intent, no workspace publication and no pull request anywhere; after `shikigami proposals policy revoke`, the next proposal parks for a human instead and the admitted objective is unchanged. This plan is EP-4 of [MasterPlan 20](../masterplans/20-propose-unrequested-work-from-observed-activity-under-governed-standing-policies.md). Milestones 1 and 2 require [plan 114](114-bound-observation-with-observer-allowances-source-adapters-a-deterministic-pre-filter-and-the-proposal-ledger.md) to be Complete; milestone 3 also requires plan 116 to be Complete, because the admission branch is a patch guard inside its Flow.


## Progress

- [x] Milestone 1: The standing-policy migration, `Shikigami.Initiative.Policy` with its sealed policy, validator, store and reservation exist; PostgreSQL tests prove install validation, fresh-read revocation, expiry, window and total exhaustion and digest pinning. Completed 2026-11-04: InitiativePolicy (11 cases): install refusals, digest pin, fresh-read revocation, window and total exhaustion, expiry, convergence; migration 0044 with a matching schema.
- [x] Milestone 2: `shikigami proposals policy install|revoke|list` work as the configured local operator; `just haskell-conventions` accepts the new composition module. Completed 2026-11-04: shikigami proposals policy install, revoke and list exist; option cases pass in the server suite; just haskell-conventions accepts the module.
- [x] Milestone 3: The admission branch of `propose-work` behind `shikigami-initiative-admission-v1` admits one funded, staffed, bounded objective per covered proposal, falls back to the human path when not covered, refuses fresh after revocation or expiry, and the planted-instruction and no-publication cases pass; the standing-policy ADR is written. Completed 2026-11-04: AdmitProposal (13 cases) from the stream consumer through admission, including the coordinator's own association; ADR 0114 written; 739 core, 604 PostgreSQL, 107 server and 37 agent cases pass, the workers suite only flaking on FRIC-59's Git case.


## Surprises & Discoveries

- The plan omits one required step: `Objective.Runtime.runTarget` denies a run whose job names an objective unless `Association.admitRunTx NewRun` has retained that association. `initiative-launch` therefore registers it in the transaction that enqueues the job, acting for the proposer. A test that drains the coordinator found this.
- `ActiveWork` is a concurrency gauge, not a spend, so summing it across admissions exhausted totals immediately. Totals arithmetic excludes it.
- An admission receipt references a real proposal row, so its foreign key is what makes `AlreadyAdmitted` meaningful; a retried `initiative-admit` step reads back its own reservation instead of refusing.


## Decision Log

- Decision: Standing policies are durable rows installed by the configured local operator, read fresh under a row lock at every admission and pinned by digest in the admission receipt.
  Rationale: Revocation must stop new admission immediately, which a journaled snapshot cannot do, while an admitted objective must prove which policy admitted it. Installing an agent or Skill writes no such row, so no declaration can create one.
  Date: 2026-11-04

- Decision: Admission funds and staffs an independent coordinator run with its own root rather than a delegated child of the proposer's run.
  Rationale: `enrollRootRun` refuses descendants and a child would inherit the proposer's evaluation-sized root. An addressed run with its own root and an objective association is how the adaptive fixture already starts a coordinator, and it keeps the per-objective envelope separate from observation spend.
  Date: 2026-11-04

- Decision: Totals are reserved conservatively: each admission takes one whole per-objective envelope from the policy's total limits, and the policy is exhausted when the remainder cannot cover another whole envelope.
  Rationale: Reading actual usage of admitted roots at admission time would couple the policy to accounting settlement and to unknown usage. Pure arithmetic over the policy's own rows is deterministic, bounded and honest about what was promised.
  Date: 2026-11-04

- Decision: Every admission counts against totals and the window, including ones later marked refused, rather than the plan's "stage other than refused".
  Rationale: The plan also says a reservation stays consumed when its admission fails, and the two cannot both hold. Counting all rows is the conservative reading and keeps a failing configuration from spending a total repeatedly.
  Date: 2026-11-04

- Decision: The admission patch is taken by `runFlowBehavior` and handed to the interpreter, not guarded in the Flow body, and `initiative-admit` tries the policies `initiative-open` journaled.
  Rationale: The narrowing in `initiative-open` needs the same answer as the admission branch, so one guard must govern both. Trying journaled policies through the locked read is what produces a recorded `policy-gone` refusal when a policy disappears between covering and reserving.
  Date: 2026-11-04

- Decision: Admission notices use a new recipient-bound `emitSignalTo`, journaled as `emit-signal-<label>`.
  Rationale: `resolveSinkRecipient` would consult the activity's actor, which is observed text. The hyphenated name is what the declaration language can spell.
  Date: 2026-11-04

- Decision: `PolicyContext.principalActive` is a predicate rather than the plan's directory snapshot, and policy identity resolution of the coordinator happens at funding.
  Rationale: The directory's lifecycle consultation is IO. A predicate keeps `validatePolicy` pure, and a coordinator paused after reservation should refuse at funding rather than on stale data.
  Date: 2026-11-04


## Outcomes & Retrospective

Complete. A covered proposal becomes one objective with one assignment, its own root, one queued coordinator run admitted to that objective, one receipt pinned to the policy's digest and one notice, with no ask. Without a policy, past exhaustion or after revocation, the proposal parks for a person with the refusal journaled. IR-21 acceptance 3, 8 (admission half), 9 (policy half) and 4 (admission half) are proved. Driving an admitted objective to completion is not claimed here.


## Context and Orientation

Shikigami is a Cabal multi-package Haskell service; `shikigami-core` owns domain code, `shikigami-server` owns the operator binary `shikigami`, `shikigami-workers` owns the background roles and `shikigami-migrations` owns SQL migrations listed in `shikigami-migrations/sql-migrations/manifest`. Plan 114 created the `Initiative` concept vertical under `shikigami-core/src/Shikigami/Initiative/` with the vocabulary this plan extends: `StandingPolicyId` (an allocated UUIDv7 identity with `newStandingPolicyId`, `parseStandingPolicyId`, `standingPolicyIdText`), the closed `SourceKind` and `ActionClass` sums, `InitiativeLimit (scope :: Symbol)`, the scoped `Duration "initiative-window"` and `Duration "initiative-objective"`, `Proposal`, `ProposalView`, `RequestedAuthority` and the ledger (`Shikigami.Initiative.Ledger`). Plan 116 created `Shikigami.Flow.Initiative` (the `Initiative` effect, `InitiativeRuntime`, `runInitiative`, the `propose-work` Flow and the patch `shikigami-initiative-v1`), `Shikigami.Initiative.Template.objectiveRequest` and `Shikigami.Initiative.Notice.admissionNotice`.

*Objectives* ([ADR 0068](../adr/0068-objective-creation-has-authority-before-association.md), [ADR 0070](../adr/0070-objective-receipts-and-integrated-acceptance-share-one-command-owner.md)): `Shikigami.Objective.Types.Objective` has `owner`, `members :: [Member {principal, roles}]` with `Role = Owner | Coordinator | Worker | Reader | Completer`, `assignments :: [Assignment]` whose `AssignmentDraft` carries `assignmentId`, `instructions`, `owner :: AgentIdentity`, `state`, `rootId :: Maybe ExecutionRootId` and `cutoff :: Maybe UTCTime`, and `status`. Public commands (`Shikigami.Objective.Command.Command`) include `SetAssignments [AssignmentDraft]` and `GrantMember AccessPrincipal [Role]`; each is applied at an exact expected `StateRevision "objective"` and returns a `Receipt` with the new revision. A Flow reaches them through `Shikigami.Flow.Objectives.create` and `command label objective expected input`, each journaled as `objectives-<label>` and executed under the run's admitted scope: a scope with `CreateObjectives` (the principal is in `objectives.agentCreation`) may create and may then command objectives it created in that scope (`Origin.lookupCreatedInScope`). A coordinator run joins an objective through `Shikigami.Objective.Association.admitRunTx NewRun`, which requires objective tracking enabled, the objective `Open` or `Blocked`, the run's identity to be a member with `Owner`, `Coordinator` or `Worker`, and the named assignment to be owned by that identity and not withdrawn; the run job must carry `objective = Just (ObjectiveAssociation {objectiveId, assignmentId})`. `shikigami-core/test-postgres/Shikigami/AdaptiveWorkflowSpec.hs` (around lines 170–190) shows the exact sequence the adaptive fixture uses: create, `SetAssignments`, `GrantMember ... [Coordinator]`, then `Shikigami.Trigger.Enqueue.addressedRunJob now identity agent AgentWorkflowRoute payload key & #objective .~ Just reference & #executionRootId .~ Just root`. The adaptive coordinator is `agents/proof/adaptive-delivery.dhall` (behavior `Flow "adaptive-delivery"`), whose run admits the association through `Objective.Runtime.resolveFlowScope` and then coordinates ([ADR 0108](../adr/0108-adaptive-decisions-commit-with-authoritative-checkpoints.md), [ADR 0111](../adr/0111-adaptive-delivery-carries-native-admission-and-reference-only-seeds.md)); its workspace authority is the `WorkspaceGrant` rows in `WorkspaceSettings.grants` (`shikigami-core/src/Shikigami/Workspace/Settings.hs`), its sink authority is the C11 grant table, and every external action needs fresh C13 authorization ([ADR 0036](../adr/0036-external-agent-actions-require-fresh-exact-authorization.md)). None of these are touched by this plan.

*Resource roots* ([ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md), [ADR 0094](../adr/0094-accounting-entities-use-allocated-identities-and-root-origin-receipts.md)): `Shikigami.Execution.ResourcesStore.allocateRootForWorkflow :: ResolvedAgentIdentity -> AgentName -> WorkflowId -> Maybe ExecutionRootId -> Envelope -> Eff es (Either ResourceError ExecutionRootId)` allocates idempotently per workflow id; `Shikigami.Agent.RunJob.runJobWorkflowId` derives a job's workflow id from its idempotency key, so a run's root can be enrolled before the job is sent. `Shikigami.Execution.Resources.Envelope {limits :: Map Dimension Limit, cutoff}`; `Limits` is the map; `Limit = Limited ResourceAmount | ExplicitlyUnbounded`.

*Run jobs*: `Shikigami.Agent.RunJob.RunJob` with `triggerKind`, `routeKind`, `objective`, `executionRootId`, `idempotencyKey :: RunKey`; `Shikigami.Agent.Run.Key.runKeyWithPrefix` and `Shikigami.Decision.Contract.versionedDigest` build versioned keys (see `addressedRunKey` in `Shikigami.Trigger.Enqueue`); `enqueueRunJob :: Pool -> RunJob -> IO (Either UsageError MessageId)` sends to the `shikigami_run_jobs` queue, and the worker derives the run's workflow identity from the key, so a second send of the same job is the same workflow instance. The scheduler's `admittedIdentity` in `shikigami-workers/src/Shikigami/Trigger/Scheduler.hs` shows how a declaration's identity is resolved through the directory snapshot (`VerifiedIdentity` from the declared principal when the directory is configured, `CompatibilityIdentity` otherwise).

*Operator commands* ([ADR 0021](../adr/0021-operator-verbs-wrap-the-owning-library.md)): `shikigami-server/src/Shikigami/Server/Command.hs` lists `adminSubcommands` and each noun's `info`; `shikigami-server/src/Shikigami/Server/Command/Objectives.hs` is the model for a noun that acts as the configured local operator (`withObjectives` requires `objectiveSettings.enabled` and `objectiveSettings.operator`, verifies migrations, and runs the owner with `LocalOperator operator`). Every composition module is listed in `tools/style/module-ownership.json` `compositionModules` ([ADR 0075](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md)). Declarations are loaded with `Shikigami.Agent.Loader.loadAgentsReport` from the configured agents directory.

*Workflow versioning*: the admission steps are new labels in the declared agent-run body and sit in their own patch block, `shikigami-initiative-admission-v1`, with a real false branch ([ADR 0012](../adr/0012-a-declared-workflow-body-only-grows-behind-a-patch.md), [workflow versioning](../workflow-versioning.md)); plan 116's milestone 1 describes the gate, the regenerated files and the conformance expectations edit.

*Value rules*: sealed validated results with public read views ([ADR 0081](../adr/0081-validated-results-use-private-seals-and-public-read-views.md)); no `Generic` on opaque values ([ADR 0080](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md)); closed sums; scoped durations and revisions; strict unprefixed fields.


## Plan of Work

### Milestone 1: The policy, its store and the reservation

Allocate the next free migration number from the manifest and create `<N>-initiative-standing-policies.sql`:

```sql
CREATE TABLE shikigami.initiative_standing_policies (
  policy_id text PRIMARY KEY,
  principal text NOT NULL,
  policy jsonb NOT NULL,
  digest text NOT NULL,
  installed_by text NOT NULL,
  installed_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  revoked_by text,
  revoked_at timestamptz,
  revision numeric NOT NULL CHECK (revision >= 0)
);
CREATE INDEX initiative_standing_policies_principal ON shikigami.initiative_standing_policies (principal, expires_at);
CREATE TABLE shikigami.initiative_admissions (
  proposal_id text PRIMARY KEY REFERENCES shikigami.initiative_proposals(proposal_id),
  policy_id text NOT NULL REFERENCES shikigami.initiative_standing_policies(policy_id),
  policy_digest text NOT NULL,
  reserved jsonb NOT NULL,
  stage text NOT NULL CHECK (stage IN ('reserved', 'created', 'funded', 'staffed', 'launched', 'refused')),
  objective_id text,
  root_id text,
  coordinator_workflow_id text,
  refusal text,
  reserved_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);
CREATE INDEX initiative_admissions_policy_window ON shikigami.initiative_admissions (policy_id, reserved_at);
```

Create `shikigami-core/src/Shikigami/Initiative/Policy.hs`:

```haskell
data PolicyInput = PolicyInput               -- the operator's document; a proposal, not a policy (ADR 0080)
  { principal :: !AgentPrincipal,
    sources :: !(NonEmpty SourceKind),
    repositories :: !(NonEmpty RepositoryId),
    actionClasses :: !(NonEmpty ActionClass),
    coordinator :: !AgentName,
    perObjective :: !Limits,
    objectiveWindow :: !(Duration "initiative-objective"),
    total :: !Limits,
    admissionsPerWindow :: !(InitiativeLimit "admissionsPerWindow"),
    window :: !(Duration "initiative-window"),
    expiresAt :: !UTCTime }
  deriving stock (Eq, Generic)         -- FromJSON rejects unknown fields; no Show (it names a principal and repositories, but is not secret; Show is fine to derive)

newtype StandingPolicy = StandingPolicy PolicyFacts     -- sealed; minted only by validatePolicy
data PolicyFacts = PolicyFacts { policyId :: !StandingPolicyId, input :: !PolicyInput, digest :: !PolicyDigest, installedBy :: !OperatorId, installedAt :: !UTCTime, revoked :: !(Maybe Revocation), revision :: !(StateRevision "standing-policy") }
data Revocation = Revocation { by :: !OperatorId, at :: !UTCTime }
newtype PolicyDigest = PolicyDigest (ExecutionDigest "standing-policy")   -- versionedDigest "shikigami.standing-policy/1" over the canonical PolicyInput
policyFacts :: StandingPolicy -> PolicyFacts
data PolicyView = PolicyView { ... text and number fields ..., state :: !Text }   -- Generic read view; state is live, revoked or expired at the view instant

data PolicyRefusal = UnknownPrincipal | PrincipalCannotCreateObjectives | UnknownRepository !RepositoryId | UnknownCoordinator !AgentName | CoordinatorNotCoordinating !AgentName | CoordinatorHasNoIdentity | EnvelopeDeniesModelAttempts | TotalBelowPerObjective !Dimension | ExpiryTooFar | ExpiryInPast | PolicyMissing | PolicyRevoked | PolicyExpired

data PolicyContext = PolicyContext      -- what the validator checks against; the CLI builds it from configuration and the directory
  { directory :: !DirectorySnapshot, objectives :: !ObjectiveSettings, workspaces :: !(Maybe WorkspaceSettings), declarations :: ![AgentDecl], now :: !UTCTime, maximumLifetime :: !(Duration "initiative-policy-lifetime") }

validatePolicy :: PolicyContext -> PolicyInput -> Either PolicyRefusal PolicyInput   -- returns the checked input; installPolicy seals it with an allocated id

installPolicy :: (Store :> es, IOE :> es) => OperatorId -> PolicyContext -> PolicyInput -> Eff es (Either PolicyRefusal StandingPolicy)
revokePolicy :: (Store :> es, IOE :> es) => OperatorId -> StandingPolicyId -> StateRevision "standing-policy" -> UTCTime -> Eff es (Either PolicyRefusal PolicyView)
listPolicies :: Maybe AgentPrincipal -> Maybe StandingPolicyId -> Int -> Transaction [PolicyView]      -- keyset page, at most 100

data Coverage = Coverage { policy :: !StandingPolicy, repositories :: !(NonEmpty RepositoryId), actionClasses :: !(NonEmpty ActionClass) }
coveringPolicies :: AgentPrincipal -> SourceKind -> UTCTime -> Transaction [StandingPolicy]     -- live, unrevoked, unexpired, source permitted; lock-free
reserveAdmission :: ProposalId -> StandingPolicyId -> RequestedAuthority -> UTCTime -> Transaction (Either AdmissionRefusal Reservation)
data Reservation = Reservation { policyId :: !StandingPolicyId, digest :: !PolicyDigest, envelope :: !Envelope, coordinator :: !AgentName, coordinatorIdentity :: !AgentIdentity }
data AdmissionRefusal = NotCovered | PolicyGone !PolicyRefusal | AdmissionsExhausted !Int | TotalsExhausted !Dimension | AlreadyAdmitted !ProposalId
recordAdmissionStage :: ProposalId -> AdmissionStage -> UTCTime -> Transaction (Either LedgerError ())
data AdmissionStage = Created !ObjectiveId | Funded !ExecutionRootId | Staffed | Launched !WorkflowId | AdmissionFailed !RefusalKind !Text
```

`validatePolicy` requires: the principal is present in the directory snapshot with an active lifecycle (or, directory-disabled, is a declared agent's compatibility identity) and is listed in `objectives.agentCreation` (otherwise the Flow could never create, and a policy that can never admit is a misconfiguration to refuse at install, not at run time); every repository is in `workspaces.repositories` by identity; the coordinator names a loaded, enabled declaration whose behavior is `Flow` or `CoordinatingSkill` and whose `identity` is declared (so the admission can resolve a principal to grant); `perObjective` names `ModelAttempts` and `ActiveWork`; for every dimension in `perObjective`, `total` names it with at least the same amount (`ExplicitlyUnbounded` in the total is allowed and means the per-objective bound alone applies); `expiresAt` is after `now` and at most `maximumLifetime` (a configuration value, default 30 days) ahead. `installPolicy` allocates the id in IO, seals, and inserts the row with `digest = versionedDigest "shikigami.standing-policy/1" (toJSON input)`; it never updates an existing row (a changed policy is a new policy and a revocation of the old one, so admission receipts stay pinned to exact digests). `revokePolicy` is a row update at the exact expected revision setting `revoked_by` and `revoked_at`, like the sink grant table's revocations. `coveringPolicies` reads without locks for the Flow's branch decision; `reserveAdmission` is the authority: it takes `FOR UPDATE` on the policy row, re-checks revoked, expired and the requested repository and action class against the row (not against a journaled copy), counts admissions in `now - window` with stage other than `refused` for the window check, sums the `reserved` envelopes of all non-refused admissions for the totals check (exhausted when any dimension's remaining amount is less than the per-objective amount), and inserts the admission row at stage `reserved` keyed by proposal id (`AlreadyAdmitted` when one exists). The reservation's `Envelope` is `perObjective` with `cutoff = now + objectiveWindow`. The coordinator identity is resolved at reservation time through the directory snapshot the same way the scheduler admits a declared identity. Every instant is a parameter.

Tests in `shikigami-core/test-postgres/Shikigami/InitiativePolicySpec.hs`: install refuses each `PolicyRefusal` with a fixture context (unknown principal, principal missing from `agentCreation`, repository outside the catalog, coordinator without identity, `perObjective` without `ModelAttempts`, total below per-objective, expiry in the past and beyond the lifetime); a valid install yields a row whose digest equals the recomputed digest and a `PolicyView` in state `live`; `revokePolicy` at a stale revision refuses; after revocation `coveringPolicies` is empty and `reserveAdmission` returns `PolicyGone PolicyRevoked` even when the caller supplies the id; with `admissionsPerWindow = 1`, the second reservation inside the window is `AdmissionsExhausted 1` and a reservation after the window succeeds (vary the `now` parameter); with `total.ModelAttempts = 3` and `perObjective.ModelAttempts = 2`, the second reservation is `TotalsExhausted ModelAttempts`; a reservation for a repository the policy does not list is `NotCovered`; two connections reserving the same proposal yield one row and one `AlreadyAdmitted`; an expired policy refuses at `reserveAdmission` with `PolicyGone PolicyExpired` although `coveringPolicies` read a moment earlier returned it.

### Milestone 2: Operator commands

Create `shikigami-server/src/Shikigami/Server/Command/Proposals.hs` with the `policy` subtree and add `("proposals", command "proposals" proposalsInfo)` to `adminSubcommands` in `Server/Command.hs`:

```text
shikigami proposals policy install --file policy.json [--json]
shikigami proposals policy revoke POLICY_ID --expected-revision N [--json]
shikigami proposals policy list [--principal P] [--after POLICY_ID] [--limit N] [--json]
```

`install` reads the `PolicyInput` document (reuse `readDocument` from the objectives command for the size-bounded strict decode), builds the `PolicyContext` from the resolved configuration (the directory snapshot through `Shikigami.Directory`, `objectiveSettings`, `workspaceSettings`, the declarations loaded from the configured agents directory with `loadAgentsReport`, the current time and a `maximumPolicyLifetime` setting that lives beside the observer allowances in `InitiativeSettings` with a default of 30 days), requires the configured local operator exactly as `withObjectives` does, verifies migrations, and prints the `PolicyView` (JSON with `--json`, a table otherwise) with its id, digest and expiry. `revoke` prints the view in state `revoked`. `list` pages keyset-style and prints state per row. Every refusal exits nonzero with the `PolicyRefusal` named. Add the module to `compositionModules` in `tools/style/module-ownership.json` with a one-line rationale. Add `shikigami-server/test` cases that parse each verb's options and that `install` with a document naming an unknown repository exits nonzero with `unknown repository` in its output (the server test suite already drives commands with a configuration fixture; follow `Objectives`' cases). Plan 118 adds the read verbs for proposals and admissions to this module.

### Milestone 3: The admission branch

Extend the `Initiative` effect in `shikigami-core/src/Shikigami/Flow/Initiative.hs` with three operations, each one journaled step with a static name:

```haskell
  ReserveAdmission :: Proposal -> Initiative m AdmissionDecision          -- initiative-admit
  Fund :: Proposal -> Reservation -> Initiative m (Either RefusalKind Funded)   -- initiative-fund
  Launch :: Proposal -> Reservation -> ObjectiveId -> Funded -> Initiative m (Either RefusalKind Launched)   -- initiative-launch

data AdmissionDecision = Admit !Reservation | HumanPath !(Maybe AdmissionRefusal)
data Funded = Funded { rootId :: !ExecutionRootId, coordinatorJob :: !RunJob }
data Launched = Launched { coordinatorWorkflowId :: !WorkflowId }
```

`ReserveAdmission` reads `coveringPolicies` for the proposer and the candidate's source kind; with none it returns `HumanPath Nothing`; with one or more it calls `reserveAdmission` for the first policy (ordered by install time) whose repositories and action classes cover the proposal's `RequestedAuthority`, returning `Admit reservation` or `HumanPath (Just refusal)` so the Flow records why admission did not happen before falling back to the human wait (an exhausted window or total is a recorded, visible refusal, never a silent drop). `Fund` builds the coordinator job first, so its workflow id is known: `addressedRunJob now reservation.coordinatorIdentity reservation.coordinator AgentWorkflowRoute payload key & #objective .~ Just (ObjectiveAssociation objectiveId deliverAssignment) & #executionRootId .~ Nothing` with `key = runKeyWithPrefix ('i' :| "nitiative-admission-v1:") (versionedDigest "shikigami.initiative-admission/1" (object ["proposal" .= proposalId]))` and `payload = admissionRequest proposal objectiveId` (a bounded JSON object naming the proposal id, the objective id, the action class and the instructions text; the adaptive coordinator passes it as its request); then calls `allocateRootForWorkflow coordinatorIdentity reservation.coordinator (runJobWorkflowId job) Nothing reservation.envelope` and records stage `Funded`. `Launch` sends the job with `executionRootId = Just rootId` through `enqueueRunJob` and records stage `Launched` with the workflow id; because the workflow id is derived from the key, a replayed send is the same instance. The objective steps between them go through the existing `Objectives` capability so creation and commands carry the Flow origin and the admitted scope.

Narrow the decision's permitted action classes: when `Open` finds at least one covering policy for the proposer and source, the Flow passes the union of those policies' `actionClasses` and `repositories` to `assessmentInput`; otherwise the full `ActionClass` set and the whole catalog as plan 116 does. Record which policies were consulted in the `initiative-open` result so the choice is journaled. Then, after `RecordProposal` and before `awaitAcceptance`:

```haskell
useAdmission <- Workflow.patch (Workflow.PatchId "shikigami-initiative-admission-v1")
decision <- if useAdmission then Initiative.reserveAdmission proposal else pure (HumanPath Nothing)
case decision of
  HumanPath refusal -> awaitAcceptance allowance proposal       -- plan 116's path; the refusal is already journaled
  Admit reservation -> do
    created <- Objectives.create (declarationCoordinate "initiative-admit") request
    ... on Left: Initiative.resolve ... (RefusedBecause AdmissionRefused) and record stage AdmissionFailed; then awaitAcceptance (the proposal stays pending for a person)
    funded <- Initiative.fund proposal reservation
    _ <- Objectives.command (declarationCoordinate "initiative-grant") objectiveId revision1 (GrantMember (RecordedAgent reservation.coordinatorIdentity) [Coordinator])
    _ <- Objectives.command (declarationCoordinate "initiative-staff") objectiveId revision2 (SetAssignments [deliverDraft funded.rootId reservation.envelope.cutoff])
    launched <- Initiative.launch proposal reservation objectiveId funded
    _ <- emitSignal (declarationCoordinate "initiative-admitted") (noticeSink allowance.notices) (admissionNotice agent principal view objectiveId reservation.policyId)
    Initiative.resolve proposal.proposalId proposal.revision (AdmittedUnder objectiveId reservation.policyId)
```

`request` is `Template.objectiveRequest` as in acceptance, so the admitted objective's instructions and `retained-artifact` criterion are the same words a human would have approved. `deliverDraft` is one `AssignmentDraft` with `assignmentId = "deliver"`, the template's instructions, `owner = reservation.coordinatorIdentity`, `state = Pending`, `rootId = Just funded.rootId` and `cutoff = Just reservation.envelope.cutoff`. Expected revisions are taken from the previous reply's receipt, never guessed. `noticeSink` builds a `KizashiSignal` sink value for the allowance's `KizashiRecipient` with `recipientFrom = Actor` overridden by an explicit recipient through the Sink capability's recipient-aware path (`Sink.Intent.prepareSinkIntentForRecipientWithMessageId` as plan 112 uses; if MasterPlan 19 has not added a recipient-aware `emitSignal` variant yet, add the smallest one here and record it in the MasterPlan's Integration Points); the notice names the agent, says nobody requested the work, links the proposal, the objective and the policy, and says how to stop (`shikigami proposals policy revoke <id>`) and how to cancel the objective (`shikigami objectives command ... cancel`). Add `AdmittedUnder !ObjectiveId !StandingPolicyId` to `Resolution`. Declare the patch:

```text
    patch shikigami-initiative-admission-v1 {
      step initiative-admit -> InitiativeAdmissionDecision
      step objectives-initiative-admit -> ObjectiveReply
      step initiative-fund -> InitiativeFunded
      step objectives-initiative-grant -> ObjectiveReply
      step objectives-initiative-staff -> ObjectiveReply
      step initiative-launch -> InitiativeLaunched
      step emit-signal-initiative-admitted -> SinkResult
    }
```

Use the declarable spelling the DSL accepts for the sink step (plan 112 faces the same `emit-signal:<label>` question; align with whatever it chose if it has landed, otherwise declare the hyphenated name and make the runtime step name match). Run the keiro gate, regenerate, edit `KeiroConformance/Expectations.hs`, and confirm `shikigamiActivePatches` contains both initiative patch ids.

Tests. `shikigami-core/test-postgres/Shikigami/AdmitProposalSpec.hs`, driving the real agent-run workflow as plan 116's spec does, with a policy installed through `installPolicy` naming the harness coordinator identity (the `adaptive-delivery` proof declaration with a declared identity) and repository 0: the bug envelope yields one objective in `Open` whose members are the proposer (`Owner`) and the coordinator (`Coordinator`), one assignment `deliver` in `Pending` owned by the coordinator with the root and cutoff set, one root whose envelope equals the policy's per-objective limits with cutoff equal to the admission instant plus the objective window and whose origin binding names the coordinator, one queued run job whose `objective` names the objective and `deliver` and whose `executionRootId` is that root, one admission row at stage `launched` pinned to the policy digest, the proposal row `admitted`, one Kizashi intent addressed to the allowance's recipient, and no approval child; the journaled `initiative-admit` result names the policy id. Not covered: a policy for another source kind leaves the proposal pending with an approval child and an `initiative-admit` result of `HumanPath Nothing`. Exhaustion: `admissionsPerWindow = 1` admits the first proposal and records `HumanPath (Just (AdmissionsExhausted 1))` for a second conversation, which then parks for a person. Revocation: revoke between `RecordProposal` and `ReserveAdmission` (install the crash hook after `initiative-proposal`, revoke, resume) and assert `PolicyGone PolicyRevoked` and the human path, while an objective admitted earlier is unchanged in status, assignment and root. Expiry: a policy whose `expiresAt` has passed by the admission instant refuses the same way. Creation denied: remove the proposer from `agentCreation` after install (the install check passed earlier) and assert the admission records `AdmissionFailed CreationDenied`, the reservation stays consumed, the proposal is pending and an approval child exists. Planted instructions (IR-21 acceptance 4 for admission): an excerpt naming another repository, another coordinator and "merge it now" admits with the policy's repository and coordinator, and the created objective's instructions contain the no-publication sentence. No publication (acceptance 3): assert the only outbox intent is the admission notice, that `shikigami.workspace_*` tables (whatever the workspace vertical's publication receipts are called; `grep -n publication shikigami-migrations/sql-migrations/*.sql`) have no row for the objective, and that the coordinator declaration's grants are byte-identical before and after. Restart: `crashAt (StepName "initiative-fund")` then resume yields one root, one job and one admission row at `launched`. `shikigami-workers/test/Shikigami/AdmitProposalSpec.hs` repeats the covered case from the stream consumer through the worker, as plan 116's worker spec does, and additionally drains the coordinator job once to assert the coordinator run's `objectives-policy` step admits the association (the run may then stop at adaptive admission for lack of providers; that is not this plan's acceptance).

Write one ADR with the next free number: `standing policies are revocable durable grants and admission funds an independent coordinator run` (context: IR-21 item 7 and acceptance 3, 8 and 9; decision: the row, the fresh read under lock, the digest pin, conservative totals, the independent run with its own root, the template's reviewable-artifact stop, no grant of workspace, sink or tool authority; alternatives: policy in process configuration, a journaled policy snapshot, a delegated child, reading actual usage for totals; consequences: revocation is immediate for new admissions only, totals are promises not measurements, a changed policy is a new policy). Link it from the MasterPlan.


## Concrete Steps

Run from the repository root; enter `nix develop` if native tools are unavailable.

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
EP4_BASE=$(git rev-parse HEAD)
cabal build all
```

After milestone 1:

```bash
just migrate
cabal test shikigami-migrations-test --test-show-details=direct
cabal test shikigami-core-postgres-test --test-show-details=direct --test-options='-p InitiativePolicy --num-threads 1'
```

After milestone 2:

```bash
just haskell-conventions
cabal test shikigami-server-test --test-show-details=direct --test-options='-p Proposals'
cabal run shikigami -- proposals policy install --file tests/initiative/policy-fixture.json --json
cabal run shikigami -- proposals policy list --json
```

Expected: the install prints a view with a `shikigami_standing_policy_...` id, a digest and state `live`; the list shows it. (Create the fixture document under `tests/initiative/` as part of this milestone.)

After declaring the patch and before committing generated files:

```bash
just keiro-check
just keiro-scaffold
git add shikigami-core/src/Shikigami/*/Generated shikigami-core/src/Shikigami/Generated shikigami-core/src/keiro-dsl-conformance.workspace.shikigami
git commit -m "feat(initiative): declare the admission patch" -m "MasterPlan: docs/masterplans/20-propose-unrequested-work-from-observed-activity-under-governed-standing-policies.md" -m "ExecPlan: docs/plans/117-admit-bounded-objectives-autonomously-under-explicit-revocable-standing-policies.md" -m "Intention: intention_01m6kxnhhjekdvwtpnm74m8d46"
just keiro-gate "$EP4_BASE"
```

After milestone 3:

```bash
cabal test shikigami-core-postgres-test --test-show-details=direct --test-options='-p "AdmitProposal|ProposeWork|ObjectiveStore|ExecutionResources" --num-threads 1'
cabal test shikigami-workers-test --test-show-details=direct --test-options='-p "AdmitProposal|ProposeWork"'
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test shikigami-agent-test --test-show-details=direct
```

Expected: every named group passes; `keiro-gate` classifies the change as a new patch with no unexplained breaking finding; the full suites exit zero. Commit at milestone boundaries with the trailers shown above.


## Validation and Acceptance

IR-21 acceptance 3: under a standing policy an equivalent message admits one bounded objective that ends at a reviewable artifact and publishes nothing. Acceptance 2 re-proven: without a policy the same message parks for a person and no objective, root, assignment or run exists. Acceptance 4 for admission: planted instructions cannot change the repository, the coordinator, the recipient or the policy. Acceptance 8: an exhausted admission window or total stops admission with a recorded, visible refusal and the proposal falls back to the human path. Acceptance 9, the policy half: revoking a policy or letting it expire stops new admission at the fresh read while admitted work stays under its own objective's controls. Required acceptance is the PostgreSQL, worker and server groups named above, `just keiro-gate` against the plan's baseline, `just haskell-conventions`, `just migrate` with a matching expected schema, and the full suites exiting zero. Driving the admitted objective to completion is plan 86's concern and plan 118's optional native trial, not acceptance here.


## Idempotence and Recovery

The migration is additive. `installPolicy` never updates; `revokePolicy` is a keyed update at an exact revision; `reserveAdmission` is keyed by proposal id. The admission steps are journaled in order and each IO is idempotent under its key: objective creation through the creator-scoped operation ([ADR 0073](../adr/0073-objective-identity-is-allocated-and-creation-receipts-own-deduplication.md)), root allocation per workflow id, objective commands at exact revisions (a replayed command with the same operation key returns its original receipt), and the run job whose identity is its key. A crash between stages is recovered by the resume worker; the admission row's `stage` shows how far it got and `shikigami proposals admissions` (plan 118) reads it. A reservation consumed by a failed admission stays consumed; the operator releases it by revoking and reinstalling the policy if the totals matter, which keeps totals promises rather than measurements. The patch is additive; old journals take the false branch and the human path. Do not roll back across the patch; roll forward.


## Interfaces and Dependencies

This plan owns `Shikigami.Initiative.Policy` (`PolicyInput`, `StandingPolicy`, `PolicyFacts`, `PolicyDigest`, `PolicyView`, `PolicyRefusal`, `PolicyContext`, `validatePolicy`, `installPolicy`, `revokePolicy`, `listPolicies`, `coveringPolicies`, `reserveAdmission`, `Reservation`, `AdmissionRefusal`, `AdmissionStage`, `recordAdmissionStage`), the `ReserveAdmission`, `Fund` and `Launch` operations with `AdmissionDecision`, `Funded`, `Launched` and the `AdmittedUnder` resolution, the admission branch of `propose-work`, the `maximumPolicyLifetime` setting, the standing-policy migration, `Shikigami.Server.Command.Proposals` with its `policy` verbs, the patch `shikigami-initiative-admission-v1` with its declared steps, the fixture document under `tests/initiative/`, and the ADR. It consumes plan 114's vocabulary and ledger and plan 116's Flow, template and notice unchanged; milestones 1 and 2 require plan 114 to be Complete and milestone 3 requires plan 116 to be Complete. It does not add read verbs for proposals or admissions, metrics or guides (plan 118), and it does not change any workspace, sink or tool authority. Dependency source lookup starts with Mori: `mori registry show shinzui/keiro --full` for `patch`, child spawning and the queue contract, and `mori registry docs shinzui/keiro-runtime-patterns` for the scalar and vertical-slice standards.

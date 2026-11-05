---
id: 114
slug: bound-observation-with-observer-allowances-source-adapters-a-deterministic-pre-filter-and-the-proposal-ledger
title: "Bound observation with observer allowances, source adapters, a deterministic pre-filter and the proposal ledger"
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
      at: 2026-11-05T00:54:00Z
      mode: "implement"
      note: "Implementing observation vocabulary, adapters, ledger and intake"
---

# Bound observation with observer allowances, source adapters, a deterministic pre-filter and the proposal ledger

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Shikigami agents can already be triggered by activity on the `activity.v1` stream, but a stream-triggered agent today runs a workflow for every matching message, spends whatever its behavior spends, and leaves no record of the messages it decided were not worth acting on. This plan gives Shikigami the bounded first stage of [IR-21](../improvement-requests/propose-unrequested-work-from-observed-activity.md): a vocabulary for unrequested work, an *observer allowance* in process configuration that says which principal may observe which sources at what cost, closed per-source adapters that turn an envelope into a bounded excerpt, a pure deterministic pre-filter, and a ledger in PostgreSQL where every skip and every proposal is recorded. After it, a message from the Intercom channel that matches a declared observer agent either leaves one bounded skip row and starts nothing, or leaves one resource root sized by the allowance and one run job, committed together with the inbox row. Two messages about the same conversation can only ever converge on one pending proposal, because the ledger keys proposals by observer principal and source subject. Nothing in this plan calls a model, creates an objective or notifies anyone; it makes the later stages cheap, bounded and recorded.

You can see it working in `cabal test shikigami-workers-test --test-options='-p StreamInbox'`: delivering a fixture chat envelope for an agent with an allowance produces one `execution_root_origins` row, one root with the allowance's envelope and one queued job carrying that root, while delivering unrelated chatter produces one `initiative_candidates` row with reason `excerpt-too-short` and no job. `cabal test shikigami-core-postgres-test --test-options='-p InitiativeLedger'` shows that two proposals recorded for the same key by two connections converge on one row. This plan is EP-1 of [MasterPlan 20](../masterplans/20-propose-unrequested-work-from-observed-activity-under-governed-standing-policies.md). It depends on no unfinished plan. Milestone 1 (the vocabulary module) is a named gate for plan 115, which may start as soon as it is accepted.


## Progress

- [x] Milestone 1: `Shikigami.Initiative.Types` and `Shikigami.Initiative.Settings` exist with their checked values, closed sums, allocated identities and the `initiatives` settings object; the unit suite proves parsers, codecs and settings validation; `tests/types/initiative-values.py` proves the sealed and opaque values cannot be constructed generically. Completed 2026-11-04: InitiativeValue and initiative configuration groups pass; tests/types/initiative-values.py refuses all 26 forgeries; just haskell-conventions accepts the Initiative root.
- [ ] Milestone 2: `Shikigami.Initiative.Source` and `Shikigami.Initiative.Prefilter` turn fixture envelopes for the three source kinds into candidates or skips deterministically; property tests prove totality and that the same envelope always yields the same verdict.
- [ ] Milestone 3: The proposal ledger migration and `Shikigami.Initiative.Ledger` exist; the stream consumer records skips and enrolls evaluation roots inside the inbox transaction; the PostgreSQL and worker suites prove atomicity, keyed convergence, owner checks and window exhaustion.


## Surprises & Discoveries

- `Shikigami.Execution.Resources.Dimension` encodes map keys as arrays of pairs, so the plan's `limits` document would not have been writable by an operator. `Initiative.Settings.renderLimits` and `parseLimits` give operators `{"ModelAttempts": 1, "Tokens": "unbounded"}`; the root's own stored codec is unchanged. Plan 117's policy document reuses them.
- `mkAgentPrincipal` admits only `agent_`-prefixed names, so a `CompatibilityIdentity` can never equal a listed principal; observation effectively requires a verified principal, as objective creation does.
- Tasty refuses the plans' `-p "A|B"` filter syntax; use `--test-option=-p --test-option='/A/||/B/'` (FRIC-57).


## Decision Log

- Decision: The pre-filter runs in the stream consumer and records skips there, so an irrelevant message costs one bounded row and no workflow.
  Rationale: The consumer already matches declarations against the envelope and commits exactly one durable disposition per record ([ADR 0009](../adr/0009-kafka-offsets-advance-only-after-durable-dispositions.md)). A pure function over the envelope is safe in that transaction; a model call would not be. The Flow in plan 116 re-derives the candidate with the same function so a run never trusts intake for authority.
  Date: 2026-11-04

- Decision: The proposal key is a versioned digest of the observer principal and the source subject; the pending row for a key is the owner and a losing allocated id is discarded.
  Rationale: Activity ids differ per restatement and model output is not stable. The source subject is the coordinate redelivery, restart and restatement share. This is the receipt-owned deduplication rule of [ADR 0073](../adr/0073-objective-identity-is-allocated-and-creation-receipts-own-deduplication.md).
  Date: 2026-11-04

- Decision: Observation spend is a per-run resource root enrolled at the trigger from the observer allowance; attention limits are bounded counts over ledger rows inside a window.
  Rationale: `enrollRootRun` refuses descendants and the inbox transaction is the only place a root and a job become one fact. Counts need no reservation and no second accounting owner.
  Date: 2026-11-04

- Decision: `InitiativeSettings` carries `maximumPolicyLifetime` from the start rather than plan 117 adding it later, and it defaults to 30 days.
  Rationale: The settings object refuses unknown keys, so a later addition would be the same field with a migration of nothing; defining it with the object keeps one codec.
  Date: 2026-11-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shikigami is a Cabal multi-package Haskell service (GHC 9.12.4, `cabal.project` at the repository root). `shikigami-core` owns domain code under `shikigami-core/src/Shikigami/`, `shikigami-workers` owns the background roles under `shikigami-workers/src/Shikigami/`, `shikigami-migrations` owns the SQL migrations under `shikigami-migrations/sql-migrations/` with a `manifest` listing them in order, and `shikigami-server` owns the operator binary. Modules are grouped by concept into *verticals* (for example `Shikigami.Objective.*`, `Shikigami.Trigger.*`); the closed list of concept roots and individually reviewed composition modules is `tools/style/module-ownership.json`, checked by `just haskell-conventions`, and a new root needs a rationale in that file in the same change ([ADR 0075](../adr/0075-service-composition-has-a-closed-reviewed-module-budget.md)). This plan adds the root `Initiative`: the concept of unrequested work an agent notices in observed activity and proposes. The word *proposal* is already taken inside `Shikigami.Coordination.Proposal` for the adaptive coordinator's organization proposals, which is why the root is not called `Proposal`; the records inside it keep the request's words.

An *activity envelope* (`shikigami-core/src/Shikigami/Activity.hs`, `ActivityEnvelope`) is the `activity.v1` record: `activityId`, `occurredAt`, `source`, `actor` (`kind :: ActorKind`, `id`), `subject` (`kind`, `subjectId`), `verb`, a free-form JSON `payload`, `contextRefs` and `idempotencyKey`, every coordinate an `ActivityCoordinate (scope :: Symbol)` newtype from `Shikigami.Activity.Coordinate`. The channel runtime `mori://shinzui/kanmon` publishes them: `kanmon-channel-intercom` sets `source = "external/intercom"` and a verb from its topic mapping with the message body in the payload, and `kanmon-channel-transcript` publishes `source = "external/transcripts"`, verb `transcript.recorded`, with `transcript_text` in the payload (`mori://shinzui/kanmon/docs/initial-spec`). A *stream trigger* (`docs/user/triggers.md`) is `Trigger.Stream {match :: StreamMatch}` on an `AgentDecl` (`shikigami-core/src/Shikigami/Agent/Decl.hs`); `Shikigami.Trigger.Stream.matchesStreamWith` is the AND of its present predicates plus the feedback guard that excludes `actor.kind = "agent"`.

The *stream consumer* is `shikigami-workers/src/Shikigami/Trigger/Consumer.hs`. `processActivity` resolves the envelope's instant (`envelopeOccurredAt`, substituting the receive time with a log line when the envelope's claim is unparseable), calls `prepareActivityHits`, which for each matching declaration builds a `RunJob` with `Shikigami.Trigger.Enqueue.runJobFromEnvelopeWithIdentity` (trigger kind `TriggeredByStream`, `triggerPayload = toJSON envelope`, `executionRootId = Nothing`, idempotency key `stream-run-v2:<versioned digest of agent name and activity id>`) and admits the identity through `prepareTrigger` against the Meibo directory snapshot (`Shikigami.Directory`), recording a `RunSkip` at `TriggerStage` (`Shikigami.Directory.Store`) when lifecycle refuses. `inboxHandler` then commits every prepared trigger inside `Keiro.Inbox.runInboxTransaction`, which is the transaction that also writes the inbox row; the broker offset is acknowledged only after that commit ([ADR 0009](../adr/0009-kafka-offsets-advance-only-after-durable-dispositions.md)). `shikigami-workers/test/Shikigami/StreamInboxSpec.hs` drives this path broker-free through `processDecodedActivity` with fixture envelopes and asserts on the inbox row and the `shikigami_run_jobs` queue.

A *resource root* ([ADR 0051](../adr/0051-resource-roots-own-conservative-reservations-and-actual-attempts.md), [ADR 0094](../adr/0094-accounting-entities-use-allocated-identities-and-root-origin-receipts.md)) is the accounting entity that bounds a run tree's spend: `Shikigami.Execution.Resources.Envelope {limits :: Map Dimension Limit, cutoff :: UTCTime}` with `Dimension = ActiveWork | LifetimeDescendants | ModelAttempts | ToolAttempts | Tokens | CostMicroUsd` and `Limit = Limited ResourceAmount | ExplicitlyUnbounded`; a dimension absent from `limits` denies spending. `Shikigami.Execution.ResourcesStore.allocateRootForWorkflow :: ResolvedAgentIdentity -> AgentName -> WorkflowId -> Maybe ExecutionRootId -> Envelope -> Eff es (Either ResourceError ExecutionRootId)` allocates a UUIDv7 `ExecutionRootId` in IO, then inside its own `runTransaction` inserts the origin row keyed by the workflow id with a binding of creator, agent and envelope, re-reads it and calls `enrollRootTx`, so a retry recovers the same root and a changed binding is an `IdentityConflict`. `Shikigami.Execution.Admission.enrollRootRun` wraps it for a `RunJob` and refuses descendants. `Shikigami.Agent.RunJob.runJobWorkflowId` derives the run's workflow id from its idempotency key.

*Value rules* every new type follows: nominal newtypes with checked parsers and explicit text renderers (`Shikigami.Execution.Identity.OperationId`, `Shikigami.Objective.Keys` are models); opaque identities over `Data.KindID.V7` with a full singular prefix, parsed with `KindID.parseText`, refusing non-UUIDv7 and non-canonical encodings, allocated only in IO, with no `Generic` and no real record selector (`ExecutionRootId` in `Shikigami.Execution.Identity` is the model, per [ADR 0080](../adr/0080-opaque-checked-values-do-not-expose-generic-construction.md)); validated results sealed in private newtypes with public read views ([ADR 0081](../adr/0081-validated-results-use-private-seals-and-public-read-views.md)); closed sums instead of booleans; scoped `Duration (scope :: Symbol)` from `Shikigami.Duration` and `StateRevision (scope :: Symbol)` from `Shikigami.StateRevision`; positive bounded limits like `Shikigami.Inspection.Settings.InspectionLimit (scope :: Symbol)`; strict, unprefixed record fields with `DuplicateRecordFields` ([the record patterns](mori://shinzui/haskell-jitsurei/docs/core-record-patterns)); and [the domain scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids). `tests/types/opaque-values.py` is the compiler-driven probe that proves opacity; `just domain-value-types` runs it.

*Settings*: process configuration is declared once in `shikigami-core/src/Shikigami/App/Config.hs` and loaded by `App/Config/Load.hs` through Settei. The optional objective settings object (`ObjectiveSettings` in `Shikigami.Objective.Types`, loaded under `stableKey "objectives"` with every key checked and a `defaultObjectiveSettings` constant when absent) and the inspection settings (`shikigami-core/src/Shikigami/Inspection/Settings.hs`) are the models to copy. The *Meibo principal* ([ADR 0033](../adr/0033-recorded-agent-principals-key-durable-state.md)) is the durable identity: `Shikigami.Agent.Principal.AgentPrincipal` (checked, `mkAgentPrincipal`, `principalText`) inside `AgentIdentity = VerifiedIdentity AgentPrincipal | CompatibilityIdentity AgentName | UnresolvedLegacyIdentity`; `identityText` renders the admitted forms. `ObjectiveSettings.agentCreation :: [AgentPrincipal]` is how the objective owner lists principals in configuration; this plan lists observers the same way.

*Tests*: `shikigami-core/test/Main.hs` registers unit groups, `shikigami-core/test-postgres/Main.hs` registers PostgreSQL groups under `Shikigami.Migrations.TestSupport.withShikigamiMigratedSuite`, and `shikigami-workers/test/Main.hs` registers the worker groups; every new spec module is added to its suite's `other-modules` in the package `.cabal`. The suites use tasty and tasty-hunit (and tasty-quickcheck or hedgehog where the package already depends on one; check the `.cabal` before adding a dependency). PostgreSQL suites have exhausted fixture connections under default parallelism (friction entries FRIC-2, FRIC-5, FRIC-17 and FRIC-51 in `docs/friction-log/`); run them with `--test-options='--num-threads 1'` when that recurs.

Relevant local decisions beyond those already named: [ADR 0029](../adr/0029-model-routing-output-is-a-proposal-until-validated-against-journaled-authority.md) (the `Assessment` this plan seals is minted only by plan 115's validator because model output is a proposal until validated); [ADR 0068](../adr/0068-objective-creation-has-authority-before-association.md) (an allowance is not creation authority); [ADR 0022](../adr/0022-the-journal-ends-at-enqueue-and-receipts-own-delivery-truth.md) (nothing here enqueues a sink). No ADR covers unrequested-work proposals; the MasterPlan names the decisions this initiative will record.


## Plan of Work

### Milestone 1: The vocabulary and the observer allowance

Create `shikigami-core/src/Shikigami/Initiative/Types.hs`. The identities:

```haskell
newtype ProposalId = ProposalId (KindID "shikigami_proposal")
  deriving stock (Eq, Ord, Show)

newProposalId :: IO ProposalId
parseProposalId :: Text -> Either Text ProposalId   -- exact prefix, canonical text, UUIDv7 only
proposalIdText :: ProposalId -> Text

newtype StandingPolicyId = StandingPolicyId (KindID "shikigami_standing_policy")
  -- the same three functions; plan 117 allocates these
```

Both get `ToJSON`/`FromJSON` through their renderer and parser, no `Generic`, no selector. The closed sums:

```haskell
data SourceKind = IntercomConversation | MeetingTranscript | ChatFixture
data ActionClass = ReproduceAndDiagnose | DraftFix | DraftDocumentation
data SkipReason
  = UnsupportedSource | AgentActor | ExcerptTooShort | ExcerptTooLong
  | NoObserverAllowance | SourceNotPermitted | NoRepositories
  | EvaluationsExhausted | ProposalsExhausted | NotificationsExhausted
  | AlreadyProposed !ProposalId | AlreadyOwned !ObjectiveId | Suppressed !UTCTime
  | NotActionable | DecisionRefused !FailureCode
data ProposalStatus
  = Pending | Accepted !ObjectiveId | Admitted !ObjectiveId !StandingPolicyId
  | Rejected !UTCTime | Expired !UTCTime | Refused !RefusalKind
data RefusalKind = CreationDenied | AdmissionRefused | AcceptanceFailed
```

`ActionClass` has no publishing or merging constructor on purpose; [IR-21](../improvement-requests/propose-unrequested-work-from-observed-activity.md) item 7 says a policy cannot permit publication, and the type makes that unexpressible. Each sum has a stable `Text` rendering (`sourceKindText`, `actionClassText`, `skipReasonText`, kebab-case) and a parser, used by the ledger and the views; derive `Generic` and the JSON codecs only on these plain enumerations.

The checked values: `Excerpt` (private newtype over `Text`; `parseExcerpt` admits 1 to 8192 characters with no control characters other than newline and tab; `excerptText`; `Show` renders `Excerpt <protected>`; its `ToJSON` is explicit and there is no `FromJSON` so an excerpt never decodes from an untrusted document, only from the envelope adapter), `ExcerptDigest` (an `ExecutionDigest "initiative-excerpt"` from `Shikigami.Execution.Coordinate.executionDigestFor "shikigami.initiative-excerpt/1"`), `Confidence` (private `Double`, finite and in `[0, 1]`, modelled on `Shikigami.Program.Decision.Examples.ModelConfidence`), `OutcomeText` and `CriterionText` (1 to 1024 characters, following `Shikigami.Objective.Content.checkedText`), and `InitiativeLimit (scope :: Symbol)` (positive, at most 16777216, `parseInitiativeLimit`, `initiativeLimitInt`, `FromJSON` through the parser, `type role InitiativeLimit nominal`).

The structured coordinates. Add to `shikigami-core/src/Shikigami/Objective/Keys.hs`, where the objective owner's nominal locators live and where plan 116 will reference them from `ExternalReference` without importing `Initiative`:

```haskell
data ObservedSource = ObservedSource
  { source :: !(ActivityCoordinate "source"),
    subjectKind :: !(ActivityCoordinate "subject-kind"),
    subjectId :: !(ActivityCoordinate "subject-id") }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype ProposalRef = ProposalRef Text        -- parseProposalRef admits a canonical shikigami_proposal KindID text
```

Then in `Initiative.Types`:

```haskell
data EvidenceRef = EvidenceRef
  { activity :: !ActivityId, subject :: !ObservedSource, occurredAt :: !UTCTime, digest :: !ExcerptDigest }

newtype ProposalKey = ProposalKey (ExecutionDigest "proposal-key")
proposalKeyFor :: AgentPrincipal -> ObservedSource -> ProposalKey   -- versionedDigest "shikigami.proposal-key/1" over {"observer","source","subjectKind","subjectId"}

data Observed = Observed
  { activity :: !ActivityId, subject :: !ObservedSource, kind :: !SourceKind,
    actor :: !Actor, occurredAt :: !UTCTime, excerpt :: !Excerpt }

newtype Candidate = Candidate CandidateFacts   -- sealed: constructor not exported, minted by Prefilter.prefilter
data CandidateFacts = CandidateFacts { observer :: !AgentPrincipal, observed :: !Observed, evidence :: !EvidenceRef, allowance :: !AllowanceView }
candidateFacts :: Candidate -> CandidateFacts

newtype Assessment = Assessment AssessmentFacts  -- sealed: minted only by plan 115's validator in Shikigami.Program.Decision.Initiative
data AssessmentFacts = AssessmentFacts
  { outcome :: !OutcomeText, criteria :: !(NonEmpty CriterionText), repository :: !RepositoryId,
    actionClass :: !ActionClass, confidence :: !Confidence, evidence :: !(NonEmpty EvidenceRef) }
assessmentFacts :: Assessment -> AssessmentFacts
sealAssessment :: AssessmentFacts -> Assessment  -- exported from an Internal module imported only by the validator

data RequestedAuthority = RequestedAuthority { repository :: !RepositoryId, actionClass :: !ActionClass, limits :: !Limits, objectiveWindow :: !(Duration "initiative-objective") }
```

`RepositoryId` is `Shikigami.Repository.RepositoryId`, the operator-approved repository identity IR-11 uses. The seal-with-an-internal-module pattern (`Shikigami.Initiative.Types.Internal` exporting `sealAssessment` and the `Candidate` constructor, imported only by the two minters) is how `Shikigami.Generated.Nominals.Internal` keeps `mkObjectiveId` out of general reach; follow it and list the internal module in the cabal `other-modules`. The public read views `CandidateView`, `AssessmentView` and `ProposalView` are ordinary `Generic` records with `ToJSON`/`FromJSON` whose fields are text renderings and plain numbers (ids as text, instants, status as a tag with its payload fields), produced by `candidateView`, `assessmentView` and `proposalView`; a view never converts back to its sealed value. The `Proposal` record itself:

```haskell
data Proposal = Proposal
  { proposalId :: !ProposalId, key :: !ProposalKey, observer :: !AgentPrincipal, subject :: !ObservedSource,
    assessment :: !AssessmentView, requested :: !RequestedAuthority, status :: !ProposalStatus,
    proposedAt :: !UTCTime, expiresAt :: !UTCTime, revision :: !(StateRevision "proposal"), runId :: !WorkflowId }
```

Create `shikigami-core/src/Shikigami/Initiative/Settings.hs`:

```haskell
data InitiativeSettings = InitiativeSettings { observers :: ![ObserverAllowance] }

data ObserverAllowance = ObserverAllowance
  { principal :: !AgentPrincipal,
    sources :: !(NonEmpty SourceKind),
    minimumExcerptLength :: !(InitiativeLimit "minimumExcerptLength"),
    evaluation :: !EvaluationEnvelope,
    evaluationsPerWindow :: !(InitiativeLimit "evaluationsPerWindow"),
    proposalsPerWindow :: !(InitiativeLimit "proposalsPerWindow"),
    notificationsPerWindow :: !(InitiativeLimit "notificationsPerWindow"),
    window :: !(Duration "initiative-window"),
    proposalExpiry :: !(Duration "initiative-proposal"),
    rejectionSuppression :: !(Duration "initiative-suppression"),
    notices :: !NoticeTarget }

data EvaluationEnvelope = EvaluationEnvelope { limits :: !Limits, cutoff :: !(Duration "initiative-evaluation") }
data NoticeTarget = KizashiRecipient !(DeclarationCoordinate "recipient")

resolveAllowance :: InitiativeSettings -> AgentIdentity -> Either SkipReason ObserverAllowance
evaluationEnvelopeAt :: UTCTime -> EvaluationEnvelope -> Envelope
```

The `FromJSON` instance refuses unknown keys, duplicate principals and more than 256 observers, requires every duration positive, and requires `evaluation.limits` to name `ModelAttempts` (a Flow evaluation is one model call; an envelope that denies it is a configuration error, not a silent skip). `resolveAllowance` admits only `VerifiedIdentity` and `CompatibilityIdentity` whose rendered text equals a listed principal, returning `NoObserverAllowance` otherwise. Add `initiativeSettings :: Maybe InitiativeSettings` to `AppConfig` in `shikigami-core/src/Shikigami/App/Config.hs`, loaded with `optional (publicSettingWithRenderer (stableKey "initiatives") "Observer allowances: which principals may observe which sources, at what evaluation envelope and attention limits" jsonDecoder renderJson)`; nothing in it is secret, and `--describe-config` must render it. Export the record from `App.Config` like `InspectionSettings`. Add `Initiative` to `domainRoots` in `tools/style/module-ownership.json` with the rationale that unrequested work from observed activity is a concept vertical. Add every new module to `shikigami-core/shikigami-core.cabal`.

Tests for this milestone: `shikigami-core/test/Shikigami/InitiativeValueSpec.hs` (parsers accept and refuse the documented bounds; `proposalKeyFor` is stable across field order and differs when any coordinate differs; `SkipReason` and `ProposalStatus` round-trip through their codecs; `Excerpt` has no `FromJSON`); `shikigami-core/test/Shikigami/AppConfigSpec.hs` gains cases for the `initiatives` object (absent, valid, unknown key, duplicate principal, envelope without `ModelAttempts`, zero duration); and `tests/types/initiative-values.py`, modelled on `tests/types/opaque-values.py`, compiles a positive client that uses the public parsers and views, then negative clients that must fail to construct `ProposalId`, `Candidate` and `Assessment` through constructors, coercion, record update or `Generic`. Register it in `just domain-value-types`.

### Milestone 2: Source adapters and the pre-filter

Create `shikigami-core/src/Shikigami/Initiative/Source.hs`:

```haskell
sourceKindFor :: ActivityCoordinate "source" -> Maybe SourceKind   -- external/intercom, external/transcripts, fixture/chat
observe :: ActivityEnvelope -> Either SkipReason Observed
```

`observe` refuses `actor.kind == AgentActor` with `AgentActor` even when the consumer was started with `--include-agent-actors`, because observed agent output is never a candidate for unrequested work; refuses unknown sources with `UnsupportedSource`; and extracts the excerpt from the payload path each channel documents: `payload.body` (with `payload.subject` prefixed when present) for `IntercomConversation`, `payload.transcript_text` for `MeetingTranscript`, and `payload.text` for `ChatFixture`. The fixture source exists so acceptance can run without a channel; it is recognised only when the envelope's `source` is exactly `fixture/chat`. Missing or non-string fields are `ExcerptTooShort`; text over the bound is truncated to 8192 characters at a character boundary and marked by setting the digest over the truncated text, never refused, because a long transcript is still evidence. `occurredAt` is parsed with `Shikigami.Trigger.Enqueue.envelopeOccurredAt`; an unparseable claim takes the caller-supplied instant, mirroring the consumer's own substitution.

Create `shikigami-core/src/Shikigami/Initiative/Prefilter.hs`:

```haskell
prefilter :: ObserverAllowance -> UTCTime -> Observed -> Either SkipReason Candidate
```

Total and pure: `SourceNotPermitted` when the kind is not in the allowance's `sources`; `ExcerptTooShort` when the excerpt is shorter than `minimumExcerptLength`; otherwise a `Candidate` whose `evidence` is the `EvidenceRef` of the observed excerpt and whose `allowance` is the allowance's view. The `UTCTime` is the instant the caller already decided on (the consumer's resolved occurrence, the Flow's journaled value); the function reads no clock. Create `shikigami-core/src/Shikigami/Initiative/Intake.hs`:

```haskell
data Disposition = SkipObserved !SkipReason !Observed | SkipEnvelope !SkipReason | Evaluate !Candidate !Envelope
disposition :: Maybe InitiativeSettings -> UTCTime -> AgentIdentity -> ActivityEnvelope -> Disposition
```

which composes `resolveAllowance`, `observe`, `prefilter` and `evaluationEnvelopeAt`; `SkipEnvelope` covers envelopes that could not even be observed (unsupported source, agent actor) and is recorded without a subject. Tests: `shikigami-core/test/Shikigami/InitiativePrefilterSpec.hs` with fixture envelopes for each source kind (an Intercom message with a body describing a double-click bug, a transcript, a fixture chat line, an agent-authored message, an unknown source, a payload without text), asserting the exact `Disposition`, and a property that `disposition` is deterministic (equal inputs give equal outputs) and total (never throws) over generated envelopes if a property library is already a dependency, otherwise over a table of edge cases.

### Milestone 3: The ledger and the intake change

Allocate the next free migration number from `shikigami-migrations/sql-migrations/manifest` when you implement (MasterPlan 19's plans may have taken numbers; never reuse one) and create `<N>-initiative-ledger.sql`:

```sql
CREATE TABLE shikigami.initiative_observers (
  observer text PRIMARY KEY
);
CREATE TABLE shikigami.initiative_candidates (
  observer text NOT NULL,
  activity_id text NOT NULL,
  source text,
  subject_kind text,
  subject_id text,
  verdict text NOT NULL CHECK (verdict IN ('skipped', 'evaluating', 'proposed', 'not-actionable')),
  skip_reason text,
  proposal_id text,
  run_workflow_id text,
  recorded_at timestamptz NOT NULL,
  PRIMARY KEY (observer, activity_id)
);
CREATE INDEX initiative_candidates_window ON shikigami.initiative_candidates (observer, recorded_at);
CREATE TABLE shikigami.initiative_proposals (
  proposal_id text PRIMARY KEY,
  proposal_key text NOT NULL,
  observer text NOT NULL,
  source text NOT NULL,
  subject_kind text NOT NULL,
  subject_id text NOT NULL,
  assessment jsonb NOT NULL,
  requested jsonb NOT NULL,
  status text NOT NULL,
  status_detail jsonb NOT NULL,
  proposed_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  resolved_at timestamptz,
  suppressed_until timestamptz,
  revision numeric NOT NULL CHECK (revision >= 0),
  run_workflow_id text NOT NULL
);
CREATE UNIQUE INDEX initiative_proposals_pending_key ON shikigami.initiative_proposals (proposal_key) WHERE status = 'pending';
CREATE INDEX initiative_proposals_key ON shikigami.initiative_proposals (proposal_key, proposed_at);
CREATE INDEX initiative_proposals_window ON shikigami.initiative_proposals (observer, proposed_at);
```

Every table is schema-qualified because the pool's `search_path` is `kiroku`. Append the file to `manifest`, regenerate `expected-schema.txt` the way the migration tests do, and extend `shikigami-migrations/test` so the new tables appear in the expected schema. No body text is stored: `assessment` is the `AssessmentView`, whose evidence entries carry digests and coordinates only.

Create `shikigami-core/src/Shikigami/Initiative/Ledger.hs`, the only writer of these tables:

```haskell
recordSkipTx :: AgentPrincipal -> UTCTime -> Maybe WorkflowId -> Either (SkipReason, ActivityId) (SkipReason, Observed) -> Transaction ()
recordCandidateTx :: Candidate -> WorkflowId -> UTCTime -> Transaction ()          -- verdict 'evaluating'
checkOwner :: AgentPrincipal -> ObservedSource -> UTCTime -> Transaction (Either SkipReason ())   -- pending proposal, accepted/admitted with open objective, or suppression
checkWindows :: ObserverAllowance -> UTCTime -> Transaction WindowUsage
data WindowUsage = WindowUsage { evaluations, proposals, notifications :: !Int, exhausted :: ![Exhaustion] }
data Exhaustion = EvaluationsAt !Int | ProposalsAt !Int | NotificationsAt !Int
recordProposal :: (Store :> es, IOE :> es) => ProposalId -> Candidate -> Assessment -> RequestedAuthority -> UTCTime -> Duration "initiative-proposal" -> WorkflowId -> Eff es (Either LedgerError ProposalReceipt)
data ProposalReceipt = ProposalReceipt { proposalId :: !ProposalId, disposition :: !ProposalDisposition, revision :: !(StateRevision "proposal") }
data ProposalDisposition = Created | Converged      -- Converged: a pending proposal for the key already existed; its id is returned and the supplied id is discarded
resolveProposal :: ProposalId -> StateRevision "proposal" -> ProposalStatus -> UTCTime -> Transaction (Either LedgerError (StateRevision "proposal"))
readProposal :: ProposalId -> Transaction (Maybe Proposal)
readPendingByKey :: ProposalKey -> Transaction (Maybe Proposal)
recordNotificationTx :: AgentPrincipal -> ProposalId -> UTCTime -> Transaction ()   -- counted toward notificationsPerWindow (plan 116 calls it)
```

`checkOwner` returns `AlreadyProposed` when a pending row exists for `proposalKeyFor observer subject`, `AlreadyOwned objectiveId` when the most recent `accepted` or `admitted` row for the key names an objective whose status is still `Open` or `Blocked` (read through `Shikigami.Objective.Store.readVersion` or a lock-free status read the objective owner exposes; do not take `FOR UPDATE` on the objective), and `Suppressed until` when the most recent `rejected` or `expired` row has `suppressed_until` in the future. `checkWindows` locks the observer's anchor row (`INSERT ... ON CONFLICT DO NOTHING` then `SELECT ... FOR UPDATE`) and counts candidates with verdict `evaluating` or `proposed`, proposals, and notifications inside `now - window`; the caller decides what to do with `exhausted`. `recordProposal` allocates nothing itself: the caller allocates the `ProposalId` in IO, and the insert uses `ON CONFLICT (proposal_key) WHERE status = 'pending' DO NOTHING` followed by a read by key, so a concurrent or replayed insert returns `Converged` with the winning id ([ADR 0073](../adr/0073-objective-identity-is-allocated-and-creation-receipts-own-deduplication.md)). `resolveProposal` requires the exact expected revision and advances it; `Rejected` and `Expired` set `suppressed_until` from the allowance's `rejectionSuppression`. Every instant is a parameter. Readers decode stored JSON through the view codecs and refuse corruption inside the transaction with a typed `LedgerError` (`LedgerCorrupt`, `LedgerConflict`, `LedgerMissing`), following [ADR 0107](../adr/0107-profile-and-objective-corruption-refuses-within-the-owning-transaction.md).

Change the stream consumer. In `shikigami-workers/src/Shikigami/Trigger/Consumer.hs`, thread `Maybe InitiativeSettings` into `processActivityRecordWithDirectory` and `prepareActivityHits` (the role command in `shikigami-workers/src/Shikigami/Workers/Command/Worker.hs` or wherever the stream consumer is built passes `config.initiativeSettings`). After `prepareTrigger` admits the identity, call `Initiative.Intake.disposition settings resolvedOccurredAt identity activity`. For `SkipObserved` and `SkipEnvelope`, replace the job send in the prepared trigger with `Ledger.recordSkipTx` so the inbox transaction commits the skip row and nothing else; log one structured line `initiative.skip` with the reason and no excerpt. For `Evaluate candidate envelope`, allocate a root id in IO (`newExecutionRootId`) before the transaction and, inside `commitTrigger`, call the new `Shikigami.Execution.ResourcesStore.allocateRootForWorkflowTx :: ExecutionRootId -> ResolvedAgentIdentity -> AgentName -> WorkflowId -> Envelope -> Transaction (Either ResourceError ExecutionRootId)` (factor the body of `allocateRootForWorkflow` so both share one implementation and the existing function becomes `newExecutionRootId >>= runTransaction . allocateRootForWorkflowTx ...`) for `runJobWorkflowId job`, then `Ledger.recordCandidateTx`, then `enqueueRunJobTx` with `executionRootId = Just root`. The envelope's cutoff is the receipt instant plus `evaluation.cutoff`; use the transaction's `clock_timestamp()` read once, as the objective owner does. An agent without an allowance takes the unchanged path and its job bytes are identical to today's. A `ResourceError` inside the transaction is a handler failure that rolls back the inbox row, the root and the job and surfaces as `TransientFailure`, which the existing classification already handles.

Tests: `shikigami-core/test-postgres/Shikigami/InitiativeLedgerSpec.hs` (skip rows are bounded and carry no excerpt; `recordProposal` from two connections for one key yields one row and one `Created` plus one `Converged`; `checkOwner` returns `AlreadyProposed` for a pending key, `AlreadyOwned` for an accepted key whose fixture objective is open and nothing for a completed one, `Suppressed` inside the rejection window and nothing after it; `checkWindows` counts only rows inside the window and reports exhaustion at the limit; `resolveProposal` refuses a stale revision; a corrupt `assessment` column is a `LedgerCorrupt` refusal, not an exception). Extend `shikigami-workers/test/Shikigami/StreamInboxSpec.hs` with an observer agent (a `Flow` behavior, a stream match on `fixture/chat`, a static directory principal) and an `initiatives` settings value: a fixture chat envelope describing a bug commits one inbox row, one `execution_root_origins` row whose binding envelope equals the allowance's envelope, one `shikigami.initiative_candidates` row with verdict `evaluating` and one queued job whose `executionRootId` is that root; an envelope with a two-word body commits one inbox row, one candidate row with reason `excerpt-too-short` and no job; an agent-authored envelope commits one row with reason `agent-actor`; a non-observer agent's job is byte-identical to the current fixture's; and a store failure injected after the root insert (reuse the spec's existing rollback fixture) leaves no inbox row, no root and no job. Add `tests/types/initiative-values.py` to `just domain-value-types` if not done in milestone 1.


## Concrete Steps

Run from the repository root; enter `nix develop` if native tools are unavailable.

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
EP1_BASE=$(git rev-parse HEAD)
cabal build all
```

After milestone 1:

```bash
just haskell-conventions
just domain-value-types
cabal test shikigami-core-test --test-show-details=direct --test-options='-p "Initiative|AppConfig"'
cabal run shikigami -- --describe-config | grep -n initiatives
```

Expected: the module policy accepts the `Initiative` root; the type probe reports every positive client compiled and every negative client refused; the unit groups pass; the described configuration lists the `initiatives` key with its description.

After milestone 3:

```bash
just migrate
cabal test shikigami-migrations-test --test-show-details=direct
cabal test shikigami-core-postgres-test --test-show-details=direct --test-options='-p InitiativeLedger --num-threads 1'
cabal test shikigami-workers-test --test-show-details=direct --test-options='-p StreamInbox'
cabal test shikigami-core-test shikigami-core-postgres-test shikigami-workers-test shikigami-server-test shikigami-agent-test --test-show-details=direct
```

Expected: the migration applies and the expected schema matches; every named group passes; the full suites exit zero. Commit at milestone boundaries:

```text
feat(initiative): bound stream observation with allowances, a pre-filter and the proposal ledger

MasterPlan: docs/masterplans/20-propose-unrequested-work-from-observed-activity-under-governed-standing-policies.md
ExecPlan: docs/plans/114-bound-observation-with-observer-allowances-source-adapters-a-deterministic-pre-filter-and-the-proposal-ledger.md
Intention: intention_01m6kxnhhjekdvwtpnm74m8d46
```


## Validation and Acceptance

IR-21 acceptance 5 (unrelated chatter produces recorded skips and no notifications) is proved here: the worker suite shows a skip row and no job for short, agent-authored and unsupported envelopes, and nothing in this plan can notify. The ledger half of acceptance 6 (one proposal for one key under concurrent and replayed inserts) and acceptance 7 (an open objective for the key is an owner) are proved by `InitiativeLedgerSpec`. The MasterPlan's early intake check is this plan's StreamInbox cases: one transaction, one root, one job, and full rollback on failure. Required acceptance is the named unit, PostgreSQL and worker groups, the type probe, `just haskell-conventions`, `just migrate` with a matching expected schema, and the full suites exiting zero. A live Kafka delivery from a real Intercom channel is not required; `processDecodedActivity` is the same code path the broker consumer calls.


## Idempotence and Recovery

The migration is additive and applied once by the manifest. Every ledger write is keyed (observer and activity id; proposal key while pending; proposal id and expected revision), so a retried step converges. The intake change lives entirely inside the inbox transaction, so a crash leaves either nothing or everything, and the broker redelivers; `allocateRootForWorkflowTx` recovers the same root for the same workflow id on redelivery. If a settings object is removed, the consumer stops enrolling and skipping and returns to today's byte-identical jobs; rows already written stay for inspection. Do not fix the migration number in advance; take the next free number when you implement, and if the manifest changed under you, renumber before committing.


## Interfaces and Dependencies

This plan owns `Shikigami.Initiative.Types` (with `Shikigami.Initiative.Types.Internal`), `Shikigami.Initiative.Settings`, `Shikigami.Initiative.Source`, `Shikigami.Initiative.Prefilter`, `Shikigami.Initiative.Intake`, `Shikigami.Initiative.Ledger`, the `ObservedSource` and `ProposalRef` additions to `Shikigami.Objective.Keys`, `ResourcesStore.allocateRootForWorkflowTx`, the `initiatives` settings object and `AppConfig.initiativeSettings`, the `Initiative` module root, the ledger migration, the stream consumer change and `tests/types/initiative-values.py`. It defines `ProposalId`, `StandingPolicyId`, `SourceKind`, `ActionClass`, `SkipReason`, `ProposalStatus`, `RefusalKind`, `Excerpt`, `ExcerptDigest`, `Confidence`, `OutcomeText`, `CriterionText`, `InitiativeLimit`, `EvidenceRef`, `ProposalKey`, `Observed`, `Candidate`, `Assessment`, `RequestedAuthority`, `Proposal`, the three views, `ObserverAllowance`, `EvaluationEnvelope`, `NoticeTarget`, `Disposition` and the ledger API exactly as plans 115, 116, 117 and 118 consume them; a change to any of these after plan 115 starts is recorded in the MasterPlan's Integration Points first. It does not define the assessment decision program or its validator (plan 115), any Flow, capability effect or patch (plan 116), standing policies or admissions (plan 117), or any operator command, metric or guide (plan 118). It depends on no unfinished plan. Dependency source lookup starts with Mori: `mori registry show shinzui/kanmon --full` and `mori path mori://shinzui/kanmon/docs/initial-spec` for the channel payload shapes, `mori registry docs shinzui/keiro-runtime-patterns` for the scalar, vertical-slice and test-layout standards, and `mori registry show shinzui/keiro --full` for the inbox transaction contract.

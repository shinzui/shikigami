-- | The one place Shikigami decides how a durable workflow run is configured.
--
-- A Keiro workflow journals its steps to Postgres and replays that journal
-- instead of re-running them, so an instance suspended before a deploy is
-- resumed by code that has since changed. 'Keiro.Workflow.patch' is what keeps
-- such an instance coherent: it journals a branch decision once and replays it
-- forever, so the instance stays on the code shape it started under while fresh
-- instances take the new one.
--
-- That mechanism only works if the deployed code says which patches are active,
-- and it says so through 'WorkflowRunOptions'. The plain
-- 'Keiro.Workflow.runWorkflow' entry point uses 'defaultWorkflowRunOptions',
-- whose @activePatches@ is empty — so a workflow run through it sees /every/
-- patch as 'False', including patches its own deploy introduced. Every durable
-- workflow run in this service therefore goes through the values below.
--
-- __This module is the only place Shikigami constructs 'WorkflowRunOptions'.__
-- A second options value built at a call site is a second answer to "which
-- patches are active", and the workflow that gets the wrong one silently takes
-- the wrong branch. New workflow run or resume options belong here too. Keep
-- their lease domains distinct: the PGMQ delivery heartbeat that
-- @docs\/plans\/17-behavior-retry-semantics-run-timeouts-and-visibility-heartbeat.md@
-- needs uses @Keiro.PGMQ.JobContext.extendLease@; the Keiro resume worker
-- injects @WorkflowRunOptions.leaseHeartbeat@ itself and is configured through
-- @WorkflowResumeOptions.leaseTtl@. A direct run in a process that has no
-- resume worker leaves @leaseHeartbeat@ unset. A direct run beside a resume
-- worker goes through 'runWorkflowLeased', which holds the same instance lease
-- the resume worker claims.
--
-- The rules that govern when a change needs a patch at all are in
-- @docs\/workflow-versioning.md@.
module Shikigami.Workflow.Versioning
  ( shikigamiActivePatches,
    shikigamiWorkflowRunOptions,
    shikigamiWorkflowResumeOptions,
    shikigamiWorkflowResumeOptionsWith,
    LeasedRun (..),
    runWorkflowLeased,
    terminalWorkflowRetention,
    prepareAdmittedInput,
    admitWorkflowInput,
  )
where

import Control.Exception (throw)
import Control.Lens ((&), (.~))
import Control.Monad (when)
import Data.Aeson (Value, toJSON)
import Data.Generics.Labels ()
import Data.Maybe (isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Time (NominalDiffTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUIDv4
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Effectful.Exception (catch, finally)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow (JournalAppendOutcome (..), LeaseHeartbeat (..), PatchId (..), StepName (..), Workflow, WorkflowError (WorkflowJournalAppendError), WorkflowId (..), WorkflowJournalEvent (..), WorkflowLeaseLost (..), WorkflowName (..), WorkflowOutcome, WorkflowRunOptions (..), defaultWorkflowRunOptions, patchSetStepName, prepareJournalAppend, runWorkflowWith)
import Keiro.Workflow.Gc (WorkflowGcPolicy (..))
import Keiro.Workflow.Instance (ClaimOutcome (..), claimInstance, releaseInstance)
import Keiro.Workflow.Resume (WorkflowResumeOptions (..), defaultWorkflowResumeOptions)
import Keiro.Workflow.Schema (lockWorkflowStepTx, lookupStepResultTx, workflowLifecycleMarkersTx, workflowStepLockKey)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.AdaptiveDelivery.Generated.WorkflowRuntime qualified as Adaptive
import Shikigami.AgentRun.Generated.WorkflowRuntime qualified as AgentRun
import Shikigami.App (AppEnv (..))
import Shikigami.Approval.Generated.WorkflowRuntime qualified as Approval
import Shikigami.ContinuingWorker.Generated.WorkflowRuntime qualified as ContinuingWorker
import Shikigami.DanwaConversation.Generated.WorkflowRuntime qualified as DanwaConversation
import Shikigami.Execution.Capacity (RuntimeLimits (..), capacityLimit, defaultRuntimeLimits)
import Shikigami.ExecutionDriver.Generated.WorkflowRuntime qualified as Execution
import Shikigami.RecurringCheckpointCycle.Generated.WorkflowRuntime qualified as MandateCycle
import Shikigami.RecurringObjective.Generated.WorkflowRuntime qualified as Mandate

-- | Every patch id this deployment has active, read from the checked
-- specification rather than written here.
--
-- Each workflow's declared patch ids reach Haskell as @declaredPatches@ in its
-- generated @WorkflowRuntime@ module, scaffolded from
-- @domain\/shikigami-agent-run.keiro@ and @domain\/shikigami-conversation.keiro@.
-- Adding a patch id therefore means editing the specification, regenerating, and
-- passing @just keiro-gate@ — which is the discipline, not a description of it.
-- A hand-written list beside the generated one could drift from the gated one,
-- which is the precise failure this module exists to prevent.
--
-- The sets are unioned because Keiro's resume worker carries a single
-- 'WorkflowRunOptions' for every workflow it drives (@runOptions@ in
-- 'WorkflowResumeOptions'), so there is no boundary at which a per-workflow set
-- could be applied. Activating a patch id for a workflow that never calls
-- 'Keiro.Workflow.patch' with it is inert; it costs one extra entry in that
-- instance's reserved @__workflow_patches__@ record.
shikigamiActivePatches :: Set PatchId
shikigamiActivePatches =
  AgentRun.declaredPatches
    <> Approval.declaredPatches
    <> DanwaConversation.declaredPatches
    <> Execution.declaredPatches
    <> ContinuingWorker.declaredPatches
    <> Adaptive.declaredPatches
    <> Mandate.declaredPatches
    <> MandateCycle.declaredPatches

-- | The options every first run of a Shikigami workflow uses.
shikigamiWorkflowRunOptions :: AppEnv -> WorkflowRunOptions
shikigamiWorkflowRunOptions AppEnv {tracer = appTracer, metrics = appMetrics} =
  defaultWorkflowRunOptions
    & #activePatches .~ shikigamiActivePatches
    & #tracer .~ Just appTracer
    & #metrics .~ appMetrics

-- | The options the resume worker uses, carrying 'shikigamiWorkflowRunOptions'
-- so a resumed run is configured exactly as its first run was.
shikigamiWorkflowResumeOptions :: AppEnv -> NominalDiffTime -> WorkflowResumeOptions
shikigamiWorkflowResumeOptions = shikigamiWorkflowResumeOptionsWith defaultRuntimeLimits

shikigamiWorkflowResumeOptionsWith :: RuntimeLimits -> AppEnv -> NominalDiffTime -> WorkflowResumeOptions
shikigamiWorkflowResumeOptionsWith limits appEnv timeout =
  defaultWorkflowResumeOptions
    & #runOptions .~ shikigamiWorkflowRunOptions appEnv
    & #leaseTtl .~ workflowLeaseTtl timeout
    & #maxConcurrentAdvances .~ capacityLimit limits.advances

-- | How long an instance lease lasts for a run bounded by @timeout@. The
-- direct path and the resume worker use the same value, so neither outlives
-- the other's claim.
workflowLeaseTtl :: NominalDiffTime -> NominalDiffTime
workflowLeaseTtl timeout = timeout + 30

-- | What a leased direct run did.
data LeasedRun a
  = -- | This caller held the instance lease and ran the workflow.
    Advanced !(WorkflowOutcome a)
  | -- | Another runner holds the lease, or took it mid-run. That runner owns
    -- the run's progress; this caller made none and has nothing to report.
    AdvancedElsewhere
  deriving stock (Eq, Show)

-- | Run a workflow directly while holding its instance lease.
--
-- Keiro's plain direct run takes no lease, and resume discovery returns every
-- @running@ instance whose lease is absent. In a process that runs both, the
-- resume worker therefore re-enters a first run still in flight, and each
-- executes the step the other has not journaled yet: a model call is made
-- twice, and a step that refuses a second concurrent attempt fails the run
-- while the first attempt is still working (FRIC-86). Claiming the lease the
-- resume worker claims makes the two paths exclude each other.
--
-- A terminal instance cannot be claimed and needs no lease: its run is a
-- side-effect-free replay of the recorded outcome, which a redelivered job
-- still wants. The lease is renewed before each fresh step, exactly as for a
-- resumed run, and released when the run returns or throws.
runWorkflowLeased ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  AppEnv ->
  NominalDiffTime ->
  WorkflowName ->
  WorkflowId ->
  Eff (Workflow : es) a ->
  Eff es (LeasedRun a)
runWorkflowLeased appEnv timeout name wid body = do
  owner <- UUID.toText <$> liftIO UUIDv4.nextRandom
  let ttl = workflowLeaseTtl timeout
      options = shikigamiWorkflowRunOptions appEnv
  claimInstance owner ttl name wid >>= \case
    ClaimAcquired ->
      ( (Advanced <$> runWorkflowWith (options & #leaseHeartbeat .~ Just LeaseHeartbeat {owner, ttl}) name wid body)
          `catch` (\WorkflowLeaseLost -> pure AdvancedElsewhere)
      )
        `finally` releaseInstance owner False name wid
    ClaimUnavailable -> Advanced <$> runWorkflowWith options name wid body
    ClaimLeaseHeld -> pure AdvancedElsewhere
    ClaimPaced -> pure AdvancedElsewhere

-- | Keep terminal workflow journals for ninety days. This bounds the workflow
-- idempotency window; redelivery older than that requires operator review.
-- Keiro excludes live instances and completed children of live parents.
-- Evidence streams/rows and sink receipts have separate ownership and survive.
terminalWorkflowRetention :: WorkflowGcPolicy
terminalWorkflowRetention = WorkflowGcPolicy {retention = 90 * 86400, batchSize = 100}

-- External ingestion precedes the runner's fresh-journal check. Atomically seed
-- only an unadmitted generation; an existing input or patch set is historical.
-- Taking the public ingestion lock also arbitrates a concurrent old producer.
prepareAdmittedInput :: (IOE :> es) => WorkflowName -> WorkflowId -> StepName -> Value -> Eff es (Transaction JournalAppendOutcome)
prepareAdmittedInput name identity label value = do
  now <- liftIO getCurrentTime
  snapshot <- prepareJournalAppend name identity 0 (StepRecorded patchSetStepName (toJSON (map unPatchId (Set.toList shikigamiActivePatches))) now)
  ingestion <- prepareJournalAppend name identity 0 (StepRecorded label.unStepName value now)
  pure do
    -- Same lifecycle lock used by the public journal's terminal writers.
    lockWorkflowStepTx (workflowStepLockKey identity.unWorkflowId name.unWorkflowName 0 "__keiro_lifecycle__")
    lockWorkflowStepTx (workflowStepLockKey identity.unWorkflowId name.unWorkflowName 0 label.unStepName)
    original <- lookupStepResultTx identity.unWorkflowId name.unWorkflowName 0 label.unStepName
    patches <- lookupStepResultTx identity.unWorkflowId name.unWorkflowName 0 patchSetStepName
    markers <- workflowLifecycleMarkersTx identity.unWorkflowId name.unWorkflowName 0
    when (isNothing original && not (null markers)) (Tx.condemn >> throw (WorkflowJournalAppendError "an unadmitted terminal workflow cannot gain input"))
    when (isNothing original && isNothing patches) do
      snapshot >>= \case
        JournalAppended {} -> pure ()
        JournalAlreadyPresent {} -> pure ()
        _ -> Tx.condemn >> throw (WorkflowJournalAppendError "native input patch snapshot could not commit")
    ingestion

admitWorkflowInput :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> StepName -> Value -> Eff es ()
admitWorkflowInput name identity label value = do
  prepared <- prepareAdmittedInput name identity label value
  outcome <- runTransaction prepared
  case outcome of
    JournalAppended {} -> pure ()
    JournalAlreadyPresent {} -> pure ()
    _ -> throw (WorkflowJournalAppendError "native workflow input could not commit")

-- | Deploying changed workflow code over instances that are already running.
--
-- A Keiro workflow journals each step to Postgres and replays that journal
-- instead of re-running it, so an instance suspended before a deploy is resumed
-- by code that has since changed. Nothing in the runtime notices the change: it
-- matches journal records to steps by name, so new code asking for a name the
-- old journal happens to hold gets the old value.
--
-- @Keiro.Workflow.patch@ is the escape hatch, and these are its executable
-- proof. Each case manufactures the in-flight instance the hazard needs —
-- Shikigami has no deployment yet, so there is no real one to find — by running
-- a workflow to suspension under one code shape and resuming it under another.
--
-- The rules these cases enforce are written out in @docs\/workflow-versioning.md@.
-- A change to a rule there should change a case here.
module Shikigami.WorkflowVersioningSpec (tests) where

import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, getCurrentTime, secondsToNominalDiffTime)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Keiro.Outbox (listOutbox)
import Keiro.Workflow
  ( PatchId (..),
    StepName (..),
    Workflow,
    WorkflowId (..),
    WorkflowName (..),
    WorkflowOutcome (..),
    WorkflowRunOptions (..),
    defaultWorkflowRunOptions,
    loadStepIndex,
    patch,
    patchSetStepName,
    patchStepName,
    runWorkflowWith,
    step,
  )
import Keiro.Workflow.Resume (WorkflowResumeOptions (..))
import Keiro.Workflow.Sleep (runWorkflowTimerWorker)
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kioku.Id (SessionId, genSessionId)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (runStoreResource)
import Kiroku.Store.Effect.Resource (withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Agent.Workflow.Input (awaitInput, deliverInputTo)
import Shikigami.Flow (FlowDef (..), FlowRuntime (..), lookupFlow)
import Shikigami.Flow.Acknowledgement (runAcknowledgement)
import Shikigami.Flow.Capability (MemoryEnv (..), SinkEnv (..), runActivity, runMemory, runSink)
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.Sink.GrantStore (GrantSource (StaticGrants))
import Shikigami.Sink.Permission (defaultGrantTable)
import Shikigami.Workflow.Versioning (shikigamiActivePatches, shikigamiWorkflowResumeOptions)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "WorkflowVersioning"
    [ testCase "resume lease exceeds the synchronous behavior timeout" do
        let timeout = secondsToNominalDiffTime 300
            WorkflowResumeOptions
              { leaseTtl,
                runOptions = WorkflowRunOptions {leaseHeartbeat}
              } = shikigamiWorkflowResumeOptions timeout
        assertEqual "resume lease includes the scheduling margin" (secondsToNominalDiffTime 330) leaseTtl
        assertEqual "resume worker, not direct runs, installs the instance heartbeat" Nothing leaseHeartbeat,
      testCase "in-flight workflow survives a simulated deploy under a patch guard" inFlightSurvivesDeploy,
      testCase "behavior retry patch pins agent and conversation labels per deploy" behaviorRetryLabelsArePinned,
      testCase "emitSignal ordinals preserved in flight, labels when fresh" emitSignalSchemeIsPinnedPerInstance
    ]

-- ── Test A: the patch primitive, end to end ─────────────────────────────────

-- | A workflow started before a patch shipped keeps the old branch; one started
-- after takes the new one.
--
-- Two bodies share one 'WorkflowName', which is what a deploy looks like from
-- the journal's point of view: same stream, different code. The new body inserts
-- a step (@enrich@) ahead of the parked instance's resume point — the change
-- class @docs\/workflow-versioning.md@ rule 4 says must be guarded, because the
-- parked instance cannot finish coherently under the new shape.
--
-- The options are built here rather than taken from
-- "Shikigami.Workflow.Versioning" on purpose: this case is about the mechanism,
-- so it must not pass or fail because of which patches production happens to
-- have active today.
inFlightSurvivesDeploy :: IO ()
inFlightSurvivesDeploy =
  withShikigamiMigratedDatabase \connStr ->
    withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
      tracer <- noopTracer
      let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
      collectRuns <- newIORef (0 :: Int)

      -- The old deploy: the patch does not exist yet, so its options name none.
      parked <-
        runAppIO appEnv (runWorkflowWith preDeployOptions versioningWorkflowName inFlightId (oldShape collectRuns))
      assertEqual "the pre-deploy run parks on its awakeable" (Right Suspended) parked
      assertEqual "the pre-deploy run executed collect once" 1 =<< readIORef collectRuns

      delivered <-
        runAppIO appEnv (deliverInputTo versioningWorkflowName inFlightId externalAnswerStep ("answered" :: Text))
      assertEqual "the external answer resolves the awakeable" (Right True) delivered

      -- The deploy happens here: same workflow name, changed body, patch active.
      resumed <-
        runAppIO appEnv (runWorkflowWith postDeployOptions versioningWorkflowName inFlightId (newShape collectRuns))
      assertEqual
        "the in-flight instance completes on the OLD branch"
        (Right (Completed "v1:answered"))
        resumed
      assertEqual
        "collect was replayed from the journal, not re-executed"
        1
        =<< readIORef collectRuns

      inFlight <- loadStepNames appEnv versioningWorkflowName inFlightId
      assertEqual
        "the in-flight instance journaled its patch decision"
        (Right True)
        (elem (patchStepName versioningPatch) <$> inFlight)
      assertEqual
        "it recorded no patch set, because it started before the patch existed"
        (Right False)
        (elem patchSetStepName <$> inFlight)
      assertEqual
        "it never ran the inserted step"
        (Right False)
        (elem "enrich" <$> inFlight)

      -- A fresh instance under the same new code takes the other branch.
      freshRuns <- newIORef (0 :: Int)
      freshParked <-
        runAppIO appEnv (runWorkflowWith postDeployOptions versioningWorkflowName freshId (newShape freshRuns))
      assertEqual "the fresh run parks on its awakeable" (Right Suspended) freshParked
      freshDelivered <-
        runAppIO appEnv (deliverInputTo versioningWorkflowName freshId externalAnswerStep ("answered" :: Text))
      assertEqual "the external answer resolves the fresh awakeable" (Right True) freshDelivered
      freshResumed <-
        runAppIO appEnv (runWorkflowWith postDeployOptions versioningWorkflowName freshId (newShape freshRuns))
      assertEqual
        "the fresh instance completes on the NEW branch"
        (Right (Completed "v2:answered"))
        freshResumed

      fresh <- loadStepIndexFor appEnv versioningWorkflowName freshId
      assertEqual
        "the fresh instance recorded the active patch set"
        (Right True)
        (Map.member patchSetStepName <$> fresh)
      assertEqual
        "the fresh instance journaled the patch decision as true"
        (Right (Just (Aeson.Bool True)))
        (Map.lookup (patchStepName versioningPatch) <$> fresh)
      assertEqual
        "the fresh instance ran the inserted step"
        (Right True)
        (Map.member "enrich" <$> fresh)

versioningWorkflowName :: WorkflowName
versioningWorkflowName = WorkflowName "shikigami.test-versioning"

versioningPatch :: PatchId
versioningPatch = PatchId "shikigami-test-versioning-v2"

inFlightId :: WorkflowId
inFlightId = WorkflowId "wid-inflight"

freshId :: WorkflowId
freshId = WorkflowId "wid-fresh"

externalAnswerStep :: StepName
externalAnswerStep = StepName "external-answer"

-- | The options a deploy made before the patch existed would have used.
preDeployOptions :: WorkflowRunOptions
preDeployOptions = defaultWorkflowRunOptions

-- | The options the deploy that introduces the patch uses.
postDeployOptions :: WorkflowRunOptions
postDeployOptions = defaultWorkflowRunOptions {activePatches = Set.singleton versioningPatch}

-- | The body as it was before the change: collect, then park.
--
-- The 'IORef' counts executions of @collect@'s /action/, which is how the test
-- tells a replay (the action does not run) from a re-run (it does).
oldShape :: IORef Int -> Eff (Workflow : AppEffects) Text
oldShape collectRuns = do
  _ <- step (StepName "collect") (countCollect collectRuns)
  answer <- awaitInput externalAnswerStep
  pure ("v1:" <> answer)

-- | The body after the change: an inserted @enrich@ step and a different result,
-- both behind the patch.
newShape :: IORef Int -> Eff (Workflow : AppEffects) Text
newShape collectRuns = do
  useNewShape <- patch versioningPatch
  if useNewShape
    then do
      _ <- step (StepName "collect") (countCollect collectRuns)
      _ <- step (StepName "enrich") (pure ("enriched" :: Text))
      answer <- awaitInput externalAnswerStep
      pure ("v2:" <> answer)
    else do
      _ <- step (StepName "collect") (countCollect collectRuns)
      answer <- awaitInput externalAnswerStep
      pure ("v1:" <> answer)

countCollect :: (IOE :> es) => IORef Int -> Eff es Text
countCollect ref = do
  _ <- liftIO (atomicModifyIORef' ref \n -> (n + 1, n))
  pure "v1"

-- | The production retry patch keeps the old behavior label decodable for an
-- instance started before deployment and selects only the v2 label for a fresh
-- instance. Conversation labels carry a message id, but the patch decision is
-- the same stable journal value.
behaviorRetryLabelsArePinned :: IO ()
behaviorRetryLabelsArePinned =
  withShikigamiMigratedDatabase \connStr ->
    withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
      tracer <- noopTracer
      let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
      traverse_ (exerciseLabelFamily appEnv) labelFamilies
      assertBool
        "the deployed patch set contains the behavior retry id"
        (Set.member behaviorRetryPatch shikigamiActivePatches)
  where
    -- The conversation entry is the LEGACY branch's label family. Fresh
    -- conversations run the rotating shape, whose behavior label is the static
    -- `run-behavior-v2` with no message id, guarded by
    -- shikigami-conversation-rotation-v1 rather than by the retry patch; that
    -- one is covered by the Conversation cases in "Shikigami.AgentWorkflowSpec".
    -- Both label sets are live, because which one an instance is on is a durable
    -- property of that instance.
    labelFamilies =
      [ (WorkflowName "shikigami.agent-run", "run-behavior", "run-behavior-v2"),
        (WorkflowName "shikigami.danwa-conversation", "run-behavior:msg-versioning", "run-behavior-v2:msg-versioning")
      ]

behaviorRetryPatch :: PatchId
behaviorRetryPatch = PatchId "shikigami-behavior-retry-v1"

exerciseLabelFamily :: AppEnv -> (WorkflowName, Text, Text) -> IO ()
exerciseLabelFamily appEnv (workflowName, oldLabel, newLabel) = do
  let suffix = oldLabel
      oldId = WorkflowId ("retry-old:" <> suffix)
      freshId' = WorkflowId ("retry-fresh:" <> suffix)
      postRetryOptions = defaultWorkflowRunOptions {activePatches = Set.singleton behaviorRetryPatch}

  parked <- runAppIO appEnv (runWorkflowWith defaultWorkflowRunOptions workflowName oldId (oldRetryShape oldLabel))
  assertEqual (Text.unpack oldLabel <> " pre-deploy shape parks") (Right Suspended) parked
  resumed <- runAppIO appEnv (runWorkflowWith postRetryOptions workflowName oldId (newRetryShape oldLabel newLabel))
  assertEqual (Text.unpack oldLabel <> " old journal decodes") (Right (Completed (Right Aeson.Null))) resumed
  oldIndex <- loadStepIndexFor appEnv workflowName oldId
  assertEqual (Text.unpack oldLabel <> " remains present") (Right True) (Map.member oldLabel <$> oldIndex)
  assertEqual (Text.unpack newLabel <> " is absent from the old journal") (Right False) (Map.member newLabel <$> oldIndex)

  fresh <- runAppIO appEnv (runWorkflowWith postRetryOptions workflowName freshId' (newRetryShape oldLabel newLabel))
  assertEqual (Text.unpack newLabel <> " fresh shape completes") (Right (Completed (Right Aeson.Null))) fresh
  freshIndex <- loadStepIndexFor appEnv workflowName freshId'
  assertEqual (Text.unpack newLabel <> " is present in the fresh journal") (Right True) (Map.member newLabel <$> freshIndex)
  assertEqual (Text.unpack oldLabel <> " is absent from the fresh journal") (Right False) (Map.member oldLabel <$> freshIndex)

oldRetryShape :: Text -> Eff (Workflow : AppEffects) Value
oldRetryShape label = do
  _ <- step (StepName label) (pure (Right Aeson.Null :: Either Text Value))
  awaitInput (StepName ("retry-park:" <> label))

newRetryShape :: Text -> Text -> Eff (Workflow : AppEffects) (Either Text Value)
newRetryShape oldLabel newLabel = do
  useRetrySemantics <- patch behaviorRetryPatch
  step
    (StepName (if useRetrySemantics then newLabel else oldLabel))
    (pure (Right Aeson.Null))

-- ── Test B: the emit-signal scheme is pinned per instance ───────────────────

-- | A flow parked before the labels patch shipped keeps naming its emissions by
-- ordinal; a flow started after names them by label.
--
-- This is the concrete instance of Test A's mechanism, on the change this plan
-- actually made. The escalation is the emission that matters: it is journaled
-- /after/ the deploy, by an instance that started before it, so it is the one a
-- naming-scheme change could strand. Under the guard it must land on
-- @emit-signal:1@ — the name the old scheme would have given it — and must not
-- add a third outbox row.
--
-- Reverting the guard in "Shikigami.Flow.Capability" (forcing the label branch
-- unconditionally) makes this case fail on exactly that: the escalation lands on
-- @emit-signal:escalate@ instead of @emit-signal:1@.
emitSignalSchemeIsPinnedPerInstance :: IO ()
emitSignalSchemeIsPinnedPerInstance =
  withShikigamiMigratedDatabase \connStr ->
    withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
      tracer <- noopTracer
      session <- genSessionId
      let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing}
      flow <- requireAtRiskFlow

      -- Pre-deploy: empty patch set, so the flow names emissions by ordinal.
      parked <- runFlow appEnv (atRiskRuntime session) preLabelsOptions flow inFlightFlowId
      assertEqual "the high-risk flow parks for acknowledgement" (Right Suspended) parked
      afterAlert <- loadStepNames appEnv flowWorkflowName inFlightFlowId
      assertEqual
        "the pre-deploy alert journaled under the ordinal scheme"
        (Right True)
        (elem "emit-signal:0" <$> afterAlert)
      assertEqual "the alert enqueued exactly one outbox row" (Right 1) =<< outboxCount appEnv

      -- The deploy happens here: same flow code, labels patch now active.
      fireDueApprovalTimer appEnv
      resumed <- runFlow appEnv (atRiskRuntime session) postLabelsOptions flow inFlightFlowId
      assertEqual "the timed-out flow completes escalated" (Right (Completed escalatedOutput)) resumed

      afterEscalation <- loadStepNames appEnv flowWorkflowName inFlightFlowId
      assertEqual
        "the escalation kept the OLD scheme, because this instance started under it"
        (Right True)
        (elem "emit-signal:1" <$> afterEscalation)
      assertEqual
        "the escalation did not journal under a label"
        (Right False)
        (elem "emit-signal:escalate" <$> afterEscalation)
      assertEqual
        "alert plus escalation, and no duplicate alert from an orphaned step name"
        (Right 2)
        =<< outboxCount appEnv

      -- A flow started after the deploy uses labels.
      freshParked <- runFlow appEnv (atRiskRuntime session) postLabelsOptions flow freshFlowId
      assertEqual "the fresh flow parks for acknowledgement" (Right Suspended) freshParked
      fresh <- loadStepNames appEnv flowWorkflowName freshFlowId
      assertEqual
        "the fresh flow journaled its alert under the label"
        (Right True)
        (elem "emit-signal:alert" <$> fresh)
      assertEqual
        "the fresh flow used no ordinal"
        (Right False)
        (elem "emit-signal:0" <$> fresh)

      -- The scheme above is only reachable in production if the id is actually
      -- deployed, which is what Shikigami.Workflow.Versioning reads out of the
      -- checked specification.
      assertBool
        "the deployed patch set contains the id this case exercises"
        (Set.member emitSignalLabelsPatch shikigamiActivePatches)

emitSignalLabelsPatch :: PatchId
emitSignalLabelsPatch = PatchId "shikigami-emit-signal-labels-v1"

flowWorkflowName :: WorkflowName
flowWorkflowName = WorkflowName "shikigami.flow.spike"

inFlightFlowId :: WorkflowId
inFlightFlowId = WorkflowId "flow-versioning-inflight"

freshFlowId :: WorkflowId
freshFlowId = WorkflowId "flow-versioning-fresh"

preLabelsOptions :: WorkflowRunOptions
preLabelsOptions = defaultWorkflowRunOptions

postLabelsOptions :: WorkflowRunOptions
postLabelsOptions = defaultWorkflowRunOptions {activePatches = Set.singleton emitSignalLabelsPatch}

requireAtRiskFlow :: IO FlowDef
requireAtRiskFlow =
  case lookupFlow "at-risk-customer" of
    Just flow -> pure flow
    Nothing -> assertFailure "at-risk-customer flow should be registered"

-- | The acknowledgement environment the at-risk flow parks through.
--
-- It moved out of 'requireAtRiskFlow' when acknowledgement became a capability:
-- looking a flow up no longer needs it, running one still does.
atRiskRuntime :: SessionId -> FlowRuntime
atRiskRuntime session =
  FlowRuntime
    { approval = Approval.defaultApprovalEnv session,
      acknowledgementDeadline = secondsToNominalDiffTime 1
    }

-- | Run a registered flow's body under explicit options — the way
-- "Shikigami.FlowLifecycleSpec" does, but with the options as a parameter, which
-- is the whole point here.
runFlow ::
  AppEnv ->
  FlowRuntime ->
  WorkflowRunOptions ->
  FlowDef ->
  WorkflowId ->
  IO (Either StoreError (WorkflowOutcome Value))
runFlow appEnv runtime options FlowDef {run} workflowId =
  runEff
    . runErrorNoCallStack
    . withKirokuStore (connectionSettings appEnv)
    . runStoreResource
    $ runWorkflowWith options flowWorkflowName workflowId body
  where
    memoryEnv = MemoryEnv {appEnv, agent = flowAgentDecl, sessionId = Nothing}
    sinkEnv =
      SinkEnv
        { agent = "at-risk-customer",
          runId = "flow-versioning-run",
          occurredAt = Just flowOccurredAt,
          danwaTarget = Nothing,
          activity = Just sampleActivity,
          grants = StaticGrants defaultGrantTable
        }
    body =
      runActivity sampleActivity
        . runMemory memoryEnv
        . runSink sinkEnv
        . runAcknowledgement (approval runtime) (acknowledgementDeadline runtime)
        $ run highRiskPayload

fireDueApprovalTimer :: AppEnv -> IO ()
fireDueApprovalTimer appEnv = do
  now <- getCurrentTime
  fired <- runAppIO appEnv (runWorkflowTimerWorker Nothing (addUTCTime 2 now) Approval.approvalTimeoutFireAction)
  assertBool "approval timeout timer should fire" (either (const False) (maybe False (const True)) fired)

outboxCount :: AppEnv -> IO (Either StoreError Int)
outboxCount appEnv = fmap length <$> runAppIO appEnv (listOutbox "shinzui/shikigami")

-- ── Reading a journal ───────────────────────────────────────────────────────

loadStepIndexFor :: AppEnv -> WorkflowName -> WorkflowId -> IO (Either StoreError (Map Text Value))
loadStepIndexFor appEnv workflowName workflowId =
  runAppIO appEnv (loadStepIndex workflowName workflowId 0)

loadStepNames :: AppEnv -> WorkflowName -> WorkflowId -> IO (Either StoreError [Text])
loadStepNames appEnv workflowName workflowId =
  fmap Map.keys <$> loadStepIndexFor appEnv workflowName workflowId

-- ── Fixtures ────────────────────────────────────────────────────────────────

flowAgentDecl :: AgentDecl
flowAgentDecl =
  AgentDecl
    { name = "at-risk-customer",
      description = "workflow versioning test agent",
      trigger = Event {eventType = "customer.risk_detected"},
      behavior = Deterministic {rule = "flow-test", params = mempty},
      sinks = [],
      delegates = [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True
    }

flowOccurredAt :: UTCTime
flowOccurredAt = UTCTime (fromGregorian 2026 6 27) 0

sampleActivity :: ActivityEnvelope
sampleActivity =
  ActivityEnvelope
    { activityId = "act_flow_versioning",
      occurredAt = "2026-06-27T00:00:00Z",
      source = "shinzui/shikigami",
      actor = Actor {kind = "service", id = "flow-versioning-test", session = Nothing},
      subject = Subject {subjectType = "ticket", subjectId = "ticket_1"},
      verb = "customer.risk_detected",
      payload = Aeson.object [],
      contextRefs = [],
      idempotencyKey = "act_flow_versioning"
    }

highRiskPayload :: Value
highRiskPayload =
  Aeson.object
    [ ("text", toJSON ("Customer says they will cancel after repeated outages." :: Text)),
      ( "enrichment",
        Aeson.object
          [ ("sentiment", toJSON ("negative" :: Text)),
            ("risks", toJSON (["churn risk"] :: [Text]))
          ]
      )
    ]

expectedVerdict :: Value
expectedVerdict =
  Aeson.object
    [ ("level", toJSON ("high" :: Text)),
      ("rationale", toJSON ("customer relationship at risk" :: Text)),
      ("ticketId", toJSON ("ticket_1" :: Text))
    ]

escalatedOutput :: Value
escalatedOutput =
  Aeson.object
    [ ("status", toJSON ("escalated" :: Text)),
      ("verdict", expectedVerdict)
    ]

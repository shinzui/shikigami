module Shikigami.FlowLifecycleSpec (tests) where

import Data.Aeson (Value (Bool, Object, String), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, getCurrentTime, secondsToNominalDiffTime)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Keiro.Outbox (listOutbox)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), loadStepIndex, runWorkflowWith, step)
import Keiro.Workflow.Awakeable (AwakeableId)
import Keiro.Workflow.Awakeable.Schema (countPendingAwakeables)
import Keiro.Workflow.Sleep (runWorkflowTimerWorker, sleepNamed)
import Kioku.Api.Types (Confidence (HighConfidence, MediumConfidence), MemoryRecord (..), MemoryType (MemoryConstraint, MemoryPattern), confidenceToText, memoryTypeToText)
import Kioku.Id (MemoryId, SessionId, genSessionId, idText)
import Kioku.Id qualified as NominalId
import Kioku.Memory (MemoryWriteError (..))
import Kioku.Memory qualified as Memory
import Kioku.Memory.ReadModel (MemoryRow (..))
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (Store, runStoreResource)
import Kiroku.Store.Effect.Resource (withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Shibuya.Telemetry.Effect (runTracingNoop)
import Shikigami.Action.Authorization (denyAllActionAuthorizer)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Priority (Normal), RecipientFrom (SubjectOwner), SignalType (Reminder), Sink (..), Trigger (..), defaultDelegationBudget, defaultMemoryPolicy)
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Delegate.Depth (DelegationDepth, parseDelegationDepth)
import Shikigami.Agent.Loader (AgentLoadEntry (AgentLoaded), AgentLoadReport (..))
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (ResolvedAgentIdentity (CompatibilityAgent), compatibilityIdentity)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Behavior.Run (newBehaviorEnv)
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Duration (parseDuration)
import Shikigami.Flow (FlowDef (..), FlowEffects, FlowRuntime (..), atRiskCustomerLifecycleDiagram, flowDeclarationErrors, flowRegistry, lookupFlow, registeredFlowNames)
import Shikigami.Flow.Acknowledgement (Ack (..), ackFromDecision, runAcknowledgement)
import Shikigami.Flow.Capability
  ( MemoryEnv (..),
    MemoryPriority (..),
    MemoryQuery (..),
    RememberOptions (..),
    SinkEnv (..),
    currentActivity,
    defaultRememberOptions,
    deterministicFlowMemoryId,
    emitSignal,
    recall,
    recordFlowMemory,
    remember,
    rememberWith,
    runActivity,
    runMemory,
    runSink,
  )
import Shikigami.Flow.Decision qualified as FlowDecision
import Shikigami.Flow.Delegate qualified as FlowDelegate
import Shikigami.Flow.Objectives qualified as FlowObjectives
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Flow.Workers qualified as FlowWorkers
import Shikigami.Memory.Access (shikigamiMemorySpace)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.PracticeReview.Capability qualified as PracticeReview
import Shikigami.PracticeReview.Memory qualified as PracticeReviewMemory
import Shikigami.RuntimePolicy (DefaultModelRequirement (..))
import Shikigami.Sink.GrantStore (GrantSource (StaticGrants))
import Shikigami.Sink.Permission (SinkKind (SKizashiSignal), defaultGrantTable)
import Shikigami.Sink.Types (SinkOutcome (DeniedOutcome, Enqueued), SinkResult (..))
import Shikigami.Trigger.Schedule (parseCron)
import Shikigami.WorkerSession.Capability (CoordinatorRun (..))
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "FlowLifecycle"
    [ -- No FlowRuntime is constructed here any more, and that is the assertion:
      -- asking which flows exist no longer requires the machinery for running one.
      testCase "flow registry resolves at-risk-customer and misses unknown flows" do
        case lookupFlow (declarationCoordinate ("at-risk-customer")) of
          Just FlowDef {name = flowName} -> assertEqual "registered flow name" (declarationCoordinate "at-risk-customer") flowName
          Nothing -> assertFailure "expected at-risk-customer flow to be registered"
        case lookupFlow (declarationCoordinate ("unknown-flow")) of
          Nothing -> pure ()
          Just flow -> assertFailure ("expected unknown lookup to miss, got " <> show flow),
      -- registeredFlowNames is what `shikigami validate` and worker boot consult,
      -- and they must never disagree with what the runtime can actually run. The
      -- two are projections of one list in Shikigami.Flow, and this pins that.
      testCase "registeredFlowNames names exactly the flows the registry builds" do
        assertEqual
          "registered names match the built registry"
          [flowName | FlowDef {name = flowName} <- flowRegistry]
          registeredFlowNames
        assertBool "at least one flow is registered" (not (null registeredFlowNames)),
      testCase "a Flow behavior naming an unregistered flow is a declaration error" do
        assertEqual
          "unknown flow is refused, and the message names what is registered"
          ["unknown flow no-such-flow; registered flows: objective-example, shikumi-decision-example, shikumi-judgment-example, at-risk-customer, delegation-proof, architecture-practice-router, opentelemetry-practice-review"]
          (flowDeclarationErrors (flowBehaviorAgent (Flow {name = declarationCoordinate ("no-such-flow")})))
        assertEqual
          "a registered flow is accepted"
          []
          (flowDeclarationErrors (flowBehaviorAgent (Flow {name = declarationCoordinate ("at-risk-customer")})))
        assertEqual
          "a non-flow behavior is not this check's business"
          []
          (flowDeclarationErrors (flowBehaviorAgent (Deterministic {rule = "flow-test", params = mempty}))),
      testCase "trivial flow completes through keiro runWorkflowWith" do
        outcome <- (runFlowWorkflow databaseFixture) completedFlow (WorkflowId "flow-completed-spike")
        assertEqual "two-step flow completes" (Right (Completed (toJSON (2 :: Int)))) outcome,
      testCase "sleeping flow suspends through keiro runWorkflowWith" do
        outcome <- (runSleepSpike databaseFixture) (WorkflowId "flow-sleeping-spike")
        assertEqual "sleeping flow suspends" (Right Suspended) outcome,
      testCase "currentActivity exposes the triggering activity envelope" do
        outcome <- (runFlowWorkflow databaseFixture) activityFlow (WorkflowId "flow-activity-spike")
        assertEqual "activity id is available to the flow" (Right (Completed (String "act_flow_test"))) outcome,
      testCase "remember and recall use the flow memory capability" do
        outcome <- (runFlowWorkflow databaseFixture) memoryFlow (WorkflowId "flow-memory-spike")
        assertEqual "recalled memories include the remembered flow note" (Right (Completed (Bool True))) outcome,
      testCase "emitSignal enqueues an allowed sink outbox intent" do
        (outcome, count) <- (runFlowWorkflowWithAgent databaseFixture) "at-risk-customer" sinkFlow (WorkflowId "flow-sink-spike")
        assertEqual
          "allowed sink returns a delivered outbox result"
          (Right (Completed (toJSON (SinkResult SKizashiSignal (Enqueued (declarationCoordinate "outbox:flow-sink-spike:emit-signal:alert"))))))
          outcome
        assertEqual "allowed sink enqueues one outbox message" (Right 1) count,
      testCase "emitSignal records denied sinks without enqueueing" do
        (outcome, count) <- (runFlowWorkflowWithAgent databaseFixture) "intruder" sinkFlow (WorkflowId "flow-denied-sink-spike")
        case outcome of
          Right (Completed encodedResult) -> case encodedResult of
            _ | encodedResult == toJSON (SinkResult SKizashiSignal (DeniedOutcome "agent 'intruder' has no sink grants")) -> pure ()
            other -> assertFailure ("expected denied sink result, got " <> show other)
          other -> assertFailure ("denied sink flow should complete, got " <> show other)
        assertEqual "denied sink does not enqueue an outbox message" (Right 0) count,
      testCase "registered at-risk-customer flow parks then completes when acknowledged" do
        (withAtRiskFlow databaseFixture) \appEnv runtime aidRef flow -> do
          let workflowId = WorkflowId "flow-at-risk-ack"
          parked <- runFlowInAppEnv appEnv runtime "at-risk-customer" flow workflowId highRiskPayload
          assertEqual "high-risk flow parks for acknowledgement" (Right Suspended) parked

          pending <- runAppIO appEnv countPendingAwakeables
          assertEqual "one acknowledgement awakeable is pending" (Right 1) pending
          beforeOutbox <- outboxCount appEnv
          assertEqual "alert outbox row is enqueued before acknowledgement" (Right 1) beforeOutbox

          aid <- readCapturedAwakeable aidRef
          resolved <- Approval.resolveApproval appEnv aid (Approval.Approved (object ["by" .= ("relationship-owner" :: Text)]))
          assertBool "approval signal resolves the awakeable" resolved

          resumed <- runFlowInAppEnv appEnv runtime "at-risk-customer" flow workflowId highRiskPayload
          assertEqual "acknowledged flow completes" (Right (Completed acknowledgedOutput)) resumed
          afterOutbox <- outboxCount appEnv
          assertEqual "acknowledged branch does not enqueue escalation" (Right 1) afterOutbox,
      testCase "registered at-risk-customer flow escalates after acknowledgement timeout" do
        (withAtRiskFlow databaseFixture) \appEnv runtime _aidRef flow -> do
          let workflowId = WorkflowId "flow-at-risk-timeout"
          parked <- runFlowInAppEnv appEnv runtime "at-risk-customer" flow workflowId highRiskPayload
          assertEqual "high-risk flow parks for acknowledgement deadline" (Right Suspended) parked

          fireDueApprovalTimer appEnv
          resumed <- runFlowInAppEnv appEnv runtime "at-risk-customer" flow workflowId highRiskPayload
          assertEqual "timed-out flow completes escalated" (Right (Completed escalatedOutput)) resumed
          afterOutbox <- outboxCount appEnv
          assertEqual "timeout branch enqueues alert plus escalation" (Right 2) afterOutbox,
      testCase "registered at-risk-customer flow replays parked alert without duplicating outbox" do
        (withAtRiskFlow databaseFixture) \appEnv runtime aidRef flow -> do
          let workflowId = WorkflowId "flow-at-risk-crash-replay"
          first <- runFlowInAppEnv appEnv runtime "at-risk-customer" flow workflowId highRiskPayload
          assertEqual "first run parks" (Right Suspended) first
          firstOutbox <- outboxCount appEnv
          assertEqual "first run enqueues alert once" (Right 1) firstOutbox

          replayed <- runFlowInAppEnv appEnv runtime "at-risk-customer" flow workflowId highRiskPayload
          assertEqual "replayed run remains parked" (Right Suspended) replayed
          replayedOutbox <- outboxCount appEnv
          assertEqual "replay does not enqueue another alert" (Right 1) replayedOutbox

          aid <- readCapturedAwakeable aidRef
          resolved <- Approval.resolveApproval appEnv aid (Approval.Approved (object ["by" .= ("relationship-owner" :: Text)]))
          assertBool "approval signal resolves after replay" resolved
          completed <- runFlowInAppEnv appEnv runtime "at-risk-customer" flow workflowId highRiskPayload
          assertEqual "replayed flow can still complete" (Right (Completed acknowledgedOutput)) completed,
      -- Replay is the regime a durable workflow exists to survive: re-invoking a
      -- completed workflow under the same id re-runs its body with every
      -- journaled step answered from the journal rather than executed. An effect
      -- that is not itself a step has no journal entry to answer it, so it runs
      -- again -- and a `remember` that mints a fresh memory id each time turns
      -- that into one extra memory row per replay.
      testCase "replaying a completed flow does not duplicate its memory" do
        (withAtRiskFlow databaseFixture) \appEnv runtime aidRef flow -> do
          let workflowId = WorkflowId "flow-at-risk-memory-replay"
          parked <- runFlowInAppEnv appEnv runtime "at-risk-customer" flow workflowId highRiskPayload
          assertEqual "high-risk flow parks for acknowledgement" (Right Suspended) parked

          aid <- readCapturedAwakeable aidRef
          resolved <- Approval.resolveApproval appEnv aid (Approval.Approved (object ["by" .= ("relationship-owner" :: Text)]))
          assertBool "approval signal resolves the awakeable" resolved

          completed <- runFlowInAppEnv appEnv runtime "at-risk-customer" flow workflowId highRiskPayload
          assertEqual "acknowledged flow completes" (Right (Completed acknowledgedOutput)) completed
          afterFirst <- acknowledgedMemoryCount appEnv
          assertEqual "the acknowledged branch records its note once" 1 afterFirst

          replayed <- runFlowInAppEnv appEnv runtime "at-risk-customer" flow workflowId highRiskPayload
          assertEqual "replaying the completed flow returns the journaled value" (Right (Completed acknowledgedOutput)) replayed
          afterReplay <- acknowledgedMemoryCount appEnv
          assertEqual "replay does not record the note a second time" 1 afterReplay

          -- The row count says the duplicate is gone; the step index says *why*.
          -- Both memory operations are now journal entries, which is what the
          -- replay answers from instead of re-running them.
          journaled <- flowStepKeys appEnv workflowId
          assertBool
            ("recall is journaled under its label, got " <> show journaled)
            (Set.member "recall-risk-history" journaled)
          assertBool
            ("remember is journaled under its label, got " <> show journaled)
            (Set.member "remember-acknowledged" journaled),
      -- The crash window a journaled step cannot close by itself: keiro steps are
      -- at-least-once at the step boundary, so an action that ran but whose
      -- journal append did not commit runs again on resume. There is no public
      -- API for losing an append, so this exercises the property the
      -- deterministic id buys, in both directions -- which is also the contract
      -- `remember` documents: its arguments must be a pure function of
      -- replay-stable inputs.
      testCase "one deterministic id records idempotently and refuses a changed payload" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                memoryEnv = MemoryEnv {appEnv, agent = flowAgentDecl "at-risk-customer", identity = CompatibilityAgent (fixtureAgentName "at-risk-customer"), aliasPool = Nothing, sessionId = Nothing}
                mid = deterministicFlowMemoryId (WorkflowName "shikigami.flow.spike") (WorkflowId "flow-crash-window") 0 (declarationCoordinate "acknowledged")
                note = object ["summary" .= ("at-risk customer alert acknowledged" :: Text)]

            firstWrite <- recordFlowMemory memoryEnv mid defaultRememberOptions note
            assertRecordedId "the first write succeeds" mid firstWrite
            secondWrite <- recordFlowMemory memoryEnv mid defaultRememberOptions note
            assertRecordedId "a re-executed step window writes the same id" mid secondWrite
            rows <- acknowledgedMemoryCount appEnv
            assertEqual "one active row survives both writes" 1 rows

            drifted <- recordFlowMemory memoryEnv mid defaultRememberOptions (object ["summary" .= ("something else entirely" :: Text)])
            case drifted of
              Left (MemoryConflict detail) ->
                assertBool
                  ("the conflict should name the field that differs, got " <> show detail)
                  ("content" `Text.isInfixOf` detail)
              other -> assertFailure ("a changed payload under a known id must conflict, got " <> show other),
      -- The other half of the defect, and the one a row count cannot see: a flow
      -- that branches on what it recalled must take the same branch on replay.
      -- Journaling `recall` is what makes that true, and the only way to observe
      -- it is to change the store between a run and its replay. This flow puts
      -- no `step` between the recall and its result on purpose -- the at-risk
      -- flow's own `classify` step would mask the difference by answering from
      -- the journal whether or not the recall did.
      testCase "a replayed recall answers from the journal, not from the changed store" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            session <- genSessionId
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                memoryEnv = MemoryEnv {appEnv, agent = flowAgentDecl "at-risk-customer", identity = CompatibilityAgent (fixtureAgentName "at-risk-customer"), aliasPool = Nothing, sessionId = Nothing}
                replayedId = WorkflowId "flow-recall-replay"
                freshId = WorkflowId "flow-recall-fresh"
                runCount workflowId = runFlowBody appEnv (spikeRuntime session) "at-risk-customer" recallCountFlow workflowId (object [])

            before <- runCount replayedId
            assertEqual "the first run recalls nothing" (Right (Completed (toJSON (0 :: Int)))) before

            let decoyId = deterministicFlowMemoryId (WorkflowName "decoy") (WorkflowId "decoy") 0 (declarationCoordinate "decoy")
            written <- recordFlowMemory memoryEnv decoyId defaultRememberOptions (object ["summary" .= ("ticket_1 was escalated before" :: Text)])
            assertRecordedId "the decoy memory is written" decoyId written

            after <- runCount replayedId
            assertEqual "the replay answers from the journal" (Right (Completed (toJSON (0 :: Int)))) after

            -- Without this the assertion above would pass just as well against a
            -- store that never actually changed.
            freshRun <- runCount freshId
            assertEqual "a run with no journal does see the new memory" (Right (Completed (toJSON (1 :: Int)))) freshRun,
      -- What a flow can say about its own memories now that the metadata is not
      -- hardcoded. This flow runs under WorkflowName "shikigami.flow.spike",
      -- which no specification member declares, so its labels need no
      -- declaration in domain/shikigami/agent-run.keiro.
      testCase "rememberWith records chosen metadata while remember keeps the old defaults" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            session <- genSessionId
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
            outcome <- runFlowBody appEnv (spikeRuntime session) "at-risk-customer" supersessionFlow (WorkflowId "flow-supersession-spike") (object [])
            (firstId, secondId) <- case outcome of
              Right (Completed (Object o)) -> case (KeyMap.lookup "first" o, KeyMap.lookup "second" o) of
                (Just (String a), Just (String b)) -> pure (a, b)
                _ -> assertFailure ("flow should return both memory ids, got " <> show o)
              other -> assertFailure ("supersession flow should complete, got " <> show other)

            rows <- scopeRows appEnv
            -- Destructured rather than read through selectors because
            -- MemoryRow, MemoryRecord and RememberOptions all have fields by
            -- these names; naming the constructor is what disambiguates them.
            MemoryRow
              { priority = defaultedPriority,
                confidence = defaultedConfidence,
                memoryType = defaultedType,
                supersedes = defaultedLineage,
                tags = defaultedTags,
                status = defaultedStatus
              } <-
              requireRow "the plain remember" firstId rows
            MemoryRow
              { priority = chosenPriority,
                confidence = chosenConfidence,
                memoryType = chosenType,
                supersedes = chosenLineage,
                tags = chosenTags,
                status = chosenStatus
              } <-
              requireRow "the rememberWith" secondId rows

            -- A pre-existing flow memory must still record exactly what it did
            -- before RememberOptions existed.
            assertEqual "default priority is unchanged" 100 defaultedPriority
            assertEqual "default confidence is unchanged" (confidenceToText MediumConfidence) defaultedConfidence
            assertEqual "default type is unchanged" (memoryTypeToText MemoryPattern) defaultedType
            assertEqual "a default remember claims no lineage" Nothing defaultedLineage
            assertBool "the flow tag is still written" (Set.member "flow" defaultedTags)

            assertEqual "chosen priority lands" 10 chosenPriority
            assertEqual "chosen confidence lands" (confidenceToText HighConfidence) chosenConfidence
            assertEqual "chosen type lands" (memoryTypeToText MemoryConstraint) chosenType
            assertEqual "the lineage pointer names the first memory" (Just firstId) chosenLineage
            assertBool
              "extraTags union rather than replace, so a flow cannot un-tag itself out of its own queries"
              (Set.isSubsetOf (Set.fromList ["flow", "revision"]) chosenTags)

            -- kioku separates lineage from retirement: `supersedes` on a record
            -- says "this descends from that", and retiring the older row is a
            -- distinct command this capability does not issue. Kioku's own L1
            -- distillation does both explicitly. So both rows are still active,
            -- and this pins that rather than the other way round.
            assertEqual "recording lineage does not retire the older memory" "active" defaultedStatus
            assertEqual "the superseding memory is active too" "active" chosenStatus,
      testCase "acknowledgement wrapper maps approval decisions" do
        assertEqual "approved maps to acknowledged" (Acknowledged (toJSON True)) (ackFromDecision (Approval.Approved (toJSON True)))
        assertEqual "rejected maps to declined" (Declined "no") (ackFromDecision (Approval.Rejected "no"))
        assertEqual "timeout maps to timeout" TimedOut (ackFromDecision Approval.TimedOut)
    ]

completedFlow :: FlowDef
completedFlow =
  FlowDef
    { name = declarationCoordinate "completed-spike",
      decisionSlots = [],
      requiresDefaultModel = DefaultModelRequired,
      lifecycle = atRiskCustomerLifecycleDiagram,
      run = twoStepFlow
    }

activityFlow :: FlowDef
activityFlow =
  FlowDef
    { name = declarationCoordinate "activity-spike",
      decisionSlots = [],
      requiresDefaultModel = DefaultModelRequired,
      lifecycle = atRiskCustomerLifecycleDiagram,
      run = \_payload -> do
        activity <- currentActivity
        pure (String (activityCoordinateText ((.activityId) activity)))
    }

memoryFlow :: FlowDef
memoryFlow =
  FlowDef
    { name = declarationCoordinate "memory-spike",
      decisionSlots = [],
      requiresDefaultModel = DefaultModelRequired,
      lifecycle = atRiskCustomerLifecycleDiagram,
      run = \_payload -> do
        _ <- remember (declarationCoordinate "note") (object ["summary" .= ("flow durable note" :: Text)])
        memories <- recall (declarationCoordinate "note-back") (MemoryQuery "flow durable note")
        pure (Bool (any (\MemoryRecord {content} -> content == "flow durable note") memories))
    }

-- | How many memories the recall returned, and nothing else.
--
-- Deliberately has no 'step' after the recall: its result /is/ the recall's
-- result, so a replay that re-queried the store instead of reading the journal
-- would return a different number.
recallCountFlow :: FlowDef
recallCountFlow =
  FlowDef
    { name = declarationCoordinate "recall-count-spike",
      decisionSlots = [],
      requiresDefaultModel = DefaultModelRequired,
      lifecycle = atRiskCustomerLifecycleDiagram,
      run = \_payload -> toJSON . length <$> recall (declarationCoordinate "history") (MemoryQuery "prior escalation")
    }

-- | Two memories, the second declaring the first as its lineage.
--
-- The non-obvious part is why threading @first@ into the second call is safe.
-- @first@ is a journaled step result, not a fresh value: a replay hands the
-- flow the same 'MemoryId' the original run recorded, so the supersession
-- target is replay-stable and the deterministic id of the superseding row does
-- not move between a run and its replay. Building the second write out of
-- anything /not/ journaled would break exactly that.
supersessionFlow :: FlowDef
supersessionFlow =
  FlowDef
    { name = declarationCoordinate "supersession-spike",
      decisionSlots = [],
      requiresDefaultModel = DefaultModelRequired,
      lifecycle = atRiskCustomerLifecycleDiagram,
      run = \_payload -> do
        first <- remember (declarationCoordinate "first") (object ["summary" .= ("original note" :: Text)])
        second <- rememberWith (declarationCoordinate "constraint") (revisionOptions first) (object ["summary" .= ("revised note" :: Text)])
        pure (object ["first" .= idText first, "second" .= idText second])
    }

revisionOptions :: MemoryId -> RememberOptions
revisionOptions first =
  defaultRememberOptions
    { priority = MemoryPriority 10,
      confidence = HighConfidence,
      memoryType = MemoryConstraint,
      supersedes = Just first,
      extraTags = Set.singleton "revision"
    }

sinkFlow :: FlowDef
sinkFlow =
  FlowDef
    { name = declarationCoordinate "sink-spike",
      decisionSlots = [],
      requiresDefaultModel = DefaultModelRequired,
      lifecycle = atRiskCustomerLifecycleDiagram,
      run = \_payload -> toJSON <$> emitSignal (declarationCoordinate "alert") sampleKizashiSink (object ["summary" .= ("flow alert" :: Text)])
    }

twoStepFlow :: (FlowEffects es) => Value -> Eff es Value
twoStepFlow _payload = do
  _ <- step (StepName "a") (pure (String "a"))
  step (StepName "b") (pure (toJSON (2 :: Int)))

-- | Proof that a flow body can suspend and resume through keiro.
--
-- It carries its own constraint rather than 'FlowEffects' because 'sleepNamed'
-- needs 'Store' and 'IOE', which are exactly what 'FlowEffects' stopped granting
-- a flow body. This is a harness-level spike and is never registered, so it is
-- allowed the wider row; a registered flow would have to reach suspension
-- through a capability instead.
sleepFlow :: (Workflow :> es, Store :> es, IOE :> es) => Value -> Eff es Value
sleepFlow _payload = do
  _ <- step (StepName "before-wait") (pure (String "before-wait"))
  sleepNamed (StepName "wait") 300
  pure (String "after-wait")

runFlowWorkflow ::
  DatabaseFixture ->
  FlowDef ->
  WorkflowId ->
  IO (Either StoreError (WorkflowOutcome Value))
runFlowWorkflow databaseFixture flow workflowId =
  fst <$> (runFlowWorkflowWithAgent databaseFixture) "at-risk-customer" flow workflowId

runFlowWorkflowWithAgent ::
  DatabaseFixture ->
  Text ->
  FlowDef ->
  WorkflowId ->
  IO (Either StoreError (WorkflowOutcome Value), Either StoreError Int)
runFlowWorkflowWithAgent databaseFixture flowAgent flow workflowId =
  (withShikigamiFreshDatabase databaseFixture) \connStr ->
    withStore (defaultConnectionSettings connStr) \kirokuStore -> do
      tracer <- noopTracer
      session <- genSessionId
      let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
      outcome <- runFlowBody appEnv (spikeRuntime session) flowAgent flow workflowId (object [])
      count <- outboxCount appEnv
      pure (outcome, count)

-- | An acknowledgement environment for a flow that never parks.
--
-- 'runAcknowledgement' needs one even when the body under it never calls
-- 'Shikigami.Flow.Acknowledgement.awaitAck', because the interpreter is applied
-- to the whole row rather than to the calls inside it.
spikeRuntime :: SessionId -> FlowRuntime
spikeRuntime session =
  FlowRuntime
    { approval = Approval.defaultApprovalEnv session,
      acknowledgementDeadline = (either (error . show) id (parseDuration (secondsToNominalDiffTime 1)))
    }

-- | The sleeping spike's runner. It bypasses the capability interpreters
-- entirely: 'sleepFlow' is not a 'FlowDef' because it needs 'Store' and 'IOE',
-- which a flow body no longer gets.
runSleepSpike :: DatabaseFixture -> WorkflowId -> IO (Either StoreError (WorkflowOutcome Value))
runSleepSpike databaseFixture workflowId =
  (withShikigamiFreshDatabase databaseFixture) \connStr ->
    withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
      tracer <- noopTracer
      let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
      runEff
        . runErrorNoCallStack
        . withKirokuStore (defaultConnectionSettings connStr)
        . runStoreResource
        $ runWorkflowWith
          (shikigamiWorkflowRunOptions appEnv)
          (WorkflowName "shikigami.flow.spike")
          workflowId
          (sleepFlow (object []))

runFlowInAppEnv ::
  AppEnv ->
  FlowRuntime ->
  Text ->
  FlowDef ->
  WorkflowId ->
  Value ->
  IO (Either StoreError (WorkflowOutcome Value))
runFlowInAppEnv = runFlowBody

runFlowBody ::
  AppEnv ->
  FlowRuntime ->
  Text ->
  FlowDef ->
  WorkflowId ->
  Value ->
  IO (Either StoreError (WorkflowOutcome Value))
runFlowBody appEnv runtime flowAgent FlowDef {run} workflowId input =
  newBehaviorEnv >>= \behaviorEnv ->
    runEff
      . runTracingNoop
      . runErrorNoCallStack
      . withKirokuStore (appEnv.connectionSettings)
      . runStoreResource
      $ runWorkflowWith
        (shikigamiWorkflowRunOptions appEnv)
        (WorkflowName "shikigami.flow.spike")
        workflowId
        ( runActivity sampleActivity
            . runMemory memoryEnv
            . runSink sinkEnv
            . FlowDecision.runDecisionDisabled
            . FlowDelegate.runDelegate delegateEnv
            . FlowObjectives.runObjectives Nothing (Right Nothing)
            . FlowWorkers.runWorkers Nothing denyAllActionAuthorizer (CoordinatorRun (WorkflowId "disabled-flow-fixture") (compatibilityIdentity (fixtureAgentName flowAgent)) runtime.approval.currentSession Nothing Nothing) (Right Nothing)
            . Routing.runRouting
              Routing.RoutingEnv
                { Routing.agent = flowDecl,
                  Routing.sessionId = nominalSessionFixture,
                  Routing.behaviorEnv = behaviorEnv,
                  Routing.runtime =
                    Routing.routingRuntime
                      (AgentLoadReport [AgentLoaded "flow-test.dhall" flowDecl])
                      disabledDirectoryHandle
                }
            . runAcknowledgement ((.approval) runtime) ((.acknowledgementDeadline) runtime)
            . PracticeReview.runExecutionContext practiceReviewExecutionContext
            . PracticeReview.runPracticeReviewEvidence False PracticeReview.unavailablePracticeReviewRuntime
            . PracticeReview.runPracticeReviewEvaluator False behaviorEnv PracticeReview.unavailablePracticeReviewRuntime
            . PracticeReviewMemory.runPracticeReviewMemoryUnjournaled practiceReviewMemoryEnv
            . PracticeReview.runPracticeReviewAttention False PracticeReview.unavailablePracticeReviewRuntime
            $ run input
        )
  where
    flowDecl = flowAgentDecl flowAgent
    memoryEnv = MemoryEnv {appEnv, agent = flowDecl, identity = CompatibilityAgent (fixtureAgentName flowAgent), aliasPool = Nothing, sessionId = Nothing}
    practiceReviewExecutionContext =
      PracticeReview.PracticeReviewExecutionContext
        { PracticeReview.identity = compatibilityIdentity (fixtureAgentName flowAgent),
          PracticeReview.parentWorkflowId = Nothing,
          PracticeReview.parentSessionId = Nothing,
          PracticeReview.childWorkflowId = WorkflowId "flow-test-workflow",
          PracticeReview.childSessionId = nominalSessionFixture
        }
    practiceReviewMemoryEnv =
      PracticeReviewMemory.PracticeReviewMemoryEnv
        { PracticeReviewMemory.appEnv = appEnv,
          PracticeReviewMemory.agent = flowDecl,
          PracticeReviewMemory.identity = CompatibilityAgent (fixtureAgentName flowAgent),
          PracticeReviewMemory.sessionId = Nothing
        }
    delegateEnv =
      FlowDelegate.DelegateEnv
        { FlowDelegate.agent = flowDecl,
          FlowDelegate.context =
            DelegateCtx
              { identity = compatibilityIdentity (fixtureAgentName flowAgent),
                depth = fixtureDelegationDepth 0,
                sessionId = Just ((.currentSession) ((.approval) runtime)),
                parentSessionId = Nothing,
                parentRunWorkflowId = Nothing,
                lineage = map fixtureAgentName [flowAgent],
                executionPermissions = Nothing,
                executionRootId = Nothing,
                delegationBudgetId = Nothing,
                budgetLimit = defaultDelegationBudget
              },
          FlowDelegate.agents = [flowDecl, flowAgentDecl "web-researcher"],
          FlowDelegate.directory = disabledDirectoryHandle
        }
    sinkEnv =
      SinkEnv
        { agent = fixtureAgentName flowAgent,
          runId = nominalSessionFixture,
          occurredAt = Just flowOccurredAt,
          danwaTarget = Nothing,
          -- The same activity the flow's own capability sees, so a signal
          -- emitted from inside it resolves recipientFrom the way production does.
          activity = Just sampleActivity,
          grants = StaticGrants defaultGrantTable,
          directory = disabledDirectoryHandle,
          identity = compatibilityIdentity (fixtureAgentName flowAgent)
        }

-- | The runtime is handed to the test rather than consumed by 'lookupFlow',
-- because 'lookupFlow' no longer takes one: it configures
-- 'runAcknowledgement' inside 'runFlowBody' instead.
withAtRiskFlow :: DatabaseFixture -> (AppEnv -> FlowRuntime -> IORef (Maybe AwakeableId) -> FlowDef -> IO ()) -> IO ()
withAtRiskFlow databaseFixture action =
  (withShikigamiFreshDatabase databaseFixture) \connStr ->
    withStore (defaultConnectionSettings connStr) \kirokuStore -> do
      tracer <- noopTracer
      session <- genSessionId
      aidRef <- newIORef Nothing
      let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
          runtime =
            FlowRuntime
              { approval = approvalEnv aidRef session,
                acknowledgementDeadline = (either (error . show) id (parseDuration (secondsToNominalDiffTime 1)))
              }
      case lookupFlow (declarationCoordinate ("at-risk-customer")) of
        Just flow -> action appEnv runtime aidRef flow
        Nothing -> assertFailure "at-risk-customer flow should be registered"

approvalEnv :: IORef (Maybe AwakeableId) -> SessionId -> Approval.ApprovalEnv
approvalEnv aidRef currentSession =
  Approval.ApprovalEnv
    { currentSession,
      requiresApproval = \_ _ _ -> pure Approval.ApprovalNotRequired,
      recordPark = \_ aid _ -> writeIORef aidRef (Just aid),
      postAsk = \_ _ _ -> pure ()
    }

readCapturedAwakeable :: IORef (Maybe AwakeableId) -> IO AwakeableId
readCapturedAwakeable aidRef =
  readIORef aidRef >>= \case
    Just aid -> pure aid
    Nothing -> assertFailure "expected acknowledgement awakeable to be captured"

fireDueApprovalTimer :: AppEnv -> IO ()
fireDueApprovalTimer appEnv = do
  now <- getCurrentTime
  fired <- runAppIO appEnv (runWorkflowTimerWorker Nothing (addUTCTime 2 now) Approval.approvalTimeoutFireAction)
  assertBool "approval timeout timer should fire" (either (const False) (maybe False (const True)) fired)

-- | How many active memories carry the at-risk flow's acknowledged note.
--
-- Counted by scope rather than by session because this harness builds its
-- 'MemoryEnv' with @sessionId = Nothing@ (see 'runFlowBody'), so there is no
-- session to count under. The content compared against is what
-- @Shikigami.Flow.AtRiskCustomer@'s acknowledged note puts in its @summary@
-- field, which @Shikigami.Agent.Run.renderLearning@ stores verbatim.
acknowledgedMemoryCount :: AppEnv -> IO Int
acknowledgedMemoryCount appEnv =
  runAppIO appEnv (Memory.getActiveRowsByScope shikigamiMemorySpace (agentScope (CompatibilityAgent (fixtureAgentName "at-risk-customer")))) >>= \case
    Right (Right rows) -> pure (length (filter isAcknowledgedNote rows))
    Right (Left err) -> assertFailure ("memory rows should be readable, got " <> show err)
    Left _ -> assertFailure "memory rows should be readable, got a store error"

-- | Every step name the harness's flow workflow journaled for one instance,
-- minus the markers keiro writes on its own behalf (all of which are @__@-
-- prefixed). Mirrors @loadLifecycleStepKeys@ in "Shikigami.AgentWorkflowSpec".
flowStepKeys :: AppEnv -> WorkflowId -> IO (Set Text)
flowStepKeys appEnv workflowId =
  runAppIO appEnv (loadStepIndex (WorkflowName "shikigami.flow.spike") workflowId 0) >>= \case
    Right journal -> pure (Set.filter (not . Text.isPrefixOf "__") (Map.keysSet journal))
    Left err -> assertFailure ("the step index should be readable, got " <> show err)

-- | 'MemoryWriteError' has no 'Eq' instance, so a successful write is asserted
-- by pattern rather than by comparing the whole 'Either'.
assertRecordedId :: String -> MemoryId -> Either MemoryWriteError MemoryId -> IO ()
assertRecordedId label expected = \case
  Right actual -> assertEqual label expected actual
  Left err -> assertFailure (label <> ", got " <> show err)

-- | Every active memory in the test agent's scope.
scopeRows :: AppEnv -> IO [MemoryRow]
scopeRows appEnv =
  runAppIO appEnv (Memory.getActiveRowsByScope shikigamiMemorySpace (agentScope (CompatibilityAgent (fixtureAgentName "at-risk-customer")))) >>= \case
    Right (Right rows) -> pure rows
    Right (Left err) -> assertFailure ("memory rows should be readable, got " <> show err)
    Left _ -> assertFailure "memory rows should be readable, got a store error"

requireRow :: String -> Text -> [MemoryRow] -> IO MemoryRow
requireRow label wanted rows =
  case [row | row@MemoryRow {memoryId} <- rows, memoryId == wanted] of
    [row] -> pure row
    other -> assertFailure (label <> " should be exactly one active row " <> show wanted <> ", got " <> show (length other))

isAcknowledgedNote :: MemoryRow -> Bool
isAcknowledgedNote MemoryRow {content} = content == "at-risk customer alert acknowledged"

outboxCount :: AppEnv -> IO (Either StoreError Int)
outboxCount appEnv =
  fmap length <$> runAppIO appEnv (listOutbox "shinzui/shikigami")

sampleActivity :: ActivityEnvelope
sampleActivity =
  ActivityEnvelope
    { activityId = activityCoordinate ("act_flow_test"),
      occurredAt = activityCoordinate ("2026-06-27T00:00:00Z"),
      source = activityCoordinate ("shinzui/shikigami"),
      actor = Actor {kind = either (error . show) id (parseActorKind ("service")), id = activityCoordinate ("flow-test"), session = fmap activityCoordinate (Nothing)},
      subject = Subject {kind = activityCoordinate ("ticket"), subjectId = activityCoordinate ("ticket_1")},
      verb = activityCoordinate ("customer.risk_detected"),
      payload = object [],
      contextRefs = [],
      idempotencyKey = activityCoordinate ("act_flow_test")
    }

sampleKizashiSink :: Sink
sampleKizashiSink =
  KizashiSignal
    { source = activityCoordinate ("shinzui/shikigami"),
      signalType = Reminder,
      priority = Normal,
      importance = either (error . show) id (parseSignalImportance (50)),
      recipientFrom = SubjectOwner,
      defaultRecipient = fmap declarationCoordinate (Just "recipient_x"),
      intentTemplate = "triage this",
      extraContextTags = ["verb:customer.risk_detected"]
    }

-- | An agent declaration that differs from 'flowAgentDecl' only in its behavior,
-- so a behavior-validation assertion is about the behavior and nothing else.
flowBehaviorAgent :: Behavior -> AgentDecl
flowBehaviorAgent behavior = (flowAgentDecl "declaration-test") {behavior}

flowAgentDecl :: Text -> AgentDecl
flowAgentDecl flowAgent =
  AgentDecl
    { name = fixtureAgentName flowAgent,
      description = "flow capability test agent",
      trigger = Event {eventType = declarationCoordinate ("customer.risk_detected")},
      behavior =
        Deterministic
          { rule = "flow-test",
            params = mempty
          },
      sinks = [],
      delegates = map fixtureAgentName [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = agentEnablement (True),
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

flowOccurredAt :: UTCTime
flowOccurredAt = UTCTime (fromGregorian 2026 6 27) 0

highRiskPayload :: Value
highRiskPayload =
  object
    [ "text" .= ("Customer says they will cancel after repeated outages." :: Text),
      "enrichment"
        .= object
          [ "sentiment" .= ("negative" :: Text),
            "risks" .= ["churn risk" :: Text]
          ]
    ]

expectedVerdict :: Value
expectedVerdict =
  object
    [ "level" .= ("high" :: Text),
      "rationale" .= ("customer relationship at risk" :: Text),
      "ticketId" .= ("ticket_1" :: Text)
    ]

acknowledgedOutput :: Value
acknowledgedOutput =
  object
    [ "status" .= ("acknowledged" :: Text),
      "verdict" .= expectedVerdict,
      "acknowledgement" .= object ["by" .= ("relationship-owner" :: Text)]
    ]

escalatedOutput :: Value
escalatedOutput =
  object
    [ "status" .= ("escalated" :: Text),
      "verdict" .= expectedVerdict
    ]

nominalSessionFixture :: NominalId.SessionId
nominalSessionFixture = either (error . show) id (NominalId.parseId "kioku_session_01kvxa7d2cezhs874g3n8dfgme")

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureDelegationDepth :: Int -> DelegationDepth
fixtureDelegationDepth = either (error . show) id . parseDelegationDepth . toInteger

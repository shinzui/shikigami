module Shikigami.AgentWorkflowSpec (tests) where

import Baikai.Trace (TraceEvent (CallStarted), TraceSink (..))
import Contravariant.Extras (contrazip5)
import Control.Exception (SomeException, throwIO, try)
import Control.Lens (view, (&), (.~))
import Control.Monad (forM_, void, when)
import Data.Aeson (Result (..), ToJSON, Value (..), eitherDecode, fromJSON, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (elemIndex, find)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian, getCurrentTime, secondsToNominalDiffTime)
import Data.UUID qualified as UUID
import Effectful (Eff, liftIO, runEff)
import Effectful.Dispatch.Static (unsafeEff_)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as HasqlSession
import Hasql.Statement (Statement, preparable)
import Keiro.Integration.Event (decodeJsonIntegrationEvent)
import Keiro.Outbox (OutboxRow (..), defaultPublishOptions, listOutbox, publishClaimedOutbox)
import Keiro.Outbox qualified as Outbox
import Keiro.PGMQ qualified as Job
import Keiro.Timer qualified as Timer
import Keiro.Workflow (PatchId (..), StepName (..), Workflow, WorkflowId (..), WorkflowInstanceRow (..), WorkflowName (..), WorkflowOutcome (..), WorkflowRunOptions (..), completedStepName, defaultWorkflowRunOptions, loadStepIndex, patchSetStepName, runWorkflow, runWorkflowWith)
import Keiro.Workflow.Awakeable (AwakeableId (..), signalAwakeable)
import Keiro.Workflow.Awakeable.Schema (countPendingAwakeables)
import Keiro.Workflow.Child (runChildWorkflow)
import Keiro.Workflow.Child.Schema (ChildRow (..), ChildStatus (..), lookupChildrenOfParent)
import Keiro.Workflow.Gc qualified as Gc
import Keiro.Workflow.Instance (lookupInstance)
import Keiro.Workflow.Resume (ResumeSummary (..), defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Keiro.Workflow.Sleep (runWorkflowTimerWorker)
import Keiro.Workflow.Types (continueSeedStepName)
import Kioku.Api.Types (Confidence (MediumConfidence), MemoryRecord (..), MemoryType (MemoryPattern))
import Kioku.Id (SessionId, genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Memory.ReadModel (MemoryRow (..))
import Kioku.Session (SessionRow (..))
import Kioku.Session qualified as Session
import Kioku.Session.Domain (StartSessionData (..))
import Kioku.Session.ReadModel (TurnRow (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Error (StoreError)
import Network.HTTP.Types (hContentType, status200, status204, status400, status404)
import Network.Wai (Application, pathInfo, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Approval (ApprovalChannel (..), ApprovalDecision (..), ApprovalEnv (..), ApprovalPolicySnapshot (..), ApprovalRequest (..), ApprovalRequirement (..), approvalTimeoutFireAction, autoApprovePolicy, defaultApprovalEnv, resolveApproval)
import Shikigami.Agent.Approval.Notification qualified as ApprovalNotification
import Shikigami.Agent.Approval.Workflow qualified as ApprovalWorkflow
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Conversation.SessionIndex qualified as SessionIndex
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), IdentityDecl (..), ProfileRequirement (..), RecordPolicy (..), Sink (..), Trigger (..), defaultDelegationBudget, defaultMemoryPolicy, mkDelegationBudget, mkRecallLimit)
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Delegate (awaitAllDelegated, awaitDelegated, cancelSiblingsOnFailure, delegate, delegatedWorkflowIdV2)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..), DelegationError (..))
import Shikigami.Agent.Delegate.Depth (DelegationDepth, parseDelegationDepth)
import Shikigami.Agent.Loader (AgentLoadEntry (AgentLoaded), AgentLoadReport (..), loadAgent)
import Shikigami.Agent.Name (AgentName, agentNameText, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (VerifiedIdentity), ResolvedAgentIdentity (CompatibilityAgent, VerifiedAgent), compatibilityIdentity, mkAgentPrincipal)
import Shikigami.Agent.Run (AgentRunResult (..), recallAgentLearnings, recallPriorLearnings)
import Shikigami.Agent.Run.Key (RunKey, parseRunKey, runKeyText)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (..), TriggerKind (..), runJobWorkflowId)
import Shikigami.Agent.Workflow (AgentRunDeps (..), AgentRunFailure (..), AgentRunHooks (..), SinkIntent (..), agentRunFailureDetail, agentRunRegistry, agentRunWorkflow, agentRunWorkflowName, defaultAgentRunHooks, executionRuntime, publishSinkIntent, runAgentRunWorkflow)
import Shikigami.AgentRun.Status qualified as RunStatus
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.Attestation.Envelope (profileDigest)
import Shikigami.Attestation.PolicyValue qualified as PV
import Shikigami.Attestation.Profile
  ( AllowedCall (..),
    EvidenceStrength (EvidenceModelObserved),
    Issuer (..),
    ProfileDigest,
    ProfileId (..),
    ProfileLifecycle (Active),
    ProfileVersion (..),
    Prohibitions (..),
    SanctionedExecutionProfile (..),
    SanctionedExecutionProfileRef (..),
    ThinkingLevel (ThinkingHigh),
    defaultProhibitions,
    noSignerRequirements,
    profileDigestText,
    unlimitedProfileLimits,
  )
import Shikigami.Attestation.Resolve (ProfileResolutionError (..), ResolvedProfile, parseResolvedProfile, postgresProfileStore, resolveProfile)
import Shikigami.Behavior.Error (TransientBehaviorFailure (..))
import Shikigami.Behavior.Provider.Coordinate qualified as Coordinate
import Shikigami.Behavior.Run (BehaviorEnv, newBehaviorEnv, newBehaviorEnvWithTraceSink)
import Shikigami.Capability.Catalog qualified as CapabilityCatalog
import Shikigami.Capability.Overlay qualified as CapabilityOverlay
import Shikigami.Capability.Provider qualified as CapabilityProvider
import Shikigami.Directory (PrincipalRecord (..), disabledDirectoryHandle, newDirectoryHandle, refreshDirectory, staticDirectorySource)
import Shikigami.Directory qualified as Directory
import Shikigami.Duration (parseDuration)
import Shikigami.Execution.Admission (enrollRootRun)
import Shikigami.Execution.Driver (ExecutionDriverResult (..))
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Execution.Policy.Types qualified as Harness
import Shikigami.Execution.Quantity (ResourceAmount, parseResourceAmount)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Resources
import Shikigami.Execution.SelectionRuntime (assignmentIdFor)
import Shikigami.Execution.Transcript qualified as Replay
import Shikigami.ExecutionSelectionWorkflowSpec qualified as ExecutionFixture
import Shikigami.Fixture.ExecutionIdentity (fixtureRootId)
import Shikigami.Fixture.KawaStub (kawaDoorwayApplication)
import Shikigami.Fixture.SinkHttp (testSinkHttp, testSinkHttpFor)
import Shikigami.Flow.Decision qualified as FlowDecision
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Integration.Danwa (AddressedMessage (..), addressedMessageEventType)
import Shikigami.Log qualified as Log
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace)
import Shikigami.Memory.AliasStore qualified as AliasStore
import Shikigami.Memory.Scope (agentScope, legacyAgentScope)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.PracticeReview.Capability qualified as PracticeReviewCapability
import Shikigami.RunEvidence.Catalog qualified as ExecutionCatalog
import Shikigami.RunEvidenceSpec (completeScenarioEvidence)
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Sink (GrantSource (DbGrants, StaticGrants), defaultGrantTable)
import Shikigami.Sink.Config (DanwaConfig (..), KanmonConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Sink.GrantStore (checkGrant, reconcileGrantPrincipal, revokeGrant, upsertGrant)
import Shikigami.Sink.Permission (SinkKind (..))
import Shikigami.Trigger.Enqueue qualified as Enqueue
import Shikigami.Trigger.Schedule (parseCron)
import Shikigami.Workflow.Registry qualified as Registry
import Shikigami.Workflow.Versioning (shikigamiWorkflowResumeOptions, shikigamiWorkflowRunOptions, terminalWorkflowRetention)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Tool (SomeTool (..), mkTool)
import Streamly.Data.Fold qualified as Fold
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "AgentWorkflow"
    [ testCase "compatibility names with colliding old punctuation retain separate stored sessions" do
        withShikigamiFreshDatabase databaseFixture \connStr -> do
          tracer <- noopTracer
          let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
          colon <- startDecoyConversationSession appEnv "a:b" "same-subject"
          dot <- startDecoyConversationSession appEnv "a.b" "same-subject"
          assertBool "allocated sessions are independent" (colon /= dot)
          runningSessionsFor appEnv "a:b" "same-subject" >>= assertEqual "colon scope restores its own row" [idText colon]
          runningSessionsFor appEnv "a.b" "same-subject" >>= assertEqual "dot scope restores its own row" [idText dot],
      testCase "the current baseline journals v2 and capability resolution without patch activation" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                deps = testDeps appEnv behaviorEnv defaultAgentRunHooks
                oldJob = retryVersioningJob "heartbeat:test-retry-old"
                freshJob = retryVersioningJob "heartbeat:test-retry-fresh"

            oldOutcome <-
              runAppIO appEnv $
                runWorkflowWith
                  defaultWorkflowRunOptions
                  agentRunWorkflowName
                  (runJobWorkflowId oldJob)
                  (agentRunWorkflow deps (Just oldJob))
            assertBool ("optionless current run completes: " <> show oldOutcome) (isCompleted oldOutcome)
            oldIndex <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (runJobWorkflowId oldJob) 0)
            assertEqual "current journal omits the retired behavior label" (Right False) (Map.member "run-behavior" <$> oldIndex)
            assertEqual "current journal writes v2" (Right True) (Map.member "run-behavior-v2" <$> oldIndex)
            assertEqual "current journal resolves capability overlays" (Right True) (Map.member "resolve-capability-overlays" <$> oldIndex)

            freshOutcome <- runAgentRunWorkflow deps freshJob
            assertBool ("fresh agent run completes: " <> show freshOutcome) (isCompleted freshOutcome)
            status <- RunStatus.deriveRunStatus kirokuStore freshJob.agentName (runJobWorkflowId freshJob)
            case status of
              Right (Just view) -> do
                assertEqual "real successful run lifecycle" RunStatus.Succeeded view.lifecycle
                assertBool "success exposes its session" (isJust view.sessionId)
                assertBool "success exposes its summary" (isJust view.summary)
                assertBool "success exposes completion time" (isJust view.completedAt)
                assertEqual "repeated status reads are stable" (Right (Just view)) =<< RunStatus.deriveRunStatus kirokuStore freshJob.agentName (runJobWorkflowId freshJob)
              other -> assertFailure ("successful status missing: " <> show other)
            freshIndex <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (runJobWorkflowId freshJob) 0)
            assertEqual "fresh journal writes the v2 behavior label" (Right True) (Map.member "run-behavior-v2" <$> freshIndex)
            assertEqual "fresh journal never writes the legacy label" (Right False) (Map.member "run-behavior" <$> freshIndex)
            assertEqual "fresh journal resolves even the empty overlay set" (Right True) (Map.member "resolve-capability-overlays" <$> freshIndex),
      testCase "a Skill overlay admission lease is released before driver and later lifecycle work" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            events <- newIORef ([] :: [Text])
            active <- newIORef False
            tracer <- noopTracer
            let traceSink =
                  TraceSink
                    ( Fold.drainMapM \case
                        CallStarted {} -> recordCapabilityEvent events "model"
                        _ -> pure ()
                    )
            behaviorEnv <- newBehaviorEnvWithTraceSink (Just traceSink)
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                declaration = capabilityDecl "overlay-lifecycle" (Skill {path = declarationCoordinate ("../agents/skills/triage-note")}) [workspaceReadId] (Just overlayIdentity) [KawaDigest {subjectType = activityCoordinate ("overlay"), verb = activityCoordinate ("overlay.read")}]
                hooks =
                  AgentRunHooks
                    { beforeStepBody = \stepName -> recordCapabilityEvent events ("before:" <> unStepName stepName),
                      afterStepBody = \stepName -> recordCapabilityEvent events ("after:" <> unStepName stepName)
                    }
                runtime =
                  capabilityRuntime
                    [workspaceReadV1]
                    [trackingCapabilityProvider events active "v1" workspaceReadV1 (Right ())]
                    allowCapability
                deps =
                  (testDepsWithAgents appEnv behaviorEnv hooks [declaration])
                    { capabilities = runtime
                    }
                runJob = capabilityJob "overlay-lifecycle" "overlay-lifecycle:run"

            -- The fresh population freezes a menu lease, releases it, and
            -- reacquires only tools actually requested by an unfinished call.
            writeIORef events []
            registered <- runAppIO appEnv ExecutionCatalog.registerProjectionCatalog
            assertBool (show registered) (case registered of Right (Right _) -> True; _ -> False)
            Enqueue.ensureRunQueue _kirokuStore.pool >>= assertEqual "execution queue ready" (Right ())
            let newJob = runJob & #idempotencyKey .~ fixtureRunKey "overlay-lifecycle:durable"
                execution = Replay.executionIdFor (assignmentIdFor (runJobWorkflowId newJob).unWorkflowId)
            runAgentRunWorkflow deps newJob >>= assertEqual "new parent releases its advance" (Right Suspended)
            completed <- ExecutionFixture.driveExecutionChild appEnv (executionRuntime deps) execution 20
            assertEqual "durable overlay run succeeds" Replay.Succeeded completed.phase
            finished <- runAgentRunWorkflow deps newJob
            assertBool (show finished) (isCompleted finished)
            observedNew <- readIORef events
            assertCapabilityEventOrder observedNew ["after:recall", "acquire:v1", "release:v1", "after:admit-skill-execution", "model", "before:record", "before:complete"]
            assertEqual "a no-tool response needs only its admission lease" 1 (length (filter (== "acquire:v1") observedNew))
            assertEqual "the new run leaves no provider lease" False =<< readIORef active,
      testCase "capability resolution refusals are permanent before open-session" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            events <- newIORef ([] :: [Text])
            active <- newIORef False
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                unknownId = expectCapabilityRight (CapabilityOverlay.mkCapabilityId "workspace.unknown")
                mutation = capabilityDescriptor "workspace.write" "v1" CapabilityOverlay.IdempotentMutation
                provider = trackingCapabilityProvider events active "unused" workspaceReadV1 (Right ())
                allowedRuntime = capabilityRuntime [workspaceReadV1] [provider] allowCapability
                deniedRuntime =
                  capabilityRuntime
                    [workspaceReadV1]
                    [provider]
                    denyCapability
                mutationRuntime = capabilityRuntime [mutation] [] allowCapability
                cases =
                  [ ("unknown", capabilityDecl "overlay-unknown" (Skill {path = declarationCoordinate ("unused")}) [unknownId] (Just overlayIdentity) [], CapabilityProvider.emptyCapabilityRuntime),
                    ("duplicate", capabilityDecl "overlay-duplicate" (Skill {path = declarationCoordinate ("unused")}) [workspaceReadId, workspaceReadId] (Just overlayIdentity) [], allowedRuntime),
                    ("denied", capabilityDecl "overlay-denied" (Skill {path = declarationCoordinate ("unused")}) [workspaceReadId] (Just overlayIdentity) [], deniedRuntime),
                    ("missing-identity", capabilityDecl "overlay-no-identity" (Skill {path = declarationCoordinate ("unused")}) [workspaceReadId] Nothing [], allowedRuntime),
                    ("non-skill", capabilityDecl "overlay-non-skill" (ShikumiProgram {task = declarationCoordinate ("noop-summary"), preferEnrichment = False, grounding = Nothing, enabledBy = Nothing}) [workspaceReadId] (Just overlayIdentity) [], allowedRuntime),
                    ("mutation", capabilityDecl "overlay-mutation" (Skill {path = declarationCoordinate ("unused")}) [descriptorCapability mutation] (Just overlayIdentity) [], mutationRuntime)
                  ]
            forM_ cases \(label, declaration, runtime) -> do
              let runJob = capabilityJob (agentDeclNameForTest declaration) ("overlay-refusal:" <> label)
                  deps = (testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [declaration]) {capabilities = runtime}
              result <- runAgentRunWorkflow deps runJob
              case result of
                Right (Completed (Left (PermanentAgentRunFailure _))) -> pure ()
                other -> assertFailure (Text.unpack label <> " should be a permanent refusal, got " <> show other)
              stepIndex <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (runJobWorkflowId runJob) 0)
              assertEqual (Text.unpack label <> " journals the resolution refusal") (Right True) (Map.member "resolve-capability-overlays" <$> stepIndex)
              assertEqual (Text.unpack label <> " never opens a session") (Right False) (Map.member "open-session" <$> stepIndex)
            assertEqual "no permanent refusal reaches provider acquisition" [] =<< readIORef events,
      testCase "transient v2 failure leaves no value and a later advance succeeds" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            attempts <- newIORef (0 :: Int)
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                hooks =
                  ( defaultAgentRunHooks
                      & #beforeStepBody
                        .~ ( \stepName ->
                               when (unStepName stepName == "run-behavior-v2") do
                                 attempt <- atomicModifyIORef' attempts \count -> (count + 1, count)
                                 when (attempt == 0) (throwIO (TransientBehaviorFailure "simulated transient provider failure"))
                           )
                  )
                deps = testDeps appEnv behaviorEnv hooks

            firstAttempt <- try @SomeException (runAgentRunWorkflow deps transientRetryJob)
            case firstAttempt of
              Left _ -> pure ()
              Right outcome -> assertFailure ("first transient attempt should escape, got " <> show outcome)
            afterFailure <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (runJobWorkflowId transientRetryJob) 0)
            assertEqual "failed attempt appended no v2 value" (Right False) (Map.member "run-behavior-v2" <$> afterFailure)

            retried <- runAgentRunWorkflow deps transientRetryJob
            assertBool ("retry completes: " <> show retried) (isCompleted retried)
            assertEqual "the behavior body ran twice" 2 =<< readIORef attempts
            afterSuccess <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (runJobWorkflowId transientRetryJob) 0)
            assertEqual "successful retry appended the v2 value" (Right True) (Map.member "run-behavior-v2" <$> afterSuccess),
      testCase "permanent v2 failure is journaled once and replayed" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            attempts <- newIORef (0 :: Int)
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                hooks =
                  ( defaultAgentRunHooks
                      & #beforeStepBody
                        .~ ( \stepName ->
                               when (unStepName stepName == "run-behavior-v2") (modifyIORef' attempts (+ 1))
                           )
                  )
                deps = testDepsWithAgents appEnv behaviorEnv hooks [missingTaskDecl]

            firstAttempt <- runAgentRunWorkflow deps permanentFailureJob
            replayed <- runAgentRunWorkflow deps permanentFailureJob
            let isPermanent = \case
                  Right (Completed (Left (PermanentAgentRunFailure detail))) -> "unknown task" `Text.isInfixOf` detail
                  _ -> False
            assertBool ("first attempt is permanent: " <> show firstAttempt) (isPermanent firstAttempt)
            assertBool ("replay keeps the permanent value: " <> show replayed) (isPermanent replayed)
            assertEqual "permanent behavior body executes once" 1 =<< readIORef attempts
            status <- RunStatus.deriveRunStatus kirokuStore permanentFailureJob.agentName (runJobWorkflowId permanentFailureJob)
            case status of
              Right (Just view) -> do
                assertEqual "completed failure is not success" RunStatus.Failed view.lifecycle
                assertEqual "failure kind" (Just RunStatus.BehaviorFailed) ((.kind) <$> view.failure)
              other -> assertFailure ("permanent failure status missing: " <> show other),
      -- Before this, every kioku result on the agent-run path was discarded with
      -- @_ <-@ or @void@, so a run whose session kioku refused to open still
      -- reported Completed (Right ...) — a successful run with no durable record
      -- of itself. A root session with positive depth is kioku's own lineage rejection,
      -- so it exercises the refusal layer without breaking the store the journal
      -- also needs.
      testCase "a refused session open fails the run instead of completing it" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [decl]
                refusedJob =
                  (job & #idempotencyKey .~ (fixtureRunKey "heartbeat:test-refused-session") & #delegationDepth .~ (Just (fixtureDelegationDepth 1)))

            result <- runAgentRunWorkflow deps refusedJob
            case result of
              Right (Completed (Left (PermanentAgentRunFailure detail))) ->
                assertBool
                  ("the failure names the refused write: " <> Text.unpack detail)
                  ("opening the run's kioku session was refused" `Text.isInfixOf` detail)
              other -> assertFailure ("a refused session open must not complete successfully, got " <> show other)

            -- The refusal is journaled, so a replay answers the same way rather
            -- than opening a session on the second attempt.
            replayed <- runAgentRunWorkflow deps refusedJob
            case replayed of
              Right (Completed (Left (PermanentAgentRunFailure _))) -> pure ()
              other -> assertFailure ("replay must keep the refusal, got " <> show other),
      testCase "Never completes a successful session without recording memory" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                neverDecl = withRecordPolicy Never decl
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [neverDecl]
                neverJob = (job & #idempotencyKey .~ (fixtureRunKey "heartbeat:test-record-never"))

            result <- runAgentRunWorkflow deps neverJob
            sid <- case result of
              Right (Completed (Right AgentRunResult {sessionId, recordedMemId})) -> do
                assertEqual "the record step returns no memory id" Nothing recordedMemId
                pure sessionId
              other -> assertFailure ("Never run should complete, got " <> show other)

            memories <- runAppIO appEnv (Memory.getRowsBySession shikigamiMemorySpace sid)
            case memories of
              Right (Right rows) -> assertEqual "no memory row was written" 0 (length rows)
              other -> assertFailure ("memory lookup should succeed, got " <> show other)

            session <- runAppIO appEnv (Session.getById shikigamiMemorySpace sid)
            case session of
              Right (Right (Just SessionRow {status})) -> assertEqual "session still completes" "completed" status
              other -> assertFailure ("session lookup should return a completed row, got " <> show other),
      testCase "Always records a failure memory before failing the session" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                alwaysDecl = withRecordPolicy Always missingTaskDecl
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [alwaysDecl]

            result <- runAgentRunWorkflow deps permanentFailureJob
            case result of
              Right (Completed (Left _)) -> pure ()
              other -> assertFailure ("Always run should fail permanently, got " <> show other)

            memories <- runAppIO appEnv (Memory.getActiveRowsByScope shikigamiMemorySpace (agentScope (CompatibilityAgent (fixtureAgentName "missing-task-agent"))))
            case memories of
              Right (Right [MemoryRow {content, tags}]) -> do
                assertBool "failure content is explicit" ("run failed: " `Text.isPrefixOf` content)
                assertBool "failure tag is present" (Set.member "failure" tags)
              other -> assertFailure ("expected one failure memory, got " <> show other),
      testCase "recallLimit caps fallback recall" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
            forM_ [1 .. 5 :: Int] (recordRecallFixture appEnv)
            limit <- either (assertFailure . Text.unpack) pure (mkRecallLimit 3)
            recalled <- recallPriorLearnings appEnv limit (agentScope (CompatibilityAgent (fixtureAgentName "recall-limit-agent"))) "recall fixture"
            assertEqual "declared bound caps fallback rows" 3 (length recalled),
      testCase "verified recall composes the principal scope with an accepted legacy alias" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                principal = either (error . Text.unpack) id (mkAgentPrincipal "agent_renamed")
                aliasPool = pool kirokuStore
            recordLegacyRecallFixture appEnv "old-handle"
            _ <- AliasStore.reconcileAlias aliasPool principal "old-handle" >>= either (assertFailure . Text.unpack) pure
            limit <- either (assertFailure . Text.unpack) pure (mkRecallLimit 3)
            recalled <- recallAgentLearnings appEnv (Just aliasPool) limit (VerifiedAgent principal) "legacy alias fixture"
            assertEqual
              "legacy content remains reachable after rename"
              ["legacy alias fixture"]
              (map (\MemoryRecord {content = memoryContent} -> memoryContent) recalled),
      testCase "reopening storage after a presentation rename retains agent_heartbeat recall and grant" do
        (withShikigamiFreshDatabase databaseFixture) \connStr -> do
          tracer <- noopTracer
          let settings = defaultConnectionSettings connStr
              appEnv = AppEnv {connectionSettings = settings, tracer, metrics = Nothing, store = Nothing}
              principal = either (error . Text.unpack) id (mkAgentPrincipal "agent_heartbeat")
              verified = VerifiedIdentity principal
          withStore settings \firstStore -> do
            recordLegacyRecallFixture appEnv "old-heartbeat"
            _ <- AliasStore.reconcileAlias (pool firstStore) principal "old-heartbeat" >>= either (assertFailure . Text.unpack) pure
            _ <- reconcileGrantPrincipal (pool firstStore) "heartbeat" "agent_heartbeat" >>= either (assertFailure . Text.unpack) pure
            upsertGrant (pool firstStore) "heartbeat-renamed" verified SKawaDigest (Just "rename-demo")
              >>= either (assertFailure . Text.unpack) pure
          withStore settings \reopenedStore -> do
            limit <- either (assertFailure . Text.unpack) pure (mkRecallLimit 3)
            recalled <- recallAgentLearnings appEnv (Just (pool reopenedStore)) limit (VerifiedAgent principal) "legacy alias fixture"
            assertEqual
              "post-restart recall follows the alias to agent_heartbeat"
              ["legacy alias fixture"]
              (map (\MemoryRecord {content = memoryContent} -> memoryContent) recalled)
            checkGrant (DbGrants (pool reopenedStore)) verified SKawaDigest >>= \case
              Right () -> pure ()
              Left denial -> assertFailure ("post-restart principal grant was denied: " <> show denial),
      testCase "replays completed lifecycle steps for the same run id" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                deps = testDeps appEnv behaviorEnv defaultAgentRunHooks

            firstRun <- runAgentRunWorkflow deps job
            second <- runAgentRunWorkflow deps job
            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")

            case (firstRun, second) of
              (Right (Completed (Right AgentRunResult {sessionId = firstSessionId})), Right (Completed (Right AgentRunResult {sessionId = secondSessionId}))) -> do
                assertEqual "open-session replayed the original session id" firstSessionId secondSessionId
                assertEqual "dispatch-sinks enqueued one stable outbox row" (Right 1) (length <$> outboxRows)
              other -> assertEqual "both workflow runs complete successfully" "completed twice" (show other),
      -- The two-phase gate, and the reason both phases exist: the enqueue-time
      -- check decides whether an outbox row is written at all, and the
      -- publish-time check revalidates before delivery. A revocation landing
      -- between them must stop the delivery even though the row is already
      -- queued and its journaled SinkResult truthfully says Enqueued.
      testCase "a revocation between enqueue and publish delivers nothing" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            received <- newIORef (Map.empty :: Map (Text, Text) Text)
            testWithApplication (pure (kawaDoorwayApplication received)) \port -> do
              tracer <- noopTracer
              behaviorEnv <- newBehaviorEnv
              let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                  pool' = pool kirokuStore
                  deps =
                    (testDeps appEnv behaviorEnv defaultAgentRunHooks)
                      { grants = DbGrants pool',
                        kawa = KawaConfig {baseUrl = "http://localhost:" <> Text.pack (show port), sourceSegment = "shinzui/shikigami"}
                      }

              -- heartbeat/KawaDigest is seeded granted, so the run enqueues.
              runResult <- runAgentRunWorkflow deps job
              outboxBefore <- runAppIO appEnv (listOutbox "shinzui/shikigami")
              assertEqual "the granted run enqueued one outbox row" (Right 1) (length <$> outboxBefore)

              -- Now revoke, and drive the publisher exactly as the worker does.
              _ <- revokeGrant pool' (compatibilityIdentity (fixtureAgentName "heartbeat")) SKawaDigest (Just "test") >>= either (assertFailure . show) pure
              let publishBatch rows =
                    traverse (\row -> (outboxId row,) <$> publishSinkIntent deps row) rows
              published <- runAppIO appEnv (publishClaimedOutbox publishBatch defaultPublishOptions Nothing)

              delivered <- readIORef received
              assertEqual "the kawa stub received nothing" 0 (Map.size delivered)
              assertBool ("the publish pass itself succeeded: " <> show published) (isRight' published)
              assertBool ("the run completed: " <> show runResult) (isCompleted runResult),
      testCase "resumes after a crash without rerunning journaled step bodies" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            counts <- newIORef Map.empty
            shouldCrash <- newIORef True
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                hooks =
                  ( defaultAgentRunHooks
                      & #beforeStepBody
                        .~ ( \stepName -> do
                               modifyIORef' counts (Map.insertWith (+) (unStepName stepName) (1 :: Int))
                               when (unStepName stepName == "run-behavior-v2") do
                                 crashNow <- atomicModifyIORef' shouldCrash \current -> (False, current)
                                 when crashNow (ioError (userError "simulated crash in run-behavior"))
                           )
                  )
                deps = testDeps appEnv behaviorEnv hooks

            crashedRun <- try (runAgentRunWorkflow deps crashJob)
            case crashedRun of
              Left (_ :: SomeException) -> pure ()
              Right other -> assertEqual "first run should crash inside run-behavior" "exception" (show other)

            afterCrash <- readIORef counts
            assertEqual "journaled pre-behavior steps ran once before the crash" (Just 1) (Map.lookup "ingest-job" afterCrash)
            assertEqual "lookup-agent ran once before the crash" (Just 1) (Map.lookup "lookup-agent" afterCrash)
            assertEqual "resolve-profile ran once before the crash" (Just 1) (Map.lookup "resolve-profile" afterCrash)
            assertEqual "open-session ran once before the crash" (Just 1) (Map.lookup "open-session" afterCrash)
            assertEqual "recall ran once before the crash" (Just 1) (Map.lookup "recall" afterCrash)
            assertEqual "run-behavior-v2 was attempted once before the crash" (Just 1) (Map.lookup "run-behavior-v2" afterCrash)

            second <- runAgentRunWorkflow deps crashJob
            case second of
              Right (Completed (Right _result)) -> pure ()
              other -> assertEqual "second run should complete" "completed" (show other)

            finalCounts <- readIORef counts
            assertEqual "ingest-job replayed without rerunning" (Just 1) (Map.lookup "ingest-job" finalCounts)
            assertEqual "lookup-agent replayed without rerunning" (Just 1) (Map.lookup "lookup-agent" finalCounts)
            assertEqual "resolve-profile replayed without rerunning" (Just 1) (Map.lookup "resolve-profile" finalCounts)
            assertEqual "open-session replayed without rerunning" (Just 1) (Map.lookup "open-session" finalCounts)
            assertEqual "recall replayed without rerunning" (Just 1) (Map.lookup "recall" finalCounts)
            assertEqual "run-behavior-v2 reran after its failed attempt" (Just 2) (Map.lookup "run-behavior-v2" finalCounts)
            assertEqual "record ran once after recovery" (Just 1) (Map.lookup "record" finalCounts)
            assertEqual "complete ran once after recovery" (Just 1) (Map.lookup "complete" finalCounts)

            stepKeys <- loadLifecycleStepKeys appEnv crashJob
            assertEqual "one row per completed lifecycle step" (Right expectedLifecycleSteps) stepKeys
            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            assertEqual "recovered run enqueued one stable outbox row" (Right 1) (length <$> outboxRows),
      testCase "an unknown required profile refuses before opening a session" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [profiledDecl]

            result <- runAgentRunWorkflow deps profileRefusalJob
            case result of
              Right (Completed (Left err)) ->
                assertBool ("failure should name the profile: " <> show err) ("sanctioned-review" `Text.isInfixOf` agentRunFailureDetail err)
              other -> assertFailure ("expected a permanent profile refusal, got " <> show other)

            sessions <- runAppIO appEnv (Session.getByScope shikigamiMemorySpace (agentScope (CompatibilityAgent (fixtureAgentName "heartbeat"))))
            case sessions of
              Right (Right rows) -> assertEqual "no session was opened" 0 (length rows)
              other -> assertFailure ("session query should succeed, got " <> show (first (const ("store-error" :: String)) other))
            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            assertEqual "no sink intent was enqueued" (Right 0) (length <$> outboxRows),
      testCase "a resumed run keeps the profile content and digest it originally resolved" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            resolverCalls <- newIORef (0 :: Int)
            shouldCrash <- newIORef True
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                profileStore = postgresProfileStore (pool kirokuStore)
                originalContent = workflowProfile (ProfileVersion "1")
                originalDigest = profileDigest originalContent
                originalResolved = resolvedWorkflowProfile originalContent originalDigest
                resolver profileId version = do
                  modifyIORef' resolverCalls (+ 1)
                  now <- getCurrentTime
                  resolveProfile profileStore now profileId version
                hooks =
                  ( defaultAgentRunHooks
                      & #beforeStepBody
                        .~ ( \stepName ->
                               when (unStepName stepName == "run-behavior-v2") do
                                 crashNow <- atomicModifyIORef' shouldCrash \current -> (False, current)
                                 when crashNow (ioError (userError "simulated crash after resolve-profile"))
                           )
                  )
                deps =
                  (testDepsWithAgents appEnv behaviorEnv hooks [profiledDecl])
                    { resolveRunProfile = resolver
                    }

            insertWorkflowProfile (pool kirokuStore) originalContent originalDigest
            crashed <- try (runAgentRunWorkflow deps profilePinningJob)
            case crashed of
              Left (_ :: SomeException) -> pure ()
              Right other -> assertFailure ("first run should crash after profile resolution, got " <> show other)

            pinnedBefore <- loadProfileResolution appEnv profilePinningJob
            assertEqual "the original content and digest were journaled" (Right (Just originalResolved)) pinnedBefore

            let replacementContent = workflowProfile (ProfileVersion "2")
                replacementDigest = profileDigest replacementContent
            replaceWorkflowProfile
              (pool kirokuStore)
              sampleWorkflowProfileId
              (ProfileVersion "1")
              replacementContent
              replacementDigest

            resumed <- runAgentRunWorkflow deps profilePinningJob
            case resumed of
              Right (Completed (Right _)) -> pure ()
              other -> assertFailure ("resumed run should complete, got " <> show other)

            calls <- readIORef resolverCalls
            assertEqual "resolution executed only on the first attempt" 1 calls
            pinnedAfter <- loadProfileResolution appEnv profilePinningJob
            assertEqual "replay kept the original profile rather than the replacement" pinnedBefore pinnedAfter,
      testCase "a pinned tuple mismatch refuses before the provider or session boundary" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                content = workflowProfileWith defaultThinkingProhibitions (ProfileVersion "1")
                digest = profileDigest content
                resolved = resolvedWorkflowProfile content digest
                deps =
                  (testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [profiledSkillDecl])
                    { resolveRunProfile = \_profileId _version -> pure (Right resolved)
                    }

            result <- runAgentRunWorkflow deps profileViolationJob
            case result of
              Right (Completed (Left err)) -> do
                let detail = agentRunFailureDetail err
                assertBool ("violation should name the attempted model: " <> Text.unpack detail) ("stub-v1" `Text.isInfixOf` detail)
                assertBool ("violation should name the pinned digest: " <> Text.unpack detail) (profileDigestText digest `Text.isInfixOf` detail)
              other -> assertFailure ("expected a permanent provider-profile refusal, got " <> show other)

            sessions <- runAppIO appEnv (Session.getByScope shikigamiMemorySpace (agentScope (CompatibilityAgent (fixtureAgentName "profiled-skill"))))
            case sessions of
              Right (Right rows) -> assertEqual "the provider seam was refused before session creation" 0 (length rows)
              other -> assertFailure ("session query should succeed, got " <> show (first (const ("store-error" :: String)) other)),
      testCase "a profiled Flow is constrained before its capability interpreters run" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                content = workflowProfileWith defaultThinkingProhibitions (ProfileVersion "1")
                digest = profileDigest content
                resolved = resolvedWorkflowProfile content digest
                deps =
                  (testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [profiledFlowDecl])
                    { resolveRunProfile = \_profileId _version -> pure (Right resolved)
                    }

            result <- runAgentRunWorkflow deps profiledFlowViolationJob
            case result of
              Right (Completed (Left err)) -> do
                let detail = agentRunFailureDetail err
                assertBool ("Flow violation should name the attempted model: " <> Text.unpack detail) ("stub-v1" `Text.isInfixOf` detail)
                assertBool ("Flow violation should name the pinned digest: " <> Text.unpack detail) (profileDigestText digest `Text.isInfixOf` detail)
              other -> assertFailure ("expected a permanent Flow profile refusal, got " <> show other)

            sessions <- runAppIO appEnv (Session.getByScope shikigamiMemorySpace (agentScope (CompatibilityAgent (fixtureAgentName "profiled-flow"))))
            case sessions of
              Right (Right rows) -> assertEqual "the profiled Flow was refused before session creation" 0 (length rows)
              other -> assertFailure ("session query should succeed, got " <> show (first (const ("store-error" :: String)) other)),
      testCase "resumes after a crash between record and complete without duplicating memory" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            counts <- newIORef Map.empty
            shouldCrash <- newIORef True
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                hooks =
                  ( defaultAgentRunHooks
                      & #beforeStepBody
                        .~ ( \stepName -> do
                               modifyIORef' counts (Map.insertWith (+) (unStepName stepName) (1 :: Int))
                               when (unStepName stepName == "complete") do
                                 crashNow <- atomicModifyIORef' shouldCrash \current -> (False, current)
                                 when crashNow (ioError (userError "simulated crash before complete"))
                           )
                  )
                deps = testDeps appEnv behaviorEnv hooks

            crashedRun <- try (runAgentRunWorkflow deps recordBeforeCompleteCrashJob)
            case crashedRun of
              Left (_ :: SomeException) -> pure ()
              Right other -> assertEqual "first run should crash before complete" "exception" (show other)

            afterCrash <- readIORef counts
            assertEqual "record step completed before the crash" (Just 1) (Map.lookup "record" afterCrash)
            assertEqual "complete step was reached once before the crash" (Just 1) (Map.lookup "complete" afterCrash)

            resumed <- runAgentRunWorkflow deps recordBeforeCompleteCrashJob
            sid <- case resumed of
              Right (Completed (Right AgentRunResult {sessionId})) -> pure sessionId
              other -> assertFailure ("resumed run should complete, got " <> show other)

            finalCounts <- readIORef counts
            assertEqual "record replayed without rerunning" (Just 1) (Map.lookup "record" finalCounts)
            assertEqual "complete body ran once after recovery" (Just 2) (Map.lookup "complete" finalCounts)

            memories <- runAppIO appEnv (Memory.getRowsBySession shikigamiMemorySpace sid)
            case memories of
              Right (Right rows) -> assertEqual "exactly one memory row for the resumed session" 1 (length rows)
              other -> assertFailure ("memory lookup should succeed, got " <> show other)

            session <- runAppIO appEnv (Session.getById shikigamiMemorySpace sid)
            case session of
              Right (Right (Just SessionRow {status, modelUsed})) -> do
                assertEqual "session completed after resume" "completed" status
                -- The durable half of the promise that a stub never passes for
                -- a model: whatever answered is named on the row, so a run made
                -- without a model is identifiable long after the process that
                -- logged its provider has gone.
                assertEqual "the completed session names the model that answered" (Just "stub-v1") modelUsed
              other -> assertFailure ("session lookup should return completed row, got " <> show other),
      testCase "runs Flow behavior through the agent workflow" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [flowDecl]

            result <- runAgentRunWorkflow deps flowJob
            case result of
              Right (Completed (Right AgentRunResult {behaviorOutput})) ->
                assertEqual "flow behavior returns its classified verdict" expectedFlowOutput behaviorOutput
              other -> assertFailure ("flow behavior should complete, got " <> show other)

            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            assertEqual "low-risk flow emits no sink outbox rows" (Right 0) (length <$> outboxRows),
      -- The durable half of the memory proof. The pure rules live in
      -- "Shikigami.BehaviorInputSpec"; this runs the whole
      -- open-session → recall → flow → emit pipeline against a real database
      -- and shows a decision changed by something the agent learned earlier.
      --
      -- The payload is the same calm text the low-risk case above uses, and the
      -- flow reaches the opposite verdict — so it is memory, not the trigger,
      -- that moved it. Recall works without a vector extension because
      -- 'Shikigami.Agent.Run.recallPriorLearnings' falls back to
      -- @getActiveByScope@, which makes this deterministic in CI.
      testCase "a recalled escalation flips the flow's verdict on a calm payload" do
        (withShikigamiFreshDatabase databaseFixture) \connStr ->
          withStore (defaultConnectionSettings connStr) \kirokuStore -> do
            tracer <- noopTracer
            behaviorEnv <- newBehaviorEnv
            let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [flowDecl]

            recordPriorEscalation appEnv (runKeyText ((.idempotencyKey) flowMemoryJob))

            -- A high verdict emits its alert and then parks awaiting
            -- acknowledgement; the low case above completes outright. Parking
            -- is itself the branch evidence, and the emitted row carries the
            -- verdict that caused it.
            parked <- runAgentRunWorkflow deps flowMemoryJob
            case parked of
              Right Suspended -> pure ()
              other -> assertEqual "high-risk flow parks awaiting acknowledgement" "Suspended" (show other)

            outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
            case outboxRows of
              Right [OutboxRow {event}] ->
                case decodeJsonIntegrationEvent event of
                  Right SinkIntent {output} ->
                    assertEqual
                      "the emitted signal carries a verdict the recalled memory forced"
                      ( object
                          [ "level" .= ("high" :: Text),
                            "rationale" .= ("prior escalation on this subject: customer relationship at risk" :: Text),
                            "ticketId" .= (.idempotencyKey) flowMemoryJob
                          ]
                      )
                      output
                  Left err -> assertFailure ("the outbox row should decode as a sink intent, got " <> show err)
              other -> assertFailure ("expected exactly one emitted signal, got " <> show (fmap length other)),
      testGroup
        "Conversation"
        [ testCase "new conversation session carries principal id under the name-keyed scope" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                directory <-
                  newDirectoryHandle
                    (staticDirectorySource [PrincipalRecord {principalId = declarationCoordinate ("agent_heartbeat"), handle = declarationCoordinate ("heartbeat"), lifecycle = Directory.Active}])
                refreshDirectory directory >>= either (assertFailure . Text.unpack) pure
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    env = (testConversationEnv appEnv behaviorEnv [conversationDecl]) {Conversation.directory = directory}

                turn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                sid <- case turn of
                  Right result -> pure ((.sessionId) result)
                  Left err -> assertFailure ("conversation turn failed: " <> show err)
                sessions <- runAppIO appEnv (Session.getByScope shikigamiMemorySpace (agentScope (verifiedAgentIdentity "agent_heartbeat")))
                case sessions of
                  Right (Right [SessionRow {agentId}]) -> assertEqual "session agent id" "agent_heartbeat" agentId
                  other -> assertFailure ("name-keyed scope should contain one attributed session, got " <> show other)
                loaded <- runAppIO appEnv (Session.getById shikigamiMemorySpace sid)
                case loaded of
                  Right (Right (Just SessionRow {agentId})) -> assertEqual "resolved session row" "agent_heartbeat" agentId
                  other -> assertFailure ("conversation session should be readable, got " <> show other),
          testCase "parks and resumes a danwa conversation as one workflow session" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    env = testConversationEnv appEnv behaviorEnv [conversationDecl]

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                secondTurn <- Conversation.runConversationTurn env conversationDecl secondAddressedMessage

                case (firstTurn, secondTurn) of
                  (Right firstResult, Right secondResult) -> do
                    assertEqual "second human turn reuses the first kioku session" ((.sessionId) firstResult) ((.sessionId) secondResult)
                    assertBool "first reply is represented by a durable outbox message" ("outbox:danwa-conversation:conv_thread_1:danwa-reply:msg_human_1" `Text.isPrefixOf` (.replyMessageId) firstResult)
                    assertBool "second reply is represented by a durable outbox message" ("outbox:danwa-conversation:conv_thread_1:danwa-reply:msg_human_2" `Text.isPrefixOf` (.replyMessageId) secondResult)

                    turns <- runAppIO appEnv (Session.getTurns shikigamiMemorySpace ((.sessionId) firstResult))
                    case turns of
                      Right (Right rows) ->
                        assertEqual
                          "one conversation session records user/assistant/user/assistant"
                          [("user", 0), ("assistant", 1), ("user", 2), ("assistant", 3)]
                          (turnRoleIndex <$> rows)
                      other -> assertFailure ("getTurns should return conversation turns, got " <> show (first (const ("store-error" :: String)) other))

                    outboxRows <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                    assertEqual "two danwa replies are queued through the outbox" (Right 2) (length <$> outboxRows)

                    pending <- runAppIO appEnv countPendingAwakeables
                    assertEqual "workflow parks again after the second reply" (Right 1) pending

                    -- One turn per generation, so the two turns are on two
                    -- generations and each label appears once in its own -- not
                    -- twice in one under two different computed suffixes.
                    firstKeys <- conversationStepKeys appEnv firstAddressedMessage 0
                    secondKeys <- conversationStepKeys appEnv firstAddressedMessage 1

                    assertEqual
                      "unbound initial seed retains its complete wire value"
                      (Just (object ["agentName" .= ("" :: Text), "identity" .= object ["kind" .= ("unresolved-legacy" :: Text)], "turnsSoFar" .= (0 :: Int), "pendingMessage" .= Null, "lastMessageId" .= Null]))
                      (Map.lookup continueSeedStepName firstKeys)
                    assertEqual
                      "carried seed retains its complete wire value"
                      (Just (object ["agentName" .= ("heartbeat" :: Text), "identity" .= compatibilityIdentity (fixtureAgentName "heartbeat"), "turnsSoFar" .= (1 :: Int), "pendingMessage" .= secondAddressedMessage, "lastMessageId" .= firstAddressedMessage.messageId]))
                      (Map.lookup continueSeedStepName secondKeys)

                    assertBool "the first turn's result is journaled in generation 0" (Map.member "turn-result" firstKeys)
                    assertBool "the second turn's result is journaled in generation 1" (Map.member "turn-result" secondKeys)
                    assertBool "the first assistant turn and reply are one durable step" (Map.member "record-assistant-and-reply" firstKeys)
                    assertBool "the second assistant turn and reply are one durable step" (Map.member "record-assistant-and-reply" secondKeys)

                    -- The label carries no message id any more, so "one
                    -- turn-result per generation" is the property that replaces
                    -- "one turn-result per message".
                    assertEqual "generation 0 holds exactly one turn result" 1 (length (filter (== "turn-result") (Map.keys firstKeys)))
                    assertEqual "generation 1 holds exactly one turn result" 1 (length (filter (== "turn-result") (Map.keys secondKeys)))

                    -- danwa-reply names the outbox row, not a journal step.
                    assertBool "the first reply is not journaled as a separate sink step" (not (any ("danwa-reply" `Text.isPrefixOf`) (Map.keys firstKeys)))
                    assertBool "the second reply is not journaled as a separate sink step" (not (any ("danwa-reply" `Text.isPrefixOf`) (Map.keys secondKeys)))

                    -- The await label lost its ordinal with everything else: a
                    -- generation arms exactly one next-message promise.
                    assertEqual "generation 0 armed the static next-message promise" ["awkid:next-message"] (filter ("awkid:" `Text.isPrefixOf`) (Map.keys firstKeys))
                    assertEqual "generation 1 armed the static next-message promise" ["awkid:next-message"] (filter ("awkid:" `Text.isPrefixOf`) (Map.keys secondKeys))
                  other -> assertFailure ("conversation turns should succeed, got " <> show other),
          testCase "conversation permanent v2 failure completes as a replayable typed failure" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    env = testConversationEnv appEnv behaviorEnv [missingTaskDecl]

                firstFailure <- Conversation.runConversationTurn env missingTaskDecl permanentConversationMessage
                replayed <- Conversation.runConversationTurn env missingTaskDecl permanentConversationMessage
                assertBool
                  ("first turn returns the permanent detail: " <> show firstFailure)
                  (either (Text.isInfixOf "unknown task" . Conversation.conversationTurnFailureDetail) (const False) firstFailure)
                assertEqual "replay returns the same typed failure" firstFailure replayed
                stepIndex <- conversationStepKeys appEnv permanentConversationMessage 0
                assertBool "conversation journals the static v2 label" (Map.member "run-behavior-v2" stepIndex)
                assertBool "conversation never journals the legacy label" (not (Map.member "run-behavior" stepIndex)),
          testCase "conversation execution fails closed on a declared overlay" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    declaration = capabilityDecl "conversation-overlay" (Skill {path = declarationCoordinate ("unused")}) [workspaceReadId] (Just overlayIdentity) []
                    env = testConversationEnv appEnv behaviorEnv [declaration]
                    message = permanentConversationMessage

                failed <- Conversation.runConversationTurn env declaration message
                case failed of
                  Left refusal ->
                    assertBool
                      ("conversation refusal should name the overlay mismatch: " <> show refusal)
                      ("capability overlay mismatch" `Text.isInfixOf` Conversation.conversationTurnFailureDetail refusal)
                  Right result -> assertFailure ("conversation must not ignore the overlay, got " <> show result),
          -- Session resolution used to be a linear scan over every session the
          -- agent had ever had, filtered on subjectRef. It is now a keyed read
          -- of shikigami.conversation_sessions, confirmed against kioku. The
          -- decoy is a running session in the same scope under a different
          -- subject: the exact row the scan had to walk past, and the exact row
          -- a mis-keyed lookup would return.
          testCase "resolves its own session and ignores a decoy in the same scope" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    env = testConversationEnv appEnv behaviorEnv [conversationDecl]

                decoy <- startDecoyConversationSession appEnv "heartbeat" "conv_decoy_thread"

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                secondTurn <- Conversation.runConversationTurn env conversationDecl secondAddressedMessage

                case (firstTurn, secondTurn) of
                  (Right firstResult, Right secondResult) -> do
                    let sid = (.sessionId) firstResult
                    assertEqual "both turns resolve the same session" sid ((.sessionId) secondResult)
                    assertBool "the decoy in the same scope is never selected" (sid /= decoy)

                    indexed <- runAppIO appEnv (SessionIndex.lookupConversationSession "conv_thread_1")
                    assertEqual
                      "the index points at this conversation's own session"
                      (Right (Just (idText sid)))
                      indexed

                    -- The decoy was started outside the conversation path, so
                    -- nothing indexed it. That is what makes the hit above a
                    -- keyed answer rather than a coincidence.
                    decoyIndexed <- runAppIO appEnv (SessionIndex.lookupConversationSession "conv_decoy_thread")
                    assertEqual "the decoy conversation has no index row" (Right Nothing) decoyIndexed

                    ours <- runningSessionsFor appEnv "heartbeat" "conv_thread_1"
                    assertEqual "exactly one running session carries this conversation id" [idText sid] ours

                    theirs <- runningSessionsFor appEnv "heartbeat" "conv_decoy_thread"
                    assertEqual "the decoy is still running and untouched" [idText decoy] theirs
                  other -> assertFailure ("both conversation turns should succeed, got " <> show other),
          -- The ingress path used to read the step index at a hard-coded
          -- generation 0. That is correct only while nothing rotates the
          -- journal, and M2 makes every turn rotate. Reading the resolved
          -- generation must be behaviour-preserving *before* rotation exists,
          -- which is what this pins: delivery finds the armed promise on a
          -- parked conversation, and refuses one that was never started rather
          -- than throwing.
          testCase "delivery resolves the live generation instead of assuming zero" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    env = testConversationEnv appEnv behaviorEnv [conversationDecl]

                -- Nothing has run, so there is no instance and no generation.
                -- currentGeneration answers 0 for an unknown workflow, so this
                -- is also the proof that the new read is total.
                cold <- Conversation.deliverConversationInputFromApp appEnv firstAddressedMessage
                assertEqual "a conversation that never started has nothing to deliver to" False cold

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                assertBool ("first turn should succeed, got " <> show firstTurn) (either (const False) (const True) firstTurn)

                -- The turn parked on next-message, so the promise is armed and
                -- discoverable through the resolved generation.
                delivered <- Conversation.deliverConversationInputFromApp appEnv secondAddressedMessage
                assertEqual "a parked conversation accepts the next message" True delivered

                -- Signalling the same promise twice must not resolve it twice.
                again <- Conversation.deliverConversationInputFromApp appEnv secondAddressedMessage
                assertEqual "the promise is consumed once" False again,
          -- The bounded-journal claim, stated as something that can fail. The
          -- old body ran every turn of a conversation in one immortal
          -- generation, so replay cost grew with the conversation and never
          -- recovered. Five turns now means five generations, each holding one
          -- turn's worth of labels -- and all five turns still land in ONE kioku
          -- session, because rotation bounds the journal, not the conversation.
          testCase "rotates onto a fresh generation after every turn" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    env = testConversationEnv appEnv behaviorEnv [conversationDecl]
                    messages = [conversationMessageNumbered n | n <- [1 .. 5]]

                results <- traverse (Conversation.runConversationTurn env conversationDecl) messages
                sessions <-
                  traverse
                    ( \(n, result) -> case result of
                        Right turnResult -> pure ((.sessionId) turnResult)
                        Left err -> assertFailure ("turn " <> show (n :: Int) <> " should succeed, got " <> show err)
                    )
                    (zip [1 ..] results)

                conversationSession <- case sessions of
                  [] -> assertFailure "five turns should produce five results"
                  firstSession : rest -> do
                    assertBool "all five turns are recorded in one kioku session" (all (== firstSession) rest)
                    pure firstSession

                -- Generation 4 exists, which is the rotation claim: turn N ran
                -- in generation N-1.
                generation4 <- conversationStepKeys appEnv (conversationMessageNumbered 1) 4
                assertBool "the fifth turn ran in generation 4" (Map.member "turn-result" generation4)

                -- No generation holds two turns. This is the property the
                -- static labels depend on and the one that bounds replay.
                forM_ [0 .. 4] \generation -> do
                  keys <- conversationStepKeys appEnv (conversationMessageNumbered 1) generation
                  assertEqual
                    ("generation " <> show generation <> " holds exactly one turn result")
                    1
                    (length (filter (== "turn-result") (Map.keys keys)))
                  assertEqual
                    ("generation " <> show generation <> " armed exactly one next-message promise")
                    ["awkid:next-message"]
                    (filter ("awkid:" `Text.isPrefixOf`) (Map.keys keys))

                firstKeys <- conversationStepKeys appEnv (conversationMessageNumbered 1) 0
                liveKeys <- conversationStepKeys appEnv (conversationMessageNumbered 1) 4
                let token keys = case Map.lookup "awkid:next-message" keys of
                      Just value -> case fromJSON value of
                        Success aid -> pure (aid :: AwakeableId)
                        Error err -> assertFailure err
                      Nothing -> assertFailure "published generation token missing"
                oldToken <- token firstKeys
                newToken <- token liveKeys
                assertBool "rotation publishes a fresh opaque token" (oldToken /= newToken)
                let wake = object ["tag" .= ("NextMessage" :: Text), "contents" .= conversationMessageNumbered 6]
                oldAccepted <- runAppIO appEnv (signalAwakeable oldToken wake)
                assertEqual "old token cannot signal the live generation" (Right False) oldAccepted
                newAccepted <- runAppIO appEnv (signalAwakeable newToken wake)
                assertEqual "published live token accepts the next input" (Right True) newAccepted

                -- Ten turns in one session, in order, is what proves rotation
                -- bounded the journal without fragmenting the conversation.
                turns <- runAppIO appEnv (Session.getTurns shikigamiMemorySpace conversationSession)
                case turns of
                  Right (Right rows) ->
                    assertEqual
                      "five turns are recorded as five user/assistant pairs"
                      [(role, index) | index <- [0 .. 9], let role = if even index then "user" else "assistant"]
                      (turnRoleIndex <$> rows)
                  other -> assertFailure ("getTurns should return conversation turns, got " <> show (first (const ("store-error" :: String)) other))
                forM_ [1 :: Int, 2] \_ -> do
                  resumed <- runAppIO appEnv (resumeWorkflowsOnce (shikigamiWorkflowResumeOptions appEnv (secondsToNominalDiffTime 300)) (Conversation.conversationRegistry env))
                  either (assertFailure . show) (const (pure ())) resumed
                nextKeys <- conversationStepKeys appEnv (conversationMessageNumbered 1) 5
                assertBool "the published live token drives the sixth turn" (Map.member "turn-result" nextKeys),
          -- The lifecycle claim. Before this, a conversation workflow never
          -- ended and its kioku session stayed "running" forever -- a leak, and
          -- a correctness hazard for a resolver that only ever reused running
          -- sessions. The idle timer signals the same next-message awakeable the
          -- next human message would have signalled, so the workflow ends
          -- through its own await rather than being killed from outside.
          testCase "completes the kioku session on idle timeout" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    env = testConversationEnvIdle (secondsToNominalDiffTime 1) appEnv behaviorEnv [conversationDecl]

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                sid <- case firstTurn of
                  Right result -> pure ((.sessionId) result)
                  Left err -> assertFailure ("first turn should succeed, got " <> show err)

                (runningStatus, _) <- conversationSessionState appEnv sid
                assertEqual "the session is running while the conversation is parked" "running" runningStatus

                fired <- fireDueConversationIdleTimer appEnv
                assertBool "the idle timer fires" fired

                -- Firing resolves the awakeable and flips the instance back to
                -- running; the resume worker is what drives it to observe the
                -- timeout and end. That is the production path -- the ingress
                -- path deliberately will not drive a live conversation, which is
                -- the same refusal the busy case relies on.
                resumed <- runAppIO appEnv (resumeConversationOnce appEnv env)
                assertEqual "the resume pass ends the idle epoch" (Right 1) (completed <$> resumed)

                (completedStatus, _) <- conversationSessionState appEnv sid
                assertEqual "the idle timeout completes the kioku session" "completed" completedStatus

                pending <- runAppIO appEnv countPendingAwakeables
                assertEqual "the ended epoch leaves no promise armed" (Right 0) pending,
          -- A timer armed for turn N belongs to the generation turn N+1 closed.
          -- Under one turn per generation the generation IS the staleness token,
          -- so this is a property of the timer id rather than of a counter
          -- somebody has to keep in step -- but it is only testable if the stale
          -- timer is actually fired.
          testCase "ignores a timer armed in a superseded generation" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    env = testConversationEnvIdle (secondsToNominalDiffTime 1) appEnv behaviorEnv [conversationDecl]

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                sid <- case firstTurn of
                  Right result -> pure ((.sessionId) result)
                  Left err -> assertFailure ("first turn should succeed, got " <> show err)

                staleTimer <- captureConversationIdleTimer appEnv
                -- The second message rotates generation 0 shut, which is what
                -- makes generation 0's armed timer stale.
                secondTurn <- Conversation.runConversationTurn env conversationDecl secondAddressedMessage
                assertBool ("second turn should succeed, got " <> show secondTurn) (either (const False) (const True) secondTurn)

                before <- conversationStepKeys appEnv secondAddressedMessage 1
                runAppIO appEnv (Conversation.conversationIdleTimeoutFireAction staleTimer) >>= assertEqual "superseded timer is cancelled" (Right Nothing)
                let legacy =
                      staleTimer
                        & #payload .~ case staleTimer.payload of
                          Object fields -> Object (KeyMap.delete "generation" fields)
                          value -> value
                runAppIO appEnv (Conversation.conversationIdleTimeoutFireAction legacy) >>= assertEqual "legacy timer cannot target a successor" (Right Nothing)
                after <- conversationStepKeys appEnv secondAddressedMessage 1
                assertEqual "old timers append no orphan wake to the live generation" before after

                stale <- conversationStepKeys appEnv firstAddressedMessage 0
                assertBool "the superseded generation records no terminal step" (not (Map.member "idle-timeout" stale))

                (liveStatus, _) <- conversationSessionState appEnv sid
                assertEqual "the live conversation's session is untouched" "running" liveStatus

                -- And the conversation still works.
                thirdTurn <- Conversation.runConversationTurn env conversationDecl (conversationMessageNumbered 3)
                assertBool ("the conversation continues, got " <> show thirdTurn) (either (const False) (const True) thirdTurn),
          -- The other half of ending an epoch: the next message opens a NEW
          -- session that names the closed one, so a conversation's history stays
          -- walkable across every epoch it has had. previousSessionId was
          -- unconditionally Nothing before, which was the only honest answer
          -- while nothing ever completed a session.
          testCase "opens a new epoch after idle timeout, chaining session lineage" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    env = testConversationEnvIdle (secondsToNominalDiffTime 1) appEnv behaviorEnv [conversationDecl]

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                firstSession <- case firstTurn of
                  Right result -> pure ((.sessionId) result)
                  Left err -> assertFailure ("first turn should succeed, got " <> show err)

                _ <- fireDueConversationIdleTimer appEnv
                ended <- runAppIO appEnv (resumeConversationOnce appEnv env)
                assertEqual "the resume pass ends the idle epoch" (Right 1) (completed <$> ended)

                (closedStatus, _) <- conversationSessionState appEnv firstSession
                assertEqual "the first epoch's session is closed" "completed" closedStatus

                -- A message after the timeout finds a terminated workflow, so it
                -- starts a fresh epoch.
                nextEpoch <- Conversation.runConversationTurn env conversationDecl secondAddressedMessage
                secondSession <- case nextEpoch of
                  Right result -> pure ((.sessionId) result)
                  Left err -> assertFailure ("the next epoch's turn should succeed, got " <> show err)

                assertBool "the new epoch opens a different session" (secondSession /= firstSession)

                (openedStatus, openedPrevious) <- conversationSessionState appEnv secondSession
                assertEqual "the new epoch's session is running" "running" openedStatus
                assertEqual
                  "the new epoch names the closed session as its predecessor"
                  (Just (idText firstSession))
                  openedPrevious

                -- The index moved with the conversation, so the next turn
                -- resolves the new session rather than the closed one.
                indexed <- runAppIO appEnv (SessionIndex.lookupConversationSession "conv_thread_1")
                assertEqual "the index follows the conversation into its new epoch" (Right (Just (idText secondSession))) indexed

                -- The new epoch is a new workflow INSTANCE, which is the whole
                -- reason the epoch exists: a completed keiro instance replays
                -- its completion rather than accepting new work, so reusing the
                -- id would have swallowed this message and returned the previous
                -- epoch's result.
                epochNow <- runAppIO appEnv (SessionIndex.lookupConversationEpoch "conv_thread_1")
                assertEqual "the conversation advanced to epoch 1" (Right 1) epochNow

                epoch0 <- conversationStepKeysAt 0 appEnv secondAddressedMessage 0
                epoch1 <- conversationStepKeysAt 1 appEnv secondAddressedMessage 0
                assertBool "epoch 0's journal holds the timeout that ended it" (Map.member "idle-timeout" epoch0)
                assertBool "epoch 1 has a journal of its own" (Map.member "turn-result" epoch1)
                assertBool "epoch 1 did not end" (not (Map.member "idle-timeout" epoch1)),
          -- The next turn's promise is now armed BEFORE the behavior runs, so
          -- the window in which a message finds nothing to signal is a few
          -- journaled steps rather than a whole model call.
          --
          -- A failing turn is what makes that testable without racing a thread:
          -- the behavior fails, so the turn never reaches the point where the
          -- promise used to be allocated -- and the promise is in the journal
          -- anyway. The old ordering could not have produced this journal.
          -- Because the turn then ends, the promise is withdrawn rather than
          -- left pending on a workflow that is over.
          testCase "arms the next promise before running the behavior" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    env = testConversationEnv appEnv behaviorEnv [missingTaskDecl]

                failed <- Conversation.runConversationTurn env missingTaskDecl permanentConversationMessage
                assertBool
                  ("the turn should fail permanently, got " <> show failed)
                  (either (Text.isInfixOf "unknown task" . Conversation.conversationTurnFailureDetail) (const False) failed)

                keys <- conversationStepKeys appEnv permanentConversationMessage 0
                assertBool "the promise was allocated before the behavior ran" (Map.member "awkid:next-message" keys)
                assertBool "the behavior did run and failed" (Map.member "run-behavior-v2" keys)
                assertBool "the turn recorded no result" (not (Map.member "turn-result" keys))

                pending <- runAppIO appEnv countPendingAwakeables
                assertEqual "a failed turn withdraws the promise it armed" (Right 0) pending,
          -- The routine busy case used to run down an error path. A message that
          -- finds no armed promise was treated as a brand-new conversation, so
          -- it ran a ConversationStart against a live workflow and came back as
          -- a transient failure -- indistinguishable, to the worker, from a
          -- store problem.
          --
          -- Consuming the promise without driving the workflow reproduces that
          -- window deterministically: the instance is alive, nothing is armed,
          -- and a third message arrives.
          testCase "redelivers a message that finds no armed promise, rather than restarting" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    env = testConversationEnv appEnv behaviorEnv [conversationDecl]
                    thirdMessage = thirdAddressedMessage

                firstTurn <- Conversation.runConversationTurn env conversationDecl firstAddressedMessage
                sid <- case firstTurn of
                  Right result -> pure ((.sessionId) result)
                  Left err -> assertFailure ("first turn should succeed, got " <> show err)

                -- Claim the armed promise without letting the workflow advance.
                claimed <- Conversation.deliverConversationInputFromApp appEnv secondAddressedMessage
                assertEqual "the second message claims the armed promise" True claimed

                -- The third message now finds a live conversation with nothing
                -- armed: the busy window.
                busy <- Conversation.runConversationTurn env conversationDecl thirdMessage
                case busy of
                  Left (Conversation.ConversationBusy detail) ->
                    assertBool
                      ("the backpressure names the message: " <> Text.unpack detail)
                      ("msg_human_3" `Text.isInfixOf` detail)
                  other -> assertFailure ("a busy conversation should report backpressure, got " <> show other)

                -- Backpressure, not damage: no second session, and the
                -- conversation is exactly where it was.
                running <- runningSessionsFor appEnv "heartbeat" "conv_thread_1"
                assertEqual "no new session was created for the busy message" [idText sid] running

                -- Letting the conversation catch up is the resume worker's job:
                -- the claimed promise flipped the instance back to running, and
                -- resuming it processes the second message and parks again.
                drained <- drainConversationResumes appEnv env
                assertBool ("the resume worker should advance the conversation, got " <> show drained) (drained > 0)

                -- With the conversation free again, the redelivery lands.
                redelivered <- Conversation.runConversationTurn env conversationDecl thirdMessage
                case redelivered of
                  Right result -> assertEqual "the redelivered turn lands in the same session" sid ((.sessionId) result)
                  Left err -> assertFailure ("the redelivered message should be processed, got " <> show err)

                turns <- runAppIO appEnv (Session.getTurns shikigamiMemorySpace sid)
                case turns of
                  Right (Right rows) ->
                    assertEqual
                      "all three messages are recorded in one session, in order"
                      [("user", 0), ("assistant", 1), ("user", 2), ("assistant", 3), ("user", 4), ("assistant", 5)]
                      (turnRoleIndex <$> rows)
                  other -> assertFailure ("getTurns should return conversation turns, got " <> show (first (const ("store-error" :: String)) other))
        ],
      testGroup
        "Delegate"
        [ testCase "an explicitly enrolled root keeps one envelope and rejects descendant enrollment" do
            withShikigamiFreshDatabase databaseFixture \connStr -> do
              tracer <- noopTracer
              let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
              now <- getCurrentTime
              let envelope = Resources.Envelope (Map.singleton Resources.LifetimeDescendants (Resources.Limited (fixtureAmount 1))) (addUTCTime 3600 now)
              first <- runAppIO appEnv (enrollRootRun envelope (capabilityJob "heartbeat" "new-root"))
              job <- case first of
                Right (Right admitted) -> pure admitted
                other -> assertFailure (show other)
              replay <- runAppIO appEnv (enrollRootRun envelope job)
              assertEqual "root admission is idempotent" (Right (Right job)) replay
              descendant <- runAppIO appEnv (enrollRootRun envelope (job & #parentRunWorkflowId .~ Just (WorkflowId "parent")))
              case descendant of
                Right (Left (Resources.InvalidResourceRequest _)) -> pure ()
                other -> assertFailure ("descendant enrollment should fail: " <> show other),
          testCase "resource-enrolled delegation journals the inherited root and denial creates no child" do
            withShikigamiFreshDatabase databaseFixture \connStr -> do
              tracer <- noopTracer
              parentSession <- genSessionId
              now <- getCurrentTime
              let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                  root = fixtureRootId "delegation-resource-root"
                  envelope = Resources.Envelope (Map.singleton Resources.LifetimeDescendants (Resources.Limited (fixtureAmount 1))) (addUTCTime 3600 now)
                  parentName = WorkflowName "shikigami.test-resource-parent"
                  parentId = WorkflowId "resource-parent"
                  childId = delegatedWorkflowIdV2 parentId (fixtureAgentName "heartbeat") (declarationCoordinate "first")
                  deniedId = delegatedWorkflowIdV2 (WorkflowId "other-parent") (fixtureAgentName "heartbeat") (declarationCoordinate "second")
                  supervisor = decl & #delegates .~ map fixtureAgentName ["heartbeat"]
                  ctx = parentDelegateContext parentSession & #executionRootId .~ Just root
                  body key = void (delegate [decl] disabledDirectoryHandle supervisor ctx (declarationCoordinate key) (fixtureAgentName "heartbeat") (object []))
              runAppIO appEnv (Resources.enrollRoot root envelope) >>= assertEqual "explicit root admitted" (Right (Right Resources.Accepted))
              runAppIO appEnv (runWorkflow parentName parentId (body "first")) >>= assertEqual "child spawned" (Right (Completed ()))
              recorded <- runAppIO appEnv (loadStepIndex agentRunWorkflowName childId 0)
              case fmap (Map.lookup "ingest-job") recorded of
                Right (Just value) -> case fromJSON @RunJob value of
                  Success child -> assertEqual "child inherits root" (Just root) child.executionRootId
                  Error err -> assertFailure err
                other -> assertFailure ("child ingestion absent: " <> show other)
              -- A different parent workflow still spends the same resource root.
              denied <- try @DelegationError (runAppIO appEnv (runWorkflow parentName (WorkflowId "other-parent") (body "second")))
              case denied of
                Left (DelegationBudgetUnavailable _) -> pure ()
                other -> assertFailure ("resource exhaustion should deny: " <> show other)
              runAppIO appEnv (lookupInstance agentRunWorkflowName deniedId) >>= assertEqual "no child created on denial" (Right Nothing),
          testCase "parent suspends awaiting delegated child and resumes with child output" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                parentSession <- genSessionId
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    deps = testDeps appEnv behaviorEnv defaultAgentRunHooks
                    parentWorkflowName = WorkflowName "shikigami.test-delegate-parent"
                    parentWorkflowId = WorkflowId "delegate-parent-1"
                    childWorkflowId = delegatedWorkflowIdV2 parentWorkflowId (fixtureAgentName "heartbeat") (declarationCoordinate "heartbeat")
                    parentBody = parentDelegateWorkflow parentSession

                parked <- runAppIO appEnv (runWorkflow parentWorkflowName parentWorkflowId parentBody)
                assertEqual "parent parks on delegated child" (Right Suspended) parked

                childRun <-
                  runAppIO appEnv $
                    runChildWorkflow
                      defaultWorkflowRunOptions
                      agentRunWorkflowName
                      childWorkflowId
                      (agentRunWorkflow deps Nothing)
                childOutput <-
                  case childRun of
                    Right (Completed (Right AgentRunResult {behaviorOutput = childBehaviorOutput})) -> pure childBehaviorOutput
                    other -> assertFailure ("child agent workflow should complete, got " <> show other)

                resumed <- runAppIO appEnv (runWorkflow parentWorkflowName parentWorkflowId parentBody)
                assertEqual "parent resumes with child behavior output" (Right (Completed childOutput)) resumed,
          testCase "a cycle is refused at the durable delegation boundary" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                parentSession <- genSessionId
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    parentWorkflowName = WorkflowName "shikigami.test-delegate-cycle"
                    parentWorkflowId = WorkflowId "delegate-cycle-parent"
                    supervisor = (decl & #delegates .~ ([(fixtureAgentName "heartbeat")]))
                    ctx =
                      DelegateCtx
                        { identity = compatibilityIdentity (fixtureAgentName "heartbeat"),
                          depth = fixtureDelegationDepth 0,
                          sessionId = Just parentSession,
                          parentSessionId = Nothing,
                          parentRunWorkflowId = Nothing,
                          lineage = map fixtureAgentName ["test-parent", "heartbeat"],
                          executionPermissions = Nothing,
                          executionRootId = Nothing,
                          delegationBudgetId = Nothing,
                          budgetLimit = defaultDelegationBudget
                        }
                    parentBody = void (delegate [decl] disabledDirectoryHandle supervisor ctx (declarationCoordinate "cycle") (fixtureAgentName "heartbeat") (object []))
                refused <- try @DelegationError (runAppIO appEnv (runWorkflow parentWorkflowName parentWorkflowId parentBody))
                case refused of
                  Left err -> assertEqual "the ancestor target is rejected" (DelegationCycleDetected (fixtureAgentName "heartbeat")) err
                  Right outcome -> assertFailure ("cyclic delegation should fail before spawning, got " <> show outcome),
          testCase "an exhausted root budget is refused before child spawn" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                parentSession <- genSessionId
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    parentWorkflowName = WorkflowName "shikigami.test-delegate-exhausted"
                    parentWorkflowId = WorkflowId "delegate-exhausted-parent"
                    supervisor = (decl & #delegates .~ ([(fixtureAgentName "heartbeat")]))
                    zeroBudget = either (error . Text.unpack) id (mkDelegationBudget 0)
                    ctx = (parentDelegateContext parentSession) {budgetLimit = zeroBudget}
                    parentBody = void (delegate [decl] disabledDirectoryHandle supervisor ctx (declarationCoordinate "over-budget") (fixtureAgentName "heartbeat") (object []))
                refused <- try @DelegationError (runAppIO appEnv (runWorkflow parentWorkflowName parentWorkflowId parentBody))
                case refused of
                  Left err -> assertEqual "the zero budget is exhausted" DelegationBudgetExhausted err
                  Right outcome -> assertFailure ("over-budget delegation should fail before spawning, got " <> show outcome),
          testCase "proof supervisor fans out to specialists and records lineage" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                proofAgents <- loadProofAgents
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks proofAgents
                    parentWorkflowId = runJobWorkflowId researchSupervisorJob
                    webWorkflowId = delegatedWorkflowIdV2 parentWorkflowId (fixtureAgentName "web-researcher") (declarationCoordinate "delegate-0")
                    codeWorkflowId = delegatedWorkflowIdV2 parentWorkflowId (fixtureAgentName "code-researcher") (declarationCoordinate "delegate-1")
                    WorkflowId webWorkflowIdText = webWorkflowId
                    WorkflowId codeWorkflowIdText = codeWorkflowId
                    expectedRunningChildLinks =
                      Set.fromList
                        [ ("shikigami.agent-run", webWorkflowIdText, "running"),
                          ("shikigami.agent-run", codeWorkflowIdText, "running")
                        ]

                parked <- runAgentRunWorkflow deps researchSupervisorJob
                assertEqual "research supervisor parks after spawning children" (Right Suspended) parked
                childLinksAfterPark <- runAppIO appEnv (lookupChildrenOfParent (runJobWorkflowId researchSupervisorJob).unWorkflowId "shikigami.agent-run")
                assertEqual
                  "initial park creates two running child workflow links"
                  (Right expectedRunningChildLinks)
                  (childLinkSummary <$> childLinksAfterPark)

                replayedWhileChildrenPending <- runAgentRunWorkflow deps researchSupervisorJob
                assertEqual "parent replay while children are pending parks again" (Right Suspended) replayedWhileChildrenPending
                childLinksAfterReplay <- runAppIO appEnv (lookupChildrenOfParent (runJobWorkflowId researchSupervisorJob).unWorkflowId "shikigami.agent-run")
                assertEqual
                  "parent replay does not duplicate delegated children"
                  (childLinkSummary <$> childLinksAfterPark)
                  (childLinkSummary <$> childLinksAfterReplay)

                webRun <-
                  runAppIO appEnv $
                    runChildWorkflow
                      defaultWorkflowRunOptions
                      agentRunWorkflowName
                      webWorkflowId
                      (agentRunWorkflow deps Nothing)
                assertChildCompleted "web specialist completes" webRun

                codeRun <-
                  runAppIO appEnv $
                    runChildWorkflow
                      defaultWorkflowRunOptions
                      agentRunWorkflowName
                      codeWorkflowId
                      (agentRunWorkflow deps Nothing)
                assertChildCompleted "code specialist completes" codeRun

                resumed <- runAgentRunWorkflow deps researchSupervisorJob
                parentSession <-
                  case resumed of
                    Right (Completed (Right AgentRunResult {sessionId = parentSessionId', behaviorOutput})) -> do
                      assertEqual "supervisor synthesizes both findings" expectedSupervisorOutput behaviorOutput
                      pure parentSessionId'
                    other -> assertFailure ("research supervisor should complete after children, got " <> show other)

                children <- runAppIO appEnv (Session.getDelegationChildren shikigamiMemorySpace parentSession)
                case children of
                  Right (Right rows) ->
                    assertEqual
                      "kioku records both delegated child sessions"
                      ( Set.fromList
                          [ ("shikigami.agent.v2.759d78a7-1085-5bd2-b52b-8e01209c3711", Just (idText parentSession), 1),
                            ("shikigami.agent.v2.0f861389-9eef-5ffc-8643-7382fc4b2bc7", Just (idText parentSession), 1)
                          ]
                      )
                      (lineageSummary rows)
                  other -> assertFailure ("getDelegationChildren should return rows, got " <> show (first (const ("store-error" :: String)) other)),
          testCase "Flow delegates through the governed capability" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                proofAgents <- loadProofAgents
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks (flowDelegationDecl : proofAgents)
                    parentWorkflowId = runJobWorkflowId flowDelegationJob
                    childWorkflowId = delegatedWorkflowIdV2 parentWorkflowId (fixtureAgentName "web-researcher") (declarationCoordinate "web-researcher")

                parked <- runAgentRunWorkflow deps flowDelegationJob
                assertEqual "delegating Flow parks on its child" (Right Suspended) parked
                childRun <-
                  runAppIO appEnv $
                    runChildWorkflow
                      defaultWorkflowRunOptions
                      agentRunWorkflowName
                      childWorkflowId
                      (agentRunWorkflow deps Nothing)
                assertChildCompleted "Flow specialist completes" childRun
                resumed <- runAgentRunWorkflow deps flowDelegationJob
                case resumed of
                  Right (Completed (Right AgentRunResult {behaviorOutput})) ->
                    assertEqual "Flow returns the delegated output" expectedWebFinding behaviorOutput
                  other -> assertFailure ("delegating Flow should complete, got " <> show other),
          testCase "Flow refuses a target absent from its declaration" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                proofAgents <- loadProofAgents
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    deniedDecl = (flowDelegationDecl & #delegates .~ ([]))
                    deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks (deniedDecl : proofAgents)
                refused <- try @DelegationError (runAgentRunWorkflow deps flowDelegationDeniedJob)
                assertEqual "the capability applies the agent allow-list" (Left (DelegationNotAllowed (fixtureAgentName "web-researcher"))) refused,
          testCase "awaitAllDelegated retains successes beside a failed child" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                parentSession <- genSessionId
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [decl, missingTaskDecl]
                    supervisor = collectionSupervisorDecl
                    parentWorkflowName = WorkflowName "shikigami.test-delegate-collect"
                    parentWorkflowId = WorkflowId "delegate-collect-parent"
                    successId = delegatedWorkflowIdV2 parentWorkflowId (fixtureAgentName "heartbeat") (declarationCoordinate "success")
                    failureId = delegatedWorkflowIdV2 parentWorkflowId (fixtureAgentName "missing-task-agent") (declarationCoordinate "failure")
                    parentBody = parentCollectWorkflow parentSession supervisor

                parked <- runAppIO appEnv (runWorkflow parentWorkflowName parentWorkflowId parentBody)
                assertEqual "collector parks on child results" (Right Suspended) parked
                successRun <- runAppIO appEnv (runChildWorkflow defaultWorkflowRunOptions agentRunWorkflowName successId (agentRunWorkflow deps Nothing))
                failureRun <- runAppIO appEnv (runChildWorkflow defaultWorkflowRunOptions agentRunWorkflowName failureId (agentRunWorkflow deps Nothing))
                assertChildCompleted "successful collected child completes" successRun
                assertChildFailed "failed agent run still produces its typed child result" failureRun
                resumed <- runAppIO appEnv (runWorkflow parentWorkflowName parentWorkflowId parentBody)
                case resumed of
                  Right (Completed [Right _, Left failure]) ->
                    assertBool ("the failure should be retained as a delegated outcome: " <> Text.unpack failure) ("DelegatedChildFailed" `Text.isPrefixOf` failure)
                  other -> assertFailure ("collector should retain one success and one failure, got " <> show other),
          testCase "first observed failure cancels a running sibling truthfully" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                parentSession <- genSessionId
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    deps = testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [decl, missingTaskDecl]
                    supervisor = collectionSupervisorDecl
                    parentWorkflowName = WorkflowName "shikigami.test-delegate-cancel"
                    parentWorkflowId = WorkflowId "delegate-cancel-parent"
                    failureId = delegatedWorkflowIdV2 parentWorkflowId (fixtureAgentName "missing-task-agent") (declarationCoordinate "failure-first")
                    siblingId = delegatedWorkflowIdV2 parentWorkflowId (fixtureAgentName "heartbeat") (declarationCoordinate "cancelled-sibling")
                    parentBody = parentCancellationWorkflow parentSession supervisor

                parked <- runAppIO appEnv (runWorkflow parentWorkflowName parentWorkflowId parentBody)
                assertEqual "cancelling collector parks on the failure-first child" (Right Suspended) parked
                failureRun <- runAppIO appEnv (runChildWorkflow defaultWorkflowRunOptions agentRunWorkflowName failureId (agentRunWorkflow deps Nothing))
                assertChildFailed "failure-first child records its typed result" failureRun
                resumed <- runAppIO appEnv (runWorkflow parentWorkflowName parentWorkflowId parentBody)
                case resumed of
                  Right (Completed [Left failure, Left cancellation]) -> do
                    assertBool "the first result records the child failure" ("DelegatedChildFailed" `Text.isPrefixOf` failure)
                    assertEqual "the sibling result says why it was cancelled" "delegated child cancelled after sibling failure" cancellation
                  other -> assertFailure ("cancellation collector should return two failures, got " <> show other)
                cancelledChild <- runAppIO appEnv (runChildWorkflow defaultWorkflowRunOptions agentRunWorkflowName siblingId (agentRunWorkflow deps Nothing))
                assertEqual "the sibling workflow carries Keiro's cancelled marker" (Right Cancelled) cancelledChild
        ],
      testGroup
        "Approval"
        [ testCase "generated job, restart, approval, evidence and delivery converge" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                asks <- newIORef []
                remote <- newIORef Map.empty
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                testWithApplication (pure (\request respond -> if take 2 (pathInfo request) == ["v1", "sources"] then kawaDoorwayApplication remote request respond else approvalDanwaApplication asks request respond)) \port -> do
                  let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                      danwaConfig = DanwaConfig {baseUrl = localApprovalBaseUrl port, agentParticipant = "part_agent_test"}
                      kizashiConfig = KizashiConfig {baseUrl = "http://127.0.0.1:1", defaultRecipient = "recipient:test"}
                  sinkHttp <- testSinkHttpFor danwaConfig
                  let notifier = ApprovalNotification.approvalNotifier Log.silentLogger sinkHttp danwaConfig kizashiConfig
                      deps =
                        (testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks [decl])
                          { approvalPolicy =
                              ApprovalPolicySnapshot
                                { requireFor = Set.singleton SKawaDigest,
                                  channel = ViaDanwa,
                                  deadline = either (error . show) id (parseDuration 60)
                                },
                            approvalWorkflow = ApprovalWorkflow.ApprovalWorkflowEnv {ApprovalWorkflow.notifier = notifier},
                            danwa = danwaConfig,
                            http = sinkHttp,
                            deliveryPool = Just kirokuStore.pool,
                            kawa = KawaConfig {baseUrl = localApprovalBaseUrl port, sourceSegment = "shinzui/shikigami"}
                          }

                  let consume dependencies expected = Job.withJobRuntime connStr Nothing \runtime -> do
                        _ <- either (assertFailure . show) pure =<< Enqueue.ensureRunQueue runtime.runtimePool
                        _ <- either (assertFailure . show) pure =<< Enqueue.enqueueRunJob runtime.runtimePool approvalJob
                        observed <- newIORef (0 :: Int)
                        outcome <- Job.runJobEff runtime do
                          Job.ensureJobQueue RunJobs.runJob
                          Job.runJobOnce 1 RunJobs.runJob \queued -> do
                            result <- liftIO (runAgentRunWorkflow dependencies queued)
                            liftIO do
                              expected result
                              modifyIORef' observed (+ 1)
                            pure Job.Done
                        either (assertFailure . show) pure outcome
                        assertEqual "one job consumed" 1 =<< readIORef observed
                  consume deps (assertEqual "parent parks on approval child" (Right Suspended))
                  parentSteps <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (runJobWorkflowId approvalJob) 0)
                  assertEqual "fresh parent journals its policy" (Right True) (Map.member "resolve-approval-policy" <$> parentSteps)
                  children <- runAppIO appEnv (lookupChildrenOfParent (runJobWorkflowId approvalJob).unWorkflowId "shikigami.agent-run")
                  child <- case children of
                    Right [row] -> pure row
                    other -> assertFailure ("expected one approval child relation, got " <> show other)

                  driveApprovalChildToPark appEnv deps
                  posted <- readIORef asks
                  message <- case posted of
                    [single] -> pure single
                    other -> assertFailure ("expected one Danwa ask, got " <> show other)
                  assertBool "ask carries stable review id" (childId child `Text.isInfixOf` message)
                  awakeableId <- either (assertFailure . Text.unpack) pure (approvalTokenFromMessage message)

                  childSteps <- runAppIO appEnv (loadStepIndex ApprovalWorkflow.approvalWorkflowName (WorkflowId (childId child)) 0)
                  assertEqual "child records the static notify step" (Right True) (Map.member "notify" <$> childSteps)
                  assertEqual "child allocates the static decision awakeable" (Right True) (Map.member "awkid:decision" <$> childSteps)

                  -- Recreate the volatile behavior environment before resuming;
                  -- journals, queue and published token remain in PostgreSQL.
                  restartedBehavior <- newBehaviorEnv
                  let restarted = (deps & #behaviorEnv .~ (restartedBehavior))
                  resolved <- resolveApproval appEnv awakeableId (Approved (object ["approved" .= True]))
                  assertBool "first CLI-shaped signal resolves" resolved
                  resolvedAgain <- resolveApproval appEnv awakeableId (Approved (object ["approved" .= True]))
                  assertEqual "repeated signal is idempotently refused" False resolvedAgain
                  completedCount <- resumeApprovalToCompletion appEnv restarted
                  assertEqual "resume passes complete child and parent" 2 completedCount

                  afterOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                  assertEqual "approved sink is dispatched exactly once" (Right 1) (length <$> afterOutbox)
                  row <- case afterOutbox of
                    Right [single] -> pure single
                    other -> assertFailure (show other)
                  firstPublish <- runEff (publishSinkIntent restarted row)
                  assertEqual "approved intent reaches doorway" Outbox.PublishSucceeded firstPublish
                  consume restarted \case
                    Right (Completed (Right _)) -> pure ()
                    other -> assertFailure ("redelivery did not replay completion: " <> show other)
                  assertEqual "redelivered signal remains consumed" False =<< resolveApproval appEnv awakeableId (Approved (object []))
                  assertEqual "receipt prevents another send" Outbox.PublishSucceeded =<< runEff (publishSinkIntent restarted row)
                  assertEqual "one remote logical effect" 1 . Map.size =<< readIORef remote
                  finalOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                  assertEqual "replayed job emits no second intent" (Right 1) (length <$> finalOutbox)
                  completeScenarioEvidence connStr (runCorrelationId (runJobWorkflowId approvalJob).unWorkflowId) approvalJob.idempotencyKey,
          testCase "approved answer resumes and dispatches sink once" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                aidRef <- newIORef Nothing
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    deps = testDepsWithApproval appEnv behaviorEnv defaultAgentRunHooks (approvalEnv aidRef)

                parked <- runAgentRunWorkflow deps approvalJob
                case parked of
                  Right Suspended -> pure ()
                  other -> assertEqual "workflow parks for approval" "Suspended" (show other)

                let registry = Registry.workflowRegistry deps (testConversationEnv appEnv behaviorEnv [conversationDecl])
                assertEqual
                  "production registry covers all five families"
                  ["shikigami.agent-run", "shikigami.approval", "shikigami.danwa-conversation", "shikigami.execution", "shikigami.worker-session"]
                  (map unWorkflowName (Map.keys registry))
                driveApprovalChildToPark appEnv deps
                pending <- runAppIO appEnv countPendingAwakeables
                assertEqual "one awakeable is pending while parked" (Right 1) pending
                beforeOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "sink is not dispatched before approval" (Right 0) (length <$> beforeOutbox)

                now <- getCurrentTime
                protected <- runAppIO appEnv (Gc.listWorkflowGcCandidates (addUTCTime (91 * 86400) now) terminalWorkflowRetention)
                assertEqual "even old live parent and approval child are not collectible" (Right []) protected
                aid <- readCapturedAwakeable aidRef
                resolved <- resolveApproval appEnv aid (Approved (object ["approved" .= True]))
                assertBool "approval signal resolves the awakeable" resolved
                completedCount <- resumeApprovalToCompletion appEnv deps
                assertEqual "resume passes complete child and parent" 2 completedCount

                afterOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "approved sink is dispatched once" (Right 1) (length <$> afterOutbox)
                recent <- runAppIO appEnv (Gc.listWorkflowGcCandidates now terminalWorkflowRetention)
                assertEqual "newly terminal instances retain their journals" (Right []) recent
                collected <- runAppIO appEnv (Gc.gcWorkflowsOnce (addUTCTime (91 * 86400) now) terminalWorkflowRetention)
                assertEqual "expired terminal parent and approval child are collected" (Right 2) ((.deleted) <$> collected),
          testCase "rejected answer resumes and suppresses sink dispatch" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                aidRef <- newIORef Nothing
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    deps = testDepsWithApproval appEnv behaviorEnv defaultAgentRunHooks (approvalEnv aidRef)

                parked <- runAgentRunWorkflow deps rejectedJob
                case parked of
                  Right Suspended -> pure ()
                  other -> assertEqual "workflow parks for approval" "Suspended" (show other)

                driveApprovalChildToPark appEnv deps
                aid <- readCapturedAwakeable aidRef
                resolved <- resolveApproval appEnv aid (Rejected "not approved")
                assertBool "rejection signal resolves the awakeable" resolved
                completedCount <- resumeApprovalToCompletion appEnv deps
                assertEqual "resume passes complete child and parent" 2 completedCount

                afterOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "rejected sink is suppressed" (Right 0) (length <$> afterOutbox),
          testCase "permanent notification failure fails the parent without enqueuing" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    runJob = (approvalJob & #idempotencyKey .~ (fixtureRunKey "heartbeat:test-approval-notify-permanent"))
                    deps =
                      (testDepsWithApproval appEnv behaviorEnv defaultAgentRunHooks defaultApprovalEnv)
                        { approvalWorkflow =
                            ApprovalWorkflow.ApprovalWorkflowEnv
                              { ApprovalWorkflow.notifier =
                                  ApprovalWorkflow.ApprovalNotifier
                                    { ApprovalWorkflow.recordPark = \_ _ _ _ -> pure (),
                                      ApprovalWorkflow.postAsk = \_ _ _ _ -> pure (Left (ApprovalWorkflow.PermanentNotification "forbidden"))
                                    }
                              }
                        }

                runAgentRunWorkflow deps runJob >>= assertEqual "parent initially parks" (Right Suspended)
                completedCount <- resumeApprovalToCompletion appEnv deps
                assertEqual "permanent failure completes child and parent" 2 completedCount
                parentSteps <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (runJobWorkflowId runJob) 0)
                assertEqual "parent records fail-session" (Right True) (Map.member "fail-session" <$> parentSteps)
                child <- onlyApprovalChild appEnv runJob
                childSteps <- runAppIO appEnv (loadStepIndex ApprovalWorkflow.approvalWorkflowName (WorkflowId (childId child)) 0)
                assertEqual "permanent notify outcome is journaled" (Right True) (Map.member "notify" <$> childSteps)
                outbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "failed notification enqueues no sink" (Right 0) (length <$> outbox),
          testCase "transient notification failure leaves notify unrecorded and increments child attempts" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                posts <- newIORef (0 :: Int)
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    runJob = (approvalJob & #idempotencyKey .~ (fixtureRunKey "heartbeat:test-approval-notify-transient"))
                    deps =
                      (testDepsWithApproval appEnv behaviorEnv defaultAgentRunHooks defaultApprovalEnv)
                        { approvalWorkflow =
                            ApprovalWorkflow.ApprovalWorkflowEnv
                              { ApprovalWorkflow.notifier =
                                  ApprovalWorkflow.ApprovalNotifier
                                    { ApprovalWorkflow.recordPark = \_ _ _ _ -> pure (),
                                      ApprovalWorkflow.postAsk = \_ _ _ _ -> do
                                        modifyIORef' posts (+ 1)
                                        pure (Left (ApprovalWorkflow.TransientNotification "temporarily unavailable"))
                                    }
                              }
                        }

                runAgentRunWorkflow deps runJob >>= assertEqual "parent initially parks" (Right Suspended)
                resumeOutcome <- runAppIO appEnv (resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps))
                case resumeOutcome of
                  Right ResumeSummary {resumed} -> assertBool "resume attempted the transiently failing child" (resumed > 0)
                  other -> assertFailure ("transient child resume failed unexpectedly: " <> show other)
                readIORef posts >>= assertEqual "one notification attempt ran" 1
                child <- onlyApprovalChild appEnv runJob
                childSteps <- runAppIO appEnv (loadStepIndex ApprovalWorkflow.approvalWorkflowName (WorkflowId (childId child)) 0)
                assertEqual "transient notify has no journal result" (Right False) (Map.member "notify" <$> childSteps)
                instanceResult <- runAppIO appEnv (lookupInstance ApprovalWorkflow.approvalWorkflowName (WorkflowId (childId child)))
                case instanceResult of
                  Right (Just row) -> assertEqual "child attempt count increments" 1 (attempts row)
                  other -> assertFailure ("approval child instance missing: " <> show other)
                outbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "transient notification enqueues no sink" (Right 0) (length <$> outbox),
          testCase "notification retry reuses one review identity and one decision token" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \_kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                attemptsRef <- newIORef (0 :: Int)
                posts <- newIORef []
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    runJob = (approvalJob & #idempotencyKey .~ (fixtureRunKey "heartbeat:test-approval-notify-crash-window"))
                    notifier =
                      ApprovalWorkflow.ApprovalNotifier
                        { ApprovalWorkflow.recordPark = \_ _ _ _ -> pure (),
                          ApprovalWorkflow.postAsk = \reviewId awakeableId _ _ -> do
                            attempt <- atomicModifyIORef' attemptsRef \count -> let next = count + 1 in (next, next)
                            modifyIORef' posts ((reviewId, awakeableId) :)
                            pure
                              if attempt == 1
                                then Left (ApprovalWorkflow.TransientNotification "accepted remotely before local commit")
                                else Right ()
                        }
                    childEnv = ApprovalWorkflow.ApprovalWorkflowEnv {ApprovalWorkflow.notifier = notifier}
                    deps =
                      (testDepsWithApproval appEnv behaviorEnv defaultAgentRunHooks defaultApprovalEnv)
                        { approvalWorkflow = childEnv
                        }

                runAgentRunWorkflow deps runJob >>= assertEqual "parent initially parks" (Right Suspended)
                child <- onlyApprovalChild appEnv runJob
                let runChild =
                      runAppIO appEnv $
                        runChildWorkflow
                          defaultWorkflowRunOptions
                          ApprovalWorkflow.approvalWorkflowName
                          (WorkflowId (childId child))
                          (ApprovalWorkflow.approvalWorkflow childEnv Nothing)

                firstAttempt <- try @ApprovalWorkflow.ApprovalNotificationTransientFailure runChild
                case firstAttempt of
                  Left (ApprovalWorkflow.ApprovalNotificationTransientFailure detail) ->
                    assertEqual "first attempt models the post/commit crash window" "accepted remotely before local commit" detail
                  Right other -> assertFailure ("first notification attempt should fail transiently, got " <> show other)
                runChild >>= assertEqual "retry posts and then parks" (Right Suspended)

                recordedPosts <- reverse <$> readIORef posts
                awakeableId <- case recordedPosts of
                  [firstPost, secondPost] -> do
                    assertEqual "retry preserves review id and awakeable token" firstPost secondPost
                    pure (snd firstPost)
                  other -> assertFailure ("expected two notification posts, got " <> show other)

                resolveApproval appEnv awakeableId (Approved (object ["approved" .= True]))
                  >>= assertEqual "one decision wins" True
                resolveApproval appEnv awakeableId (Rejected "too late")
                  >>= assertEqual "later conflicting decision loses" False
                completedCount <- resumeApprovalToCompletion appEnv deps
                assertEqual "child and parent complete after the winning decision" 2 completedCount
                outbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "the approved sink is still dispatched exactly once" (Right 1) (length <$> outbox)
        ],
      testGroup
        "Deadline"
        [ testCase "timeout resumes and suppresses sink dispatch" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                aidRef <- newIORef Nothing
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    deps = testDepsWithApprovalAndDeadline appEnv behaviorEnv defaultAgentRunHooks (approvalEnv aidRef) (Just (secondsToNominalDiffTime 1))

                parked <- runAgentRunWorkflow deps timeoutJob
                case parked of
                  Right Suspended -> pure ()
                  other -> assertEqual "workflow parks for approval deadline" "Suspended" (show other)

                driveApprovalChildToPark appEnv deps
                fireDueApprovalTimer appEnv
                completedCount <- resumeApprovalToCompletion appEnv deps
                assertEqual "resume passes complete child and parent" 2 completedCount

                afterOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "timed-out sink is suppressed" (Right 0) (length <$> afterOutbox),
          testCase "approved answer before deadline wins over late timer" do
            (withShikigamiFreshDatabase databaseFixture) \connStr ->
              withStore (defaultConnectionSettings connStr) \kirokuStore -> do
                tracer <- noopTracer
                behaviorEnv <- newBehaviorEnv
                aidRef <- newIORef Nothing
                let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connStr, tracer, metrics = Nothing, store = Nothing}
                    deps = testDepsWithApprovalAndDeadline appEnv behaviorEnv defaultAgentRunHooks (approvalEnv aidRef) (Just (secondsToNominalDiffTime 1))

                parked <- runAgentRunWorkflow deps answeredBeforeDeadlineJob
                case parked of
                  Right Suspended -> pure ()
                  other -> assertEqual "workflow parks for approval deadline" "Suspended" (show other)

                driveApprovalChildToPark appEnv deps
                aid <- readCapturedAwakeable aidRef
                resolved <- resolveApproval appEnv aid (Approved (object ["approved" .= True]))
                assertBool "approval signal resolves before deadline" resolved
                fireDueApprovalTimer appEnv
                completedCount <- resumeApprovalToCompletion appEnv deps
                assertEqual "resume passes complete child and parent" 2 completedCount

                afterOutbox <- runAppIO appEnv (listOutbox "shinzui/shikigami")
                assertEqual "approved sink still dispatches once" (Right 1) (length <$> afterOutbox)
        ]
    ]

parentDelegateWorkflow :: SessionId -> Eff (Workflow : AppEffects) Value
parentDelegateWorkflow currentSession = do
  delegated <-
    delegate
      [decl]
      disabledDirectoryHandle
      ((decl & #delegates .~ (map fixtureAgentName ["heartbeat"])))
      (parentDelegateContext currentSession)
      (declarationCoordinate "heartbeat")
      (fixtureAgentName "heartbeat")
      (object ["source" .= ("delegate-test" :: Text)])
  awaitDelegated delegated

parentCollectWorkflow :: SessionId -> AgentDecl -> Eff (Workflow : AppEffects) [Either Text Value]
parentCollectWorkflow currentSession supervisor = do
  success <- delegate [decl, missingTaskDecl] disabledDirectoryHandle supervisor (parentDelegateContext currentSession) (declarationCoordinate "success") (fixtureAgentName "heartbeat") (object [])
  failure <- delegate [decl, missingTaskDecl] disabledDirectoryHandle supervisor (parentDelegateContext currentSession) (declarationCoordinate "failure") (fixtureAgentName "missing-task-agent") (object [])
  awaitAllDelegated [success, failure]

parentCancellationWorkflow :: SessionId -> AgentDecl -> Eff (Workflow : AppEffects) [Either Text Value]
parentCancellationWorkflow currentSession supervisor = do
  failure <- delegate [decl, missingTaskDecl] disabledDirectoryHandle supervisor (parentDelegateContext currentSession) (declarationCoordinate "failure-first") (fixtureAgentName "missing-task-agent") (object [])
  sibling <- delegate [decl, missingTaskDecl] disabledDirectoryHandle supervisor (parentDelegateContext currentSession) (declarationCoordinate "cancelled-sibling") (fixtureAgentName "heartbeat") (object [])
  cancelSiblingsOnFailure [failure, sibling]

parentDelegateContext :: SessionId -> DelegateCtx
parentDelegateContext currentSession =
  DelegateCtx
    { identity = compatibilityIdentity (fixtureAgentName "test-parent"),
      depth = fixtureDelegationDepth 0,
      sessionId = Just currentSession,
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      lineage = map fixtureAgentName ["test-parent"],
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing,
      budgetLimit = defaultDelegationBudget
    }

verifiedAgentIdentity :: Text -> ResolvedAgentIdentity
verifiedAgentIdentity raw = VerifiedAgent (either (error . Text.unpack) id (mkAgentPrincipal raw))

testDeps :: AppEnv -> BehaviorEnv -> AgentRunHooks -> AgentRunDeps
testDeps appEnv behaviorEnv hooks =
  testDepsWithAgents appEnv behaviorEnv hooks [decl]

testDepsWithAgents :: AppEnv -> BehaviorEnv -> AgentRunHooks -> [AgentDecl] -> AgentRunDeps
testDepsWithAgents appEnv behaviorEnv hooks agentDecls =
  AgentRunDeps
    { appEnv,
      behaviorEnv,
      decisions = FlowDecision.emptyDecisionServices,
      actionAuthorizer = allowAllActionAuthorizerForTests,
      capabilities = CapabilityProvider.emptyCapabilityRuntime,
      coordination = Nothing,
      workspace = Nothing,
      agents = agentDecls,
      kizashi = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "recipient"},
      kawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = "shinzui/shikigami"},
      kanmon = KanmonConfig {baseUrl = "http://localhost:1"},
      danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_test"},
      rei = ReiConfig {baseUrl = Nothing},
      http = testSinkHttp,
      hooks,
      approvalPolicy = autoApprovePolicy (either (error . show) id (parseDuration 900)),
      approvalWorkflow = ApprovalWorkflow.defaultApprovalWorkflowEnv,
      runTimeout = (either (error . show) id (parseDuration (secondsToNominalDiffTime 300))),
      harness = Harness.defaultHarnessPolicy,
      delegationBudget = defaultDelegationBudget,
      logger = Log.silentLogger,
      grants = StaticGrants defaultGrantTable,
      directory = disabledDirectoryHandle,
      routing = testRoutingRuntime agentDecls,
      practiceReview = PracticeReviewCapability.unavailablePracticeReviewRuntime,
      deliveryPool = Nothing,
      resolveRunProfile = \profileId version -> pure (Left (UnknownProfile profileId version))
    }

testDepsWithApproval :: AppEnv -> BehaviorEnv -> AgentRunHooks -> (SessionId -> ApprovalEnv) -> AgentRunDeps
testDepsWithApproval appEnv behaviorEnv hooks approval =
  testDepsWithApprovalAndDeadline appEnv behaviorEnv hooks approval Nothing

testDepsWithApprovalAndDeadline :: AppEnv -> BehaviorEnv -> AgentRunHooks -> (SessionId -> ApprovalEnv) -> Maybe NominalDiffTime -> AgentRunDeps
testDepsWithApprovalAndDeadline appEnv behaviorEnv hooks approval deadline =
  AgentRunDeps
    { appEnv,
      behaviorEnv,
      decisions = FlowDecision.emptyDecisionServices,
      actionAuthorizer = allowAllActionAuthorizerForTests,
      capabilities = CapabilityProvider.emptyCapabilityRuntime,
      coordination = Nothing,
      workspace = Nothing,
      agents = [decl],
      kizashi = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "recipient"},
      kawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = "shinzui/shikigami"},
      kanmon = KanmonConfig {baseUrl = "http://localhost:1"},
      danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_test"},
      rei = ReiConfig {baseUrl = Nothing},
      http = testSinkHttp,
      hooks,
      approvalPolicy =
        ApprovalPolicySnapshot
          { requireFor = Set.singleton SKawaDigest,
            channel = ViaDanwa,
            deadline = either (error . show) id (parseDuration (fromMaybe (secondsToNominalDiffTime 900) deadline))
          },
      approvalWorkflow = approvalWorkflowFromLegacy approval,
      runTimeout = (either (error . show) id (parseDuration (secondsToNominalDiffTime 300))),
      harness = Harness.defaultHarnessPolicy,
      delegationBudget = defaultDelegationBudget,
      logger = Log.silentLogger,
      grants = StaticGrants defaultGrantTable,
      directory = disabledDirectoryHandle,
      routing = testRoutingRuntime [decl],
      practiceReview = PracticeReviewCapability.unavailablePracticeReviewRuntime,
      deliveryPool = Nothing,
      resolveRunProfile = \profileId version -> pure (Left (UnknownProfile profileId version))
    }

testRoutingRuntime :: [AgentDecl] -> Routing.RoutingRuntime
testRoutingRuntime declarations =
  Routing.routingRuntime
    ( AgentLoadReport
        [ AgentLoaded ("agent-" <> show position <> ".dhall") declaration
        | (position, declaration) <- zip [(1 :: Int) ..] declarations
        ]
    )
    disabledDirectoryHandle

approvalEnv :: IORef (Maybe AwakeableId) -> SessionId -> ApprovalEnv
approvalEnv aidRef currentSession =
  ApprovalEnv
    { currentSession,
      requiresApproval = \_ kind _ ->
        pure
          if kind == SKawaDigest
            then ApprovalRequired approvalRequest
            else ApprovalNotRequired,
      recordPark = \_ aid _ -> writeIORef aidRef (Just aid),
      postAsk = \_ _ _ -> pure ()
    }

approvalWorkflowFromLegacy :: (SessionId -> ApprovalEnv) -> ApprovalWorkflow.ApprovalWorkflowEnv
approvalWorkflowFromLegacy approvalFor =
  ApprovalWorkflow.ApprovalWorkflowEnv
    { ApprovalWorkflow.notifier =
        ApprovalWorkflow.ApprovalNotifier
          { ApprovalWorkflow.recordPark = \session _ aid request ->
              (.recordPark) (approvalFor session) session aid request,
            ApprovalWorkflow.postAsk = \_ _ _ _ -> pure (Right ())
          }
    }

approvalRequest :: ApprovalRequest
approvalRequest =
  ApprovalRequest
    { prompt = "Dispatch heartbeat digest?",
      context = object ["source" .= ("test" :: Text)],
      channel = ViaDanwa
    }

readCapturedAwakeable :: IORef (Maybe AwakeableId) -> IO AwakeableId
readCapturedAwakeable aidRef =
  readIORef aidRef >>= \case
    Just aid -> pure aid
    Nothing -> ioError (userError "approval park should capture awakeable id")

loadProofAgents :: IO [AgentDecl]
loadProofAgents = do
  results <-
    traverse
      loadAgent
      [ "../agents/proof/research-supervisor.dhall",
        "../agents/proof/web-researcher.dhall",
        "../agents/proof/code-researcher.dhall"
      ]
  case sequence results of
    Right loaded -> pure loaded
    Left err -> assertFailure ("proof agents should load: " <> show err)

assertChildCompleted :: String -> Either err (WorkflowOutcome (Either AgentRunFailure AgentRunResult)) -> IO ()
assertChildCompleted label = \case
  Right (Completed (Right _)) -> pure ()
  other -> assertFailure (label <> ", got " <> show (first (const ("store-error" :: String)) other))

assertChildFailed :: String -> Either err (WorkflowOutcome (Either AgentRunFailure AgentRunResult)) -> IO ()
assertChildFailed label = \case
  Right (Completed (Left _)) -> pure ()
  other -> assertFailure (label <> ", got " <> show (first (const ("store-error" :: String)) other))

lineageSummary :: [SessionRow] -> Set.Set (Text, Maybe Text, Int)
lineageSummary rows =
  Set.fromList
    [ (agentId, parentSessionId, delegationDepth)
    | SessionRow {agentId, parentSessionId, delegationDepth} <- rows
    ]

childLinkSummary :: [ChildRow] -> Set.Set (Text, Text, Text)
childLinkSummary rows =
  Set.fromList
    [ (childName, childId, childStatusText status)
    | ChildRow {childName, childId, status} <- rows
    ]

childStatusText :: ChildStatus -> Text
childStatusText = \case
  Running -> "running"
  ChildCompleted -> "completed"
  ChildCancelled -> "cancelled"
  ChildFailed -> "failed"

onlyApprovalChild :: AppEnv -> RunJob -> IO ChildRow
onlyApprovalChild appEnv runJob = do
  children <- runAppIO appEnv (lookupChildrenOfParent (runJobWorkflowId runJob).unWorkflowId "shikigami.agent-run")
  case children of
    Right [child] -> pure child
    other -> assertFailure ("expected one approval child, got " <> show other)

-- | The conversation environment every Conversation case runs against.
--
-- Named rather than repeated per case because there are now several cases and
-- the interesting differences between them are the agent list and the idle
-- window, not the six fields they all share.
-- | One generation's step index for the given epoch of a conversation.
conversationStepKeys :: AppEnv -> AddressedMessage -> Int -> IO (Map Text Value)
conversationStepKeys = conversationStepKeysAt 0

conversationStepKeysAt :: Int -> AppEnv -> AddressedMessage -> Int -> IO (Map Text Value)
conversationStepKeysAt epoch appEnv msg generation = do
  loaded <- runAppIO appEnv (loadStepIndex Conversation.conversationWorkflowName (Conversation.conversationWorkflowId epoch msg) generation)
  case loaded of
    Right keys -> pure keys
    Left err -> assertFailure ("loadStepIndex failed: " <> show err)

testConversationEnv :: AppEnv -> BehaviorEnv -> [AgentDecl] -> Conversation.ConversationEnv
testConversationEnv appEnv behaviorEnv conversationAgents =
  testConversationEnvIdle (secondsToNominalDiffTime 1800) appEnv behaviorEnv conversationAgents

-- | As 'testConversationEnv', with the idle window under the test's control.
--
-- The idle cases arm a timer and then fire it by hand rather than waiting, so
-- the window they pass is only what the armed row's fireAt records.
testConversationEnvIdle :: NominalDiffTime -> AppEnv -> BehaviorEnv -> [AgentDecl] -> Conversation.ConversationEnv
testConversationEnvIdle idleWindow appEnv behaviorEnv conversationAgents =
  Conversation.ConversationEnv
    { Conversation.appEnv = appEnv,
      Conversation.behaviorEnv = behaviorEnv,
      Conversation.decisions = FlowDecision.emptyDecisionServices,
      Conversation.deliveryPool = Nothing,
      Conversation.resolveRunProfile = (testDepsWithAgents appEnv behaviorEnv defaultAgentRunHooks conversationAgents).resolveRunProfile,
      Conversation.runTimeout = (either (error . show) id (parseDuration (secondsToNominalDiffTime 300))),
      Conversation.harness = Harness.defaultHarnessPolicy,
      Conversation.idleTimeout = either (error . show) id (parseDuration idleWindow),
      Conversation.danwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_test"},
      Conversation.agents = conversationAgents,
      Conversation.grants = StaticGrants defaultGrantTable,
      Conversation.directory = disabledDirectoryHandle
    }

-- | A running session in the same agent scope under a different subject.
--
-- This is the row the pre-index resolver had to walk past on every single turn:
-- 'Kioku.Session.getByScope' returns every session the agent has ever had, and
-- resolution then scanned them for a @subjectRef@ match. The decoy makes "we
-- selected the right session" a claim with something to be wrong about.
startDecoyConversationSession :: AppEnv -> Text -> Text -> IO SessionId
startDecoyConversationSession appEnv agentName decoyConversationId = do
  now <- getCurrentTime
  sid <- genSessionId
  let recordedIdentity = CompatibilityAgent (fixtureAgentName agentName)
  result <-
    runAppIO appEnv $
      Session.start
        StartSessionData
          { sessionId = sid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor recordedIdentity,
            ownerPrincipal = Nothing,
            agentId = agentName,
            focus = "conversation",
            scope = agentScope recordedIdentity,
            subjectRef = Just decoyConversationId,
            previousSessionId = Nothing,
            parentSessionId = Nothing,
            delegationDepth = 0,
            startedAt = now
          }
  case result of
    Right (Right _) -> pure sid
    other -> assertFailure ("decoy session should start, got " <> show (first (const ("store-error" :: String)) other))

-- | Every running session in this agent's scope whose subject is this
-- conversation.
runningSessionsFor :: AppEnv -> Text -> Text -> IO [Text]
runningSessionsFor appEnv agentName wantedConversationId = do
  rows <- runAppIO appEnv (Session.getByScope shikigamiMemorySpace (agentScope (CompatibilityAgent (fixtureAgentName agentName))))
  case rows of
    Right (Right allRows) ->
      pure
        [ sessionId
        | SessionRow {sessionId, subjectRef, status} <- allRows,
          subjectRef == Just wantedConversationId,
          status == "running"
        ]
    other -> assertFailure ("getByScope should succeed, got " <> show (first (const ("store-error" :: String)) other))

turnRoleIndex :: TurnRow -> (Text, Int)
turnRoleIndex TurnRow {role, turnIndex} = (role, turnIndex)

-- | Run resume passes until the conversation stops making progress.
--
-- Two passes is the ordinary number: one in which the resolved promise rotates
-- the generation shut, and one in which the new generation runs its turn and
-- parks. Draining rather than counting keeps the test about the outcome.
drainConversationResumes :: AppEnv -> Conversation.ConversationEnv -> IO Int
drainConversationResumes appEnv env = go (0 :: Int) (8 :: Int)
  where
    go total 0 = pure total
    go total budget = do
      summary <- runAppIO appEnv (resumeConversationOnce appEnv env)
      case summary of
        Right ResumeSummary {advanced} | advanced > 0 -> go (total + advanced) (budget - 1)
        _ -> pure total

-- | One resume pass over the conversation registry, configured the way
-- production configures it.
--
-- Run and resume share the service's options construction site.
resumeConversationOnce :: AppEnv -> Conversation.ConversationEnv -> Eff AppEffects ResumeSummary
resumeConversationOnce appEnv env =
  resumeWorkflowsOnce
    (shikigamiWorkflowResumeOptions appEnv (secondsToNominalDiffTime 300))
    (Conversation.conversationRegistry env)

-- | Fire a due conversation idle-timeout timer through the same one loop the
-- runtime uses. Returns whether a row fired.
-- | Drain due timers until the conversation idle timer is the one that fires.
--
-- __Not a single pass, and the reason is worth knowing.__ Recording a turn also
-- schedules a kioku L1 distillation timer (@kind: "ramp"@, written by
-- @l1TimerScheduleProjection@ in the same transaction as the assistant turn), so
-- a parked conversation has more than one due row. 'runWorkflowTimerWorker'
-- claims exactly one per call, ordered by @fire_at@, and a row whose fire action
-- declines it is left in @firing@ — which the claim query skips, so it costs one
-- pass and does not spin. Draining is therefore how a test reaches its own timer
-- without depending on which row sorted first.
-- Hold the old timer's claimed row while its workflow rotates. Other timer
-- kinds belong to their existing owners and are irrelevant in this fixture.
captureConversationIdleTimer :: AppEnv -> IO Timer.TimerRow
captureConversationIdleTimer app = go (8 :: Int)
  where
    go 0 = assertFailure "no conversation timer found" >> fail "timer"
    go remaining = do
      now <- getCurrentTime
      claimed <- runAppIO app (Timer.claimDueTimer (addUTCTime 120 now))
      case claimed of
        Right (Just row) -> case row.payload of
          Object fields | KeyMap.lookup "kind" fields == Just (String Conversation.conversationIdleTimeoutKind) -> pure row
          _ -> go (remaining - 1)
        other -> assertFailure (show other) >> fail "timer"

fireDueConversationIdleTimer :: AppEnv -> IO Bool
fireDueConversationIdleTimer appEnv = go (8 :: Int)
  where
    go 0 = pure False
    go budget = do
      now <- getCurrentTime
      ours <- newIORef False
      claimed <-
        runAppIO appEnv $
          runWorkflowTimerWorker Nothing (addUTCTime 120 now) \row -> do
            outcome <- Conversation.conversationIdleTimeoutFireAction row
            unsafeEff_ (writeIORef ours (maybe False (const True) outcome))
            pure outcome
      wasOurs <- readIORef ours
      case claimed of
        Right (Just _) | not wasOurs -> go (budget - 1)
        Right (Just _) -> pure True
        _ -> pure False

-- | One session's lifecycle status and lineage predecessor.
--
-- Returned as a pair rather than the whole row because @status@ is ambiguous
-- under @DuplicateRecordFields@ here -- four imported records carry one.
conversationSessionState :: AppEnv -> SessionId -> IO (Text, Maybe Text)
conversationSessionState appEnv sid = do
  loaded <- runAppIO appEnv (Session.getById shikigamiMemorySpace sid)
  case loaded of
    Right (Right (Just SessionRow {status = rowStatus, previousSessionId = rowPrevious})) -> pure (rowStatus, rowPrevious)
    other -> assertFailure ("getById should return the session, got " <> show (first (const ("store-error" :: String)) other))

fireDueApprovalTimer :: AppEnv -> IO ()
fireDueApprovalTimer appEnv = do
  now <- getCurrentTime
  fired <- runAppIO appEnv (runWorkflowTimerWorker Nothing (addUTCTime 2 now) approvalTimeoutFireAction)
  assertBool "approval timeout timer should fire" (either (const False) (maybe False (const True)) fired)

approvalTokenFromMessage :: Text -> Either Text AwakeableId
approvalTokenFromMessage message = do
  line <- maybe (Left "approval ask has no approve command") Right (find (Text.isPrefixOf prefix) (Text.lines message))
  let token = Text.takeWhile (/= ' ') (Text.drop (Text.length prefix) line)
  uuid <- maybe (Left "approval ask token is not a UUID") Right (UUID.fromText token)
  pure (AwakeableId uuid)
  where
    prefix = "Approve: shikigami resolve-approval "

approvalDanwaApplication :: IORef [Text] -> Application
approvalDanwaApplication asks request respond =
  case (requestMethod request, pathInfo request) of
    ("POST", ["conversations"]) ->
      respond
        ( responseLBS
            status200
            [(hContentType, "application/json")]
            "{\"conversationId\":\"conv_approval\",\"status\":\"active\",\"kind\":\"thread\",\"startedBy\":\"part_agent_test\",\"parentConversationId\":\"\"}"
        )
    ("POST", ["conversations", "conv_approval", "participants"]) -> respond (responseLBS status204 [] "")
    ("POST", ["conversations", "conv_approval", "messages"]) -> do
      body <- strictRequestBody request
      case eitherDecode @Value body of
        Right (Object fields) ->
          case KeyMap.lookup "content" fields of
            Just (String content) -> do
              modifyIORef' asks (content :)
              respond
                ( responseLBS
                    status200
                    [(hContentType, "application/json")]
                    "{\"messageId\":\"msg_approval\",\"conversationId\":\"conv_approval\",\"author\":\"part_agent_test\",\"content\":\"approval\",\"postedAt\":\"2026-08-23T00:00:00Z\"}"
                )
            _ -> respond (responseLBS status400 [] "missing content")
        _ -> respond (responseLBS status400 [] "invalid JSON")
    _ -> respond (responseLBS status404 [] "not found")

localApprovalBaseUrl :: Int -> Text
localApprovalBaseUrl port = "http://127.0.0.1:" <> Text.pack (show port)

driveApprovalChildToPark :: AppEnv -> AgentRunDeps -> IO ()
driveApprovalChildToPark appEnv deps = do
  outcome <- runAppIO appEnv (resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps))
  case outcome of
    Left err -> assertFailure ("approval child resume failed: " <> show err)
    Right report -> assertBool "approval child was discovered and driven" (resumed report > 0)

resumeApprovalToCompletion :: AppEnv -> AgentRunDeps -> IO Int
resumeApprovalToCompletion appEnv deps = do
  firstPass <- runAppIO appEnv (resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps))
  secondPass <- runAppIO appEnv (resumeWorkflowsOnce defaultWorkflowResumeOptions (agentRunRegistry deps))
  case (firstPass, secondPass) of
    (Right firstReport, Right secondReport) -> pure (completed firstReport + completed secondReport)
    other -> assertFailure ("approval resume failed: " <> show other)

-- | The lifecycle step names one agent run journaled, with Keiro's reserved
-- bookkeeping removed so the assertion is about this workflow's own steps.
loadLifecycleStepKeys :: AppEnv -> RunJob -> IO (Either String (Set.Set Text))
loadLifecycleStepKeys appEnv runJob = do
  result <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (runJobWorkflowId runJob) 0)
  pure (first show (Set.delete patchSetStepName . Set.delete completedStepName . Map.keysSet <$> result))

loadProfileResolution :: AppEnv -> RunJob -> IO (Either String (Maybe ResolvedProfile))
loadProfileResolution appEnv runJob = do
  result <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (runJobWorkflowId runJob) 0)
  pure do
    journal <- first show result
    encoded <- maybe (Left "resolve-profile was not journaled") Right (Map.lookup "resolve-profile" journal)
    resolution <- case fromJSON encoded :: Result (Either ProfileResolutionError (Maybe ResolvedProfile)) of
      Success value -> Right value
      Error err -> Left ("cannot decode resolve-profile: " <> err)
    first show resolution

loadCapabilityResolution :: AppEnv -> RunJob -> IO (Either String CapabilityOverlay.ResolvedCapabilitySet)
loadCapabilityResolution appEnv runJob = do
  result <- runAppIO appEnv (loadStepIndex agentRunWorkflowName (runJobWorkflowId runJob) 0)
  pure do
    journal <- first show result
    encoded <- maybe (Left "resolve-capability-overlays was not journaled") Right (Map.lookup "resolve-capability-overlays" journal)
    resolution <- case fromJSON encoded :: Result (Either CapabilityCatalog.CapabilityResolutionError CapabilityOverlay.ResolvedCapabilitySet) of
      Success value -> Right value
      Error err -> Left ("cannot decode resolve-capability-overlays: " <> err)
    first show resolution

data CapabilityTestInput = CapabilityTestInput {value :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema, FromModel)

instance Validatable CapabilityTestInput

data CapabilityTestOutput = CapabilityTestOutput {answer :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

capabilityRuntime ::
  [CapabilityOverlay.CapabilityDescriptor] ->
  [CapabilityProvider.CapabilityProvider] ->
  ( CapabilityCatalog.ResolutionSubject ->
    CapabilityOverlay.CapabilityDescriptor ->
    Either CapabilityCatalog.CapabilityResolutionError ()
  ) ->
  CapabilityProvider.CapabilityRuntime
capabilityRuntime descriptors providers authorize =
  CapabilityProvider.CapabilityRuntime
    { CapabilityProvider.catalog = expectCapabilityRight (CapabilityCatalog.mkCapabilityCatalog descriptors),
      CapabilityProvider.providers = expectCapabilityRight (CapabilityProvider.mkCapabilityProviderRegistry providers),
      CapabilityProvider.authorize = authorize
    }

allowCapability ::
  CapabilityCatalog.ResolutionSubject ->
  CapabilityOverlay.CapabilityDescriptor ->
  Either CapabilityCatalog.CapabilityResolutionError ()
allowCapability _ _ = Right ()

denyCapability ::
  CapabilityCatalog.ResolutionSubject ->
  CapabilityOverlay.CapabilityDescriptor ->
  Either CapabilityCatalog.CapabilityResolutionError ()
denyCapability _ CapabilityOverlay.CapabilityDescriptor {CapabilityOverlay.capability = capabilityId} =
  Left
    CapabilityCatalog.CapabilityAuthorizationDenied
      { CapabilityCatalog.capability = capabilityId,
        CapabilityCatalog.reason = "policy denied"
      }

trackingCapabilityProvider ::
  IORef [Text] ->
  IORef Bool ->
  Text ->
  CapabilityOverlay.CapabilityDescriptor ->
  Either CapabilityProvider.CapabilityReleaseError () ->
  CapabilityProvider.CapabilityProvider
trackingCapabilityProvider events active label descriptor releaseResult =
  CapabilityProvider.CapabilityProvider
    { CapabilityProvider.descriptor = descriptor,
      CapabilityProvider.acquire = \_scope -> do
        writeIORef active True
        recordCapabilityEvent events ("acquire:" <> label)
        pure
          ( Right
              CapabilityProvider.CapabilityLease
                { CapabilityProvider.descriptor = descriptor,
                  CapabilityProvider.tools = [capabilityTestTool (descriptorToolName descriptor)],
                  CapabilityProvider.release = do
                    recordCapabilityEvent events ("release:" <> label)
                    writeIORef active False
                    pure releaseResult
                }
          )
    }

capabilityTestTool :: Text -> SomeTool
capabilityTestTool toolName =
  SomeTool
    ( mkTool toolName "Return the supplied value." \CapabilityTestInput {value} ->
        pure CapabilityTestOutput {answer = value}
    )

descriptorToolName :: CapabilityOverlay.CapabilityDescriptor -> Text
descriptorToolName CapabilityOverlay.CapabilityDescriptor {CapabilityOverlay.tools} =
  case tools of
    CapabilityOverlay.CapabilityToolDescriptor {CapabilityOverlay.name} : _ -> name
    [] -> error "test capability descriptor must declare one tool"

recordCapabilityEvent :: IORef [Text] -> Text -> IO ()
recordCapabilityEvent events event = modifyIORef' events (<> [event])

assertCapabilityEventOrder :: [Text] -> [Text] -> IO ()
assertCapabilityEventOrder observed expected = do
  indices <-
    traverse
      (\event -> maybe (assertFailure ("missing capability event " <> Text.unpack event <> " in " <> show observed)) pure (elemIndex event observed))
      expected
  assertBool
    ("capability events were out of order: " <> show observed)
    (and (zipWith (<) indices (drop 1 indices)))

workspaceReadId :: CapabilityOverlay.CapabilityId
workspaceReadId = expectCapabilityRight (CapabilityOverlay.mkCapabilityId "workspace.read")

workspaceReadV1 :: CapabilityOverlay.CapabilityDescriptor
workspaceReadV1 = capabilityDescriptor "workspace.read" "v1" CapabilityOverlay.Observation

workspaceReadV2 :: CapabilityOverlay.CapabilityDescriptor
workspaceReadV2 = capabilityDescriptor "workspace.read" "v2" CapabilityOverlay.Observation

capabilityDescriptor :: Text -> Text -> CapabilityOverlay.CapabilityOperationClass -> CapabilityOverlay.CapabilityDescriptor
capabilityDescriptor capabilityName revisionName operationClass =
  CapabilityOverlay.CapabilityDescriptor
    { CapabilityOverlay.capability = expectCapabilityRight (CapabilityOverlay.mkCapabilityId capabilityName),
      CapabilityOverlay.revision = expectCapabilityRight (CapabilityOverlay.mkCapabilityRevision revisionName),
      CapabilityOverlay.tools =
        [ CapabilityOverlay.CapabilityToolDescriptor
            { CapabilityOverlay.name = "read",
              CapabilityOverlay.operationClass = operationClass
            }
        ]
    }

descriptorCapability :: CapabilityOverlay.CapabilityDescriptor -> CapabilityOverlay.CapabilityId
descriptorCapability CapabilityOverlay.CapabilityDescriptor {CapabilityOverlay.capability} = capability

overlayIdentity :: IdentityDecl
overlayIdentity = IdentityDecl {principal = declarationCoordinate ("principal_overlay_test")}

capabilityDecl :: Text -> Behavior -> [CapabilityOverlay.CapabilityId] -> Maybe IdentityDecl -> [Sink] -> AgentDecl
capabilityDecl agentName agentBehavior overlays agentIdentity agentSinks =
  AgentDecl
    { name = fixtureAgentName agentName,
      description = "capability overlay workflow test agent",
      trigger = Event {eventType = declarationCoordinate ("test")},
      behavior = agentBehavior,
      sinks = agentSinks,
      delegates = map fixtureAgentName [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = overlays,
      identity = agentIdentity,
      memory = defaultMemoryPolicy,
      enabled = agentEnablement (True),
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

agentDeclNameForTest :: AgentDecl -> Text
agentDeclNameForTest AgentDecl {name = agentName} = agentNameText agentName

capabilityJob :: Text -> Text -> RunJob
capabilityJob agentName key =
  RunJob
    { agentName = fixtureAgentName agentName,
      identity = compatibilityIdentity (fixtureAgentName agentName),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = fixtureRunKey key,
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

expectCapabilityRight :: (Show err) => Either err value -> value
expectCapabilityRight = \case
  Left err -> error (show err)
  Right value -> value

expectedLifecycleSteps :: Set.Set Text
expectedLifecycleSteps =
  Set.fromList
    [ "ingest-job",
      "validate-execution-root",
      "lookup-agent",
      "resolve-profile",
      "resolve-capability-overlays",
      "resolve-execution-selection",
      "resolve-approval-policy",
      "open-session",
      "recall",
      "run-behavior-v2",
      "dispatch-sinks",
      "record",
      "complete"
    ]

isRight' :: Either a b -> Bool
isRight' = either (const False) (const True)

isCompleted :: Either a (WorkflowOutcome (Either failure b)) -> Bool
isCompleted (Right (Completed (Right _))) = True
isCompleted _ = False

decl :: AgentDecl
decl =
  AgentDecl
    { name = fixtureAgentName "heartbeat",
      description = "workflow test agent",
      trigger = Event {eventType = declarationCoordinate ("test")},
      behavior =
        ShikumiProgram
          { task = declarationCoordinate ("noop-summary"),
            preferEnrichment = False,
            grounding = Nothing,
            enabledBy = Nothing
          },
      sinks = [KawaDigest {subjectType = activityCoordinate ("heartbeat"), verb = activityCoordinate ("heartbeat.tick")}],
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

missingTaskDecl :: AgentDecl
missingTaskDecl =
  AgentDecl
    { name = fixtureAgentName "missing-task-agent",
      description = "workflow test agent with a permanent program-input failure",
      trigger = Event {eventType = declarationCoordinate ("test")},
      behavior =
        ShikumiProgram
          { task = declarationCoordinate ("missing-task"),
            preferEnrichment = False,
            grounding = Nothing,
            enabledBy = Nothing
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

profiledDecl :: AgentDecl
profiledDecl =
  AgentDecl
    { name = fixtureAgentName "heartbeat",
      description = "workflow test agent with a sanctioned profile",
      trigger = Event {eventType = declarationCoordinate ("test")},
      behavior =
        ShikumiProgram
          { task = declarationCoordinate ("noop-summary"),
            preferEnrichment = False,
            grounding = Nothing,
            enabledBy = Nothing
          },
      sinks = [KawaDigest {subjectType = activityCoordinate ("heartbeat"), verb = activityCoordinate ("heartbeat.tick")}],
      delegates = map fixtureAgentName [],
      delegationBudget = Nothing,
      sanctionedProfile =
        Just
          ProfileRequirement
            { profileId = ProfileId ("sanctioned-review"),
              version = fmap ProfileVersion (Just "1")
            },
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

profiledSkillDecl :: AgentDecl
profiledSkillDecl =
  AgentDecl
    { name = fixtureAgentName "profiled-skill",
      description = "workflow test skill with a sanctioned profile",
      trigger = Event {eventType = declarationCoordinate ("test")},
      behavior = Skill {path = declarationCoordinate ("agents/skills/triage-note")},
      sinks = [],
      delegates = map fixtureAgentName [],
      delegationBudget = Nothing,
      sanctionedProfile =
        Just
          ProfileRequirement
            { profileId = ProfileId ("sanctioned-review"),
              version = fmap ProfileVersion (Just "1")
            },
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

flowDecl :: AgentDecl
flowDecl =
  AgentDecl
    { name = fixtureAgentName "at-risk-customer",
      description = "workflow flow test agent",
      trigger = Event {eventType = declarationCoordinate ("test")},
      behavior = Flow {name = declarationCoordinate ("at-risk-customer")},
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

profiledFlowDecl :: AgentDecl
profiledFlowDecl =
  flowDecl
    & #name .~ fixtureAgentName "profiled-flow"
    & #sanctionedProfile
      .~ Just
        ProfileRequirement
          { profileId = ProfileId ("sanctioned-review"),
            version = fmap ProfileVersion (Just "1")
          }

flowDelegationDecl :: AgentDecl
flowDelegationDecl =
  AgentDecl
    { name = fixtureAgentName "flow-delegation-supervisor",
      description = "workflow Flow delegation test agent",
      trigger = Event {eventType = declarationCoordinate ("test")},
      behavior = Flow {name = declarationCoordinate ("delegation-proof")},
      sinks = [],
      delegates = map fixtureAgentName ["web-researcher"],
      delegationBudget = Just (either (error . Text.unpack) id (mkDelegationBudget 1)),
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

collectionSupervisorDecl :: AgentDecl
collectionSupervisorDecl =
  (decl & #name .~ (fixtureAgentName "test-collection-supervisor") & #sinks .~ ([]) & #delegates .~ (map fixtureAgentName ["heartbeat", "missing-task-agent"]))

conversationDecl :: AgentDecl
conversationDecl =
  (decl & #trigger .~ (Event {eventType = declarationCoordinate (addressedMessageEventType)}) & #sinks .~ ([DanwaConversation {topic = "support"}]))

withRecordPolicy :: RecordPolicy -> AgentDecl -> AgentDecl
withRecordPolicy recordPolicy = #memory . #recordPolicy .~ recordPolicy

firstAddressedMessage :: AddressedMessage
firstAddressedMessage =
  AddressedMessage
    { conversationId = "conv_thread_1",
      messageId = "msg_human_1",
      parentMessageId = Nothing,
      author = "part_human_test",
      content = "first question",
      agentParticipantId = "part_agent_test",
      embellishmentId = "emb_human_1",
      mentionedBy = "part_human_test",
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0
    }

secondAddressedMessage :: AddressedMessage
secondAddressedMessage =
  AddressedMessage
    { conversationId = "conv_thread_1",
      messageId = "msg_human_2",
      parentMessageId = Just "msg_human_1",
      author = "part_human_test",
      content = "follow up",
      agentParticipantId = "part_agent_test",
      embellishmentId = "emb_human_2",
      mentionedBy = "part_human_test",
      occurredAt = UTCTime (fromGregorian 2026 6 27) 1
    }

-- | The Nth human message of one long conversation.
conversationMessageNumbered :: Int -> AddressedMessage
conversationMessageNumbered n =
  AddressedMessage
    { conversationId = "conv_rotation",
      messageId = "msg_rotation_" <> Text.pack (show n),
      parentMessageId = if n == 1 then Nothing else Just ("msg_rotation_" <> Text.pack (show (n - 1))),
      author = "part_human_test",
      content = "question " <> Text.pack (show n),
      agentParticipantId = "part_agent_test",
      embellishmentId = "emb_rotation_" <> Text.pack (show n),
      mentionedBy = "part_human_test",
      occurredAt = UTCTime (fromGregorian 2026 6 27) (fromIntegral n)
    }

-- | A third human message in the same thread as 'firstAddressedMessage'.
thirdAddressedMessage :: AddressedMessage
thirdAddressedMessage =
  AddressedMessage
    { conversationId = "conv_thread_1",
      messageId = "msg_human_3",
      parentMessageId = Just "msg_human_2",
      author = "part_human_test",
      content = "third question",
      agentParticipantId = "part_agent_test",
      embellishmentId = "emb_human_3",
      mentionedBy = "part_human_test",
      occurredAt = UTCTime (fromGregorian 2026 6 27) 2
    }

permanentConversationMessage :: AddressedMessage
permanentConversationMessage =
  AddressedMessage
    { conversationId = "conv_permanent",
      messageId = "msg_permanent",
      parentMessageId = Nothing,
      author = "part_human_test",
      content = "exercise permanent failure",
      agentParticipantId = "part_agent_test",
      embellishmentId = "emb_permanent",
      mentionedBy = "part_human_test",
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0
    }

job :: RunJob
job =
  RunJob
    { agentName = fixtureAgentName "heartbeat",
      identity = compatibilityIdentity (fixtureAgentName "heartbeat"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = fixtureRunKey "heartbeat:test-workflow-replay",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

retryVersioningJob :: Text -> RunJob
retryVersioningJob key =
  RunJob
    { agentName = fixtureAgentName "heartbeat",
      identity = compatibilityIdentity (fixtureAgentName "heartbeat"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = fixtureRunKey key,
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

transientRetryJob :: RunJob
transientRetryJob = retryVersioningJob "heartbeat:test-transient-retry"

permanentFailureJob :: RunJob
permanentFailureJob =
  RunJob
    { agentName = fixtureAgentName "missing-task-agent",
      identity = compatibilityIdentity (fixtureAgentName "missing-task-agent"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = fixtureRunKey "missing-task-agent:test-permanent-failure",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

crashJob :: RunJob
crashJob =
  RunJob
    { agentName = fixtureAgentName "heartbeat",
      identity = compatibilityIdentity (fixtureAgentName "heartbeat"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = fixtureRunKey "heartbeat:test-workflow-crash-resume",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

profileRefusalJob :: RunJob
profileRefusalJob =
  RunJob
    { agentName = fixtureAgentName "heartbeat",
      identity = compatibilityIdentity (fixtureAgentName "heartbeat"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = fixtureRunKey "heartbeat:test-profile-refusal",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

profilePinningJob :: RunJob
profilePinningJob =
  RunJob
    { agentName = fixtureAgentName "heartbeat",
      identity = compatibilityIdentity (fixtureAgentName "heartbeat"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = fixtureRunKey "heartbeat:test-profile-pinning",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

profileViolationJob :: RunJob
profileViolationJob =
  RunJob
    { agentName = fixtureAgentName "profiled-skill",
      identity = compatibilityIdentity (fixtureAgentName "profiled-skill"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = fixtureRunKey "profiled-skill:test-profile-violation",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

profiledFlowViolationJob :: RunJob
profiledFlowViolationJob =
  profileViolationJob
    & #agentName .~ fixtureAgentName "profiled-flow"
    & #identity .~ compatibilityIdentity (fixtureAgentName "profiled-flow")
    & #idempotencyKey .~ fixtureRunKey "profiled-flow:test-profile-violation"

sampleWorkflowProfileId :: ProfileId
sampleWorkflowProfileId = ProfileId "sanctioned-review"

workflowProfile :: ProfileVersion -> SanctionedExecutionProfile
workflowProfile = workflowProfileWith defaultProhibitions

workflowProfileWith :: Prohibitions -> ProfileVersion -> SanctionedExecutionProfile
workflowProfileWith prohibitions version =
  SanctionedExecutionProfile
    { profileId = sampleWorkflowProfileId,
      version,
      issuer = Issuer "shinzui/kikan",
      lifecycle = Active,
      validFrom = UTCTime (fromGregorian 2026 8 1) 0,
      validUntil = Nothing,
      allowedCalls =
        NonEmpty.singleton
          AllowedCall
            { provider = Coordinate.providerCoordinate ("anthropic"),
              api = Coordinate.providerCoordinate ("messages"),
              endpointClass = Coordinate.providerCoordinate ("https"),
              modelId = Coordinate.providerCoordinate ("claude-sonnet-4-6"),
              thinking = ThinkingHigh
            },
      prohibitions,
      limits = unlimitedProfileLimits,
      minimumEvidenceStrength = EvidenceModelObserved,
      requiredCorrelationFields = [PV.policyCoordinate "request-id"],
      signerRequirements = noSignerRequirements
    }

defaultThinkingProhibitions :: Prohibitions
defaultThinkingProhibitions =
  Prohibitions
    { aliasesAllowed = PV.Prohibited,
      defaultedThinkingAllowed = PV.Permitted,
      providerFallbackAllowed = PV.Prohibited,
      modelFallbackAllowed = PV.Prohibited,
      effortClampingAllowed = PV.Prohibited,
      cliTransportsAllowed = PV.Prohibited
    }

resolvedWorkflowProfile :: SanctionedExecutionProfile -> ProfileDigest -> ResolvedProfile
resolvedWorkflowProfile content digest =
  let SanctionedExecutionProfile {profileId, version} = content
   in either (error . show) id (parseResolvedProfile content (SanctionedExecutionProfileRef {profileId, version, digest}))

insertWorkflowProfile :: Pool -> SanctionedExecutionProfile -> ProfileDigest -> IO ()
insertWorkflowProfile pool content claimedDigest = do
  let SanctionedExecutionProfile {profileId, version, issuer, validFrom, validUntil} = content
      params =
        InsertProfile
          { profileId = profileIdText profileId,
            version = profileVersionText version,
            issuer = issuerText issuer,
            lifecycle = "active",
            validFrom = validFrom,
            validUntil = validUntil,
            content = toJSON content,
            digest = profileDigestText claimedDigest
          }
  result <- Pool.use pool (HasqlSession.statement params insertWorkflowProfileStatement)
  either (assertFailure . show) pure result

data InsertProfile = InsertProfile
  { profileId :: !Text,
    version :: !Text,
    issuer :: !Text,
    lifecycle :: !Text,
    validFrom :: !UTCTime,
    validUntil :: !(Maybe UTCTime),
    content :: !Value,
    digest :: !Text
  }
  deriving stock (Generic)

insertWorkflowProfileStatement :: Statement InsertProfile ()
insertWorkflowProfileStatement =
  preparable
    """
    INSERT INTO shikigami.sanctioned_execution_profiles
      (profile_id, version, issuer, lifecycle, valid_from, valid_until, profile_content, profile_digest)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    """
    ( (view #profileId >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #version >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #issuer >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #lifecycle >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #validFrom >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz))
        <> (view #validUntil >$< Encoders.param (Encoders.nullable Encoders.timestamptz))
        <> (view #content >$< Encoders.param (Encoders.nonNullable Encoders.jsonb))
        <> (view #digest >$< Encoders.param (Encoders.nonNullable Encoders.text))
    )
    Decoders.noResult

replaceWorkflowProfile :: Pool -> ProfileId -> ProfileVersion -> SanctionedExecutionProfile -> ProfileDigest -> IO ()
replaceWorkflowProfile pool profileId oldVersion replacement claimedDigest = do
  let SanctionedExecutionProfile {version = newVersion} = replacement
      params =
        ( profileIdText profileId,
          profileVersionText oldVersion,
          profileVersionText newVersion,
          toJSON replacement,
          profileDigestText claimedDigest
        )
  result <- Pool.use pool (HasqlSession.statement params replaceWorkflowProfileStatement)
  either (assertFailure . show) pure result

replaceWorkflowProfileStatement :: Statement (Text, Text, Text, Value, Text) ()
replaceWorkflowProfileStatement =
  preparable
    """
    UPDATE shikigami.sanctioned_execution_profiles
       SET version = $3, profile_content = $4, profile_digest = $5
     WHERE profile_id = $1 AND version = $2
    """
    ( contrazip5
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.jsonb))
        (Encoders.param (Encoders.nonNullable Encoders.text))
    )
    Decoders.noResult

profileIdText :: ProfileId -> Text
profileIdText (ProfileId value) = value

profileVersionText :: ProfileVersion -> Text
profileVersionText (ProfileVersion value) = value

issuerText :: Issuer -> Text
issuerText (Issuer value) = value

recordBeforeCompleteCrashJob :: RunJob
recordBeforeCompleteCrashJob =
  RunJob
    { agentName = fixtureAgentName "heartbeat",
      identity = compatibilityIdentity (fixtureAgentName "heartbeat"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = fixtureRunKey "heartbeat:test-record-before-complete-crash",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

flowJob :: RunJob
flowJob =
  RunJob
    { agentName = fixtureAgentName "at-risk-customer",
      identity = compatibilityIdentity (fixtureAgentName "at-risk-customer"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object ["text" .= ("customer says thanks, all good" :: Text)],
      idempotencyKey = fixtureRunKey "at-risk-customer:test-flow-low",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

-- | The same agent and the same calm text as 'flowJob', under a different run
-- id so it gets its own workflow and its own subject.
flowMemoryJob :: RunJob
flowMemoryJob =
  RunJob
    { agentName = fixtureAgentName "at-risk-customer",
      identity = compatibilityIdentity (fixtureAgentName "at-risk-customer"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object ["text" .= ("customer says thanks, all good" :: Text)],
      idempotencyKey = fixtureRunKey "at-risk-customer:test-flow-memory-high",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

-- | Seed the at-risk-customer agent's memory with an escalation on this
-- subject, the way an earlier run of the flow would have
-- ('Shikigami.Flow.AtRiskCustomer.escalatedNote' is worded the same).
recordPriorEscalation :: AppEnv -> Text -> IO ()
recordPriorEscalation appEnv ticket = do
  mid <- genMemoryId
  recordedAt <- getCurrentTime
  result <-
    runAppIO appEnv $
      Memory.record
        RecordMemoryData
          { memoryId = mid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor (CompatibilityAgent (fixtureAgentName "at-risk-customer")),
            ownerPrincipal = Nothing,
            agentId = "at-risk-customer",
            sessionId = Nothing,
            scope = agentScope (CompatibilityAgent (fixtureAgentName "at-risk-customer")),
            memoryType = MemoryPattern,
            content = ticket <> " escalated after acknowledgement timeout",
            priority = 100,
            confidence = MediumConfidence,
            tags = Set.fromList ["flow", "Flow"],
            supersedes = Nothing,
            recordedAt
          }
  case result of
    Right (Right _) -> pure ()
    other -> assertFailure ("seeding the prior escalation should succeed, got " <> show other)

recordRecallFixture :: AppEnv -> Int -> IO ()
recordRecallFixture appEnv ordinal = do
  mid <- genMemoryId
  recordedAt <- getCurrentTime
  result <-
    runAppIO appEnv $
      Memory.record
        RecordMemoryData
          { memoryId = mid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor (CompatibilityAgent (fixtureAgentName "recall-limit-agent")),
            ownerPrincipal = Nothing,
            agentId = "recall-limit-agent",
            sessionId = Nothing,
            scope = agentScope (CompatibilityAgent (fixtureAgentName "recall-limit-agent")),
            memoryType = MemoryPattern,
            content = "recall fixture " <> Text.pack (show ordinal),
            priority = 100,
            confidence = MediumConfidence,
            tags = Set.fromList ["agent-run", "fixture"],
            supersedes = Nothing,
            recordedAt
          }
  case result of
    Right (Right _) -> pure ()
    other -> assertFailure ("seeding recall fixture should succeed, got " <> show other)

recordLegacyRecallFixture :: AppEnv -> Text -> IO ()
recordLegacyRecallFixture appEnv legacyName = do
  mid <- genMemoryId
  recordedAt <- getCurrentTime
  result <-
    runAppIO appEnv $
      Memory.record
        RecordMemoryData
          { memoryId = mid,
            memorySpaceId = shikigamiMemorySpace,
            actorPrincipal = agentActor (CompatibilityAgent (fixtureAgentName legacyName)),
            ownerPrincipal = Nothing,
            agentId = legacyName,
            sessionId = Nothing,
            scope = legacyAgentScope legacyName,
            memoryType = MemoryPattern,
            content = "legacy alias fixture",
            priority = 100,
            confidence = MediumConfidence,
            tags = Set.fromList ["agent-run", "legacy-alias"],
            supersedes = Nothing,
            recordedAt
          }
  case result of
    Right (Right _) -> pure ()
    other -> assertFailure ("seeding legacy recall fixture should succeed, got " <> show other)

expectedFlowOutput :: Value
expectedFlowOutput =
  object
    [ "level" .= ("low" :: Text),
      "rationale" .= ("no high-risk signal detected" :: Text),
      "ticketId" .= ("at-risk-customer:test-flow-low" :: Text)
    ]

approvalJob :: RunJob
approvalJob =
  RunJob
    { agentName = fixtureAgentName "heartbeat",
      identity = compatibilityIdentity (fixtureAgentName "heartbeat"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = fixtureRunKey "heartbeat:test-approval-approved",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

rejectedJob :: RunJob
rejectedJob =
  RunJob
    { agentName = fixtureAgentName "heartbeat",
      identity = compatibilityIdentity (fixtureAgentName "heartbeat"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = fixtureRunKey "heartbeat:test-approval-rejected",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

timeoutJob :: RunJob
timeoutJob =
  RunJob
    { agentName = fixtureAgentName "heartbeat",
      identity = compatibilityIdentity (fixtureAgentName "heartbeat"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = fixtureRunKey "heartbeat:test-approval-timeout",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

answeredBeforeDeadlineJob :: RunJob
answeredBeforeDeadlineJob =
  RunJob
    { agentName = fixtureAgentName "heartbeat",
      identity = compatibilityIdentity (fixtureAgentName "heartbeat"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object [],
      idempotencyKey = fixtureRunKey "heartbeat:test-approval-before-deadline",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

researchSupervisorJob :: RunJob
researchSupervisorJob =
  RunJob
    { agentName = fixtureAgentName "research-supervisor",
      identity = compatibilityIdentity (fixtureAgentName "research-supervisor"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object ["topic" .= ("durable workflows" :: Text)],
      idempotencyKey = fixtureRunKey "research-supervisor:test-fanout",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = map fixtureAgentName ["research-supervisor"],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

flowDelegationJob :: RunJob
flowDelegationJob =
  RunJob
    { agentName = fixtureAgentName "flow-delegation-supervisor",
      identity = compatibilityIdentity (fixtureAgentName "flow-delegation-supervisor"),
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 6 27) 0,
      triggerPayload = object ["topic" .= ("durable workflows" :: Text)],
      idempotencyKey = fixtureRunKey "flow-delegation-supervisor:test-allowed",
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = map fixtureAgentName ["flow-delegation-supervisor"],
      executionRequest = Nothing,
      executionPermissions = Nothing,
      executionRootId = Nothing,
      delegationBudgetId = Nothing
    }

flowDelegationDeniedJob :: RunJob
flowDelegationDeniedJob =
  (flowDelegationJob & #idempotencyKey .~ (fixtureRunKey "flow-delegation-supervisor:test-denied"))

expectedWebFinding :: Value
expectedWebFinding =
  object
    [ "agent" .= ("web-researcher" :: Text),
      "finding" .= ("Web sources indicate durable workflow delegation should journal child waits." :: Text)
    ]

expectedSupervisorOutput :: Value
expectedSupervisorOutput =
  object
    [ "summary" .= ("research-supervisor synthesized delegated findings" :: Text),
      "web" .= expectedWebFinding,
      "code"
        .= object
          [ "agent" .= ("code-researcher" :: Text),
            "finding" .= ("The code path should spawn child workflows before awaiting their results." :: Text)
          ]
    ]

fixtureAmount :: Integer -> ResourceAmount
fixtureAmount amount = either (error . show) id (parseResourceAmount amount)

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureDelegationDepth :: Int -> DelegationDepth
fixtureDelegationDepth = either (error . show) id . parseDelegationDepth . toInteger

fixtureRunKey :: Text -> RunKey
fixtureRunKey = either (error . show) id . parseRunKey

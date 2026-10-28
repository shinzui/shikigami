module Shikigami.ExecutionTranscriptSpec (tests) where

import Baikai.Api (Api (OpenAIResponses))
import Baikai.Content qualified as Content
import Baikai.Context qualified as Context
import Baikai.Message qualified as Message
import Baikai.Options (emptyOptions)
import Baikai.Provider.Registry qualified as Provider
import Baikai.Response qualified as Response
import Baikai.StopReason (StopReason (Stop, ToolUse))
import Baikai.Stream (liftCompleteToStream)
import Baikai.Tool qualified as BaikaiTool
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently)
import Control.Monad (void, when)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Functor ((<&>))
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.IORef
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (Eff, liftIO)
import Effectful.Dispatch.Static (unsafeEff_)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.ReadModel.Rebuild qualified as Rebuild
import Keiro.Timer qualified as Timer
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), continueAsNew, currentRunGeneration, defaultWorkflowRunOptions, loadStepIndex, runWorkflow)
import Keiro.Workflow.Awakeable (AwakeableId (..), awakeableIdText, awakeableNamed)
import Keiro.Workflow.Awakeable.Schema (AwakeableRow (..), countPendingAwakeables, lookupAwakeable, registerAwakeableTx)
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Keiro.Workflow.Child (runChildWorkflow)
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kioku.Id (genSessionId)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (GlobalPosition (..))
import Shikigami.Action.Authorization (denyAllActionAuthorizer)
import Shikigami.Agent.Approval (ApprovalChannel (..), ApprovalDecision (..), ApprovalRequest (..), approvalWorkflowId, resolveApproval)
import Shikigami.Agent.Approval.Workflow qualified as Approval
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.Run.Key (RunKey (..))
import Shikigami.Agent.RunJob (RunRouteKind (..))
import Shikigami.Behavior.Input (triggerOnly)
import Shikigami.Behavior.Run (BehaviorEnv (..), newBehaviorEnv)
import Shikigami.Behavior.Skill (SkillDir (..))
import Shikigami.Behavior.StubProvider (stubApiProvider, stubModel)
import Shikigami.Capability.Overlay (emptyResolvedCapabilitySet)
import Shikigami.Capability.Provider (emptyCapabilityProviderRegistry)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Decision.ModelCatalog (modelCatalog)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Catalog qualified as ExecutionCatalog
import Shikigami.Execution.Driver qualified as Driver
import Shikigami.Execution.Executor qualified as Executor
import Shikigami.Execution.Identity
import Shikigami.Execution.Policy (ContextProvenance (..), ModelOperationInput (..), SummaryReference (..))
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Resources qualified as R
import Shikigami.Execution.Runner qualified as Runner
import Shikigami.Execution.Selection
import Shikigami.Execution.SelectionRuntime (SelectionRuntime (..), selectionTransaction)
import Shikigami.Execution.Start qualified as Start
import Shikigami.Execution.Store qualified as Store
import Shikigami.Execution.Timer (armObservation, observationFireAction)
import Shikigami.Execution.Tools qualified as Tools
import Shikigami.Execution.Transcript
import Shikigami.Execution.Transcript qualified as Replay
import Shikigami.ExecutionDriver.Generated.WorkflowRuntime qualified as DriverGenerated
import Shikigami.Log qualified as Log
import Shikigami.Log.Correlation (runCorrelationId)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Prelude ((&), (.~))
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Store.ExecutionResources qualified as Roots
import Shikigami.Store.ExecutionSelection qualified as Calls
import Shikigami.Trigger.Enqueue (addressedRunJob, enqueueRunJobTx, ensureRunQueue)
import Shikumi.Tool (mkDynTool)
import Shikumi.Tool.Output qualified as ToolOutput
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "ExecutionTranscript"
    [ testCase "assignment admission freezes Skill and native menu once before starting its driver" $
        withConfiguredResourceFixture fixture id (Map.insert R.Tokens R.ExplicitlyUnbounded) \env original _ -> do
          (executor, _, _) <- driverRuntime env False
          described <- newIORef (0 :: Int)
          let snapshot = anotherSnapshot original "admitted-skill"
              assignment = Start.SkillAssignment snapshot.runId snapshot.agent snapshot.identity snapshot.sessionId snapshot.selection snapshot.sanctionedProfile snapshot.capabilities (Right (snapshot.policy & #maxModelTurns .~ 3)) (SkillDir "test/fixtures/durable-skill") (pure (Right (Start.SkillInput (triggerOnly (object ["private" .= ("PRIVATE_ASSIGNMENT_MARKER" :: Text)])) [])))
              tool = mkDynTool "observe" "Observe fixture." (object []) (\_ -> assertFailureTool)
              assertFailureTool = unsafeEff_ (assertFailure "menu admission invoked a native callback") >> pure (Right (ToolOutput.textToolOutput "unused"))
              factory =
                Tools.NativeToolFactory
                  { Tools.describe = \_ -> modifyIORef' described (+ 1) >> pure (Right [Executor.BoundTool observationBinding tool]),
                    Tools.prepare = \_ _ _ -> assertFailure "menu description manufactured operation coordinates" >> pure (Right [])
                  }
              describe = Tools.describeExecutionTools Log.silentLogger denyAllActionAuthorizer emptyCapabilityProviderRegistry factory
          accepted <- expectRight =<< Start.admitSkillExecution executor describe assignment
          accepted.executionId @?= snapshot.executionId
          readIORef described >>= (@?= 1)
          access <- expectRight =<< run env (Store.authorizeReplay snapshot.executionId snapshot.identity (pure (Right ())))
          (frozen, state) <- expectRight =<< run env (Store.loadExecution access)
          state.cursor @?= 0
          frozen.instructions.name @?= "durable-fixture"
          frozen.policy.maxModelTurns @?= 3
          frozen.toolBindings @?= [observationBinding]
          case frozen.initialContext.messages of
            [RequestTurn [TextBlock text] Nothing] -> assertBool "trigger frozen with instructions" ("PRIVATE_ASSIGNMENT_MARKER" `Text.isInfixOf` text)
            _ -> assertFailure "unexpected initial Skill context"
          let retired = assignment & #skillDir .~ SkillDir "/missing-retired-skill" & #policy .~ Left "retired process policy is invalid" & #input .~ (assertFailure "existing execution reconstructed its input" >> pure (Left UnsupportedReplay))
          Start.admitSkillExecution executor (\_ -> assertFailure "existing assignment reacquired its menu" >> pure (Left UnsupportedReplay)) retired >>= (@?= Right accepted)
          readIORef described >>= (@?= 1)
          Start.admitSkillExecution executor describe (retired & #runId .~ "different-run") >>= (@?= Left ExecutionIdentityConflict),
      testCase "driver generations repair lost queue delivery without another actual attempt" $
        withConfiguredResourceFixture fixture id (Map.insert R.Tokens R.ExplicitlyUnbounded) \env snapshot access -> do
          (executor, calls, _) <- driverRuntime env False
          withStore env.connectionSettings (\store -> ensureRunQueue store.pool >>= expectRight)
          let workflow = executionWorkflowId snapshot.executionId
              drive = run env (runWorkflow DriverGenerated.workflowName workflow (Driver.executionWorkflow executor (Just (Driver.ExecutionStart snapshot.executionId))))
          drive >>= (@?= ContinuedAsNew)
          second <- drive
          Just (debugState, _, _) <- inspect env snapshot.executionId
          assertBool (show (second, debugState)) (second == Suspended)
          reference <- pendingReference env snapshot
          run env (runTransaction (Tx.statement () (preparable "DELETE FROM pgmq.q_shikigami_run_jobs" E.noParams D.noResult)))
          calls >>= (@?= [])
          now <- getCurrentTime
          Just timer <- run env (Timer.claimDueTimer (addUTCTime 120 now))
          _ <- run env (observationFireAction timer)
          drive >>= (@?= ContinuedAsNew)
          drive >>= (@?= Suspended)
          pendingReference env snapshot >>= (@?= reference)
          attempts <- expectRight =<< run env (Store.inspectOperationAttempts reference.operationId)
          length attempts @?= 1
          queueCount env >>= (@?= 1)
          Executor.executeAcceptedAttempt executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          completed <- pumpDriver env executor snapshot 12
          completed.phase @?= Succeeded
          run env countPendingAwakeables >>= (@?= 0)
          calls >>= (\values -> length values @?= 1)
          let retiredBinding = executor {Executor.selectionRuntime = \_ -> error "completed result looked up a retired provider"}
          result <- expectRight =<< Start.readExecutionResult retiredBinding snapshot.identity completed
          assertBool "protected terminal result retained" (case result of Aeson.Object _ -> True; _ -> False)
          -- A completed driver returns metadata without a live provider binding.
          let unavailable = executor {Executor.replayAuthority = const (pure (Left "revoked")), Executor.authorize = const (pure (Left "retired"))}
          run env (runWorkflow DriverGenerated.workflowName workflow (Driver.executionWorkflow unavailable Nothing)) >>= (@?= Completed completed)
          (_, state) <- expectRight =<< run env (Store.loadExecution access)
          state.cursor @?= 1,
      testCase "automatic driver accepts each tool position and reconstructs exact bounded model history" $
        withConfiguredResourceFixture fixture toolConfiguration (Map.insert R.Tokens R.ExplicitlyUnbounded) \env snapshot access -> do
          (executor, calls, toolCalls) <- driverRuntime env True
          withStore env.connectionSettings (\store -> ensureRunQueue store.pool >>= expectRight)
          result <- pumpDriver env executor snapshot 30
          assertBool (show result) (result.phase == Succeeded)
          toolCalls >>= (@?= 2)
          observed <- calls
          length observed @?= 2
          let lastContext = last observed
          length lastContext.messages @?= 4
          case Vector.toList lastContext.messages of
            [Message.UserMessage {}, Message.AssistantMessage assistant, Message.ToolResultMessage first, Message.ToolResultMessage second] -> do
              assistant.stopReason @?= ToolUse
              first.toolCallId @?= "first"
              second.toolCallId @?= "second"
            _ -> assertFailure "model context lost or reordered accepted tool observations"
          (reconstructed, _, _) <- expectRight =<< run env (Store.loadModelReplayWindow access)
          length reconstructed.messages @?= 5
          Just (_, _, operations) <- inspect env snapshot.executionId
          map (\operation -> operation.specification.kind) operations @?= [ModelTurn, ToolOperation, ToolOperation, ModelTurn]
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          Map.lookup R.ModelAttempts root.usage.settled @?= Just 2
          Map.lookup R.ToolAttempts root.usage.settled @?= Just 2,
      testCase "recorded context summary survives restart and consumes an ordinary model attempt" $
        withConfiguredResourceFixture fixture summaryConfiguration (Map.insert R.Tokens R.ExplicitlyUnbounded) \env snapshot access -> do
          (executor, calls, _) <- driverRuntime env False
          withStore env.connectionSettings (\store -> ensureRunQueue store.pool >>= expectRight)
          let drive = run env (runWorkflow DriverGenerated.workflowName (executionWorkflowId snapshot.executionId) (Driver.executionWorkflow executor (Just (Driver.ExecutionStart snapshot.executionId))))
          drive >>= (@?= ContinuedAsNew)
          drive >>= (@?= Suspended)
          reference <- pendingReference env snapshot
          Executor.executeAcceptedAttempt executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          -- The process stops after accepting the summary. Its successor must
          -- reuse that result rather than spend another summary attempt.
          drive >>= (@?= ContinuedAsNew)
          drive >>= (@?= ContinuedAsNew)
          calls >>= (\values -> length values @?= 1)
          result <- pumpDriver env executor snapshot 12
          result.phase @?= Succeeded
          observed <- calls
          map (Vector.length . (.tools)) observed @?= [0, 1]
          Just (state, _, operations) <- inspect env snapshot.executionId
          state.modelTurns @?= 2
          case operations of
            [summary, regular] -> do
              map (\operation -> operation.specification.kind) operations @?= [ModelSummary, ModelTurn]
              summaryInput <- expectRight =<< run env (Store.readReplayPayload @ModelOperationInput access "operation-input" summary.input)
              regularInput <- expectRight =<< run env (Store.readReplayPayload @ModelOperationInput access "operation-input" regular.input)
              summaryInput.maxOutputTokens @?= Just 128
              ((regularInput.provenance >>= (.summary)) <&> (.operationId)) @?= Just summary.specification.operationId
              ((regularInput.provenance >>= (.summary)) <&> (.outcome)) @?= summary.outcome
              assertBool "raw summary source provenance retained" (isJust (summaryInput.provenance >>= (.summarizes)))
            _ -> assertFailure "summary was resampled after restart"
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          Map.lookup R.ModelAttempts root.usage.settled @?= Just 2,
      testCase "a summary cannot authorize tool work or trigger an unbounded resample" $
        withConfiguredResourceFixture fixture summaryConfiguration (Map.insert R.Tokens R.ExplicitlyUnbounded) \env snapshot _ -> do
          (executor, calls, toolCalls) <- driverRuntime env True
          withStore env.connectionSettings (\store -> ensureRunQueue store.pool >>= expectRight)
          result <- pumpDriver env executor snapshot 12
          result.phase @?= Replay.Failed
          result.failure @?= Just ExecutionOutputInvalid
          calls >>= (\values -> length values @?= 1)
          toolCalls >>= (@?= 0)
          Just (_, _, operations) <- inspect env snapshot.executionId
          map (\operation -> operation.specification.kind) operations @?= [ModelSummary],
      testCase "driver cancellation settles an undispatched reservation and never calls its provider" $
        withConfiguredResourceFixture fixture id (Map.insert R.Tokens R.ExplicitlyUnbounded) \env snapshot _ -> do
          (executor, calls, _) <- driverRuntime env False
          withStore env.connectionSettings (\store -> ensureRunQueue store.pool >>= expectRight)
          let drive = run env (runWorkflow DriverGenerated.workflowName (executionWorkflowId snapshot.executionId) (Driver.executionWorkflow executor (Just (Driver.ExecutionStart snapshot.executionId))))
          drive >>= (@?= ContinuedAsNew)
          drive >>= (@?= Suspended)
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          run env (Roots.setRootControl rootId root.revision True Nothing) >>= (@?= Right ())
          result <- pumpDriver env executor snapshot 12
          result.phase @?= Replay.Cancelled
          calls >>= (@?= [])
          settled <- expectRight =<< run env (Roots.inspectRoot rootId)
          settled.active @?= 0
          Map.lookup R.ModelAttempts settled.usage.settled @?= Just 1,
      testCase "driver parks one tool across approval restart and refuses revoked authority before submission" $
        withConfiguredResourceFixture fixture (\snapshot -> toolConfiguration snapshot & #policy . #humanTools .~ ["observe"]) (Map.insert R.Tokens R.ExplicitlyUnbounded) \env snapshot _ -> do
          (executor, calls, toolCalls) <- driverRuntime env True
          withStore env.connectionSettings (\store -> ensureRunQueue store.pool >>= expectRight)
          permission <- reachPermission env executor snapshot 12
          Just (parked, _, _) <- inspect env snapshot.executionId
          parked.phase @?= Parked
          parked.cursor @?= 1
          parked.modelTurns @?= 1
          tokenRef <- newIORef Nothing
          let childEnv = Approval.ApprovalWorkflowEnv (Approval.ApprovalNotifier (\_ _ token _ -> writeIORef tokenRef (Just token)) (\_ _ _ _ -> pure (Right ())))
              child = runChildWorkflow defaultWorkflowRunOptions Approval.approvalWorkflowName (approvalWorkflowId permission.reviewRequestId) (Approval.approvalWorkflow childEnv Nothing)
          run env child >>= (@?= Suspended)
          token <- readIORef tokenRef >>= maybe (assertFailure "missing approval token" >> fail "token") pure
          resolveApproval env token (Approved (object [])) >>= (@?= True)
          run env child >>= (@?= Completed (Approval.ApprovalResolved (Approved (object []))))
          let revoked = executor {Executor.authorize = const (pure (Left "authority revoked while waiting"))}
          result <- pumpDriver env revoked snapshot 12
          result.phase @?= Replay.Failed
          toolCalls >>= (@?= 0)
          calls >>= (\values -> length values @?= 1)
          Just (_, _, operations) <- inspect env snapshot.executionId
          length operations @?= 2
          case operations of
            [_, operation] -> do
              (operation.permission >>= (.resolution)) @?= Just PermissionApproved
              attempts <- expectRight =<< run env (Store.inspectOperationAttempts operation.specification.operationId)
              attempts @?= []
            _ -> assertFailure "permission consumed another logical turn",
      testCase "assistant replay retains opaque thinking and exact cut-off tool arguments" do
        let assistant =
              ReplayAssistant
                1
                [ThinkingBlock "opaque-redacted" (Just "signature") True (Just (ProviderReplay OpenAIResponses "exact-model" [object ["opaque" .= ("continuation" :: Text)]])), ToolBlock (ToolInvocation "call" "tool" (Aeson.String "{cut-off"))]
                Stop
                (Just "response")
                Nothing
                (object ["tokens" .= (4 :: Int)])
                Nothing
        Aeson.fromJSON (toJSON assistant) @?= Aeson.Success assistant
        restored <- expectRight (restoreAssistant assistant)
        length restored.content @?= 2
        toolInvocations assistant @?= [ToolInvocation "call" "tool" (Aeson.String "{cut-off")]
        let future = case toJSON assistant of Aeson.Object fields -> Aeson.Object (KeyMap.insert "format" (toJSON (2 :: Int)) fields); value -> value
        assertBool "future assistant version rejected" (case Aeson.fromJSON @ReplayAssistant future of Aeson.Error _ -> True; _ -> False),
      testCase "attempt reservation and real queue acceptance roll back and deduplicate together" $
        withFixture fixture \env snapshot access -> do
          (_, operation) <- expectRight =<< run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput)
          withStore env.connectionSettings (\store -> ensureRunQueue store.pool >>= expectRight)
          now <- getCurrentTime
          let submission = modelSubmission operation
              enqueue reference = void (enqueueRunJobTx (addressedRunJob now snapshot.identity "worker" ExecutionOperationRoute (toJSON reference) (RunKey "accepted-attempt-job")))
              failAfterQueue reference = enqueue reference >> Tx.statement () (preparable "SELECT 1/0" E.noParams (D.singleRow (D.column (D.nonNullable D.int4)))) >> pure ()
          refused <- run env (Store.submitExecutionAttemptWith access 1 submission failAfterQueue)
          case refused of Left ExecutionStorageUnavailable -> pure (); other -> assertFailure (show other)
          queueCount env >>= (@?= 0)
          run env (Store.inspectExecutionAttempt submission.request.attemptId) >>= (@?= Right Nothing)
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          root.usage @?= R.emptyUsage
          (_, attempt) <- expectRight =<< run env (Store.submitExecutionAttemptWith access 1 submission enqueue)
          run env (Store.submitExecutionAttemptWith access 1 submission enqueue) >>= (@?= Right (R.AlreadyAccepted, attempt))
          queueCount env >>= (@?= 1)
          assertBool "opaque wake token absent from metadata" (not ("00000000-0000-0000-0000-000000000000" `Text.isInfixOf` Text.pack (show (Aeson.encode attempt)))),
      testCase "racing tool attempt identities across distinct roots admit one owner" $
        withConfiguredFixture fixture toolConfiguration \env first firstAccess -> do
          now <- getCurrentTime
          let secondRoot = ExecutionRootId "second-transcript-root"
              limits = Map.insert R.Tokens (R.Limited 1000) (Map.fromList [(dimension, R.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]])
              second = anotherSnapshot first "second-tool-execution" & #selection . #rootId .~ Just secondRoot
          run env (Roots.enrollRoot secondRoot (R.Envelope limits (addUTCTime 3600 now))) >>= (@?= Right R.Accepted)
          run env (Store.admitExecution second) >>= (@?= Right R.Accepted)
          secondAccess <- expectRight =<< run env (Store.authorizeReplay second.executionId second.identity (pure (Right ())))
          let prepare snapshot access = do
                (response, assistant) <- commitToolRequest env snapshot access
                let input = ToolOperationInput response 0 (head (toolInvocations assistant)) observationBinding
                    specification = toolSpec snapshot 1 input
                _ <- expectRight =<< run env (Store.acceptOperation access 2 specification (toJSON input))
                pure (Attempt.AttemptSubmission (Store.toolAttemptRequest (AttemptId "shared-tool-attempt") specification.operationId observationBinding) Nothing (Attempt.ExecutionWake (AwakeableId UUID.nil) 0))
          a <- prepare first firstAccess
          b <- prepare second secondAccess
          (left, right) <- concurrently (run env (Store.submitExecutionAttemptWith firstAccess 3 a (\_ -> pure ()))) (run env (Store.submitExecutionAttemptWith secondAccess 3 b (\_ -> pure ())))
          length [() | Right (R.Accepted, _) <- [left, right]] @?= 1
          length [() | Left AttemptConflict <- [left, right]] @?= 1
          firstRoot <- expectRight =<< run env (Roots.inspectRoot rootId)
          otherRoot <- expectRight =<< run env (Roots.inspectRoot secondRoot)
          firstRoot.active + otherRoot.active @?= 1
          Just _ <- expectRight =<< run env (Store.inspectExecutionAttempt (AttemptId "shared-tool-attempt"))
          pure (),
      testCase "two executors obtain one claim and only one dispatch-start transition" $
        withPreparedModel fixture \env snapshot access operation reference -> do
          (left, right) <- concurrently (run env (Store.claimExecutionAttempt access 2 reference "owner-a" 60)) (run env (Store.claimExecutionAttempt access 2 reference "owner-b" 60))
          claim <- case [value | Right (Attempt.ClaimGranted value) <- [left, right]] of [value] -> pure value; other -> assertFailure (show other) >> fail "claim"
          run env (Store.claimExecutionAttempt access 3 reference "third-owner" 60) >>= (@?= Right Attempt.AttemptBusy)
          run env (Store.startExecutionAttempt access 3 claim) >>= (@?= Right R.Accepted)
          run env (Store.startExecutionAttempt access 3 claim) >>= (@?= Right R.AlreadyAccepted)
          let result = terminalAttempt
          run env (Store.completeExecutionAttempt access 4 claim result) >>= (@?= Right R.Accepted)
          run env (Store.completeExecutionAttempt access 4 claim result) >>= (@?= Right R.AlreadyAccepted)
          run env (Store.claimExecutionAttempt access 5 reference "redelivery" 60) >>= (@?= Right Attempt.AttemptFinished)
          (_, state) <- expectRight =<< run env (Store.loadExecution access)
          state.cursor @?= 1
          state.activeOperation @?= Nothing
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          Map.lookup R.ModelAttempts root.usage.settled @?= Just 1
          Map.lookup R.Tokens root.usage.settled @?= Just 3
          operation.specification.operationId @?= reference.operationId
          state.executionId @?= snapshot.executionId,
      testCase "a refused undispatched attempt retries under the same logical key with a new reservation" $
        withPreparedModel fixture \env _snapshot access operation reference -> do
          run env (Store.abandonExecutionAttempt access 2 reference) >>= (@?= Right R.Accepted)
          run env (Store.abandonExecutionAttempt access 2 reference) >>= (@?= Right R.AlreadyAccepted)
          (_, pending) <- expectRight =<< run env (Store.loadExecution access)
          pending.cursor @?= 0
          pending.activeOperation @?= Just reference.operationId
          let submission = modelSubmission operation & #request . #attemptId .~ AttemptId "second-actual-attempt"
              retry = reference & #attemptId .~ submission.request.attemptId
          _ <- expectRight =<< run env (Store.submitExecutionAttemptWith access 3 submission (\_ -> pure ()))
          run env (Store.claimExecutionAttempt access 4 reference "old-delivery" 60) >>= (@?= Right Attempt.AttemptFinished)
          claim <- expectClaim =<< run env (Store.claimExecutionAttempt access 4 retry "retry-owner" 60)
          run env (Store.startExecutionAttempt access 5 claim) >>= (@?= Right R.Accepted)
          run env (Store.completeExecutionAttempt access 6 claim terminalAttempt) >>= (@?= Right R.Accepted)
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          Map.lookup R.ModelAttempts root.usage.settled @?= Just 2
          Map.lookup R.Tokens root.usage.settled @?= Just 3
          root.active @?= 0,
      testCase "claim expiry before dispatch permits replacement without another actual attempt" $
        withPreparedModel fixture \env _snapshot access _operation reference -> do
          first <- expectClaim =<< run env (Store.claimExecutionAttempt access 2 reference "first-owner" 1)
          threadDelay 1100000
          replacement <- expectClaim =<< run env (Store.claimExecutionAttempt access 3 reference "replacement" 60)
          replacement.generation @?= 2
          run env (Store.startExecutionAttempt access 4 first) >>= (@?= Left AttemptClaimLost)
          run env (Store.startExecutionAttempt access 4 replacement) >>= (@?= Right R.Accepted)
          run env (Store.completeExecutionAttempt access 5 replacement terminalAttempt) >>= (@?= Right R.Accepted)
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          Map.lookup R.ModelAttempts root.usage.settled @?= Just 1,
      testCase "expiry after dispatch holds accounting and retains a fenced late receipt" $
        withPreparedModel fixture \env _snapshot access _operation reference -> do
          claim <- expectClaim =<< run env (Store.claimExecutionAttempt access 2 reference "former-owner" 1)
          run env (Store.startExecutionAttempt access 3 claim) >>= (@?= Right R.Accepted)
          threadDelay 1100000
          run env (Store.claimExecutionAttempt access 4 reference "replacement" 60) >>= (@?= Right Attempt.AttemptNeedsReconciliation)
          run env (Store.completeExecutionAttempt access 4 claim terminalAttempt) >>= (@?= Left AttemptClaimLost)
          run env (Store.markExecutionAttemptUncertain access 4 claim) >>= (@?= Right R.Accepted)
          run env (Store.recordLateExecutionReceipt access 5 claim terminalAttempt) >>= (@?= Right R.Accepted)
          run env (Store.recordLateExecutionReceipt access 5 claim terminalAttempt) >>= (@?= Right R.AlreadyAccepted)
          (_, state) <- expectRight =<< run env (Store.loadExecution access)
          state.phase @?= Unresolved
          state.cursor @?= 0
          state.activeOperation @?= Just reference.operationId
          Just attempt <- expectRight =<< run env (Store.inspectExecutionAttempt reference.attemptId)
          attempt.phase @?= Attempt.AttemptUncertain
          late <- maybe (assertFailure "missing late receipt" >> fail "receipt") pure attempt.lateReceipt
          restored <- expectRight =<< run env (Store.readReplayPayload @Attempt.AttemptResult access "late-attempt-receipt" late)
          restored @?= terminalAttempt
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          Map.lookup R.Tokens root.usage.held @?= Just 10
          root.active @?= 1
          run env (Store.claimExecutionAttempt access 6 reference "another-owner" 60) >>= (@?= Right Attempt.AttemptNeedsReconciliation)
          run env (Store.reconcileExecutionAttempt access 6 reference.attemptId) >>= (@?= Right R.Accepted)
          run env (Store.reconcileExecutionAttempt access 6 reference.attemptId) >>= (@?= Right R.AlreadyAccepted)
          (_, reconciledState) <- expectRight =<< run env (Store.loadExecution access)
          reconciledState.phase @?= Active
          reconciledState.cursor @?= 1
          afterTransport <- expectRight =<< run env (Roots.inspectRoot rootId)
          afterTransport.active @?= 0
          afterTransport.unknown @?= 1
          Map.lookup R.ModelAttempts afterTransport.usage.settled @?= Just 1
          Map.lookup R.Tokens afterTransport.usage.settled @?= Just 3
          call <- maybe (assertFailure "missing model receipt" >> fail "call") pure attempt.call
          let complete = terminal & #known .~ Map.fromList [(R.Tokens, 3), (R.CostMicroUsd, 0)] & #missing .~ []
              conflict = complete & #known .~ Map.fromList [(R.Tokens, 4), (R.CostMicroUsd, 0)]
          run env (runTransaction (Calls.reconcileSelectionCallTx call conflict)) >>= (@?= Left Calls.CallIdentityConflict)
          run env (runTransaction (Calls.reconcileSelectionCallTx call complete)) >>= (@?= Right R.Accepted)
          run env (runTransaction (Calls.reconcileSelectionCallTx call complete)) >>= (@?= Right R.AlreadyAccepted)
          afterBilling <- expectRight =<< run env (Roots.inspectRoot rootId)
          afterBilling.active @?= 0
          afterBilling.unknown @?= 0
          Map.lookup R.ModelAttempts afterBilling.usage.settled @?= Just 1
          Map.lookup R.Tokens afterBilling.usage.settled @?= Just 3,
      testGroup "native executor billing and cleanup" [nativeExecutorCase fixture NoInvoiceCost, nativeExecutorCase fixture UnreportedInvoiceCost],
      testCase "an unreported tool invoice cannot claim a finite cost ceiling" $
        withConfiguredResourceFixture fixture (\snapshot -> toolConfiguration snapshot & #toolBindings .~ [observationBinding & #invoiceCost .~ UnreportedInvoiceCost]) (Map.insert R.CostMicroUsd (R.Limited 100)) \env snapshot access -> do
          let billed = terminal & #known .~ Map.fromList [(R.Tokens, 3), (R.CostMicroUsd, 0)] & #missing .~ []
          (response, assistant) <- commitToolRequestWith billed env snapshot access
          let binding = head snapshot.toolBindings
              input = ToolOperationInput response 0 (head (toolInvocations assistant)) binding
              specification = toolSpec snapshot 1 input
          _ <- expectRight =<< run env (Store.acceptOperation access 2 specification (toJSON input))
          let request = Store.toolAttemptRequest (AttemptId "unreported-tool-invoice") specification.operationId binding
              enqueue _ = void (Tx.statement () (preparable "SELECT 1/0" E.noParams (D.singleRow (D.column (D.nonNullable D.int4)))))
          refused <- run env (Store.submitExecutionAttemptWith access 3 (Attempt.AttemptSubmission request Nothing (Attempt.ExecutionWake (AwakeableId UUID.nil) 0)) enqueue)
          case refused of Left (ResourceAdmissionRefused "tool invoice ceiling is unsupported") -> pure (); other -> assertFailure (show other)
          run env (Store.inspectExecutionAttempt request.attemptId) >>= (@?= Right Nothing)
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          Map.lookup R.ToolAttempts root.usage.settled @?= Nothing
          root.active @?= 0,
      testCase "rotation republishes the current wake and an old timer cannot journal into its successor" $
        withPreparedModel fixture \env snapshot access _operation reference -> do
          tokens <- newIORef []
          let workflow = executionWorkflowId snapshot.executionId
              name = WorkflowName "shikigami.execution"
              body :: Eff (Workflow : AppEffects) ()
              body = do
                generation <- currentRunGeneration
                (token, await) <- awakeableNamed (StepName "observation")
                liftIO (modifyIORef' tokens (<> [(generation, token)]))
                armObservation (Attempt.ExecutionWake token generation) reference
                if generation == 0 then continueAsNew True else void (await :: Eff (Workflow : AppEffects) Attempt.JobReference)
          run env (runWorkflow name workflow body) >>= (@?= ContinuedAsNew)
          run env (runWorkflow name workflow body) >>= (@?= Suspended)
          captured <- readIORef tokens
          (oldToken, currentToken) <- case captured of [(0, old), (1, current)] -> pure (old, current); _ -> assertFailure "unexpected generations" >> fail "generations"
          now <- getCurrentTime
          Just oldTimer <- run env (Timer.claimDueTimer (addUTCTime 61 now))
          run env (observationFireAction oldTimer) >>= (@?= Nothing)
          Just pending <- run env (lookupAwakeable (let AwakeableId value = currentToken in value))
          pending.status @?= Awakeable.Pending
          before <- run env (loadStepIndex name workflow 1)
          assertBool "old timer did not add an orphan wake to the new journal" (Map.notMember ("awk:" <> awakeableIdText oldToken) before)
          claim <- expectClaim =<< run env (Store.claimExecutionAttempt access 2 reference "rotation-executor" 60)
          run env (Store.startExecutionAttempt access 3 claim) >>= (@?= Right R.Accepted)
          run env (Store.completeExecutionAttempt access 4 claim terminalAttempt) >>= (@?= Right R.Accepted)
          run env (Store.refreshExecutionWake access 5 (Attempt.ExecutionWake currentToken 1)) >>= (@?= Right R.Accepted)
          run env (Store.publishExecutionWake reference) >>= (@?= Right ())
          run env (runWorkflow name workflow body) >>= (@?= Completed ()),
      testCase "each tool has a separate immutable operation and accepted outcome" $
        withConfiguredFixture fixture toolConfiguration \env snapshot access -> do
          (response, assistant) <- commitToolRequest env snapshot access
          let firstInput = ToolOperationInput response 0 (head (toolInvocations assistant)) observationBinding
              firstSpec = toolSpec snapshot 1 firstInput
          (_, first) <- expectRight =<< run env (Store.acceptOperation access 2 firstSpec (toJSON firstInput))
          run env (Store.acceptOperation access 2 firstSpec (toJSON firstInput)) >>= (@?= Right (R.AlreadyAccepted, first))
          let altered = firstInput & #invocation . #arguments .~ object ["injected" .= True]
          run env (Store.acceptOperation access 2 firstSpec (toJSON altered)) >>= (@?= Left OperationConflict)
          run env (Store.recordOutcomeAndAdvance access 3 firstSpec.operationId (ToolReturned [TextBlock "opaque accepted-message reference"] False) (NeedTool response 1) Nothing) >>= (@?= Right R.Accepted)
          let secondInput = ToolOperationInput response 1 (toolInvocations assistant !! 1) observationBinding
          (_, second) <- expectRight =<< run env (Store.acceptOperation access 4 (toolSpec snapshot 2 secondInput) (toJSON secondInput))
          assertBool "tool identity uses committed cursor" (first.specification.operationId /= second.specification.operationId)
          run env (Store.recordOutcomeAndAdvance access 5 second.specification.operationId (ToolReturned [TextBlock "second result"] False) NeedModel Nothing) >>= (@?= Right R.Accepted)
          run env (Store.recordOutcomeAndAdvance access 3 firstSpec.operationId (ToolReturned [TextBlock "opaque accepted-message reference"] False) (NeedTool response 1) Nothing) >>= (@?= Right R.AlreadyAccepted)
          (_, state) <- expectRight =<< run env (Store.loadExecution access)
          state.cursor @?= 3
          state.modelTurns @?= 1,
      testCase "bound approval uses the real opaque token path and resumes the same tool" $
        withConfiguredFixture fixture (\snapshot -> toolConfiguration snapshot & #policy . #humanTools .~ ["observe"]) \env snapshot access -> do
          (response, assistant) <- commitToolRequest env snapshot access
          let input = ToolOperationInput response 0 (head (toolInvocations assistant)) observationBinding
              specification = toolSpec snapshot 1 input
          _ <- expectRight =<< run env (Store.acceptOperation access 2 specification (toJSON input))
          now <- getCurrentTime
          run env (Runner.prepareAcceptedTool now False Nothing access specification.operationId [observationBinding] (\_ -> assertFailure "authorization before human decision" >> pure (Right ()))) >>= (@?= Right Runner.ToolPermissionNeeded)
          permission <- expectRight =<< run env (Store.parkOperationPermission access 3 specification.operationId)
          run env (Store.parkOperationPermission access 3 specification.operationId) >>= (@?= Right permission)
          (_, parked) <- expectRight =<< run env (Store.loadExecution access)
          parked.phase @?= Parked
          parked.cursor @?= 1
          parked.modelTurns @?= 1
          tokenRef <- newIORef Nothing
          let childEnv = Approval.ApprovalWorkflowEnv (Approval.ApprovalNotifier (\_ _ token _ -> writeIORef tokenRef (Just token)) (\_ _ _ _ -> pure (Right ())))
              parentBody = Approval.requestBoundApproval permission.reviewRequestId snapshot.sessionId (ApprovalRequest "Allow observe?" (object []) ViaDanwa) 900
              parent = runWorkflow (WorkflowName "permission-fixture") (WorkflowId snapshot.executionId.value) parentBody
              child = runChildWorkflow defaultWorkflowRunOptions Approval.approvalWorkflowName (approvalWorkflowId permission.reviewRequestId) (Approval.approvalWorkflow childEnv Nothing)
          run env parent >>= (@?= Suspended)
          run env child >>= (@?= Suspended)
          resolveApproval env (AwakeableId UUID.nil) (Approved (object [])) >>= (@?= False)
          token <- readIORef tokenRef >>= maybe (assertFailure "missing opaque token" >> fail "token") pure
          resolveApproval env token (Approved (object [])) >>= (@?= True)
          resolveApproval env token (Rejected "conflict") >>= (@?= False)
          run env child >>= (@?= Completed (Approval.ApprovalResolved (Approved (object []))))
          result <- run env parent
          case result of
            Completed (Approval.ApprovalResolved decision) -> do
              run env (Store.resolveOperationPermission access 4 specification.operationId permission.reviewRequestId decision) >>= (@?= Right R.Accepted)
              run env (Store.resolveOperationPermission access 4 specification.operationId permission.reviewRequestId decision) >>= (@?= Right R.AlreadyAccepted)
              run env (Store.resolveOperationPermission access 4 specification.operationId permission.reviewRequestId (Rejected "conflict")) >>= (@?= Left OperationConflict)
            other -> assertFailure (show other)
          (_, resumed) <- expectRight =<< run env (Store.loadExecution access)
          resumed.phase @?= Active
          resumed.activeOperation @?= Just specification.operationId
          resumed.modelTurns @?= 1
          freshAccess <- expectRight =<< run env (Store.authorizeReplay snapshot.executionId snapshot.identity (pure (Right ())))
          run env (Runner.prepareAcceptedTool now False Nothing freshAccess specification.operationId [observationBinding] (\_ -> pure (Left "revoked after human approval"))) >>= (@?= Left (ExecutionPolicyRefused "fresh tool authorization refused"))
          prepared <-
            expectRight
              =<< run
                env
                ( Runner.prepareAcceptedTool
                    now
                    False
                    Nothing
                    freshAccess
                    specification.operationId
                    [observationBinding]
                    ( \context -> do
                        context.operationId @?= specification.operationId
                        let OperationId key = specification.operationId
                        context.idempotencyKey @?= key
                        pure (Right ())
                    )
                )
          case prepared of Runner.ToolReady request -> request.input.invocation @?= input.invocation; _ -> assertFailure "approved tool should be prepared"
          run env (Runner.prepareAcceptedTool now True Nothing freshAccess specification.operationId [observationBinding] (\_ -> assertFailure "stop gate should run first" >> pure (Right ()))) >>= (@?= Left (ExecutionPolicyRefused "execution stop requested"))
          run env (Runner.prepareAcceptedTool permission.expiresAt False Nothing freshAccess specification.operationId [observationBinding] (\_ -> assertFailure "expired permission reached authorization" >> pure (Right ()))) >>= (@?= Left (ExecutionPolicyRefused "tool permission expired")),
      testCase "expired permission refuses approval and records timeout without a new turn" $
        withConfiguredFixture fixture (\snapshot -> toolConfiguration snapshot & #policy . #humanTools .~ ["observe"] & #policy . #permissionSeconds .~ 1) \env snapshot access -> do
          (response, assistant) <- commitToolRequest env snapshot access
          let input = ToolOperationInput response 0 (head (toolInvocations assistant)) observationBinding
              specification = toolSpec snapshot 1 input
          _ <- expectRight =<< run env (Store.acceptOperation access 2 specification (toJSON input))
          permission <- expectRight =<< run env (Store.parkOperationPermission access 3 specification.operationId)
          run env (Store.resolveOperationPermission access 4 specification.operationId permission.reviewRequestId TimedOut) >>= (@?= Left (ExecutionPolicyRefused "tool permission deadline has not elapsed"))
          threadDelay 1100000
          run env (Store.resolveOperationPermission access 4 specification.operationId permission.reviewRequestId (Approved (object []))) >>= (@?= Left (ExecutionPolicyRefused "tool permission expired"))
          run env (Store.resolveOperationPermission access 4 specification.operationId permission.reviewRequestId TimedOut) >>= (@?= Right R.Accepted)
          run env (Store.resolveOperationPermission access 4 specification.operationId permission.reviewRequestId TimedOut) >>= (@?= Right R.AlreadyAccepted)
          run env (Store.recordOutcomeAndAdvance access 5 specification.operationId (ToolReturned [TextBlock "forbidden callback"] False) NeedModel Nothing) >>= (@?= Left (ExecutionPolicyRefused "tool permission was not approved"))
          (_, state) <- expectRight =<< run env (Store.loadExecution access)
          state.modelTurns @?= 1
          state.cursor @?= 1,
      testCase "admission and fresh-connection reconstruction preserve the immutable snapshot" $
        withFixture fixture \env snapshot access -> do
          run env (Store.admitExecution snapshot) >>= (@?= Right R.AlreadyAccepted)
          changed <- pure (snapshot & #instructions . #body .~ "changed instructions")
          run env (Store.admitExecution changed) >>= (@?= Left ExecutionIdentityConflict)
          tracer <- noopTracer
          let restarted = AppEnv env.connectionSettings tracer env.metrics
          fresh <- expectRight =<< run restarted (Store.authorizeReplay snapshot.executionId snapshot.identity (pure (Right ())))
          (restored, state) <- expectRight =<< run restarted (Store.loadExecution fresh)
          restored @?= snapshot
          state.cursor @?= 0
          state.phase @?= Active
          run env (Store.loadExecution access) >>= (@?= Right (snapshot, state)),
      testCase "wrong identity and revoked runtime cannot obtain replay access" $
        withFixture fixture \env snapshot _ -> do
          wrong <- run env (Store.authorizeReplay snapshot.executionId (compatibilityIdentity "other") (pure (Right ())))
          assertBool "wrong identity refused" (case wrong of Left ReplayReadRefused -> True; _ -> False)
          revoked <- run env (Store.authorizeReplay snapshot.executionId snapshot.identity (pure (Left "revoked")))
          assertBool "revoked identity refused" (case revoked of Left ReplayReadRefused -> True; _ -> False),
      testCase "inspection contains references and metadata without replay bodies" $
        withFixture fixture \env snapshot access -> do
          (_, operation) <- expectRight =<< run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput)
          readInput <- expectRight =<< run env (Store.readReplayPayload @Value access "operation-input" operation.input)
          readInput @?= secretInput
          metadata <- inspect env snapshot.executionId
          assertBool "no protected marker in operator data" (not ("PRIVATE_REPLAY_MARKER" `Text.isInfixOf` Text.pack (show (Aeson.encode metadata)))),
      testCase "a permit for a different execution cannot read the first execution payload" $
        withFixture fixture \env snapshot access -> do
          (_, state) <- expectRight =<< run env (Store.loadExecution access)
          let second = anotherSnapshot snapshot "second-assignment"
          run env (Store.admitExecution second) >>= (@?= Right R.Accepted)
          other <- expectRight =<< run env (Store.authorizeReplay second.executionId second.identity (pure (Right ())))
          result <- run env (Store.readReplayPayload @Value other "snapshot" state.snapshot)
          result @?= Left CorruptReplay,
      testCase "oversized and unsupported snapshots refuse before admission" $
        withFixture fixture \env snapshot _ -> do
          let future = anotherSnapshot snapshot "future" & #format .~ 2
              huge = anotherSnapshot snapshot "huge" & #instructions . #body .~ Text.replicate 1048577 "x"
          run env (Store.admitExecution future) >>= (@?= Left UnsupportedReplay)
          run env (Store.admitExecution huge) >>= (@?= Left PayloadTooLarge)
          inspect env huge.executionId >>= (@?= Nothing),
      testCase "identical accepted operations converge and changed requests conflict" $
        withFixture fixture \env snapshot access -> do
          (admission, first) <- expectRight =<< run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput)
          admission @?= R.Accepted
          run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput) >>= (@?= Right (R.AlreadyAccepted, first))
          run env (Store.acceptOperation access 0 (spec snapshot 0) (object [])) >>= (@?= Left OperationConflict)
          snapshotRoot <- expectRight =<< run env (Roots.inspectRoot rootId)
          snapshotRoot.usage @?= R.emptyUsage,
      testCase "racing distinct proposals at one cursor admit exactly one immutable operation" $
        withFixture fixture \env snapshot access -> do
          (a, b) <-
            concurrently
              (run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput))
              (run env (Store.acceptOperation access 0 (spec snapshot 0) (object [])))
          assertBool "one accepted proposal" (isAccepted a /= isAccepted b)
          Just (state, _, operations) <- inspect env snapshot.executionId
          state.revision @?= 1
          state.cursor @?= 0
          length operations @?= 1,
      testCase "fault after outcome writes rolls back payload cursor call facts and root settlement" $
        withFixture fixture \env snapshot access -> do
          (_, operation) <- expectRight =<< run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput)
          receipt <- reserveCall env snapshot operation
          before <- payloadCount env snapshot.executionId
          run env (Store.recordOutcomeAndAdvanceWith access 1 operation.specification.operationId modelOutcome NeedModel (Just (receipt, terminal)) (pure (Left ExecutionCommandRefused))) >>= (@?= Left ExecutionCommandRefused)
          payloadCount env snapshot.executionId >>= (@?= before)
          Just pending <- inspectOperation env operation.specification.operationId
          pending.outcome @?= Nothing
          Just (state, _, _) <- inspect env snapshot.executionId
          state.revision @?= 1
          state.cursor @?= 0
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          root.active @?= 1
          root.known @?= Map.empty
          run env (Store.recordOutcomeAndAdvance access 1 operation.specification.operationId modelOutcome NeedModel (Just (receipt, terminal))) >>= (@?= Right R.Accepted)
          run env (Store.recordOutcomeAndAdvance access 1 operation.specification.operationId modelOutcome NeedModel (Just (receipt, terminal))) >>= (@?= Right R.AlreadyAccepted)
          run env (Store.recordOutcomeAndAdvance access 1 operation.specification.operationId modelOutcome WorkFinished (Just (receipt, terminal))) >>= (@?= Left OperationConflict)
          settled <- expectRight =<< run env (Roots.inspectRoot rootId)
          settled.active @?= 0
          settled.unknown @?= 1
          Map.lookup R.ModelAttempts settled.known @?= Just 1
          Map.lookup R.Tokens settled.known @?= Just 3,
      testCase "root cancellation preserves accepted outcomes and prevents new logical work" $
        withFixture fixture \env snapshot access -> do
          (_, operation) <- expectRight =<< run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput)
          receipt <- reserveCall env snapshot operation
          run env (Roots.setRootControl rootId 0 True Nothing) >>= (@?= Right ())
          run env (Store.recordOutcomeAndAdvance access 1 operation.specification.operationId modelOutcome NeedModel (Just (receipt, terminal))) >>= (@?= Right R.Accepted)
          result <- run env (Store.acceptOperation access 2 (spec snapshot 1) secretInput)
          result @?= Left (ResourceAdmissionRefused "RootCancelled")
          Just (state, _, _) <- inspect env snapshot.executionId
          state.revision @?= 2
          state.cursor @?= 1,
      testCase "unknown effects preserve reservations and cannot advance as known outcomes" $
        withFixture fixture \env snapshot access -> do
          (_, operation) <- expectRight =<< run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput)
          receipt <- reserveCall env snapshot operation
          let unknown = Calls.CallOutcome Calls.CallTransportUnknown Map.empty [R.Tokens, R.CostMicroUsd] Nothing Nothing Nothing
          run env (Store.recordOutcomeAndAdvance access 1 operation.specification.operationId (OperationUnresolved "dispatch outcome unknown") NeedModel (Just (receipt, unknown))) >>= (@?= Right R.Accepted)
          Just (state, _, _) <- inspect env snapshot.executionId
          state.phase @?= Unresolved
          state.cursor @?= 0
          run env (Store.recordOutcomeAndAdvance access 2 operation.specification.operationId modelOutcome NeedModel (Just (receipt, terminal))) >>= (@?= Left OperationConflict)
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          root.active @?= 1
          root.unknown @?= 1,
      testCase "a terminal result retains its protected outcome and converges after restart" $
        withFixture fixture \env snapshot access -> do
          (_, operation) <- expectRight =<< run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput)
          receipt <- reserveCall env snapshot operation
          outcomeRef <- expectRight (Store.outcomeReference modelOutcome)
          run env (Store.recordOutcomeAndAdvance access 1 operation.specification.operationId modelOutcome (NeedValidation outcomeRef) (Just (receipt, terminal))) >>= (@?= Right R.Accepted)
          let output = object ["reply" .= ("accepted reply" :: Text)]
          run env (Store.finishExecution access 2 output) >>= (@?= Right R.Accepted)
          run env (Store.finishExecution access 2 output) >>= (@?= Right R.AlreadyAccepted)
          fresh <- expectRight =<< run env (Store.authorizeReplay snapshot.executionId snapshot.identity (pure (Right ())))
          (_, state) <- expectRight =<< run env (Store.loadExecution fresh)
          state.phase @?= Succeeded
          ref <- maybe (assertFailure "terminal reference missing") pure state.result
          run env (Store.readReplayPayload @Value fresh "execution-result" ref) >>= (@?= Right output),
      testCase "terminal validation cannot be bypassed by supplying a different reply" $
        withFixture fixture \env original _ -> do
          let snapshot = anotherSnapshot original "validated-output" & #policy . #output .~ NonemptyReply
          run env (Store.admitExecution snapshot) >>= (@?= Right R.Accepted)
          access <- expectRight =<< run env (Store.authorizeReplay snapshot.executionId snapshot.identity (pure (Right ())))
          (_, operation) <- expectRight =<< run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput)
          receipt <- reserveCall env snapshot operation
          let empty = ModelReturned (ReplayAssistant 1 [] Stop Nothing Nothing (object []) Nothing) Nothing
          ref <- expectRight (Store.outcomeReference empty)
          run env (Store.recordOutcomeAndAdvance access 1 operation.specification.operationId empty (NeedValidation ref) (Just (receipt, terminal))) >>= (@?= Right R.Accepted)
          run env (Store.finishExecution access 2 (object ["reply" .= ("invented replacement" :: Text)])) >>= (@?= Left ExecutionOutputInvalid)
          Just (state, _, _) <- inspect env snapshot.executionId
          state.phase @?= Active
          state.result @?= Nothing,
      testCase "output repair consumes a normal model turn and has an immutable ceiling" $
        withConfiguredFixture fixture (\snapshot -> snapshot & #policy . #output .~ NonemptyReply & #policy . #outputRepairs .~ 1) \env snapshot access -> do
          (_, operation) <- expectRight =<< run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput)
          receipt <- reserveCall env snapshot operation
          let invalid = ModelReturned (ReplayAssistant 1 [TextBlock ""] Stop Nothing Nothing (object []) Nothing) Nothing
          response <- expectRight (Store.outcomeReference invalid)
          run env (Store.recordOutcomeAndAdvance access 1 operation.specification.operationId invalid (NeedValidation response) (Just (receipt, terminal))) >>= (@?= Right R.Accepted)
          (_, repair) <- expectRight =<< run env (Store.acceptOperation access 2 (spec snapshot 1 & #kind .~ ModelRepair) secretInput)
          (_, state) <- expectRight =<< run env (Store.loadExecution access)
          state.repairs @?= 1
          state.modelTurns @?= 2
          retryReceipt <- reserveCall env snapshot repair
          run env (Store.recordOutcomeAndAdvance access 3 repair.specification.operationId invalid (NeedValidation response) (Just (retryReceipt, terminal))) >>= (@?= Right R.Accepted)
          run env (Store.acceptOperation access 4 (spec snapshot 2 & #kind .~ ModelRepair) secretInput) >>= (@?= Left ExecutionOutputInvalid)
          run env (Store.acceptOperation access 4 (spec snapshot 2 & #kind .~ ModelSummary) secretInput) >>= (@?= Left (ExecutionPolicyRefused "model summaries are disabled"))
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          Map.lookup R.ModelAttempts root.usage.settled @?= Just 2
          Map.lookup R.Tokens root.usage.settled @?= Just 6,
      testCase "the immutable model-turn ceiling survives accepted refusals" $
        withFixture fixture \env original _ -> do
          let snapshot = anotherSnapshot original "one-turn" & #policy . #maxModelTurns .~ 1
          run env (Store.admitExecution snapshot) >>= (@?= Right R.Accepted)
          access <- expectRight =<< run env (Store.authorizeReplay snapshot.executionId snapshot.identity (pure (Right ())))
          (_, operation) <- expectRight =<< run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput)
          run env (Store.recordOutcomeAndAdvance access 1 operation.specification.operationId (OperationDenied "hard policy refused") NeedModel Nothing) >>= (@?= Right R.Accepted)
          run env (Store.acceptOperation access 2 (spec snapshot 1) secretInput) >>= (@?= Left (ResourceAdmissionRefused "model-turn limit exhausted"))
          Just (state, _, operations) <- inspect env snapshot.executionId
          state.modelTurns @?= 1
          state.cursor @?= 1
          length operations @?= 1,
      testCase "catalog fencing refuses replay inspection and operation admission" $
        withFixture fixture \env snapshot access -> do
          let request =
                Rebuild.RebuildRequest
                  { rebuildRunId = mustRight (Rebuild.mkRebuildRunId "execution-offline"),
                    requestedBy = "execution-fixture",
                    requestReason = "verify protected replay fence",
                    replayFrom = GlobalPosition 0
                  }
          _ <- expectRight =<< run env (Rebuild.beginGroupRebuild Catalog.validatedProjectionCatalog ExecutionCatalog.executionStoreRebuildGroupId request)
          run env (Store.loadExecution access) >>= (@?= Left ProjectionUnavailable)
          run env (Store.inspectExecution snapshot.executionId) >>= (@?= Left ProjectionUnavailable)
          run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput) >>= (@?= Left ProjectionUnavailable)
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          root.usage @?= R.emptyUsage,
      testCase "corrupt protected replay fails before the runtime can obtain a context" $
        withFixture fixture \env snapshot access -> do
          run env (runTransaction (Tx.statement snapshot.executionId.value corruptPayload))
          run env (Store.loadExecution access) >>= (@?= Left CorruptReplay)
    ]

summaryConfiguration :: ExecutionSnapshot -> ExecutionSnapshot
summaryConfiguration snapshot =
  toolConfiguration snapshot
    & #policy
    . #contextBytes
    .~ 2300
    & #policy
    . #keepRecentMessages
    .~ 1
    & #policy
    . #summaryTokens
    .~ Just 128
    & #initialContext
    . #messages
    .~ ([UserTurn [TextBlock "PRIVATE_REPLAY_MARKER"] Nothing] <> replicate 4 (UserTurn [TextBlock (Text.replicate 500 "x")] Nothing) <> [UserTurn [TextBlock "recent request"] Nothing])

-- Every invocation opens fresh app/store effects; only the provider counters
-- survive in the fixture. Production restarts reconstruct from the same rows.
driverRuntime :: AppEnv -> Bool -> IO (Executor.ExecutionRuntime, IO [Context.Context], IO Int)
driverRuntime env toolResponse = do
  observed <- newIORef []
  toolCalls <- newIORef 0
  base <- newBehaviorEnv
  let complete model context options = do
        ordinal <- atomicModifyIORef' observed (\values -> (values <> [context], length values))
        response <- Provider.complete stubApiProvider model context options
        pure (if toolResponse && ordinal == 0 then response & #message . #stopReason .~ ToolUse & #message . #content .~ Vector.fromList [Content.AssistantToolCall (Content.ToolCall "first" "observe" (object [])), Content.AssistantToolCall (Content.ToolCall "second" "observe" (object []))] else response)
      provider = stubApiProvider {Provider.complete = complete, Provider.stream = liftCompleteToStream complete}
      tool = mkDynTool "observe" "Observe fixture." (object []) \_ -> do
        unsafeEff_ (modifyIORef' toolCalls (+ 1))
        pure (Right (ToolOutput.textToolOutput "accepted observation"))
  registry <- Provider.newProviderRegistryFrom [provider]
  let selectedRuntime = SelectionRuntime (mustRight (modelCatalog [])) Nothing [provider] (base & #providerRegistry .~ Just registry) (runCorrelationId "driver") (pure (Right ())) (selectionTransaction env Nothing)
      executor = Executor.ExecutionRuntime env (const (pure (Right ()))) (const (pure (Right ()))) (const selectedRuntime) (\_ _ _ use -> Right <$> use [Executor.BoundTool observationBinding tool]) 5
  pure (executor, readIORef observed, readIORef toolCalls)

reachPermission :: AppEnv -> Executor.ExecutionRuntime -> ExecutionSnapshot -> Int -> IO PermissionBinding
reachPermission env executor snapshot remaining
  | remaining <= 0 = assertFailure "driver did not reach its permission boundary" >> fail "permission"
  | otherwise = do
      result <- run env (runWorkflow DriverGenerated.workflowName (executionWorkflowId snapshot.executionId) (Driver.executionWorkflow executor (Just (Driver.ExecutionStart snapshot.executionId))))
      case result of
        ContinuedAsNew -> reachPermission env executor snapshot (remaining - 1)
        Suspended -> do
          Just (state, _, operations) <- inspect env snapshot.executionId
          case [permission | operation <- operations, Just permission <- [operation.permission], state.activeOperation == Just operation.specification.operationId, state.phase == Parked] of
            [permission] -> pure permission
            _ -> do
              reference <- pendingReference env snapshot
              Executor.executeAcceptedAttempt executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
              reachPermission env executor snapshot (remaining - 1)
        _ -> assertFailure (show result) >> fail "permission outcome"

pendingReference :: AppEnv -> ExecutionSnapshot -> IO Attempt.JobReference
pendingReference env snapshot = do
  Just (state, _, _) <- inspect env snapshot.executionId
  operation <- maybe (assertFailure "no active operation" >> fail "active") pure state.activeOperation
  attempts <- expectRight =<< run env (Store.inspectOperationAttempts operation)
  case filter (\attempt -> attempt.phase /= Attempt.AttemptAbandoned) attempts of
    [attempt] -> pure (Attempt.JobReference 1 snapshot.executionId operation attempt.request.attemptId)
    _ -> assertFailure "expected one prepared attempt" >> fail "attempt"

pumpDriver :: AppEnv -> Executor.ExecutionRuntime -> ExecutionSnapshot -> Int -> IO Driver.ExecutionDriverResult
pumpDriver env executor snapshot remaining
  | remaining <= 0 = assertFailure "driver did not complete within its bounded fixture" >> fail "driver"
  | otherwise = do
      result <- run env (runWorkflow DriverGenerated.workflowName (executionWorkflowId snapshot.executionId) (Driver.executionWorkflow executor (Just (Driver.ExecutionStart snapshot.executionId))))
      case result of
        Completed value -> pure value
        ContinuedAsNew -> pumpDriver env executor snapshot (remaining - 1)
        Suspended -> do
          reference <- pendingReference env snapshot
          Executor.executeAcceptedAttempt executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
          pumpDriver env executor snapshot (remaining - 1)
        _ -> assertFailure (show result) >> fail "unexpected driver outcome"

nativeExecutorCase :: DatabaseFixture -> ToolInvoiceCost -> TestTree
nativeExecutorCase fixture billing = testCase (show billing <> " preserves rich output and survives release failure") $
  withConfiguredFixture fixture (\snapshot -> toolConfiguration snapshot & #toolBindings .~ [observationBinding & #invoiceCost .~ billing]) \env snapshot access -> do
    (response, assistant) <- commitToolRequest env snapshot access
    let binding = head snapshot.toolBindings
        input = ToolOperationInput response 0 (head (toolInvocations assistant)) binding
        specification = toolSpec snapshot 1 input
    (_, operation) <- expectRight =<< run env (Store.acceptOperation access 2 specification (toJSON input))
    invocations <- newIORef (0 :: Int)
    base <- newBehaviorEnv
    let tool = mkDynTool "observe" "Observe fixture." (object []) \_ -> do
          unsafeEff_ (modifyIORef' invocations (+ 1))
          pure (Right ((ToolOutput.textToolOutput "accepted") {ToolOutput.structuredContent = Just (object ["acceptedMessage" .= ("opaque-message-ref" :: Text)]), ToolOutput.extensionBlocks = [object ["native" .= True]]}))
        selectedRuntime = SelectionRuntime (mustRight (modelCatalog [])) Nothing [] base (runCorrelationId "tool-executor") (pure (Right ())) (selectionTransaction env Nothing)
        executor =
          Executor.ExecutionRuntime
            env
            (const (pure (Right ())))
            (const (pure (Right ())))
            (const selectedRuntime)
            ( \_ context requested use -> do
                requested @?= Just "observe"
                context.operationId @?= specification.operationId
                let OperationId key = specification.operationId
                context.idempotencyKey @?= key
                _ <- use [Executor.BoundTool binding tool]
                pure (Left (ExecutionPolicyRefused "fixture lease release failed"))
            )
            5
        request = Store.toolAttemptRequest (AttemptId "native-tool-attempt") specification.operationId binding
        reference = Attempt.JobReference 1 snapshot.executionId specification.operationId request.attemptId
    run env (runTransaction (registerAwakeableTx UUID.nil "shikigami.execution" (executionWorkflowId snapshot.executionId).unWorkflowId))
    _ <- expectRight =<< run env (Store.submitExecutionAttemptWith access 3 (Attempt.AttemptSubmission request Nothing (Attempt.ExecutionWake (AwakeableId UUID.nil) 0)) (\_ -> pure ()))
    Executor.executeAcceptedAttempt executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
    Executor.executeAcceptedAttempt executor snapshot.identity reference >>= (@?= Right Executor.ExecutorDone)
    readIORef invocations >>= (@?= 1)
    Just accepted <- inspectOperation env operation.specification.operationId
    ref <- maybe (assertFailure "missing native output" >> fail "outcome") pure accepted.outcome
    restored <- expectRight =<< run env (Store.readReplayPayload @OperationOutcome access "operation-outcome" ref)
    case restored of
      RichToolReturned result -> do
        result.structuredContent @?= Just (object ["acceptedMessage" .= ("opaque-message-ref" :: Text)])
        result.extensionBlocks @?= [object ["native" .= True]]
      _ -> assertFailure "rich native output was not preserved"
    Just wake <- run env (lookupAwakeable UUID.nil)
    wake.status @?= Awakeable.Completed
    root <- expectRight =<< run env (Roots.inspectRoot rootId)
    Map.lookup R.ToolAttempts root.usage.settled @?= Just 1
    root.active @?= 0
    root.unknown @?= (if billing == NoInvoiceCost then 1 else 2)
    when (billing == UnreportedInvoiceCost) (assertBool "unknown invoice was never turned into zero" (Map.notMember R.CostMicroUsd root.known))

modelSubmission :: Operation -> Attempt.AttemptSubmission
modelSubmission operation =
  Attempt.AttemptSubmission
    (R.AttemptRequest (AttemptId "prepared-model-attempt") operation.specification.operationId (Map.fromList [(R.ActiveWork, 1), (R.ModelAttempts, 1), (R.Tokens, 10)]) R.EnforcedCeiling)
    (Just (Attempt.ModelCallPreparation (Calls.CallLimits (Just 8) (Just 2) (Just 1) Nothing (Just 1000)) "actual-request-digest"))
    (Attempt.ExecutionWake (AwakeableId UUID.nil) 0)

terminalAttempt :: Attempt.AttemptResult
terminalAttempt = Attempt.AttemptResult modelOutcome (NeedValidation (mustRight (Store.outcomeReference modelOutcome))) (Just terminal)

withPreparedModel :: DatabaseFixture -> (AppEnv -> ExecutionSnapshot -> Store.ReplayAccess -> Operation -> Attempt.JobReference -> IO a) -> IO a
withPreparedModel fixture use = withFixture fixture \env snapshot access -> do
  (_, operation) <- expectRight =<< run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput)
  let submission = modelSubmission operation
  _ <- expectRight =<< run env (Store.submitExecutionAttemptWith access 1 submission (\_ -> pure ()))
  use env snapshot access operation (Attempt.JobReference 1 snapshot.executionId operation.specification.operationId submission.request.attemptId)

expectClaim :: Either ExecutionError Attempt.ClaimResult -> IO Attempt.AttemptClaim
expectClaim value = case value of Right (Attempt.ClaimGranted claim) -> pure claim; _ -> assertFailure (show value) >> fail "claim expected"

queueCount :: AppEnv -> IO Int64
queueCount env = run env (runTransaction (Tx.statement () (preparable "SELECT count(*) FROM pgmq.q_shikigami_run_jobs" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))))

observationBinding :: ToolBinding
observationBinding = ToolBinding "observe" "1" (versionedDigest "shikigami.tool-schema/1" (object [])) RepeatableObservation NoInvoiceCost

toolConfiguration :: ExecutionSnapshot -> ExecutionSnapshot
toolConfiguration snapshot = snapshot & #toolBindings .~ [observationBinding] & #offeredTools .~ toJSON [BaikaiTool.mkTool "observe" "Observe fixture." (object [])]

toolSpec :: ExecutionSnapshot -> Integer -> ToolOperationInput -> OperationSpec
toolSpec snapshot cursor input = OperationSpec (operationIdFor snapshot.executionId cursor) ToolOperation input.binding.recovery input.binding.name (versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy)) (toolScopeDigest input.binding) (Just input.position)

commitToolRequest :: AppEnv -> ExecutionSnapshot -> Store.ReplayAccess -> IO (PayloadRef, ReplayAssistant)
commitToolRequest = commitToolRequestWith terminal

commitToolRequestWith :: Calls.CallOutcome -> AppEnv -> ExecutionSnapshot -> Store.ReplayAccess -> IO (PayloadRef, ReplayAssistant)
commitToolRequestWith callOutcome env snapshot access = do
  (_, operation) <- expectRight =<< run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput)
  receipt <- reserveCall env snapshot operation
  let assistant = ReplayAssistant 1 [ToolBlock (ToolInvocation "first" "observe" (object [])), ToolBlock (ToolInvocation "second" "observe" (object []))] ToolUse Nothing Nothing (object []) Nothing
      outcome = ModelReturned assistant Nothing
  ref <- expectRight (Store.outcomeReference outcome)
  run env (Store.recordOutcomeAndAdvance access 1 operation.specification.operationId outcome (NeedTool ref 0) (Just (receipt, callOutcome))) >>= (@?= Right R.Accepted)
  pure (ref, assistant)

rootId :: ExecutionRootId
rootId = ExecutionRootId "transcript-root"

secretInput :: Value
secretInput = object ["request" .= ("PRIVATE_REPLAY_MARKER" :: Text)]

modelOutcome :: OperationOutcome
modelOutcome = ModelReturned (ReplayAssistant 1 [TextBlock "accepted reply"] Stop (Just "response") Nothing (object []) Nothing) (Just (object ["raw" .= ("provider evidence" :: Text)]))

terminal :: Calls.CallOutcome
terminal = Calls.CallOutcome Calls.CallTerminal (Map.singleton R.Tokens 3) [R.CostMicroUsd] (Just "served-model") (Just "provider-call") Nothing

spec :: ExecutionSnapshot -> Integer -> OperationSpec
spec snapshot cursor = OperationSpec (operationIdFor snapshot.executionId cursor) ModelTurn RepeatableObservation "model" (versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy)) "scope-digest" Nothing

reserveCall :: AppEnv -> ExecutionSnapshot -> Operation -> IO Calls.CallReceipt
reserveCall env snapshot operation = do
  now <- getCurrentTime
  let OperationId operationKey = operation.specification.operationId
      request = R.AttemptRequest (AttemptId ("attempt:" <> operationKey)) operation.specification.operationId (Map.fromList [(R.ActiveWork, 1), (R.ModelAttempts, 1), (R.Tokens, 10), (R.CostMicroUsd, 0)]) R.EnforcedCeiling
      limits = Calls.CallLimits (Just 8) (Just 2) (Just 1) Nothing (Just 1000)
  result <- expectRight =<< run env (Calls.reserveSelectionCall snapshot.selection limits request "actual-request-digest" now)
  case result of Calls.NewCall receipt -> pure receipt; _ -> assertFailure "new actual attempt expected"

anotherSnapshot :: ExecutionSnapshot -> Text -> ExecutionSnapshot
anotherSnapshot snapshot assignment = snapshot & #executionId .~ executionIdFor assignment & #selection . #assignmentId .~ assignment

withFixture :: DatabaseFixture -> (AppEnv -> ExecutionSnapshot -> Store.ReplayAccess -> IO a) -> IO a
withFixture fixture = withConfiguredFixture fixture id

withConfiguredFixture :: DatabaseFixture -> (ExecutionSnapshot -> ExecutionSnapshot) -> (AppEnv -> ExecutionSnapshot -> Store.ReplayAccess -> IO a) -> IO a
withConfiguredFixture fixture configure = withConfiguredResourceFixture fixture configure id

withConfiguredResourceFixture :: DatabaseFixture -> (ExecutionSnapshot -> ExecutionSnapshot) -> (R.Limits -> R.Limits) -> (AppEnv -> ExecutionSnapshot -> Store.ReplayAccess -> IO a) -> IO a
withConfiguredResourceFixture fixture configure editLimits use = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  now <- getCurrentTime
  session <- genSessionId
  let env = AppEnv (defaultConnectionSettings connection) tracer Nothing
      limits = editLimits (Map.insert R.Tokens (R.Limited 1000) (Map.fromList [(dimension, R.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]))
      selection = mustRight (resolveExecutionSelection "transcript-assignment" (mustRight (modelCatalog [])) (defaultBinding stubModel emptyOptions) Nothing Nothing Nothing Nothing (Just rootId) now)
      snapshot = configure (ExecutionSnapshot 1 (executionIdFor selection.assignmentId) "transcript-run" (AgentName "worker") (compatibilityIdentity "worker") session selection Nothing (SkillInstructions "fixture" "system" "PRIVATE_REPLAY_MARKER") (ReplayContext 1 (Just "system") [UserTurn [TextBlock "PRIVATE_REPLAY_MARKER"] Nothing]) emptyResolvedCapabilitySet (toJSON ([] :: [Value])) defaultHarnessPolicy [])
  _ <- expectRight =<< run env Catalog.registerProjectionCatalog
  run env (Roots.enrollRoot rootId (R.Envelope limits (addUTCTime 3600 now))) >>= (@?= Right R.Accepted)
  run env (Store.admitExecution snapshot) >>= (@?= Right R.Accepted)
  access <- expectRight =<< run env (Store.authorizeReplay snapshot.executionId snapshot.identity (pure (Right ())))
  use env snapshot access

payloadCount :: AppEnv -> ExecutionId -> IO Int64
payloadCount env execution = run env (runTransaction (Tx.statement execution.value (preparable "SELECT count(*) FROM shikigami.execution_payloads WHERE execution_id=$1" (E.param (E.nonNullable E.text)) (D.singleRow (D.column (D.nonNullable D.int8))))))

corruptPayload :: Statement Text ()
corruptPayload = preparable "UPDATE shikigami.execution_payloads SET body=jsonb_set(body,'{format}','2'::jsonb) WHERE execution_id=$1" (E.param (E.nonNullable E.text)) D.noResult

isAccepted :: Either e (R.Admission, a) -> Bool
isAccepted (Right (R.Accepted, _)) = True
isAccepted _ = False

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= expectRight

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

mustRight :: (Show e) => Either e a -> a
mustRight = either (error . show) id

inspect :: AppEnv -> ExecutionId -> IO (Maybe (ExecutionState, Store.ExecutionBinding, [Operation]))
inspect env execution = run env (Store.inspectExecution execution) >>= expectRight

inspectOperation :: AppEnv -> OperationId -> IO (Maybe Operation)
inspectOperation env operation = run env (Store.inspectOperation operation) >>= expectRight

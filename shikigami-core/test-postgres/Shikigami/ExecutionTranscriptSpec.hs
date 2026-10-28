module Shikigami.ExecutionTranscriptSpec (tests) where

import Baikai.Api (Api (OpenAIResponses))
import Baikai.Message qualified as Message
import Baikai.Options (emptyOptions)
import Baikai.StopReason (StopReason (Stop, ToolUse))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.IORef
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.ReadModel.Rebuild qualified as Rebuild
import Keiro.Workflow (WorkflowId (..), WorkflowName (..), WorkflowOutcome (..), defaultWorkflowRunOptions, runWorkflow)
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Keiro.Workflow.Child (runChildWorkflow)
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kioku.Id (genSessionId)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (GlobalPosition (..))
import Shikigami.Agent.Approval (ApprovalChannel (..), ApprovalDecision (..), ApprovalRequest (..), approvalWorkflowId, resolveApproval)
import Shikigami.Agent.Approval.Workflow qualified as Approval
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Behavior.StubProvider (stubModel)
import Shikigami.Capability.Overlay (emptyResolvedCapabilitySet)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Decision.ModelCatalog (modelCatalog)
import Shikigami.Execution.Catalog qualified as ExecutionCatalog
import Shikigami.Execution.Identity
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Resources qualified as R
import Shikigami.Execution.Runner qualified as Runner
import Shikigami.Execution.Selection
import Shikigami.Execution.Store qualified as Store
import Shikigami.Execution.Transcript
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Prelude ((&), (.~))
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Store.ExecutionResources qualified as Roots
import Shikigami.Store.ExecutionSelection qualified as Calls
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "ExecutionTranscript"
    [ testCase "assistant replay retains opaque thinking and exact cut-off tool arguments" do
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

observationBinding :: ToolBinding
observationBinding = ToolBinding "observe" "1" "schema-digest" RepeatableObservation

toolConfiguration :: ExecutionSnapshot -> ExecutionSnapshot
toolConfiguration snapshot = snapshot & #toolBindings .~ [observationBinding]

toolSpec :: ExecutionSnapshot -> Integer -> ToolOperationInput -> OperationSpec
toolSpec snapshot cursor input = OperationSpec (operationIdFor snapshot.executionId cursor) ToolOperation input.binding.recovery input.binding.name (versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy)) (toolScopeDigest input.binding) (Just input.position)

commitToolRequest :: AppEnv -> ExecutionSnapshot -> Store.ReplayAccess -> IO (PayloadRef, ReplayAssistant)
commitToolRequest env snapshot access = do
  (_, operation) <- expectRight =<< run env (Store.acceptOperation access 0 (spec snapshot 0) secretInput)
  receipt <- reserveCall env snapshot operation
  let assistant = ReplayAssistant 1 [ToolBlock (ToolInvocation "first" "observe" (object [])), ToolBlock (ToolInvocation "second" "observe" (object []))] ToolUse Nothing Nothing (object []) Nothing
      outcome = ModelReturned assistant Nothing
  ref <- expectRight (Store.outcomeReference outcome)
  run env (Store.recordOutcomeAndAdvance access 1 operation.specification.operationId outcome (NeedTool ref 0) (Just (receipt, terminal))) >>= (@?= Right R.Accepted)
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
      request = R.AttemptRequest (AttemptId ("attempt:" <> operationKey)) operation.specification.operationId (Map.fromList [(R.ActiveWork, 1), (R.ModelAttempts, 1), (R.Tokens, 10)]) R.EnforcedCeiling
      limits = Calls.CallLimits (Just 8) (Just 2) (Just 1) Nothing (Just 1000)
  result <- expectRight =<< run env (Calls.reserveSelectionCall snapshot.selection limits request "actual-request-digest" now)
  case result of Calls.NewCall receipt -> pure receipt; _ -> assertFailure "new actual attempt expected"

anotherSnapshot :: ExecutionSnapshot -> Text -> ExecutionSnapshot
anotherSnapshot snapshot assignment = snapshot & #executionId .~ executionIdFor assignment & #selection . #assignmentId .~ assignment

withFixture :: DatabaseFixture -> (AppEnv -> ExecutionSnapshot -> Store.ReplayAccess -> IO a) -> IO a
withFixture fixture = withConfiguredFixture fixture id

withConfiguredFixture :: DatabaseFixture -> (ExecutionSnapshot -> ExecutionSnapshot) -> (AppEnv -> ExecutionSnapshot -> Store.ReplayAccess -> IO a) -> IO a
withConfiguredFixture fixture configure use = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  now <- getCurrentTime
  session <- genSessionId
  let env = AppEnv (defaultConnectionSettings connection) tracer Nothing
      limits = Map.insert R.Tokens (R.Limited 1000) (Map.fromList [(dimension, R.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]])
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

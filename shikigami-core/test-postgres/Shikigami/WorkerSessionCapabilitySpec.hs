module Shikigami.WorkerSessionCapabilitySpec (tests) where

import Control.Exception (SomeException, try)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as AssignmentText
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff, runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Keiro.Workflow (PatchId (..), Workflow, WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), WorkflowOutcome (Completed, ContinuedAsNew, Suspended), WorkflowRunOptions (..), appendJournalEntry, continueAsNew, loadStepIndex, runWorkflowWith)
import Keiro.Workflow.Awakeable (AwakeableId (..), awakeableIdText, awakeableIdToUuid)
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Keiro.Workflow.Gc (WorkflowGcPolicy (..), gcWorkflowsOnce)
import Keiro.Workflow.Instance (lookupInstance)
import Kioku.Id (genSessionId)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (ActionAuthorizationFailure (..), ActionAuthorizer (..), allowAllActionAuthorizerForTests)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (CoordinatingSkill, Flow))
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Agent.Workflow qualified as Agent
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Behavior.Run (newBehaviorEnv)
import Shikigami.Capability.Overlay (emptyResolvedCapabilitySet)
import Shikigami.Decision.Contract (ModelAlias (..), ModelDescriptor (..))
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Execution.AssignmentKey (AssignmentKey, parseAssignmentKey)
import Shikigami.Execution.Executor (BoundTool (..))
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Execution.Policy.Types (defaultHarnessPolicy)
import Shikigami.Execution.Resources (Admission (..))
import Shikigami.Execution.Runner (OperationContext (..))
import Shikigami.Execution.Selection (ExecutionSelection (..), SelectionSource (ProcessDefault))
import Shikigami.Execution.SelectionRuntime (assignmentIdFor)
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Tools (NativeToolFactory (..))
import Shikigami.Execution.Transcript qualified as Replay
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Flow.Workers qualified as Flow
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude hiding ((.=))
import Shikigami.RouterWorkflowSpec qualified as Fixture
import Shikigami.StateRevision (StateRevision, parseRevision)
import Shikigami.WorkerSession.Capability
import Shikigami.WorkerSession.Handoff (TransferServices (..))
import Shikigami.WorkerSession.Identity (sessionWorkflowId, sessionWorkflowName)
import Shikigami.WorkerSession.Input (InstructionText, SessionLimit (..), parseInstructionText)
import Shikigami.WorkerSession.Position (MessagePosition, parseMessagePosition)
import Shikigami.WorkerSession.Store qualified as Store
import Shikigami.WorkerSession.Tools qualified as Tools
import Shikigami.WorkerSession.Types qualified as Session
import Shikigami.WorkerSession.Workflow (SessionRuntime (..))
import Shikigami.WorkerSessionStoreSpec (checkpointVersion, fixtureCheckpoints, withFixture)
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (runLLM)
import Shikumi.Tool (lowerSomeTool, runErasedOutput)
import Shikumi.Tool.Output (ToolOutput (..))
import System.Mem (performGC)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "WorkerSessionCapability"
    [ testCase "admitted commands retain acknowledgements across objective changes and reject fresh revoked writes" $
        withCapabilityFixture fixture \env admission host scope authorizer revoked _ -> do
          grant <- permit env host scope authorizer
          let session = Session.sessionIdFor admission
              input = SendWorker session (fixtureRevision 0) (fixtureRevision 0) (draft "PRIVATE_COMMAND")
          first <- expectRight =<< run env (executeCommand host authorizer grant (OperationId "send") input)
          case first of MessageAcceptedReply Accepted _ -> pure (); _ -> assertFailure (show first)
          let unavailable = host & #services . #sessions . #checkpoints .~ Nothing
          replayWithoutProvider <- expectRight =<< run env (executeCommand unavailable authorizer grant (OperationId "send") input)
          case replayWithoutProvider of MessageAcceptedReply AlreadyAccepted _ -> pure (); _ -> assertFailure (show replayWithoutProvider)
          replay <- expectRight =<< run env (executeCommand host authorizer grant (OperationId "send") input)
          case replay of MessageAcceptedReply AlreadyAccepted _ -> pure (); _ -> assertFailure (show replay)
          run env (executeCommand host authorizer grant (OperationId "send") (SendWorker session (fixtureRevision 0) (fixtureRevision 0) (draft "changed"))) >>= (@?= Left Session.MessageConflict)
          run env (executeCommand host authorizer grant (OperationId "stale") (SendWorker session (fixtureRevision 1) (fixtureRevision 0) (draft "stale" & #objectiveRevision .~ (fixtureRevision 99)))) >>= (@?= Left Session.SessionOwnerRefused)
          writeIORef revoked True
          run env (executeCommand host authorizer grant (OperationId "revoked") (SendWorker session (fixtureRevision 1) (fixtureRevision 0) (draft "no"))) >>= (@?= Left Session.SessionOwnerRefused)
          Just (state, _) <- expectRight =<< run env (Store.inspectSession session)
          state.nextSequence @?= (fixtureRevision 1),
      testCase "retry repairs driver registration after a mailbox acceptance acknowledgement was lost" $
        withCapabilityFixture fixture \env admission host scope authorizer _ _ -> do
          let session = Session.sessionIdFor admission
          access <- expectRight =<< run env (Store.authorizeSession session admission.context.identity (pure (Right ())))
          _ <- expectRight =<< run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (OperationId "send-before-registration") (Session.Instruction 1 Session.FollowUp (fixtureInstruction "retained") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing))
          run env (lookupInstance sessionWorkflowName (sessionWorkflowId session)) >>= (@?= Nothing)
          grant <- permit env host scope authorizer
          reply <- expectRight =<< run env (executeCommand host authorizer grant (OperationId "send-before-registration") (SendWorker session (fixtureRevision 0) (fixtureRevision 0) (draft "retained")))
          case reply of MessageAcceptedReply AlreadyAccepted _ -> pure (); _ -> assertFailure (show reply)
          registered <- run env (lookupInstance sessionWorkflowName (sessionWorkflowId session))
          assertBool "registered for the common resume registry" (isJust registered)
          entries <- run env (loadStepIndex sessionWorkflowName (sessionWorkflowId session) 0)
          Map.lookup "ingest-session" entries @?= Just (Aeson.object ["sessionId" .= session]),
      testCase "find reuses the admitted session after parent rotation without replacing frozen context" $
        withCapabilityFixture fixture \env admission host scope authorizer _ _ -> do
          nextMemory <- genSessionId
          let rotated = scope & #run . #runId .~ "rotated-parent" & #run . #sessionId .~ nextMemory & #context . #sessionId .~ Just nextMemory
              authority = CoordinationAuthority (\_ -> pure (Right (Just rotated))) (\_ ref -> pure (if ref == scopeFingerprint rotated then Right rotated else Left "missing"))
              nextHost = CoordinationHost host.services authority
          grant <- permit env nextHost rotated authorizer
          result <- expectRight =<< run env (executeCommand nextHost authorizer grant (OperationId "find-again") (FindWorker admission.scope.workerKey))
          case result of WorkerFound state -> state.sessionId @?= Session.sessionIdFor admission; _ -> assertFailure (show result)
          access <- expectRight =<< run env (Store.authorizeSession (Session.sessionIdFor admission) admission.context.identity (pure (Right ())))
          original <- expectRight =<< run env (Store.loadAdmission access)
          original.context.sessionId @?= admission.context.sessionId,
      testCase "foreign sessions and a scope count reset refuse without changing accepted work" $
        withCapabilityFixture fixture \env admission host scope authorizer _ _ -> do
          grant <- permit env host scope authorizer
          run env (executeCommand host authorizer grant (OperationId "foreign") (InspectWorker (Session.WorkerSessionId "foreign") (fixturePosition (-1)) 1)) >>= (@?= Left Session.SessionMissing)
          let slot = head scope.workers & #workerKey .~ "another-worker" & #sessionId .~ Nothing
              bounded = scope & #workers .~ [slot] & #maximumSessions .~ (fixtureLimit 1)
              authority = CoordinationAuthority (\_ -> pure (Right (Just bounded))) (\_ _ -> pure (Right bounded))
              restricted = CoordinationHost host.services authority
          limited <- permit env restricted bounded authorizer
          run env (executeCommand restricted authorizer limited (OperationId "excess-session") (FindWorker "another-worker")) >>= (@?= Left Session.SessionLimitExceeded),
      testCase "Flow event waits wake atomically and replay one retained event page" $
        withCapabilityFixture fixture \env admission host scope authorizer _ _ -> do
          let session = Session.sessionIdFor admission
              body = Flow.runWorkers (Just host) authorizer scope.run (Right (Just (scopeFingerprint scope))) (Flow.awaitEvents "findings" session (fixtureRevision 0) 100)
              drive = run env (runWorkflowWith (shikigamiWorkflowRunOptions env) flowName (WorkflowId scope.run.runId) body)
          drive >>= (@?= Suspended)
          grant <- permit env host scope authorizer
          _ <- expectRight =<< run env (executeCommand host authorizer grant (OperationId "send") (SendWorker session (fixtureRevision 1) (fixtureRevision 0) (draft "finding")))
          result <- drive
          case result of Completed (Right [_]) -> pure (); _ -> assertFailure (show result)
          drive >>= (@?= result)
          Just (state, _) <- expectRight =<< run env (Store.inspectSession session)
          state.nextSequence @?= (fixtureRevision 1),
      testCase "a listener journal conflict rolls back its wake and accepted message together" $
        withCapabilityFixture fixture \env admission host scope authorizer _ _ -> do
          let session = Session.sessionIdFor admission
              body = Flow.runWorkers (Just host) authorizer scope.run (Right (Just (scopeFingerprint scope))) (Flow.awaitEvents "findings" session (fixtureRevision 0) 100)
              workflow = WorkflowId scope.run.runId
          run env (runWorkflowWith (shikigamiWorkflowRunOptions env) flowName workflow body) >>= (@?= Suspended)
          token <- listenerToken env scope
          now <- getCurrentTime
          run env (appendJournalEntry flowName workflow (StepRecorded ("awk:" <> awakeableIdText token) (Aeson.String "conflict") now))
          grant <- permit env host scope authorizer
          run env (executeCommand host authorizer grant (OperationId "send") (SendWorker session (fixtureRevision 1) (fixtureRevision 0) (draft "rolled back"))) >>= (@?= Left Session.SessionStorageUnavailable)
          Just (state, _) <- expectRight =<< run env (Store.inspectSession session)
          state.revision @?= (fixtureRevision 1)
          state.eventCursor @?= (fixtureRevision 0)
          run env (runTransaction (Awakeable.lookupAwakeableStatusTx (awakeableIdToUuid token))) >>= (@?= Just Awakeable.Pending),
      testCase "an old listener cannot signal a rotated coordinator generation" $
        withCapabilityFixture fixture \env admission host scope authorizer _ _ -> do
          let session = Session.sessionIdFor admission
              workflow = WorkflowId scope.run.runId
              options = shikigamiWorkflowRunOptions env
              body = Flow.runWorkers (Just host) authorizer scope.run (Right (Just (scopeFingerprint scope))) (Flow.awaitEvents "findings" session (fixtureRevision 0) 100)
          run env (runWorkflowWith options flowName workflow body) >>= (@?= Suspended)
          token <- listenerToken env scope
          run env (runWorkflowWith options flowName workflow (continueAsNew (Aeson.object []) :: Eff (Workflow : AppEffects) ())) >>= (@?= ContinuedAsNew)
          grant <- permit env host scope authorizer
          _ <- expectRight =<< run env (executeCommand host authorizer grant (OperationId "send") (SendWorker session (fixtureRevision 1) (fixtureRevision 0) (draft "new fact")))
          successor <- run env (loadStepIndex flowName workflow 1)
          Map.lookup ("awk:" <> awakeableIdText token) successor @?= Nothing,
      testCase "a collected listener cannot poison the retained session mailbox" $
        withCapabilityFixture fixture \env admission host scope authorizer _ _ -> do
          let session = Session.sessionIdFor admission
              workflow = WorkflowId scope.run.runId
              body = Flow.runWorkers (Just host) authorizer scope.run (Right (Just (scopeFingerprint scope))) (Flow.awaitEvents "findings" session (fixtureRevision 0) 100)
          run env (runWorkflowWith (shikigamiWorkflowRunOptions env) flowName workflow body) >>= (@?= Suspended)
          token <- listenerToken env scope
          now <- getCurrentTime
          run env (appendJournalEntry flowName workflow (WorkflowCompleted now))
          _ <- run env (gcWorkflowsOnce (addUTCTime 1 now) (WorkflowGcPolicy 0 10))
          run env (Awakeable.lookupAwakeable (awakeableIdToUuid token)) >>= (@?= Nothing)
          access <- expectRight =<< run env (Store.authorizeSession session admission.context.identity (pure (Right ())))
          _ <- expectRight =<< run env (Store.acceptMessage access (fixtureRevision 1) (fixtureRevision 0) (OperationId "after-gc") (Session.Instruction 1 Session.FollowUp (fixtureInstruction "retained") (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing))
          Just (state, _) <- expectRight =<< run env (Store.inspectSession session)
          state.eventCursor @?= (fixtureRevision 1),
      testCase "coordinating Skills require admitted scope and retain a worker tool instead of running a fixed supervisor" $
        withCapabilityFixture fixture \env admission host scope authorizer _ _ -> do
          behavior <- newBehaviorEnv
          let declaration = scope.agent & #behavior .~ CoordinatingSkill "test/fixtures/durable-skill"
              acceptedScope requested =
                scope
                  & #run
                  .~ requested
                  & #agent
                  .~ declaration
                  & #context
                  . #sessionId
                  .~ Just requested.sessionId
                  & #context
                  . #executionRootId
                  .~ requested.rootId
                  & #context
                  . #executionPermissions
                  .~ requested.permittedAliases
              authority = CoordinationAuthority (\requested -> pure (Right (Just (acceptedScope requested)))) (\requested ref -> pure (if scopeFingerprint (acceptedScope requested) == ref then Right (acceptedScope requested) else Left "unknown scope"))
              selected = host & #authority .~ authority
              dependencies =
                Fixture.routerDeps env behavior (Routing.RoutingRuntime (\_ -> fail "unexpected routing") (\_ _ _ -> fail "unexpected routing")) [declaration]
                  & #coordination
                  .~ Just selected
                  & #actionAuthorizer
                  .~ authorizer
              job key =
                Fixture.routerJob key
                  & #agentName
                  .~ declaration.name
                  & #identity
                  .~ admission.context.identity
                  & #lineage
                  .~ admission.context.lineage
                  & #executionRootId
                  .~ admission.context.executionRootId
              execution input = Replay.executionIdFor (assignmentIdFor (runJobWorkflowId input).unWorkflowId)
              drive deps input = run env (runWorkflowWith (shikigamiWorkflowRunOptions env) Agent.agentRunWorkflowName (runJobWorkflowId input) (Agent.agentRunWorkflow deps (Just input)))
          let allowed = job "coordinator-admitted"
          drive dependencies allowed >>= (@?= Suspended)
          access <- expectRight =<< run env (Execution.authorizeReplay (execution allowed) admission.context.identity (pure (Right ())))
          (snapshot, _) <- expectRight =<< run env (Execution.loadExecution access)
          assertBool "admitted worker tool is frozen" (any (\binding -> binding.name == "workers") snapshot.toolBindings)
          let refused = job "coordinator-no-authority"
          denied <- drive (dependencies & #coordination .~ Nothing) refused
          case denied of Completed (Left _) -> pure (); _ -> assertFailure (show denied)
          run env (Execution.inspectExecution (execution refused)) >>= (@?= Right Nothing),
      testCase "new parent permissions cannot widen the frozen worker delegation" $
        withCapabilityFixture fixture \env admission host scope authorizer _ _ -> do
          let narrowed = scope & #run . #permittedAliases .~ Just ["other-model"] & #context . #executionPermissions .~ Just ["other-model"]
              authority = CoordinationAuthority (\_ -> pure (Right (Just narrowed))) (\_ _ -> pure (Right narrowed))
              selected = host & #authority .~ authority
          grant <- permit env selected narrowed authorizer
          run env (executeCommand selected authorizer grant (OperationId "disjoint-permissions") (SendWorker (Session.sessionIdFor admission) (fixtureRevision 0) (fixtureRevision 0) (draft "refused"))) >>= (@?= Left Session.SessionOwnerRefused)
          Just (state, _) <- expectRight =<< run env (Store.inspectSession (Session.sessionIdFor admission))
          state.nextSequence @?= (fixtureRevision 0),
      testCase "native tools pin a scope across replay and never accept model operation or root coordinates" $
        withCapabilityFixture fixture \env admission host scope authorizer _ current -> do
          snapshot <- snapshotFor scope
          let factory = Tools.coordinationTools (Just host) authorizer
          [described] <- expectRight =<< factory.describe snapshot
          let accepted = snapshot & #toolBindings .~ [described.binding] & #offeredTools .~ toJSON [lowerSomeTool described.tool]
              context = OperationContext accepted.executionId (OperationId "trusted-operation") "trusted-key" "fingerprint" "scope"
              input = toJSON (SendWorker (Session.sessionIdFor admission) (fixtureRevision 0) (fixtureRevision 0) (draft "PRIVATE_NATIVE_INSTRUCTION"))
          [prepared] <- expectRight =<< factory.prepare accepted context (Just "workers")
          output <- executeTool prepared input
          writeIORef current Nothing
          [reacquired] <- expectRight =<< factory.prepare accepted context (Just "workers")
          replay <- executeTool reacquired input
          acceptedReply output @?= Accepted
          acceptedReply replay @?= AlreadyAccepted
          let forged = case input of Aeson.Object fields -> Aeson.Object (KeyMap.insert "operationId" (Aeson.String "model-chosen") fields); other -> other
          bad <- runEff (runErrorNoCallStack @ShikumiError (runLLM (runErasedOutput reacquired.tool forged)))
          case bad of Right (Left _) -> pure (); _ -> assertFailure "model operation key accepted"
          inspection <- expectRight =<< run env (Store.inspectSessionPage (Session.sessionIdFor admission) (fixturePosition (-1)) 20)
          assertBool "operator metadata has no private instruction" (not ("PRIVATE_NATIVE_INSTRUCTION" `Text.isInfixOf` Text.pack (show (Aeson.encode inspection))))
          Aeson.eitherDecode (Aeson.encode accepted) @?= Right accepted
    ]

flowName :: WorkflowName
flowName = WorkflowName "fixture.worker-events"

draft :: Text -> WorkerInstruction
draft text = WorkerInstruction (fixtureInstruction text) (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing

permit :: AppEnv -> CoordinationHost -> CoordinationScope -> ActionAuthorizer -> IO CoordinationGrant
permit env host scope authorizer = do
  Just grant <- expectRight =<< run env (resolveGrant host authorizer scope.run (Just (scopeFingerprint scope)))
  pure grant

withCapabilityFixture :: DatabaseFixture -> (AppEnv -> Session.SessionAdmission -> CoordinationHost -> CoordinationScope -> ActionAuthorizer -> IORef Bool -> IORef (Maybe CoordinationScope) -> IO a) -> IO a
withCapabilityFixture fixture callback = withFixture fixture \env admission _ -> do
  memory <- maybe (assertFailure "missing parent session" >> fail "missing parent session") pure admission.context.sessionId
  version <- checkpointVersion admission
  (checkpoints, _) <- fixtureCheckpoints version False
  let run = CoordinatorRun "capability-parent" admission.context.identity memory admission.context.executionRootId admission.context.executionPermissions
      scope = CoordinationScope 1 run admission.scope.parent (admission.delegator & #behavior .~ CoordinatingSkill "fixture-coordinator") admission.context [WorkerSlot admission.scope.workerKey admission.worker admission.identity admission.objective (Just (Session.sessionIdFor admission))] (fixtureLimit 8) admission.maximumAssignments admission.mailboxLimit
      sessions = SessionRuntime env [admission.delegator & #name .~ fixtureAgentName "worker" & #delegates .~ map fixtureAgentName []] disabledDirectoryHandle (const (pure (Right ()))) (Just checkpoints)
  current <- newIORef (Just scope)
  revoked <- newIORef False
  let authority = CoordinationAuthority (\requested -> readIORef current <&> \value -> if requested == run then Right value else Left "foreign run") (\requested pinned -> pure (if requested == run && pinned == scopeFingerprint scope then Right scope else Left "retained scope unavailable"))
      host = CoordinationHost (TransferServices sessions Nothing Nothing) authority
      authorizer = ActionAuthorizer (\principal action -> do denied <- readIORef revoked; if denied then pure (Left (ActionPolicyDenied "revoked")) else allowAllActionAuthorizerForTests.authorize principal action) "fixture"
  callback env admission host scope authorizer revoked current

listenerToken :: AppEnv -> CoordinationScope -> IO AwakeableId
listenerToken env scope = do
  entries <- run env (loadStepIndex flowName (WorkflowId scope.run.runId) 0)
  value <- maybe (assertFailure "listener was not journaled" >> fail "missing listener") pure (Map.lookup "awkid:workers-events-findings" entries)
  case Aeson.fromJSON value of Aeson.Success token -> pure token; Aeson.Error err -> assertFailure err >> fail err

snapshotFor :: CoordinationScope -> IO Replay.ExecutionSnapshot
snapshotFor scope = do
  now <- getCurrentTime
  let descriptor = ModelDescriptor (ModelAlias "worker-model") "1" "fixture-model" "fixture" "fixture" "fixture" "fixture" Nothing "fixture" "1"
      selection = ExecutionSelection (fixtureAssignment "coordination-assignment") descriptor (Aeson.object []) ["worker-model"] Nothing scope.run.rootId ProcessDefault now
  pure (Replay.ExecutionSnapshot 1 (Replay.executionIdFor selection.assignmentId) scope.run.runId (fixtureAgentName "coordinator") scope.run.identity scope.run.sessionId selection Nothing (Replay.SkillInstructions "fixture" "fixture" "fixture") (Replay.ReplayContext 2 Nothing [Replay.RequestTurn [Replay.TextBlock "coordinate"] Nothing]) emptyResolvedCapabilitySet (toJSON ([] :: [Aeson.Value])) defaultHarnessPolicy [] Nothing)

executeTool :: BoundTool -> Aeson.Value -> IO ToolOutput
executeTool tool arguments = expectRight =<< (expectRight =<< runEff (runErrorNoCallStack @ShikumiError (runLLM (runErasedOutput tool.tool arguments))))

acceptedReply :: ToolOutput -> Admission
acceptedReply output = case output.structuredContent >>= \value -> case Aeson.fromJSON @(Either Session.SessionError WorkerReply) value of Aeson.Success result -> Just result; _ -> Nothing of
  Just (Right (MessageAcceptedReply admission _)) -> admission
  _ -> error "expected native acceptance receipt"

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= either (assertFailure . show) pure

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> fail (show err)) pure

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixturePosition :: Integer -> MessagePosition
fixturePosition value = either (error . show) id (parseMessagePosition value)

fixtureInstruction :: Text -> InstructionText
fixtureInstruction value = either (error . show) id (parseInstructionText value)

fixtureLimit :: (SessionLimit a) => Integer -> a
fixtureLimit value = either (error . show) id (parseSessionLimit value)

fixtureAssignment :: AssignmentText.Text -> AssignmentKey
fixtureAssignment = either (error . show) id . parseAssignmentKey

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

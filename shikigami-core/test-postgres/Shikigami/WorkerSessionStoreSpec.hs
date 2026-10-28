module Shikigami.WorkerSessionStoreSpec (tests) where

import Control.Concurrent.Async (concurrently)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kioku.Id (genSessionId)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Decl (defaultDelegationBudget)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Delegate.Depth (DelegationDepth (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (AgentName (..))
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Execution.Identity (ExecutionRootId (..), OperationId (..))
import Shikigami.Execution.Resources (Admission (..))
import Shikigami.Execution.Resources qualified as R
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Prelude hiding ((.=))
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Store.ExecutionResources qualified as Roots
import Shikigami.WorkerSession.Identity (assignmentChildWorkflowId)
import Shikigami.WorkerSession.Store qualified as Store
import Shikigami.WorkerSession.Types
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "WorkerSessionStore"
    [ testCase "find-or-create freezes scope and delegation snapshot without resetting limits" $
        withFixture fixture \env admission _ -> do
          (accepted, state) <- expectRight =<< run env (Store.openSession admission)
          accepted @?= AlreadyAccepted
          state.sessionId @?= sessionIdFor admission
          Aeson.eitherDecode (Aeson.encode admission) @?= Right admission
          run env (Store.openSession (admission & #maximumAssignments .~ 20)) >>= (@?= Left SessionBindingConflict)
          run env (Store.openSession (admission & #objective . #key .~ "another-objective")) >>= (@?= Left SessionBindingConflict),
      testCase "active and idle follow-ups remain ordered and retain separate assignments/results" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send-1" (instruction "first")
          (_, started) <- expectRight =<< run env (Store.startAssignment access 1 0 (OperationId "start-1") first.assignmentId)
          (_, second) <- accept env access 2 "send-2" (instruction "second")
          Store.readInstruction access first.assignmentId `inEnv` env >>= (@?= Right (instruction "first"))
          (_, result) <- expectRight =<< run env (Store.recordResult access 3 0 (OperationId "result-1") (resultFor first "retained finding"))
          (_, third) <- accept env access 4 "send-3" (instruction "third")
          map (.sequence) [first, second, third] @?= [0, 1, 2]
          assertBool "assignment identities differ" (first.assignmentId /= second.assignmentId && second.assignmentId /= third.assignmentId)
          started.childWorkflowId @?= Just (assignmentChildWorkflowId (sessionIdFor admission) admission.worker first.assignmentId).unWorkflowId
          (_, next) <- expectRight =<< run env (Store.startAssignment access 5 0 (OperationId "start-2") second.assignmentId)
          next.childWorkflowId @?= Just (assignmentChildWorkflowId (sessionIdFor admission) admission.worker second.assignmentId).unWorkflowId
          assertBool "follow-up gets a new child" (started.childWorkflowId /= next.childWorkflowId)
          Store.readResult access first.assignmentId `inEnv` env >>= (@?= Right (Just (result, resultFor first "retained finding")))
          run env (Store.acceptMessage access 0 0 (OperationId "send-1") (instruction "first")) >>= (@?= Right (AlreadyAccepted, first))
          (_, state) <- current env admission
          state.activeAssignment @?= Just second.assignmentId
          state.nextSequence @?= 3
          events <- expectRight =<< run env (Store.readEvents access 0 100)
          map (.cursor) events @?= [1 .. 6],
      testCase "concurrent identical acceptance returns one immutable receipt" $
        withFixture fixture \env admission access -> do
          let send = run env (Store.acceptMessage access 0 0 (OperationId "duplicate-send") (instruction "one"))
          (left, right) <- concurrently send send
          (a, first) <- expectRight left
          (b, second) <- expectRight right
          first @?= second
          length (filter (== Accepted) [a, b]) @?= 1
          length (filter (== AlreadyAccepted) [a, b]) @?= 1
          run env (Store.acceptMessage access 0 0 (OperationId "duplicate-send") (instruction "changed")) >>= (@?= Left MessageConflict)
          (_, state) <- current env admission
          state.nextSequence @?= 1
          state.eventCursor @?= 1,
      testCase "result and follow-up races converge without losing accepted work" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send-1" (instruction "first")
          _ <- expectRight =<< run env (Store.startAssignment access 1 0 (OperationId "start-1") first.assignmentId)
          let finish revision = run env (Store.recordResult access revision 0 (OperationId "finish") (resultFor first "finding"))
              follow revision = run env (Store.acceptMessage access revision 0 (OperationId "follow") (instruction "follow-up"))
          (result, message) <- concurrently (finish 2) (follow 2)
          (_, intermediate) <- current env admission
          case result of Left SessionRevisionConflict -> void (expectRight =<< finish intermediate.revision); Right _ -> pure (); other -> assertFailure (show other)
          (_, latest) <- current env admission
          case message of Left SessionRevisionConflict -> void (expectRight =<< follow latest.revision); Right _ -> pure (); other -> assertFailure (show other)
          (_, settled) <- current env admission
          settled.phase @?= Idle
          settled.nextSequence @?= 2
          settled.eventCursor @?= 4
          available <- expectRight =<< run env (Store.readResult access first.assignmentId)
          assertBool "result remains available after lost notification" (isJust available)
          events <- expectRight =<< run env (Store.readEvents access 0 100)
          length [() | EventReceipt {event = ResultAvailable {}} <- events] @?= 1,
      testCase "cursor integration faults roll back local progress and command acceptance" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send" (instruction "one")
          _ <- expectRight =<< run env (Store.startAssignment access 1 0 (OperationId "start") first.assignmentId)
          _ <- expectRight =<< run env (Store.recordResult access 2 0 (OperationId "finish") (resultFor first "finding"))
          run env (runTransaction (Tx.statement () (preparable "CREATE TABLE shikigami.session_test_progress (key text PRIMARY KEY)" E.noParams D.noResult)))
          let integrate = Tx.statement () (preparable "INSERT INTO shikigami.session_test_progress(key) VALUES ('once')" E.noParams D.noResult)
              count = run env (runTransaction (Tx.statement () (preparable "SELECT count(*) FROM shikigami.session_test_progress" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))))
              commit action = run env (Store.consumeEventsWith access 3 0 (OperationId "integrate") 0 3 action)
          commit (integrate >> pure (Left (SessionInputRefused "fixture fault"))) >>= (@?= Left (SessionInputRefused "fixture fault"))
          count >>= (@?= 0)
          (_, unchanged) <- current env admission
          unchanged.revision @?= 3
          unchanged.consumedCursor @?= 0
          commit (integrate >> pure (Right ())) >>= (@?= Right (Accepted, 3))
          commit (error "duplicate integration callback") >>= (@?= Right (AlreadyAccepted, 3))
          count >>= (@?= 1),
      testCase "interrupts bind the active assignment and never rewrite its instruction" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send" (instruction "accepted instruction")
          _ <- expectRight =<< run env (Store.startAssignment access 1 0 (OperationId "start") first.assignmentId)
          let wrong = instruction "interrupt" & #kind .~ Interrupt (AssignmentId "wrong-assignment")
              valid = instruction "interrupt" & #kind .~ Interrupt first.assignmentId
          run env (Store.acceptMessage access 2 0 (OperationId "interrupt") wrong) >>= (@?= Left InterruptTargetChanged)
          (_, accepted) <- accept env access 2 "interrupt" valid
          accepted.sequence @?= 1
          (_, state) <- current env admission
          state.activeAssignment @?= Just first.assignmentId
          run env (Store.readInstruction access first.assignmentId) >>= (@?= Right (instruction "accepted instruction")),
      testCase "only admitted actors read payloads and only the parent controls messages" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send" (instruction "PRIVATE_SESSION_INSTRUCTION")
          refused <- run env (Store.authorizeSession (sessionIdFor admission) (compatibilityIdentity "intruder") (pure (Right ())))
          case refused of Left SessionOwnerRefused -> pure (); _ -> assertFailure "foreign reader admitted"
          revoked <- run env (Store.authorizeSession (sessionIdFor admission) admission.context.identity (pure (Left "revoked")))
          case revoked of Left SessionOwnerRefused -> pure (); _ -> assertFailure "revoked reader admitted"
          worker <- expectRight =<< run env (Store.authorizeSession (sessionIdFor admission) admission.identity (pure (Right ())))
          run env (Store.readInstruction worker first.assignmentId) >>= (@?= Right (instruction "PRIVATE_SESSION_INSTRUCTION"))
          run env (Store.acceptMessage worker 1 0 (OperationId "forged-parent") (instruction "no")) >>= (@?= Left SessionOwnerRefused)
          metadata <- expectRight =<< run env (Store.inspectSession (sessionIdFor admission))
          assertBool "ordinary metadata excludes instructions" (not ("PRIVATE_SESSION_INSTRUCTION" `Text.isInfixOf` Text.pack (show (Aeson.encode metadata)))),
      testCase "mailbox assignment and epoch limits cannot be reset by follow-ups" $
        withConfiguredFixture fixture (\admission -> admission & #maximumAssignments .~ 2 & #mailboxLimit .~ 1) \env admission access -> do
          (_, first) <- accept env access 0 "first" (instruction "one")
          run env (Store.acceptMessage access 1 0 (OperationId "second") (instruction "two")) >>= (@?= Left SessionMailboxFull)
          _ <- expectRight =<< run env (Store.startAssignment access 1 0 (OperationId "start") first.assignmentId)
          _ <- accept env access 2 "second" (instruction "two")
          run env (Store.acceptMessage access 3 0 (OperationId "third") (instruction "three")) >>= (@?= Left SessionLimitExceeded)
          run env (Store.acceptMessage access 3 1 (OperationId "wrong-epoch") (instruction "no")) >>= (@?= Left SessionOwnerRefused)
          (_, state) <- current env admission
          state.revision @?= 3
          state.nextSequence @?= 2,
      testCase "root cancellation refuses new work while retaining an already accepted result" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send" (instruction "one")
          _ <- expectRight =<< run env (Store.startAssignment access 1 0 (OperationId "start") first.assignmentId)
          rootId <- maybe (assertFailure "fixture root missing" >> fail "fixture root missing") pure admission.context.executionRootId
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          run env (Roots.setRootControl rootId root.revision True Nothing) >>= (@?= Right ())
          run env (Store.acceptMessage access 2 0 (OperationId "late-work") (instruction "no")) >>= (@?= Left SessionOwnerRefused)
          _ <- expectRight =<< run env (Store.recordResult access 2 0 (OperationId "finish") (resultFor first "accepted finding"))
          available <- expectRight =<< run env (Store.readResult access first.assignmentId)
          assertBool "accepted outcome survives cancellation" (isJust available),
      testCase "parked and unresolved assignments retain their child and block premature closure" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send" (instruction "one")
          (_, started) <- expectRight =<< run env (Store.startAssignment access 1 0 (OperationId "start") first.assignmentId)
          (_, parked) <- expectRight =<< run env (Store.setAssignmentStatus access 2 0 (OperationId "park") first.assignmentId AssignmentParked)
          parked.childWorkflowId @?= started.childWorkflowId
          run env (Store.closeSession access 3 0 (OperationId "close") AssignmentCancelled) >>= (@?= Left SessionRevisionConflict)
          _ <- expectRight =<< run env (Store.setAssignmentStatus access 3 0 (OperationId "unknown") first.assignmentId AssignmentUnresolved)
          run env (Store.startAssignment access 4 0 (OperationId "replacement") first.assignmentId) >>= (@?= Left SessionRevisionConflict)
          (_, resumed) <- expectRight =<< run env (Store.setAssignmentStatus access 4 0 (OperationId "reconciled") first.assignmentId Running)
          run env (Store.setAssignmentStatus access 4 0 (OperationId "reconciled") first.assignmentId Running) >>= (@?= Right (AlreadyAccepted, resumed))
          resumed.childWorkflowId @?= started.childWorkflowId
          _ <- expectRight =<< run env (Store.recordResult access 5 0 (OperationId "finish") (resultFor first "finding"))
          (_, state) <- current env admission
          (_, closed) <- expectRight =<< run env (Store.closeSession access state.revision 0 (OperationId "close") AssignmentCancelled)
          closed.phase @?= Cancelled
          run env (Store.acceptMessage access closed.revision 0 (OperationId "too-late") (instruction "no")) >>= (@?= Left SessionRevisionConflict)
          run env (Store.consumeEventsWith access closed.revision 0 (OperationId "final-ack") 0 closed.eventCursor (pure (Right ()))) >>= (@?= Right (Accepted, closed.eventCursor)),
      testCase "queued assignments prevent idle session closure" $
        withFixture fixture \env _ access -> do
          (_, first) <- accept env access 0 "send" (instruction "one")
          run env (Store.closeSession access 1 0 (OperationId "close") AssignmentFailed) >>= (@?= Left AssignmentStillActive)
          run env (Store.nextAssignment access) >>= (@?= Right (Just first)),
      testCase "oversized instruction refuses before changing session progress" $
        withFixture fixture \env admission access -> do
          run env (Store.acceptMessage access 0 0 (OperationId "large") (instruction (Text.replicate 1048576 "x"))) >>= (@?= Left SessionPayloadTooLarge)
          (_, state) <- current env admission
          state.revision @?= 0
          state.nextSequence @?= 0
    ]

instruction :: Text -> Instruction
instruction text = Instruction 1 FollowUp text 1 1 1 Nothing

resultFor :: MessageReceipt -> Text -> AssignmentResult
resultFor message finding = AssignmentResult 1 message.assignmentId AssignmentSucceeded Nothing (object ["finding" .= finding]) ["opaque-artifact-reference"]

accept :: AppEnv -> Store.SessionAccess -> Integer -> Text -> Instruction -> IO (Admission, MessageReceipt)
accept env access expected key value = expectRight =<< run env (Store.acceptMessage access expected 0 (OperationId key) value)

current :: AppEnv -> SessionAdmission -> IO (SessionBinding, SessionState)
current env admission = do
  Just (state, binding) <- expectRight =<< run env (Store.inspectSession (sessionIdFor admission))
  pure (binding, state)

withFixture :: DatabaseFixture -> (AppEnv -> SessionAdmission -> Store.SessionAccess -> IO a) -> IO a
withFixture fixture = withConfiguredFixture fixture id

withConfiguredFixture :: DatabaseFixture -> (SessionAdmission -> SessionAdmission) -> (AppEnv -> SessionAdmission -> Store.SessionAccess -> IO a) -> IO a
withConfiguredFixture fixture configure callback = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  parentSession <- genSessionId
  now <- getCurrentTime
  parent <- expectRight =<< loadAgent "../agents/heartbeat.dhall"
  let env = AppEnv (defaultConnectionSettings connection) tracer Nothing
      root = ExecutionRootId "session-root"
      admission =
        configure $
          SessionAdmission
            1
            (SessionScope "fixture-coordinator" "logical-worker")
            (ObjectiveRef "fixture-checkpoint-provider" "objective-1")
            (parent & #name .~ "coordinator" & #delegates .~ ["worker"])
            (DelegateCtx (DelegationDepth 0) (compatibilityIdentity "coordinator") (Just parentSession) Nothing (Just (WorkflowId "original-parent")) [AgentName "coordinator"] (Just ["worker-model"]) (Just root) Nothing defaultDelegationBudget)
            (AgentName "worker")
            (compatibilityIdentity "worker")
            10
            4
  _ <- expectRight =<< run env Catalog.registerProjectionCatalog
  run env (Roots.enrollRoot root (R.Envelope (Map.fromList [(dimension, R.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]]) (addUTCTime 3600 now))) >>= (@?= Right Accepted)
  (accepted, _) <- expectRight =<< run env (Store.openSession admission)
  accepted @?= Accepted
  access <- expectRight =<< run env (Store.authorizeSession (sessionIdFor admission) admission.context.identity (pure (Right ())))
  callback env admission access

inEnv :: Eff AppEffects a -> AppEnv -> IO a
inEnv = flip run

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= expectRight

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

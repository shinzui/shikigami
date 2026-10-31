module Shikigami.WorkerSessionStoreSpec (tests, withFixture, withConfiguredFixture, checkpointVersion, fixtureCheckpoints) where

import Control.Concurrent.Async (concurrently)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.Id (genSessionId)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Read qualified as StoreRead
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types qualified as StoreTypes
import Shikigami.Agent.Decl (defaultDelegationBudget)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Delegate.Depth (DelegationDepth, parseDelegationDepth)
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId (..))
import Shikigami.Execution.Resources (Admission (..))
import Shikigami.Execution.Resources qualified as R
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Fixture.ExecutionIdentity (fixtureRootId)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Prelude hiding ((.=))
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.StateRevision (StateRevision, advanceRevision, parseRevision)
import Shikigami.WorkerSession.Checkpoint qualified as Checkpoint
import Shikigami.WorkerSession.Identity (assignmentChildWorkflowIdV2)
import Shikigami.WorkerSession.Input (InstructionText, SessionLimit (..), parseInstructionText)
import Shikigami.WorkerSession.Store qualified as Store
import Shikigami.WorkerSession.Types
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "WorkerSessionStore"
    [ testCase "malformed reference JSON remains a domain corruption refusal" $
        withFixture fixture \env admission access -> do
          let statement = preparable "UPDATE shikigami.worker_sessions SET binding=jsonb_set(binding,'{admission,digest}','\"invalid\"'::jsonb) WHERE session_id=$1" (E.param (E.nonNullable E.text)) D.noResult
          run env (runTransaction (Tx.statement (sessionIdFor admission).value statement))
          run env (Store.loadAdmission access) >>= (@?= Left SessionBindingConflict)
          run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (OperationId "corrupt-binding-command") (instruction "must not be retained")) >>= (@?= Left SessionBindingConflict)
          let count = run env (runTransaction (Tx.statement () (preparable "SELECT (SELECT count(*) FROM shikigami.worker_session_messages),(SELECT count(*) FROM shikigami.worker_session_commands),(SELECT count(*) FROM shikigami.worker_session_payloads)" E.noParams (D.singleRow ((,,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8))))))
          count >>= (@?= (0, 0, 1))
          run env (length <$> StoreRead.readCategory (StoreTypes.CategoryName "workerSessionLifecycle") (StoreTypes.GlobalPosition 0) 100) >>= (@?= 1),
      testCase "malformed protected session metadata remains a binding refusal" do
        mapM_
          ( \assignment -> withFixture fixture \env admission access -> do
              let statement = preparable ("UPDATE shikigami.worker_session_payloads SET " <> assignment <> " WHERE session_id=$1") (E.param (E.nonNullable E.text)) D.noResult
              run env (runTransaction (Tx.statement (sessionIdFor admission).value statement))
              run env (Store.loadAdmission access) >>= (@?= Left SessionBindingConflict)
          )
          ["digest='invalid'", "bytes=0"],
      testCase "find-or-create freezes scope and delegation snapshot without resetting limits" $
        withFixture fixture \env admission _ -> do
          (accepted, state) <- expectRight =<< run env (Store.openSession admission)
          accepted @?= AlreadyAccepted
          state.sessionId @?= sessionIdFor admission
          Aeson.eitherDecode (Aeson.encode admission) @?= Right admission
          case Aeson.toJSON admission of
            Aeson.Object fields -> do
              let oldWire = Aeson.Object (KeyMap.insert "maximumAssignments" (Aeson.toJSON (10 :: Int)) (KeyMap.insert "mailboxLimit" (Aeson.toJSON (4 :: Int)) fields))
              Aeson.encode admission @?= Aeson.encode oldWire
              mapM_ (\(key, bad) -> assertBool "invalid admission limit refused at decode" (case Aeson.fromJSON (Aeson.Object (KeyMap.insert key (Aeson.toJSON (bad :: Integer)) fields)) :: Aeson.Result SessionAdmission of Aeson.Error _ -> True; Aeson.Success _ -> False)) [("maximumAssignments", 0), ("maximumAssignments", 1001), ("mailboxLimit", 0), ("mailboxLimit", 129)]
            _ -> assertFailure "admission did not encode as an object"
          run env (Store.openSession (admission & #maximumAssignments .~ (fixtureLimit 20))) >>= (@?= Left SessionBindingConflict)
          run env (Store.openSession (admission & #objective . #key .~ "another-objective")) >>= (@?= Left SessionBindingConflict),
      testCase "active and idle follow-ups remain ordered and retain separate assignments/results" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send-1" (instruction "first")
          (_, started) <- expectRight =<< run env (Store.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (OperationId "start-1") first.assignmentId)
          (_, second) <- accept env access 2 "send-2" (instruction "second")
          Store.readInstruction access first.assignmentId `inEnv` env >>= (@?= Right (instruction "first"))
          (_, result) <- expectRight =<< run env (Store.recordResult access (fixtureRevision 3) (fixtureRevision 0) (OperationId "result-1") (resultFor first "retained finding"))
          (_, third) <- accept env access 4 "send-3" (instruction "third")
          map (.sequence) [first, second, third] @?= map fixtureRevision [0, 1, 2]
          assertBool "assignment identities differ" (first.assignmentId /= second.assignmentId && second.assignmentId /= third.assignmentId)
          started.childWorkflowId @?= Just (assignmentChildWorkflowIdV2 (sessionIdFor admission) admission.worker first.assignmentId).unWorkflowId
          (_, next) <- expectRight =<< run env (Store.startAssignment access (fixtureRevision 5) (fixtureRevision 0) (OperationId "start-2") second.assignmentId)
          next.childWorkflowId @?= Just (assignmentChildWorkflowIdV2 (sessionIdFor admission) admission.worker second.assignmentId).unWorkflowId
          assertBool "follow-up gets a new child" (started.childWorkflowId /= next.childWorkflowId)
          Store.readResult access first.assignmentId `inEnv` env >>= (@?= Right (Just (result, resultFor first "retained finding")))
          run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (OperationId "send-1") (instruction "first")) >>= (@?= Right (AlreadyAccepted, first))
          (_, state) <- current env admission
          state.activeAssignment @?= Just second.assignmentId
          state.nextSequence @?= (fixtureRevision 3)
          events <- expectRight =<< run env (Store.readEvents access (fixtureRevision 0) 100)
          map (.cursor) events @?= map fixtureRevision [1 .. 6],
      testCase "concurrent identical acceptance returns one immutable receipt" $
        withFixture fixture \env admission access -> do
          let send = run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (OperationId "duplicate-send") (instruction "one"))
          (left, right) <- concurrently send send
          (a, first) <- expectRight left
          (b, second) <- expectRight right
          first @?= second
          length (filter (== Accepted) [a, b]) @?= 1
          length (filter (== AlreadyAccepted) [a, b]) @?= 1
          run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (OperationId "duplicate-send") (instruction "changed")) >>= (@?= Left MessageConflict)
          (_, state) <- current env admission
          state.nextSequence @?= (fixtureRevision 1)
          state.eventCursor @?= (fixtureRevision 1),
      testCase "result and follow-up races converge without losing accepted work" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send-1" (instruction "first")
          _ <- expectRight =<< run env (Store.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (OperationId "start-1") first.assignmentId)
          let finish revision = run env (Store.recordResult access revision (fixtureRevision 0) (OperationId "finish") (resultFor first "finding"))
              follow revision = run env (Store.acceptMessage access revision (fixtureRevision 0) (OperationId "follow") (instruction "follow-up"))
          (result, message) <- concurrently (finish (fixtureRevision 2)) (follow (fixtureRevision 2))
          (_, intermediate) <- current env admission
          case result of Left SessionRevisionConflict -> void (expectRight =<< finish intermediate.revision); Right _ -> pure (); other -> assertFailure (show other)
          (_, latest) <- current env admission
          case message of Left SessionRevisionConflict -> void (expectRight =<< follow latest.revision); Right _ -> pure (); other -> assertFailure (show other)
          (_, settled) <- current env admission
          settled.phase @?= Idle
          settled.nextSequence @?= (fixtureRevision 2)
          settled.eventCursor @?= (fixtureRevision 4)
          available <- expectRight =<< run env (Store.readResult access first.assignmentId)
          assertBool "result remains available after lost notification" (isJust available)
          events <- expectRight =<< run env (Store.readEvents access (fixtureRevision 0) 100)
          length [() | EventReceipt {event = ResultAvailable {}} <- events] @?= 1,
      testCase "cursor integration faults roll back local progress and command acceptance" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send" (instruction "one")
          _ <- expectRight =<< run env (Store.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (OperationId "start") first.assignmentId)
          _ <- expectRight =<< run env (Store.recordResult access (fixtureRevision 2) (fixtureRevision 0) (OperationId "finish") (resultFor first "finding"))
          run env (runTransaction (Tx.statement () (preparable "CREATE TABLE shikigami.session_test_progress (key text PRIMARY KEY)" E.noParams D.noResult)))
          let integrate = Tx.statement () (preparable "INSERT INTO shikigami.session_test_progress(key) VALUES ('once')" E.noParams D.noResult)
              count = run env (runTransaction (Tx.statement () (preparable "SELECT count(*) FROM shikigami.session_test_progress" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))))
              commit action = run env (Store.consumeEventsWith access (fixtureRevision 3) (fixtureRevision 0) (OperationId "integrate") (fixtureRevision 0) (fixtureRevision 3) action)
          commit (integrate >> pure (Left (SessionInputRefused "fixture fault"))) >>= (@?= Left (SessionInputRefused "fixture fault"))
          count >>= (@?= 0)
          (_, unchanged) <- current env admission
          unchanged.revision @?= (fixtureRevision 3)
          unchanged.consumedCursor @?= (fixtureRevision 0)
          commit (integrate >> pure (Right ())) >>= (@?= Right (Accepted, fixtureRevision 3))
          commit (error "duplicate integration callback") >>= (@?= Right (AlreadyAccepted, fixtureRevision 3))
          count >>= (@?= 1),
      testCase "interrupts bind the active assignment and never rewrite its instruction" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send" (instruction "accepted instruction")
          _ <- expectRight =<< run env (Store.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (OperationId "start") first.assignmentId)
          let wrong = instruction "interrupt" & #kind .~ Interrupt (AssignmentId "wrong-assignment")
              valid = instruction "interrupt" & #kind .~ Interrupt first.assignmentId
          run env (Store.acceptMessage access (fixtureRevision 2) (fixtureRevision 0) (OperationId "interrupt") wrong) >>= (@?= Left InterruptTargetChanged)
          (_, accepted) <- accept env access 2 "interrupt" valid
          accepted.sequence @?= (fixtureRevision 1)
          (_, state) <- current env admission
          state.activeAssignment @?= Just first.assignmentId
          run env (Store.readInstruction access first.assignmentId) >>= (@?= Right (instruction "accepted instruction")),
      testCase "only admitted actors read payloads and only the parent controls messages" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send" (instruction "PRIVATE_SESSION_INSTRUCTION")
          refused <- run env (Store.authorizeSession (sessionIdFor admission) (compatibilityIdentity (fixtureAgentName "intruder")) (pure (Right ())))
          case refused of Left SessionOwnerRefused -> pure (); _ -> assertFailure "foreign reader admitted"
          revoked <- run env (Store.authorizeSession (sessionIdFor admission) admission.context.identity (pure (Left "revoked")))
          case revoked of Left SessionOwnerRefused -> pure (); _ -> assertFailure "revoked reader admitted"
          worker <- expectRight =<< run env (Store.authorizeSession (sessionIdFor admission) admission.identity (pure (Right ())))
          run env (Store.readInstruction worker first.assignmentId) >>= (@?= Right (instruction "PRIVATE_SESSION_INSTRUCTION"))
          run env (Store.acceptMessage worker (fixtureRevision 1) (fixtureRevision 0) (OperationId "forged-parent") (instruction "no")) >>= (@?= Left SessionOwnerRefused)
          metadata <- expectRight =<< run env (Store.inspectSession (sessionIdFor admission))
          assertBool "ordinary metadata excludes instructions" (not ("PRIVATE_SESSION_INSTRUCTION" `Text.isInfixOf` Text.pack (show (Aeson.encode metadata)))),
      testCase "mailbox assignment and epoch limits cannot be reset by follow-ups" $
        withConfiguredFixture fixture (\admission -> admission & #maximumAssignments .~ (fixtureLimit 2) & #mailboxLimit .~ (fixtureLimit 1)) \env admission access -> do
          (_, first) <- accept env access 0 "first" (instruction "one")
          run env (Store.acceptMessage access (fixtureRevision 1) (fixtureRevision 0) (OperationId "second") (instruction "two")) >>= (@?= Left SessionMailboxFull)
          _ <- expectRight =<< run env (Store.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (OperationId "start") first.assignmentId)
          _ <- accept env access 2 "second" (instruction "two")
          run env (Store.acceptMessage access (fixtureRevision 3) (fixtureRevision 0) (OperationId "third") (instruction "three")) >>= (@?= Left SessionLimitExceeded)
          run env (Store.acceptMessage access (fixtureRevision 3) (fixtureRevision 1) (OperationId "wrong-epoch") (instruction "no")) >>= (@?= Left SessionOwnerRefused)
          (_, state) <- current env admission
          state.revision @?= (fixtureRevision 3)
          state.nextSequence @?= (fixtureRevision 2),
      testCase "root cancellation refuses new work while retaining an already accepted result" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send" (instruction "one")
          _ <- expectRight =<< run env (Store.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (OperationId "start") first.assignmentId)
          rootId <- maybe (assertFailure "fixture root missing" >> fail "fixture root missing") pure admission.context.executionRootId
          root <- expectRight =<< run env (Roots.inspectRoot rootId)
          run env (Roots.setRootControl rootId root.revision R.StopWork Nothing) >>= (@?= Right ())
          run env (Store.acceptMessage access (fixtureRevision 2) (fixtureRevision 0) (OperationId "late-work") (instruction "no")) >>= (@?= Left SessionOwnerRefused)
          _ <- expectRight =<< run env (Store.recordResult access (fixtureRevision 2) (fixtureRevision 0) (OperationId "finish") (resultFor first "accepted finding"))
          available <- expectRight =<< run env (Store.readResult access first.assignmentId)
          assertBool "accepted outcome survives cancellation" (isJust available),
      testCase "parked and unresolved assignments retain their child and block premature closure" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send" (instruction "one")
          (_, started) <- expectRight =<< run env (Store.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (OperationId "start") first.assignmentId)
          (_, parked) <- expectRight =<< run env (Store.setAssignmentStatus access (fixtureRevision 2) (fixtureRevision 0) (OperationId "park") first.assignmentId AssignmentParked)
          parked.childWorkflowId @?= started.childWorkflowId
          run env (Store.closeSession access (fixtureRevision 3) (fixtureRevision 0) (OperationId "close") AssignmentCancelled) >>= (@?= Left SessionRevisionConflict)
          _ <- expectRight =<< run env (Store.setAssignmentStatus access (fixtureRevision 3) (fixtureRevision 0) (OperationId "unknown") first.assignmentId AssignmentUnresolved)
          run env (Store.startAssignment access (fixtureRevision 4) (fixtureRevision 0) (OperationId "replacement") first.assignmentId) >>= (@?= Left SessionRevisionConflict)
          (_, resumed) <- expectRight =<< run env (Store.setAssignmentStatus access (fixtureRevision 4) (fixtureRevision 0) (OperationId "reconciled") first.assignmentId Running)
          run env (Store.setAssignmentStatus access (fixtureRevision 4) (fixtureRevision 0) (OperationId "reconciled") first.assignmentId Running) >>= (@?= Right (AlreadyAccepted, resumed))
          resumed.childWorkflowId @?= started.childWorkflowId
          _ <- expectRight =<< run env (Store.recordResult access (fixtureRevision 5) (fixtureRevision 0) (OperationId "finish") (resultFor first "finding"))
          (_, state) <- current env admission
          (_, closed) <- expectRight =<< run env (Store.closeSession access state.revision (fixtureRevision 0) (OperationId "close") AssignmentCancelled)
          closed.phase @?= Cancelled
          run env (Store.acceptMessage access closed.revision (fixtureRevision 0) (OperationId "too-late") (instruction "no")) >>= (@?= Left SessionRevisionConflict)
          run env (Store.consumeEventsWith access closed.revision (fixtureRevision 0) (OperationId "final-ack") (fixtureRevision 0) closed.eventCursor (pure (Right ()))) >>= (@?= Right (Accepted, closed.eventCursor)),
      testCase "queued assignments prevent idle session closure" $
        withFixture fixture \env _ access -> do
          (_, first) <- accept env access 0 "send" (instruction "one")
          run env (Store.closeSession access (fixtureRevision 1) (fixtureRevision 0) (OperationId "close") AssignmentFailed) >>= (@?= Left AssignmentStillActive)
          run env (Store.nextAssignment access) >>= (@?= Right (Just first)),
      testCase "checkpoint intent survives a lost external acknowledgement and deduplicates on restart" $
        withFixture fixture \env admission access -> do
          (_, first) <- accept env access 0 "send" (instruction "one")
          _ <- expectRight =<< run env (Store.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (OperationId "start") first.assignmentId)
          _ <- expectRight =<< run env (Store.recordResult access (fixtureRevision 2) (fixtureRevision 0) (OperationId "finish") (resultFor first "retained finding"))
          version <- checkpointVersion admission
          (provider, count) <- fixtureCheckpoints version True
          (_, intent) <- expectRight =<< run env (Store.prepareCheckpoint access (fixtureRevision 3) (fixtureRevision 0) (OperationId "checkpoint") version (fixtureRevision 0) (fixtureRevision 3))
          provider.commit intent >>= (@?= Checkpoint.CheckpointUnresolved)
          (_, pending) <- current env admission
          pending.checkpointIntent @?= Just (OperationId "checkpoint")
          pending.consumedCursor @?= (fixtureRevision 0)
          run env (Store.prepareCheckpoint access (fixtureRevision 4) (fixtureRevision 0) (OperationId "overlap") version (fixtureRevision 0) (fixtureRevision 3)) >>= (@?= Left AssignmentConflict)
          run env (Store.consumeEventsWith access (fixtureRevision 4) (fixtureRevision 0) (OperationId "bypass") (fixtureRevision 0) (fixtureRevision 3) (error "pending checkpoint bypass")) >>= (@?= Left AssignmentConflict)
          restarted <- expectRight =<< run env (Store.authorizeSession pending.sessionId admission.context.identity (pure (Right ())))
          recovered <- expectRight =<< run env (Store.readCheckpointIntent restarted (OperationId "checkpoint"))
          recovered @?= intent
          Checkpoint.CheckpointAccepted receipt <- provider.commit recovered
          run env (Store.acceptCheckpointWith restarted (fixtureRevision 4) (fixtureRevision 0) (OperationId "checkpoint-ack") recovered.operationId receipt (pure (Right ()))) >>= (@?= Right (Accepted, fixtureRevision 3))
          run env (Store.acceptCheckpointWith restarted (fixtureRevision 4) (fixtureRevision 0) (OperationId "checkpoint-ack") recovered.operationId receipt (error "duplicate checkpoint integration")) >>= (@?= Right (AlreadyAccepted, fixtureRevision 3))
          count >>= (@?= 1)
          (_, integrated) <- current env admission
          integrated.consumedCursor @?= (fixtureRevision 3)
          integrated.checkpointIntent @?= Nothing,
      testCase "checkpoint conflicts and local faults preserve the exact pending intent" $
        withFixture fixture \env admission access -> do
          _ <- accept env access 0 "send" (instruction "one")
          version <- checkpointVersion admission
          (_, intent) <- expectRight =<< run env (Store.prepareCheckpoint access (fixtureRevision 1) (fixtureRevision 0) (OperationId "checkpoint") version (fixtureRevision 0) (fixtureRevision 1))
          (provider, count) <- fixtureCheckpoints version False
          provider.commit (intent & #expected . #revision .~ (fixtureRevision 99)) >>= (@?= Checkpoint.CheckpointConflict)
          Checkpoint.CheckpointAccepted receipt <- provider.commit intent
          let ack value hook = run env (Store.acceptCheckpointWith access (fixtureRevision 2) (fixtureRevision 0) (OperationId "ack") intent.operationId value hook)
          ack (receipt & #fingerprint .~ "forged") (error "forged receipt integration") >>= (@?= Left AssignmentConflict)
          ack receipt (pure (Left (SessionInputRefused "integration fault"))) >>= (@?= Left (SessionInputRefused "integration fault"))
          (_, pending) <- current env admission
          pending.revision @?= (fixtureRevision 2)
          pending.consumedCursor @?= (fixtureRevision 0)
          pending.checkpointIntent @?= Just intent.operationId
          ack receipt (pure (Right ())) >>= (@?= Right (Accepted, fixtureRevision 1))
          count >>= (@?= 1),
      testCase "event capacity refuses atomically before retaining command input" $
        withFixture fixture \env admission access -> do
          let sql statement = run env (runTransaction (Tx.sql statement))
          sql "UPDATE shikigami.worker_sessions SET state=jsonb_set(state,'{eventCursor}','100000'::jsonb)"
          run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (OperationId "at-event-capacity") (instruction "must roll back")) >>= (@?= Left SessionLimitExceeded)
          (_, state) <- current env admission
          state.revision @?= fixtureRevision 0
          state.nextSequence @?= fixtureRevision 0
          state.eventCursor @?= fixtureRevision 100000
          let count = run env (runTransaction (Tx.statement () (preparable "SELECT (SELECT count(*) FROM shikigami.worker_session_messages),(SELECT count(*) FROM shikigami.worker_session_commands),(SELECT count(*) FROM shikigami.worker_session_payloads)" E.noParams (D.singleRow ((,,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8))))))
          count >>= (@?= (0, 0, 1))
          run env (length <$> StoreRead.readCategory (StoreTypes.CategoryName "workerSessionLifecycle") (StoreTypes.GlobalPosition 0) 100) >>= (@?= 1),
      testCase "oversized instruction refuses before changing session progress" $
        withFixture fixture \env admission access -> do
          run env (Store.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (OperationId "large") (instruction (Text.replicate 1048576 "x"))) >>= (@?= Left SessionPayloadTooLarge)
          (_, state) <- current env admission
          state.revision @?= (fixtureRevision 0)
          state.nextSequence @?= (fixtureRevision 0)
    ]

instruction :: Text -> Instruction
instruction text = Instruction 1 FollowUp (fixtureInstruction text) (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) Nothing

checkpointVersion :: SessionAdmission -> IO Checkpoint.ObjectiveVersion
checkpointVersion admission = do
  now <- getCurrentTime
  root <- maybe (assertFailure "fixture root missing" >> fail "fixture root missing") pure admission.context.executionRootId
  pure (Checkpoint.ObjectiveVersion (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 1) (fixtureRevision 0) admission.identity True root (addUTCTime 3600 now))

-- A test-only external owner: its transaction commits before the optional
-- first acknowledgement is lost. Deduplication precedes optimistic validation.
fixtureCheckpoints :: Checkpoint.ObjectiveVersion -> Bool -> IO (Checkpoint.CheckpointProvider, IO Int)
fixtureCheckpoints initial loseFirst = do
  storage <- newIORef (Map.empty, initial, 0 :: Int)
  let commit intent = atomicModifyIORef' storage \stored@(receipts, version, count) ->
        case Map.lookup intent.operationId receipts of
          Just (original, receipt) | original == intent -> (stored, Checkpoint.CheckpointAccepted receipt)
          Just _ -> (stored, Checkpoint.CheckpointConflict)
          Nothing | intent.expected /= version -> (stored, Checkpoint.CheckpointConflict)
          Nothing ->
            let receipt = Checkpoint.CheckpointReceipt 1 intent.objective intent.operationId (Checkpoint.intentFingerprint intent) (advanceRevision version.revision)
                updated = (Map.insert intent.operationId (intent, receipt) receipts, version & #revision .~ (advanceRevision version.revision), count + 1)
             in (updated, if loseFirst && count == 0 then Checkpoint.CheckpointUnresolved else Checkpoint.CheckpointAccepted receipt)
  pure (Checkpoint.CheckpointProvider (\_ -> (\(_, version, _) -> Right version) <$> readIORef storage) commit, (\(_, _, count) -> count) <$> readIORef storage)

resultFor :: MessageReceipt -> Text -> AssignmentResult
resultFor message finding = AssignmentResult 1 message.assignmentId AssignmentSucceeded Nothing (object ["finding" .= finding]) ["opaque-artifact-reference"]

accept :: AppEnv -> Store.SessionAccess -> Integer -> Text -> Instruction -> IO (Admission, MessageReceipt)
accept env access expected key value = expectRight =<< run env (Store.acceptMessage access (fixtureRevision expected) (fixtureRevision 0) (OperationId key) value)

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
  let env = AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing
      root = fixtureRootId "session-root"
      admission =
        configure $
          SessionAdmission
            1
            (SessionScope "fixture-coordinator" "logical-worker")
            (ObjectiveRef "fixture-checkpoint-provider" "objective-1")
            (parent & #name .~ fixtureAgentName "coordinator" & #delegates .~ map fixtureAgentName ["worker"])
            (DelegateCtx (fixtureDelegationDepth 0) (compatibilityIdentity (fixtureAgentName "coordinator")) (Just parentSession) Nothing (Just (WorkflowId "original-parent")) [fixtureAgentName "coordinator"] (Just ["worker-model"]) (Just root) Nothing defaultDelegationBudget)
            (fixtureAgentName "worker")
            (compatibilityIdentity (fixtureAgentName "worker"))
            (fixtureLimit 10)
            (fixtureLimit 4)
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

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureInstruction :: Text -> InstructionText
fixtureInstruction value = either (error . show) id (parseInstructionText value)

fixtureLimit :: (SessionLimit a) => Integer -> a
fixtureLimit value = either (error . show) id (parseSessionLimit value)

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureDelegationDepth :: Int -> DelegationDepth
fixtureDelegationDepth = either (error . show) id . parseDelegationDepth . toInteger

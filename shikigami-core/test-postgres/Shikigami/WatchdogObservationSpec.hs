{-# LANGUAGE DataKinds #-}

module Shikigami.WatchdogObservationSpec (tests, fixtureGrant, start) where

import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally)
import Control.Lens ((&), (.~))
import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Generics.Labels ()
import Data.IORef (newIORef, writeIORef)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Timer qualified as Timer
import Keiro.Workflow (WorkflowOutcome (Suspended), defaultWorkflowRunOptions, runWorkflow)
import Keiro.Workflow.Child (runChildWorkflow)
import Keiro.Workflow.Sleep (runWorkflowTimerWorker)
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))
import Kioku.Id (genSessionId)
import Kiroku.Store.Connection (KirokuStore (..), withStore)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Agent.Approval.Workflow qualified as ApprovalWorkflow
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal)
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.App (AppEffects, AppEnv (..), runAppIO)
import Shikigami.Approval.Observation qualified as ApprovalMetadata
import Shikigami.Duration (parseDuration)
import Shikigami.Execution.AssignmentKey (parseAssignmentKey)
import Shikigami.Execution.Claim (parseClaimOwner)
import Shikigami.Execution.Identity (newAttemptId, operationIdText)
import Shikigami.Execution.Observation qualified as Execution
import Shikigami.Execution.Resources (Admission (Accepted))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Runner (OperationContext (..))
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Store qualified as ExecutionStore
import Shikigami.Execution.Transcript qualified as Execution
import Shikigami.ExecutionTranscriptSpec qualified as ExecutionFixture
import Shikigami.Fixture.ExecutionIdentity (fixtureOperationId)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Objective.Observation qualified as Objective
import Shikigami.Objective.Types qualified as Objective
import Shikigami.ObjectiveStoreSpec (bindFixtureAssignment, createFixtureObjective, withObjective)
import Shikigami.Prelude (liftIO)
import Shikigami.StateRevision (advanceRevision, initialRevision)
import Shikigami.Watchdog.Grant
import Shikigami.Watchdog.Observation qualified as Watchdog
import Shikigami.Watchdog.Types qualified as Watchdog
import Shikigami.Watchdog.Waiting qualified as Waiting
import Shikigami.WorkerSession.Input (parseInstructionText, workerCoordinate)
import Shikigami.WorkerSession.Observation
import Shikigami.WorkerSession.Store qualified as Store
import Shikigami.WorkerSession.Types
import Shikigami.WorkerSessionStoreSpec (withFixture)
import Shikigami.Workspace.Process qualified as Process
import Shikigami.Workspace.ProcessStore qualified as ProcessStore
import Shikigami.Workspace.Types qualified as Workspace
import Shikigami.Workspace.Value
import Shikigami.WorkspaceProcessProfileStoreSpec (withProfile)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "Watchdog observation"
    [ testCase "one corrupt session refuses locally while other subject kinds advance" $
        withFixture fixture \env admission access -> do
          start env access
          ExecutionFixture.withFixtureIn env \_ snapshot _ -> do
            run env (runTransaction (Tx.sql "UPDATE shikigami.worker_sessions SET state=jsonb_set(state,'{format}','2'::jsonb)"))
            grant <- fixtureGrant
            page <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
            assertBool "valid execution survives another owner's corruption" (Watchdog.Execution snapshot.executionId `elem` map (.subject) page.subjects)
            assertBool "session refusal names its population" (any (\refusal -> refusal.kind == Watchdog.Sessions && refusal.reason == Watchdog.CorruptMetadata) page.refusals)
            page.cursor.sessions @?= Nothing
            assertBool "corruption prevents clean completion" (page.passCompleted /= Watchdog.PassCompleted)
            assertBool "corrupt session cannot become a valid observation" (Watchdog.WorkerSession (sessionIdFor admission) `notElem` map (.subject) page.subjects),
      testCase "session marks follow accepted child work before any result is recorded" $
        withFixture fixture \env _ access -> do
          message <- startWithReceipt env access
          parent <- maybe (assertFailure "missing child") pure message.childWorkflowId
          ExecutionFixture.withConfiguredFixtureIn env (\snapshot -> snapshot & #runId .~ parent) id \_ snapshot _ -> do
            grant <- fixtureGrant
            first <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
            session <- onlySession first
            case session.metadata of
              Watchdog.SessionMetadata metadata [execution] -> do
                metadata.executionId @?= Nothing
                execution.executionId @?= snapshot.executionId
                execution.runId @?= parent
              _ -> assertFailure (show session)
            run env (runTransaction (Tx.sql "UPDATE shikigami.executions SET state=jsonb_set(state,'{revision}','1'::jsonb)"))
            next <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
            changed <- onlySession next
            assertBool "accepted child progress changes the session mark" (session.mark /= changed.mark),
      testCase "long settled history leaves current activity complete and bounded" $
        ExecutionFixture.withHistoryFixture fixture \env snapshot active -> do
          grant <- fixtureGrant
          page <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
          case [subject | subject <- page.subjects, subject.subject == Watchdog.Execution snapshot.executionId] of
            [subject] -> case subject.metadata of
              Watchdog.ExecutionMetadata execution -> do
                length execution.operations @?= 32
                execution.operationsComplete @?= False
                execution.activityComplete @?= True
                execution.activeOperation @?= Just active.specification.operationId
                assertBool "active operation retained ahead of history" (active.specification.operationId `elem` map (.operationId) execution.operations)
                subject.relationshipsComplete @?= Watchdog.Complete
              _ -> assertFailure (show subject)
            _ -> assertFailure (show page),
      testCase "command intents respect their deadline and exclude literal arguments" $
        withProfile fixture \env binding _ ->
          ExecutionFixture.withToolFixtureForRootIn env binding.request.rootId \_ snapshot operation -> do
            now <- getCurrentTime
            attempt <- newAttemptId
            owner <- right (parseClaimOwner "watchdog-process-observation")
            timeoutSeconds <- right (parseProcessSeconds 30)
            outputBytes <- right (parseProcessOutputBytes 1024)
            let digest :: WorkspaceCoordinate scope
                digest = workspaceCoordinate ("sha256:" <> Text.replicate 64 "a")
                command = Process.ProcessCommand (workspaceCoordinate "validate") digest (workspaceCoordinate "/bin/validate") [workspaceCoordinate "WATCHDOG_PRIVATE_SENTINEL"] (workspaceCoordinate "") Map.empty timeoutSeconds outputBytes
                logical = OperationContext snapshot.executionId operation.specification.operationId operation.specification.operationId operation.fingerprint operation.specification.scopeDigest
                fingerprint = Process.processFingerprint binding digest logical command
                record = Process.ProcessRecord operation.specification.operationId attempt owner (advanceRevision initialRevision) (Workspace.workspaceBindingDigest binding) digest fingerprint command (addUTCTime 30 now) (Process.processUnit operation.specification.operationId fingerprint) Nothing Nothing Process.ProcessReserved Nothing Nothing
            run env (runTransaction (ProcessStore.reserveProcessTx binding record)) >>= (@?= Right record)
            run env (runTransaction (ProcessStore.requestProcessLaunchTx binding record (workspaceCoordinate "00000000-0000-4000-8000-000000000001"))) >>= (@?= Right True)
            grant <- fixtureGrant
            page <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
            case [subject | subject <- page.subjects, subject.subject == Watchdog.Execution snapshot.executionId] of
              [subject] -> do
                assertBool "command waits only within its deadline" (Watchdog.CommandWait record.deadline record.operationId `elem` subject.waits)
                map (.deadline) subject.processes @?= [record.deadline]
                assertBool "process evidence" (Watchdog.ProcessEvidence record.operationId `elem` subject.evidence)
              _ -> assertFailure (show page)
            assertBool "literal command arguments excluded" (not ("WATCHDOG_PRIVATE_SENTINEL" `Text.isInfixOf` Text.pack (Lazy.unpack (encode page))))
            run env (runTransaction (Tx.statement (operationIdText record.operationId) (preparable "UPDATE shikigami.workspace_processes SET record=jsonb_set(record,'{deadline}',to_jsonb(clock_timestamp()-interval '1 second')) WHERE operation_id=$1" (E.param (E.nonNullable E.text)) D.noResult)))
            expired <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
            case [subject | subject <- expired.subjects, subject.subject == Watchdog.Execution snapshot.executionId] of
              [subject] -> do
                assertBool "expired command is not a wait" (not (any isCommandWait subject.waits))
                assertBool "expired process remains evidence" (Watchdog.ProcessEvidence record.operationId `elem` subject.evidence)
              _ -> assertFailure (show expired),
      testCase "future permissions wait; expiration keeps evidence without a waiting fact" $
        ExecutionFixture.withPermissionFixture fixture \env snapshot operation permission -> do
          grant <- fixtureGrant
          page <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
          case [subject | subject <- page.subjects, subject.subject == Watchdog.Execution snapshot.executionId] of
            [subject] -> assertBool "exact permission deadline" (Watchdog.PermissionWait permission.expiresAt `elem` subject.waits)
            _ -> assertFailure "parked execution missing"
          run env (runTransaction (Tx.sql "UPDATE shikigami.execution_transcript_operations SET state=jsonb_set(state,'{permission,expiresAt}',to_jsonb(clock_timestamp()-interval '1 second')) WHERE state->'permission' IS NOT NULL"))
          expired <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
          case [subject | subject <- expired.subjects, subject.subject == Watchdog.Execution snapshot.executionId] of
            [subject] -> do
              assertBool "expired permission is not a wait" (not (any isPermissionWait subject.waits))
              assertBool "operation evidence retained" (not (null subject.evidence))
            _ -> assertFailure (show operation),
      testCase "stopped roots remain observable without spending their allowance" $
        ExecutionFixture.withFixture fixture \env snapshot _ -> do
          root <- maybe (assertFailure "missing root") pure snapshot.selection.rootId
          before <- right =<< run env (Roots.inspectRoot root)
          run env (Roots.setRootControl root before.revision Resources.StopWork Nothing) >>= (@?= Right ())
          grant <- fixtureGrant
          page <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
          case page.subjects of
            [subject] -> do
              map (.cancelled) subject.roots @?= [Resources.StopWork]
              assertBool "root evidence" (Watchdog.RootEvidence root (advanceRevision before.revision) `elem` subject.evidence)
            _ -> assertFailure (show page)
          after <- right =<< run env (Roots.inspectRoot root)
          after.usage @?= before.usage,
      testCase "approval waits require the exact owner link and retain no approval body" $
        withFixture fixture \env admission access -> do
          message <- startWithReceipt env access
          parent <- maybe (assertFailure "missing child parent") pure message.childWorkflowId
          session <- genSessionId
          token <- newIORef Nothing
          duration <- right (parseDuration 900)
          let review = Approval.reviewRequestIdFor agentRunWorkflowName parent 0 "watchdog-observation-approval"
              childEnv = ApprovalWorkflow.ApprovalWorkflowEnv (ApprovalWorkflow.ApprovalNotifier (\_ _ opaque _ -> writeIORef token (Just opaque)) (\_ _ _ _ -> pure (Right ())))
              parentBody = ApprovalWorkflow.requestBoundApproval review session (Approval.ApprovalRequest "WATCHDOG_PRIVATE_SENTINEL" (object []) Approval.ViaDanwa) duration
          run env (runWorkflow agentRunWorkflowName parent parentBody) >>= (@?= Suspended)
          run env (runChildWorkflow defaultWorkflowRunOptions ApprovalWorkflow.approvalWorkflowName (Approval.approvalWorkflowId review) (ApprovalWorkflow.approvalWorkflow childEnv Nothing)) >>= (@?= Suspended)
          grant <- fixtureGrant
          unknown <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
          assertBool "uncorrelated approval is not a wait" (all (not . any isApprovalWait . (.waits)) unknown.subjects)
          run env (runTransaction (ApprovalMetadata.recordApprovalAssociationTx review agentRunWorkflowName parent)) >>= (@?= Right ())
          run env (runTransaction (ApprovalMetadata.recordApprovalAssociationTx review agentRunWorkflowName parent)) >>= (@?= Right ())
          timerPage <- right =<< run env (Timer.findPendingTimers (Timer.PendingTimerFilter (Just ApprovalWorkflow.approvalWorkflowName.unWorkflowName) (Just (Approval.reviewRequestIdText review))) (Timer.PendingTimerPageRequest 1 Nothing))
          deadline <- case timerPage.timers of
            [timer] -> pure timer.timer.fireAt
            _ -> assertFailure "expected one owner approval timer"
          page <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
          case page.subjects of
            [subject] -> do
              assertBool "exact timer deadline" (Watchdog.ApprovalWait deadline review `elem` subject.waits)
              assertBool "live approval wait" (any isApprovalWait subject.waits)
              assertBool "review evidence" (Watchdog.ApprovalEvidence review `elem` subject.evidence)
              map (.phase) subject.approvals @?= [Waiting.ApprovalPending]
            _ -> assertFailure (show page)
          assertBool "approval request body excluded" (not ("WATCHDOG_PRIVATE_SENTINEL" `Text.isInfixOf` Text.pack (Lazy.unpack (encode page))))
          now <- getCurrentTime
          fired <- run env (runWorkflowTimerWorker Nothing (addUTCTime 901 now) Approval.approvalTimeoutFireAction)
          assertBool "exact approval timer fired" (maybe False (const True) fired)
          expired <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
          assertBool "fired timer no longer waits" (all (not . any isApprovalWait . (.waits)) expired.subjects)
          run env (runTransaction (ApprovalMetadata.recordApprovalAssociationTx review agentRunWorkflowName (WorkflowId "another-parent"))) >>= (@?= Left ApprovalMetadata.ApprovalAssociationConflict),
      testCase "sparse active populations use indexes after terminal history accumulates" $
        withObjective fixture \env admission _ -> do
          access <- right =<< run env (Store.authorizeSession (sessionIdFor admission) admission.context.identity (pure (Right ())))
          start env access
          ExecutionFixture.withFixtureIn env \_ _ _ -> do
            run
              env
              ( runTransaction do
                  Tx.sql "INSERT INTO shikigami.objectives(objective_id,state) SELECT 'watchdog-terminal-objective-'||n::text,jsonb_set(o.state,'{status}','\"Completed\"'::jsonb) FROM shikigami.objectives o CROSS JOIN generate_series(1,4000) n"
                  Tx.sql "INSERT INTO shikigami.worker_sessions(session_id,scope_digest,state,binding) SELECT 'watchdog-terminal-session-'||n::text,'watchdog-terminal-scope-'||n::text,jsonb_set(s.state,'{phase}','\"Failed\"'::jsonb),s.binding FROM shikigami.worker_sessions s CROSS JOIN generate_series(1,4000) n"
                  Tx.sql "INSERT INTO shikigami.executions(execution_id,state,binding) SELECT 'watchdog-terminal-execution-'||n::text,jsonb_set(e.state,'{phase}','\"Succeeded\"'::jsonb),e.binding FROM shikigami.executions e CROSS JOIN generate_series(1,4000) n"
                  Tx.sql "ANALYZE shikigami.objectives"
                  Tx.sql "ANALYZE shikigami.worker_sessions"
                  Tx.sql "ANALYZE shikigami.executions"
              )
            mapM_
              ( \(table, key, selector) -> do
                  plan <- run env (runTransaction (Tx.statement () (preparable ("EXPLAIN (FORMAT JSON) SELECT " <> key <> " FROM " <> table <> " WHERE " <> key <> ">' ' AND " <> selector <> " ORDER BY " <> key <> " LIMIT 32") E.noParams (D.singleRow (D.column (D.nonNullable D.json))))))
                  assertBool (Text.unpack table <> ": " <> Lazy.unpack (encode (plan :: Value))) (not ("Seq Scan" `Text.isInfixOf` Text.pack (Lazy.unpack (encode plan))))
              )
              [ ("shikigami.objectives", "objective_id", "COALESCE(state->>'status','invalid') NOT IN ('Completed','Cancelled')"),
                ("shikigami.worker_sessions", "session_id", "COALESCE(state->>'phase','invalid') NOT IN ('Idle','Failed','Cancelled')"),
                ("shikigami.executions", "execution_id", "COALESCE(state->>'phase','invalid') NOT IN ('Succeeded','Failed','Cancelled')")
              ],
      testCase "a timed-out read refuses its page and the next transaction recovers" $
        withObjective fixture \env _ objective -> do
          grant <- fixtureGrant
          result <-
            withHeld
              env
              (Session.script "LOCK TABLE shikigami.objectives IN ACCESS EXCLUSIVE MODE")
              (timeout 2000000 (run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)))
          result @?= Just (Left Watchdog.ObservationUnavailable)
          recovered <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
          assertBool "recovered objective" (Watchdog.ObjectiveCoordinator objective `elem` map (.subject) recovered.subjects),
      testCase "truncated objective relationships remain unknown and prevent a clean pass" $
        withObjective fixture \env _ objective -> do
          _ <- bindFixtureAssignment env objective "bounded-assignment"
          run env (runTransaction (Tx.sql "UPDATE shikigami.objectives SET state=jsonb_set(state,'{assignments}',(SELECT jsonb_agg(jsonb_set(state->'assignments'->0,'{definition,assignmentId,value}',to_jsonb('bounded-' || value::text))) FROM generate_series(1,65) value))"))
          grant <- fixtureGrant
          page <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
          case page.subjects of
            [observed] -> do
              observed.relationshipsComplete @?= Watchdog.Unknown
              case observed.metadata of
                Watchdog.ObjectiveMetadata metadata _ _ _ -> length metadata.assignments @?= 64
                _ -> assertFailure "wrong subject metadata"
            _ -> do
              details <- run env (runTransaction (Tx.statement () (preparable (Objective.observationSql <> " LIMIT 1") E.noParams (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb))))))
              assertFailure (show page <> show (map (Aeson.fromJSON @Objective.ObjectiveObservation . snd) details))
          page.cursor.passClean @?= False
          page.passCompleted @?= Watchdog.PassIncomplete,
      testCase "selected objectives filter both objective and session populations before LIMIT" $
        withObjective fixture \env admission firstObjective -> do
          secondObjective <- createFixtureObjective env "watchdog-outside-objective"
          firstRef <- bindFixtureAssignment env firstObjective "first-assignment"
          secondRef <- bindFixtureAssignment env secondObjective "second-assignment"
          let first = admission & #scope . #workerKey .~ workerCoordinate "watchdog-scope-first" & #objective .~ firstRef
              second = admission & #scope . #workerKey .~ workerCoordinate "watchdog-scope-second" & #objective .~ secondRef
          mapM_
            ( \worker -> do
                _ <- right =<< run env (Store.openSession worker)
                access <- right =<< run env (Store.authorizeSession (sessionIdFor worker) worker.context.identity (pure (Right ())))
                start env access
            )
            [first, second]
          mapM_
            ( \(objective, worker) -> do
                rows <- run env (runTransaction (observeOpenSessions (SessionsForObjectives (objective :| [])) Nothing 1))
                map fst rows @?= [sessionIdFor worker]
                grant <- fixtureGrantWithScope 3 (SelectedObjectives (objective :| []))
                page <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
                map (.subject) page.subjects @?= [Watchdog.ObjectiveCoordinator objective, Watchdog.WorkerSession (sessionIdFor worker)]
                case page.subjects of
                  observed : _ -> case observed.metadata of
                    Watchdog.ObjectiveMetadata _ _ related _ -> map (.sessionId) related @?= [sessionIdFor worker]
                    _ -> assertFailure "missing coordinator metadata"
                  [] -> assertFailure "missing coordinator"
                reset <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds (page.cursor & #scope .~ Nothing & #exhausted .~ [Watchdog.Objectives, Watchdog.Sessions]))
                map (.subject) reset.subjects @?= map (.subject) page.subjects
                assertBool "every observed binding is in scope" (all ((== Just objective) . (.objective)) page.subjects)
            )
            [(firstObjective, first), (secondObjective, second)],
      testCase "mixed population wraps after three pages and budget one rotates all kinds" $
        withObjective fixture \env admission _ -> do
          access <- right =<< run env (Store.authorizeSession (sessionIdFor admission) admission.context.identity (pure (Right ())))
          start env access
          _ <- createFixtureObjective env "watchdog-second-objective"
          let second = admission & #scope . #workerKey .~ workerCoordinate "watchdog-second-worker"
          _ <- right =<< run env (Store.openSession second)
          otherAccess <- right =<< run env (Store.authorizeSession (sessionIdFor second) second.context.identity (pure (Right ())))
          start env otherAccess
          ExecutionFixture.withFixtureIn env \_ snapshot _ -> do
            assignment <- right (parseAssignmentKey "watchdog-second-execution")
            let other = snapshot & #selection . #assignmentId .~ assignment & #executionId .~ Execution.executionIdFor assignment & #runId .~ WorkflowId "watchdog-second-run"
            run env (ExecutionStore.admitExecution other) >>= (@?= Right Accepted)
            grant <- fixtureGrantWithLimit 3
            first <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)
            secondPage <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds first.cursor)
            end <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds secondPage.cursor)
            map (length . (.subjects)) [first, secondPage, end] @?= [3, 3, 0]
            length (nub (map (.subject) (first.subjects <> secondPage.subjects))) @?= 6
            end.passCompleted @?= Watchdog.PassCompleted
            again <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds end.cursor)
            map (.subject) again.subjects @?= map (.subject) first.subjects
            one <- fixtureGrantWithLimit 1
            onePages <- readPages env one 9 Watchdog.initialCursor
            map (map (kindOf . (.subject)) . (.subjects)) (take 3 onePages) @?= [[Watchdog.Objectives], [Watchdog.Sessions], [Watchdog.Executions]]
            length (nub (concatMap (map (.subject) . (.subjects)) onePages)) @?= 6
            case reverse onePages of
              final : _ -> final.passCompleted @?= Watchdog.PassCompleted
              [] -> assertFailure "no coverage pages",
      testCase "composed page observes locked objective and session within its bound" $
        withObjective fixture \env admission objective -> do
          access <- right =<< run env (Store.authorizeSession (sessionIdFor admission) admission.context.identity (pure (Right ())))
          start env access
          grant <- fixtureGrant
          locked <- newEmptyMVar
          release <- newEmptyMVar
          withStore env.connectionSettings \store -> do
            let hold = Pool.use store.pool do
                  Session.script "BEGIN"
                  _ <-
                    Session.statement
                      (Objective.objectiveIdText objective)
                      (preparable "SELECT objective_id FROM shikigami.objectives WHERE objective_id=$1 FOR UPDATE" (E.param (E.nonNullable E.text)) (D.singleRow (D.column (D.nonNullable D.text))))
                  _ <-
                    Session.statement
                      (workerSessionIdText (sessionIdFor admission))
                      (preparable "SELECT session_id FROM shikigami.worker_sessions WHERE session_id=$1 FOR UPDATE" (E.param (E.nonNullable E.text)) (D.singleRow (D.column (D.nonNullable D.text))))
                  liftIO (putMVar locked () >> takeMVar release)
                  Session.script "ROLLBACK"
            withAsync hold \worker -> do
              ready <- timeout 2000000 (takeMVar locked)
              ready @?= Just ()
              answer <- timeout 2000000 (run env (Watchdog.observePage grant Watchdog.defaultObservationBounds Watchdog.initialCursor)) `finally` putMVar release ()
              _ <- right =<< wait worker
              case answer of
                Just (Right page) -> do
                  let subjects = map (.subject) page.subjects
                  assertBool "locked coordinator present" (Watchdog.ObjectiveCoordinator objective `elem` subjects)
                  assertBool "locked session present" (Watchdog.WorkerSession (sessionIdFor admission) `elem` subjects)
                  let encoded = Text.pack (Lazy.unpack (encode page))
                  mapM_
                    (\word -> assertBool (Text.unpack word) (not (word `Text.isInfixOf` encoded)))
                    ["WATCHDOG_PRIVATE_SENTINEL", "\"instructions\"", "\"input\"", "\"output\"", "\"payload\"", "\"result\"", "\"transcript\"", "\"prompt\""]
                _ -> assertFailure (show answer),
      testCase "execution projection excludes retained prompt and replay bodies" $
        ExecutionFixture.withFixture fixture \env snapshot _ -> do
          rows <- run env (runTransaction (Execution.observeOpenExecutions Execution.AllExecutions Nothing 1))
          case rows of
            [(identifier, Right observed)] -> do
              identifier @?= snapshot.executionId
              observed.phase @?= Execution.Active
              observed.operationsComplete @?= True
              assertBool "private context absent" (not ("PRIVATE_REPLAY_MARKER" `Text.isInfixOf` Text.pack (Lazy.unpack (encode observed))))
            _ -> assertFailure (show rows),
      testCase "objective projection is bounded and never returns instruction bodies" $
        withObjective fixture \env _ objective -> do
          run env (runTransaction (Tx.sql "UPDATE shikigami.objectives SET state=jsonb_set(state,'{instructions}','\"WATCHDOG_PRIVATE_SENTINEL\"'::jsonb)"))
          rows <- run env (runTransaction (Objective.observeOpenObjectives Objective.AllOpenObjectives Nothing 1))
          case rows of
            [(identifier, Right observed)] -> do
              identifier @?= Objective.objectiveIdText objective
              observed.status @?= Objective.Open
              observed.relationshipsComplete @?= True
              Objective.goalText observed.goal @?= "integrated goal"
              assertBool "no instruction text" (not ("WATCHDOG_PRIVATE_SENTINEL" `Text.isInfixOf` Text.pack (Lazy.unpack (encode observed))))
            _ -> assertFailure (show rows),
      testCase "objective corruption is refused within its owner projection" $
        withObjective fixture \env _ objective -> do
          run env (runTransaction (Tx.sql "UPDATE shikigami.objectives SET state=jsonb_set(state,'{revision}','\"broken\"'::jsonb)"))
          run env (runTransaction (Objective.observeOpenObjectives Objective.AllOpenObjectives Nothing 1)) >>= (@?= [(Objective.objectiveIdText objective, Left Objective.ObjectiveUnavailable)]),
      testCase "session projection retains active metadata and excludes protected bodies" $
        withFixture fixture \env admission access -> do
          start env access
          rows <- run env (runTransaction (observeOpenSessions AllSessions Nothing 1))
          case rows of
            [(identifier, Right observed)] -> do
              identifier @?= sessionIdFor admission
              observed.phase @?= Active
              observed.assignmentPhase @?= Just Running
              observed.assignmentObserved @?= True
              observed.queuedAssignments @?= 0
              assertBool "child workflow retained" (observed.childWorkflowId /= Nothing)
              let encoded = Lazy.unpack (encode observed)
              mapM_
                (\word -> assertBool word (not (Text.pack word `Text.isInfixOf` Text.pack encoded)))
                ["WATCHDOG_PRIVATE_SENTINEL", "\"instructions\"", "\"input\"", "\"output\"", "\"payload\"", "\"result\"", "\"prompt\"", "\"transcript\""]
            _ -> assertFailure (show rows),
      testCase "scope is applied before pagination and idle sessions are available by exact id" $
        withFixture fixture \env admission access -> do
          direct <- right =<< run env (runTransaction (observeSessionsFor (sessionIdFor admission :| [])))
          case direct of
            [(_, Right observed)] -> observed.phase @?= Idle
            _ -> assertFailure (show direct)
          start env access
          rows <- run env (runTransaction (observeOpenSessions (SessionsWithReferences (admission.objective :| [])) Nothing 1))
          length rows @?= 1
          let other = ObjectiveRef (workerCoordinate "other-provider") (workerCoordinate "other-objective")
          run env (runTransaction (observeOpenSessions (SessionsWithReferences (other :| [])) Nothing 1)) >>= (@?= []),
      testCase "corrupt session projection is a row-local typed refusal" $
        withFixture fixture \env admission access -> do
          start env access
          run env (runTransaction (Tx.sql "UPDATE shikigami.worker_sessions SET state='{}'::jsonb"))
          run env (runTransaction (observeOpenSessions AllSessions Nothing 1)) >>= (@?= [(sessionIdFor admission, Left SessionStorageUnavailable)]),
      testCase "session observation completes while another transaction holds its row lock" $
        withFixture fixture \env admission access -> do
          start env access
          locked <- newEmptyMVar
          release <- newEmptyMVar
          withStore env.connectionSettings \store -> do
            let hold = Pool.use store.pool do
                  Session.script "BEGIN"
                  Session.statement
                    (workerSessionIdText (sessionIdFor admission))
                    (preparable "SELECT session_id FROM shikigami.worker_sessions WHERE session_id=$1 FOR UPDATE" (E.param (E.nonNullable E.text)) (D.singleRow (D.column (D.nonNullable D.text))))
                  liftIO (putMVar locked () >> takeMVar release)
                  Session.script "ROLLBACK"
            withAsync hold \worker -> do
              ready <- timeout 2000000 (takeMVar locked)
              ready @?= Just ()
              answer <-
                ( timeout
                    2000000
                    ( run
                        env
                        ( runTransaction do
                            Tx.sql "SET LOCAL statement_timeout='1500ms'"
                            Tx.sql "SET LOCAL lock_timeout='250ms'"
                            observeOpenSessions AllSessions Nothing 1
                        )
                    )
                )
                  `finally` putMVar release ()
              _ <- right =<< wait worker
              case answer of
                Just [(identifier, Right _)] -> identifier @?= sessionIdFor admission
                _ -> assertFailure (show answer)
    ]

start :: AppEnv -> Store.SessionAccess -> IO ()
start env access = do
  _ <- startWithReceipt env access
  pure ()

startWithReceipt :: AppEnv -> Store.SessionAccess -> IO MessageReceipt
startWithReceipt env access = do
  instructions <- right (parseInstructionText "WATCHDOG_PRIVATE_SENTINEL")
  let instruction = Instruction V1 FollowUp instructions initialRevision initialRevision initialRevision Nothing
  (_, accepted) <- right =<< run env (Store.acceptMessage access initialRevision initialRevision (fixtureOperationId "watchdog-observation-accept") instruction)
  (_, started) <- right =<< run env (Store.startAssignment access (advanceRevision initialRevision) initialRevision (fixtureOperationId "watchdog-observation-start") accepted.assignmentId)
  pure started

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

fixtureGrant :: IO ObservationGrant
fixtureGrant = fixtureGrantWithLimit 9

fixtureGrantWithLimit :: Int -> IO ObservationGrant
fixtureGrantWithLimit budget = fixtureGrantWithScope budget AllObjectives

fixtureGrantWithScope :: Int -> ObservationScope -> IO ObservationGrant
fixtureGrantWithScope budget scope = do
  settings <- right (eitherDecode (encode (object ["principal" .= ("agent_watchdog" :: Text.Text), "scope" .= scope, "stuckWindowSeconds" .= (60 :: Int), "parkedWindowSeconds" .= (30 :: Int), "coordinatorWindowSeconds" .= (60 :: Int), "subjectsPerSweep" .= budget])))
  identity <- VerifiedIdentity <$> right (mkAgentPrincipal "agent_watchdog")
  right (resolveObservationGrant (Just settings) identity)

readPages :: AppEnv -> ObservationGrant -> Int -> Watchdog.CoverageCursor -> IO [Watchdog.ObservationPage]
readPages _ _ 0 _ = pure []
readPages env grant count cursor = do
  page <- right =<< run env (Watchdog.observePage grant Watchdog.defaultObservationBounds cursor)
  rest <- readPages env grant (count - 1) page.cursor
  pure (page : rest)

kindOf :: Watchdog.Subject -> Watchdog.SubjectKind
kindOf (Watchdog.ObjectiveCoordinator _) = Watchdog.Objectives
kindOf (Watchdog.WorkerSession _) = Watchdog.Sessions
kindOf (Watchdog.Execution _) = Watchdog.Executions

withHeld :: AppEnv -> Session.Session () -> IO a -> IO a
withHeld env statement action = do
  locked <- newEmptyMVar
  release <- newEmptyMVar
  withStore env.connectionSettings \store -> do
    let hold = Pool.use store.pool do
          Session.script "BEGIN"
          statement
          liftIO (putMVar locked () >> takeMVar release)
          Session.script "ROLLBACK"
    withAsync hold \worker -> do
      ready <- timeout 2000000 (takeMVar locked)
      ready @?= Just ()
      answer <- action `finally` putMVar release ()
      _ <- right =<< wait worker
      pure answer

isPermissionWait :: Watchdog.WaitingFact -> Bool
isPermissionWait Watchdog.PermissionWait {} = True
isPermissionWait _ = False

isApprovalWait :: Watchdog.WaitingFact -> Bool
isApprovalWait Watchdog.ApprovalWait {} = True
isApprovalWait _ = False

isCommandWait :: Watchdog.WaitingFact -> Bool
isCommandWait Watchdog.CommandWait {} = True
isCommandWait _ = False

onlySession :: Watchdog.ObservationPage -> IO Watchdog.SubjectObservation
onlySession page = case [subject | subject <- page.subjects, Watchdog.WorkerSession _ <- [subject.subject]] of
  [subject] -> pure subject
  _ -> assertFailure (show page)

module Shikigami.ObjectiveStoreSpec (tests, crashWriter) where

import Contravariant.Extras (contrazip2, contrazip3)
import Control.Concurrent.Async (concurrently)
import Control.Exception (SomeException, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Either (isLeft, rights)
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Read qualified as StoreRead
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types qualified as StoreTypes
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests, denyAllActionAuthorizer)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (..), compatibilityIdentity, mkAgentPrincipal)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId, operationIdText)
import Shikigami.Execution.Payload (payloadIdText)
import Shikigami.Execution.Transcript (PayloadRef (..))
import Shikigami.Fixture.ExecutionIdentity (fixtureOperationId, fixtureRootId)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Objective.Capability qualified as O
import Shikigami.Objective.Command
import Shikigami.Objective.Store qualified as S
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.WorkerSession.Checkpoint qualified as CP
import Shikigami.WorkerSession.Input (InstructionText, parseInstructionText)
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Types qualified as WS
import Shikigami.WorkerSessionStoreSpec qualified as SessionsFixture
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hClose)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "ObjectiveStore"
    [ testCase "corrupt snapshot refuses through the owner and recovery preserves the retained objective" $
        withObjective fixture \env _ objective -> do
          current <- get env objective
          beforeEvents <- objectiveEventCount env
          case Aeson.toJSON current of
            Aeson.Object fields -> replaceJson env "UPDATE shikigami.objectives SET state=$1" (Aeson.Object (KeyMap.insert "title" (Aeson.Number 0) fields))
            _ -> assertFailure "complete objective must be an object"
          run env (O.readObjective ownerHost objective) >>= (@?= Left ObjectiveConflict)
          -- Public callers can ignore the refusal, but no native event, payload
          -- or negative receipt is committed by the failed command.
          _ <- run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId "corrupt-read") (ReviseInstructions (instructions "changed")))
          objectiveEventCount env >>= (@?= beforeEvents)
          count env "shikigami.objective_receipts" >>= (@?= 1)
          count env "shikigami.objective_payloads" >>= (@?= 1)
          replaceJson env "UPDATE shikigami.objectives SET state=$1" (toJSON current)
          get env objective >>= (@?= current)
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId "corrupt-read") (ReviseInstructions (instructions "changed")))
          pure (),
      testCase "corrupt command receipt refuses rather than replacing the retained outcome" $
        withObjective fixture \env _ objective -> do
          let operation = fixtureOperationId "edit"
              retry = O.executeCommand ownerHost objective (revision 0) operation (ReviseInstructions (instructions "new"))
          receipt <- right =<< run env retry
          run env (O.readCommandReceipt ownerHost objective operation) >>= (@?= Right (Just (Right receipt)))
          beforeEvents <- objectiveEventCount env
          replaceJson env "UPDATE shikigami.objective_receipts SET outcome=$1" Aeson.Null
          run env (O.readCommandReceipt ownerHost objective operation) >>= (@?= Left ObjectiveConflict)
          run env retry >>= (@?= Left ObjectiveConflict)
          objectiveEventCount env >>= (@?= beforeEvents)
          count env "shikigami.objective_receipts" >>= (@?= 2)
          replaceJson env "UPDATE shikigami.objective_receipts SET outcome=$1 WHERE operation_key LIKE '%edit%'" (toJSON (Right receipt :: Either ObjectiveError Receipt))
          run env retry >>= (@?= Right receipt),
      testCase "corrupt creation receipt prevents replacement allocation and recovers the original winner" $
        withObjective fixture \env _ objective -> do
          let recover = O.createObjective ownerHost (fixtureOperationId "create") (Just origin) request
          original <- right =<< run env recover
          original.objectiveId @?= objective
          beforeEvents <- objectiveEventCount env
          replaceJson env "UPDATE shikigami.objective_origins SET receipt=$1" Aeson.Null
          run env recover >>= (@?= Left ObjectiveConflict)
          count env "shikigami.objectives" >>= (@?= 1)
          count env "shikigami.objective_origins" >>= (@?= 1)
          objectiveEventCount env >>= (@?= beforeEvents)
          replaceJson env "UPDATE shikigami.objective_origins SET receipt=$1" (toJSON original)
          run env recover >>= (@?= Right original),
      testCase "absent receipts and genuine SQL failure retain distinct results" $
        withObjective fixture \env _ objective -> do
          let operation = fixtureOperationId "absent"
          run env (O.readCommandReceipt ownerHost objective operation) >>= (@?= Right Nothing)
          sql env "ALTER TABLE shikigami.objective_receipts RENAME TO unavailable_objective_receipts_fixture"
          run env (O.readCommandReceipt ownerHost objective operation) >>= (@?= Left ObjectiveUnavailable)
          sql env "ALTER TABLE shikigami.unavailable_objective_receipts_fixture RENAME TO objective_receipts"
          run env (O.readCommandReceipt ownerHost objective operation) >>= (@?= Right Nothing),
      testCase "corrupt checkpoint metadata cannot become absence or retain a negative receipt" $
        withObjective fixture \env admission objective -> do
          (a, b, first, second, inputA, inputB) <- checkpointPair env admission objective
          access <- right =<< run env (Sessions.authorizeSession first.sessionId admission.context.identity (pure (Right ())))
          run env (Sessions.readCheckpointIntent access first.operationId) >>= (@?= Right first)
          _ <- right =<< run env (O.executeInternal ownerHost objective first.expected.revision (fixtureOperationId "valid-sibling") (IngestCheckpoint b.assignmentId second [inputB] []))
          before <- get env objective
          let retry = O.executeInternal ownerHost objective first.expected.revision (fixtureOperationId "corrupt-checkpoint") (IngestCheckpoint a.assignmentId first [inputA] [])
          beforeReceipts <- count env "shikigami.objective_receipts"
          beforeEvents <- objectiveEventCount env
          replaceOwnedRow env "UPDATE shikigami.worker_session_commands SET state=$3 WHERE session_id=$1 AND operation_id=$2" first.sessionId.value (operationIdText first.operationId) Aeson.Null
          run env retry >>= (@?= Left ObjectiveConflict)
          count env "shikigami.objective_receipts" >>= (@?= beforeReceipts)
          objectiveEventCount env >>= (@?= beforeEvents)
          get env objective >>= (@?= before)
          replaceOwnedRow env "UPDATE shikigami.worker_session_commands SET state=$3 WHERE session_id=$1 AND operation_id=$2" first.sessionId.value (operationIdText first.operationId) (toJSON first)
          _ <- right =<< run env retry
          pure (),
      testCase "corrupt worker result cannot disappear behind its payload join" $
        withObjective fixture \env admission objective -> do
          (a, _, intent, _, input, _) <- checkpointPair env admission objective
          receipt <- case input of ResultEvidence {result = WorkerResult receipt _} -> pure receipt; _ -> fail "missing worker result"
          access <- right =<< run env (Sessions.authorizeSession receipt.sessionId admission.context.identity (pure (Right ())))
          retained <- right =<< run env (Sessions.readResult access receipt.assignmentId)
          result <- case retained of Just (_, value) -> pure value; Nothing -> fail "complete valid result missing"
          originalBody <- readOwnedJson env "SELECT body FROM shikigami.worker_session_payloads WHERE session_id=$1 AND payload_id=$2" receipt.sessionId.value (payloadIdText receipt.output.payloadId)
          before <- get env objective
          beforeReceipts <- count env "shikigami.objective_receipts"
          let retry = O.executeInternal ownerHost objective before.revision (fixtureOperationId "corrupt-result") (IngestCheckpoint a.assignmentId intent [input] [])
              replace = replaceOwnedRow env "UPDATE shikigami.worker_session_results SET state=$3 WHERE session_id=$1 AND assignment_id=$2" receipt.sessionId.value receipt.assignmentId.value
          replace Aeson.Null
          run env retry >>= (@?= Left ObjectiveConflict)
          count env "shikigami.objective_receipts" >>= (@?= beforeReceipts)
          get env objective >>= (@?= before)
          replace (toJSON receipt)
          let replaceBody = replaceOwnedRow env "UPDATE shikigami.worker_session_payloads SET body=$3 WHERE session_id=$1 AND payload_id=$2" receipt.sessionId.value (payloadIdText receipt.output.payloadId)
          case originalBody of
            Aeson.Object fields -> replaceBody (Aeson.Object (KeyMap.insert "content" (toJSON (result & #artifacts .~ ["different"])) fields))
            _ -> assertFailure "complete result envelope must be an object"
          run env retry >>= (@?= Left ObjectiveConflict)
          count env "shikigami.objective_receipts" >>= (@?= beforeReceipts)
          get env objective >>= (@?= before)
          replaceBody originalBody
          _ <- right =<< run env retry
          pure (),
      testCase "public writers at one revision produce one transition and retained conflict" $
        withObjective fixture \env _ objective -> do
          let write key text = run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId key) (ReviseInstructions (instructions text)))
          (left, rightResult) <- concurrently (write "left" "left") (write "right" "right")
          length (rights [left, rightResult]) @?= 1
          length (filter (== Left ObjectiveConflict) [left, rightResult]) @?= 1
          current <- get env objective
          current.revision @?= revision 1
          let (key, text) = if isLeft left then ("left", "left") else ("right", "right")
          -- Even a newly edited envelope cannot convert the old rejection.
          run env (O.executeCommand ownerHost objective (revision 1) (fixtureOperationId key) (ReviseInstructions (instructions text))) >>= (@?= Left ObjectiveConflict)
          count env "shikigami.objective_receipts" >>= (@?= 3),
      testCase "accepted retries recover original receipt after progress and reject changed payload" $
        withObjective fixture \env _ objective -> do
          first <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId "edit") (ReviseInstructions (instructions "new")))
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 1) (fixtureOperationId "next") (SetNextAction [nextAction "continue"]))
          run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId "edit") (ReviseInstructions (instructions "new"))) >>= (@?= Right first)
          run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId "edit") (ReviseInstructions (instructions "different"))) >>= (@?= Left ObjectiveConflict)
          run env (O.readCommandReceipt ownerHost objective (fixtureOperationId "edit")) >>= (@?= Right (Just (Right first))),
      testCase "creation is creator-scoped, concurrent and atomically retains origin and membership" $
        withDatabase fixture \env -> do
          let create = run env (O.createObjective ownerHost (fixtureOperationId "create") (Just origin) request)
          (left, rightResult) <- concurrently create create
          first <- right left
          rightResult @?= Right first
          parseObjectiveId (objectiveIdText first.objectiveId) @?= Right first.objectiveId
          assertBool "allocated objective uses its owned TypeID prefix" ("shikigami_objective_" `Text.isPrefixOf` objectiveIdText first.objectiveId)
          run env (O.createObjective ownerHost (fixtureOperationId "create") (Just origin) request) >>= (@?= Right first)
          count env "shikigami.objectives" >>= (@?= 1)
          count env "shikigami.objective_origins" >>= (@?= 1)
          objectiveEventCount env >>= (@?= 1)
          current <- get env first.objectiveId
          current.members @?= [Member owner [Owner, Coordinator, Completer]]
          other <- right =<< run env (O.createObjective (host (VerifiedCaller "other")) (fixtureOperationId "create") Nothing request)
          assertBool "creator scopes differ" (first.objectiveId /= other.objectiveId)
          run env (O.readObjective (host (VerifiedCaller "other")) first.objectiveId) >>= (@?= Left ObjectiveDenied),
      testCase "creation rollback leaves no objective, origin, receipt or lifecycle event" $
        withDatabase fixture \env -> do
          sql env "CREATE FUNCTION shikigami.reject_objective_origin() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''injected origin failure''; END'"
          sql env "CREATE TRIGGER reject_origin BEFORE INSERT ON shikigami.objective_origins FOR EACH ROW EXECUTE FUNCTION shikigami.reject_objective_origin()"
          _ <- try @SomeException (run env (O.createObjective ownerHost (fixtureOperationId "create") (Just origin) request))
          mapM_ (\table -> count env table >>= (@?= 0)) ["shikigami.objectives", "shikigami.objective_origins", "shikigami.objective_receipts", "shikigami.objective_payloads"]
          objectiveEventCount env >>= (@?= 0)
          sql env "DROP TRIGGER reject_origin ON shikigami.objective_origins"
          _ <- right =<< run env (O.createObjective ownerHost (fixtureOperationId "create") (Just origin) request)
          count env "shikigami.objectives" >>= (@?= 1),
      testCase "receipt failure rolls back evidence, revision and lifecycle append" $
        withObjective fixture \env _ objective -> do
          now <- getCurrentTime
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId "graph") (SetAssignments [draft now "a"]))
          let input = Attestation (evidenceKey "check") (criterionKey "human") (artifact "artifact") (statement "reviewed integration") False
          sql env "CREATE FUNCTION shikigami.reject_objective_receipt() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''injected receipt failure''; END'"
          sql env "CREATE TRIGGER reject_receipt BEFORE INSERT ON shikigami.objective_receipts FOR EACH ROW EXECUTE FUNCTION shikigami.reject_objective_receipt()"
          _ <- try @SomeException (run env (O.executeCommand ownerHost objective (revision 1) (fixtureOperationId "evidence") (RecordEvidence (objectiveAssignment "a") input)))
          current <- get env objective
          current.revision @?= revision 1
          current.evidence @?= []
          count env "shikigami.objective_payloads" >>= (@?= 2)
          sql env "DROP TRIGGER reject_receipt ON shikigami.objective_receipts"
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 1) (fixtureOperationId "evidence") (RecordEvidence (objectiveAssignment "a") input))
          current' <- get env objective
          length current'.evidence @?= 1,
      testCase "revoked membership denies both stale writes and retained receipt disclosure" $
        withObjective fixture \env _ objective -> do
          let collaborator = VerifiedCaller "coordinator"
              collaboratorHost = host collaborator
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId "grant") (GrantMember collaborator [Coordinator]))
          _ <- right =<< run env (O.executeCommand collaboratorHost objective (revision 1) (fixtureOperationId "edit") (SetNextAction [nextAction "next"]))
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 2) (fixtureOperationId "revoke") (RevokeMember collaborator))
          run env (O.executeCommand collaboratorHost objective (revision 1) (fixtureOperationId "edit") (SetNextAction [nextAction "next"])) >>= (@?= Left ObjectiveDenied)
          run env (O.readCommandReceipt collaboratorHost objective (fixtureOperationId "edit")) >>= (@?= Left ObjectiveDenied)
          run env (O.executeCommand collaboratorHost objective (revision 3) (fixtureOperationId "new") (SetNextAction [])) >>= (@?= Left ObjectiveDenied),
      testCase "revocation race cannot commit a later unauthorized edit" $
        withObjective fixture \env _ objective -> do
          let collaborator = VerifiedCaller "coordinator"
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId "grant") (GrantMember collaborator [Coordinator]))
          (revocation, edit) <-
            concurrently
              (run env (O.executeCommand ownerHost objective (revision 1) (fixtureOperationId "revoke") (RevokeMember collaborator)))
              (run env (O.executeCommand (host collaborator) objective (revision 1) (fixtureOperationId "edit") (SetNextAction [nextAction "next"])))
          case revocation of
            Right _ -> edit @?= Left ObjectiveDenied
            Left ObjectiveConflict -> do
              assertBool "edit won before revocation" (not (isLeft edit))
              _ <- right =<< run env (O.executeCommand ownerHost objective (revision 2) (fixtureOperationId "revoke-new") (RevokeMember collaborator))
              pure ()
            other -> assertFailure (show other)
          run env (O.executeCommand (host collaborator) objective (revision 1) (fixtureOperationId "edit") (SetNextAction [nextAction "next"])) >>= (@?= Left ObjectiveDenied),
      testCase "readers and workers cannot accept completion or grant access" $
        withObjective fixture \env _ objective -> do
          let reader = VerifiedCaller "reader"
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId "grant") (GrantMember reader [Reader]))
          _ <- right =<< run env (O.readObjective (host reader) objective)
          forM_ [AcceptCompletion, GrantMember (VerifiedCaller "intruder") [Coordinator], ReviseInstructions (instructions "inject")] \command ->
            run env (O.executeCommand (host reader) objective (revision 1) (fixtureOperationId "denied") command) >>= (@?= Left ObjectiveDenied),
      testCase "disabled tracking, default-deny agents and fresh action denial fail closed" $
        withDatabase fixture \env -> do
          let agent = RecordedAgent (VerifiedIdentity (either (error . show) id (mkAgentPrincipal "agent_creator")))
              agentHost = host agent
              granted = (agentHost & #settings .~ ((defaultObjectiveSettings & #enabled .~ (True) & #agentCreation .~ (["agent_creator"]))))
          run env (O.createObjective agentHost (fixtureOperationId "create") Nothing request) >>= (@?= Left ObjectiveDenied)
          run env (O.createObjective ((ownerHost & #settings .~ (defaultObjectiveSettings))) (fixtureOperationId "create") Nothing request) >>= (@?= Left ObjectiveDenied)
          run env (O.createObjective ((granted & #actions .~ (denyAllActionAuthorizer))) (fixtureOperationId "create") Nothing request) >>= (@?= Left ObjectiveDenied)
          first <- right =<< run env (O.createObjective granted (fixtureOperationId "create") Nothing request)
          run env (O.readObjective ownerHost first.objectiveId) >>= (@?= Left ObjectiveDenied),
      testCase "graphs, stale epochs, assignment identity reuse and terminal progress fail without changing state" $
        withObjective fixture \env _ objective -> do
          now <- getCurrentTime
          let a = draft now "a"
              b = draft now "b"
          forM_ (zip [1 .. 3 :: Int] [[a & #dependencies .~ [b.assignmentId], b & #dependencies .~ [a.assignmentId]], [a & #dependencies .~ [b.assignmentId]], [a, a]]) \(caseNumber, graph) -> do
            result <- run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId (Text.pack (show caseNumber))) (SetAssignments graph))
            assertBool "bad graph rejected" (isLeft result)
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId "graph") (SetAssignments [a]))
          run env (O.executeInternal ownerHost objective (revision 1) (fixtureOperationId "transfer") (TransferOwnership a.assignmentId (revision 99) a.owner)) >>= (@?= Left ObjectiveConflict)
          run env (O.executeCommand ownerHost objective (revision 1) (fixtureOperationId "delete") (SetAssignments [])) >>= assertLeft
          current <- get env objective
          current.revision @?= revision 1
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 1) (fixtureOperationId "cancel") CancelObjective)
          run env (O.executeCommand ownerHost objective (revision 2) (fixtureOperationId "progress") (RecordProgress a.assignmentId Done [] [])) >>= assertLeft
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 2) (fixtureOperationId "grant-after-cancel") (GrantMember (VerifiedCaller "auditor") [Reader]))
          current' <- get env objective
          current'.status @?= Cancelled,
      testCase "integrated acceptance requires current checks and authorized attestation" $
        withObjective fixture \env _ objective -> do
          now <- getCurrentTime
          let a = draft now "a" & #rootId .~ Nothing & #cutoff .~ Nothing
              send expected key command = run env (O.executeCommand ownerHost objective (revision expected) (fixtureOperationId key) command)
          _ <- right =<< send 0 "graph" (SetAssignments [a])
          _ <- right =<< send 1 "done" (RecordProgress a.assignmentId Done [] [])
          let missing = CompletionProposal (revision 2) (revision 0) (revision 0) [artifact "artifact"] [] []
          _ <- right =<< send 2 "propose-missing" (ProposeCompletion missing)
          send 3 "accept-missing" AcceptCompletion >>= (@?= Left ObjectiveInvalidEvidence)
          _ <- right =<< send 3 "attest" (RecordEvidence a.assignmentId (Attestation (evidenceKey "check") (criterionKey "human") (artifact "artifact") (statement "reviewed integrated journey") False))
          _ <- right =<< send 4 "propose" (ProposeCompletion (CompletionProposal (revision 4) (revision 0) (revision 0) [artifact "artifact"] [evidenceKey "check"] [limitation "known limitation"]))
          _ <- right =<< send 5 "revise" (ReviseInstructions (instructions "new instructions"))
          send 6 "stale-accept" AcceptCompletion >>= (@?= Left ObjectiveConflict)
          _ <- right =<< send 6 "new-attest" (RecordEvidence a.assignmentId (Attestation (evidenceKey "new-check") (criterionKey "human") (artifact "artifact") (statement "reviewed again") False))
          _ <- right =<< send 7 "new-proposal" (ProposeCompletion (CompletionProposal (revision 7) (revision 1) (revision 0) [artifact "artifact"] [evidenceKey "new-check"] []))
          _ <- right =<< send 8 "accept" AcceptCompletion
          current <- get env objective
          current.status @?= Completed
          length current.evidence @?= 2
          fmap (.approvingAuthority) current.acceptance @?= Just owner,
      testCase "sibling checkpoints commit from one base, real result projects and retries survive invalidation" $
        withObjective fixture \env admission objective -> do
          (a, b, firstIntent, secondIntent, firstInput, secondInput) <- checkpointPair env admission objective
          let base = revisionNumber firstIntent.expected.revision
              commit key intent input keyText = run env (O.executeInternal ownerHost objective (revision base) (fixtureOperationId keyText) (IngestCheckpoint key intent [input] []))
          (left, rightResult) <- concurrently (commit a.assignmentId firstIntent firstInput "checkpoint-a") (commit b.assignmentId secondIntent secondInput "checkpoint-b")
          first <- right left
          second <- right rightResult
          assertBool "distinct advancing receipts" (first.revision /= second.revision && all (> revision base) [first.revision, second.revision])
          current <- get env objective
          version <- right (S.versionFor current a.assignmentId)
          version.assignmentRevision @?= advanceRevision firstIntent.expected.assignmentRevision
          version.owner @?= a.owner
          Just version.rootId @?= a.rootId
          run env (O.readObjectiveVersion ownerHost (S.referenceFor objective a.assignmentId)) >>= (@?= Right version)
          length current.evidence @?= 2
          _ <- right =<< run env (O.executeCommand ownerHost objective current.revision (fixtureOperationId "instructions") (ReviseInstructions (instructions "changed")))
          commit a.assignmentId firstIntent firstInput "checkpoint-a" >>= (@?= Right first)
          run env (O.executeInternal ownerHost objective (revision base) (fixtureOperationId "stale-new") (IngestCheckpoint a.assignmentId firstIntent [firstInput] [])) >>= (@?= Left ObjectiveConflict),
      testCase "instruction and block/unblock cycles never revive prepared checkpoints or advance cursors" $
        withObjective fixture \env admission objective -> do
          (a, _, intent, _, input, _) <- checkpointPair env admission objective
          let base = revisionNumber intent.expected.revision
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision base) (fixtureOperationId "instructions") (ReviseInstructions (instructions "changed")))
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision (base + 1)) (fixtureOperationId "restore") (ReviseInstructions (instructions "instructions")))
          run env (O.executeInternal ownerHost objective (revision base) (fixtureOperationId "stale") (IngestCheckpoint a.assignmentId intent [input] [])) >>= (@?= Left ObjectiveConflict)
          count env "shikigami.objective_cursors" >>= (@?= 0)
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision (base + 2)) (fixtureOperationId "block") (SetBlocked True))
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision (base + 3)) (fixtureOperationId "unblock") (SetBlocked False))
          run env (O.executeInternal ownerHost objective (revision base) (fixtureOperationId "stale-after-unblock") (IngestCheckpoint a.assignmentId intent [input] [])) >>= (@?= Left ObjectiveConflict)
          count env "shikigami.objective_cursors" >>= (@?= 0),
      testCase "workers update only their own assignments and cannot attest or grant" $
        withObjective fixture \env _ objective -> do
          now <- getCurrentTime
          principal <- right (mkAgentPrincipal "agent_worker")
          let identity = VerifiedIdentity principal
              workerHost = host (RecordedAgent identity)
              own = draft now "own" & #owner .~ identity
              other = draft now "other"
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId "graph") (SetAssignments [own, other]))
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 1) (fixtureOperationId "grant") (GrantMember (RecordedAgent identity) [Worker]))
          _ <- right =<< run env (O.executeCommand workerHost objective (revision 2) (fixtureOperationId "own") (RecordProgress own.assignmentId Working [] []))
          forM_ [RecordProgress other.assignmentId Done [] [], RecordEvidence own.assignmentId (Attestation (evidenceKey "forged") (criterionKey "human") (artifact "artifact") (statement "trust me") False), GrantMember (VerifiedCaller "friend") [Coordinator]] \command ->
            run env (O.executeCommand workerHost objective (revision 3) (fixtureOperationId "denied") command) >>= (@?= Left ObjectiveDenied),
      testCase "automatic completion requires verifier-backed criterion and journey evidence" $
        withObjective fixture \env _ objective -> do
          now <- getCurrentTime
          let assignment = draft now "a"
              reference = RetainedResult "verifier-run" "verifier-execution" "sha256:retained-result" (artifact "artifact")
              verifiedHost = (ownerHost & #verifyResult .~ (\source -> pure (if source == reference then Right (EvidenceVerification CheckPassed (Just (criterionKey "auto")) True) else Left ObjectiveInvalidEvidence)))
              send expected key command = run env (O.executeCommand verifiedHost objective (revision expected) (fixtureOperationId key) command)
          _ <- right =<< send 0 "criteria" (ReviseCriteria [Criterion (criterionKey "auto") (description "verified journey") Automatic True])
          _ <- right =<< send 1 "graph" (SetAssignments [assignment & #state .~ Done])
          -- A fabricated result cannot acquire a verifier disposition.
          send 2 "fake" (RecordEvidence assignment.assignmentId (ResultEvidence (evidenceKey "fake") (criterionKey "auto") (RetainedResult "fake-run" "fake" "fake" (artifact "artifact")) True)) >>= (@?= Left ObjectiveInvalidEvidence)
          evidenceReceipt <- right =<< send 2 "verified" (RecordEvidence assignment.assignmentId (ResultEvidence (evidenceKey "verified") (criterionKey "auto") reference True))
          -- Recovery does not contact an unavailable evidence owner again.
          run env (O.executeCommand ownerHost objective (revision 2) (fixtureOperationId "verified") (RecordEvidence assignment.assignmentId (ResultEvidence (evidenceKey "verified") (criterionKey "auto") reference True))) >>= (@?= Right evidenceReceipt)
          _ <- right =<< send 3 "propose" (ProposeCompletion (CompletionProposal (revision 3) (revision 0) (revision 1) [artifact "artifact"] [evidenceKey "verified"] []))
          _ <- right =<< send 4 "accept" AcceptCompletion
          current <- get env objective
          current.status @?= Completed,
      testCase "child success is observed evidence and cannot substitute for a verifier" $
        withObjective fixture \env admission objective -> do
          (a, b, intent, _, input, _) <- checkpointPair env admission objective
          let base = revisionNumber intent.expected.revision
              send expected key command = run env (O.executeCommand ownerHost objective (revision expected) (fixtureOperationId key) command)
          _ <- right =<< run env (O.executeInternal ownerHost objective (revision base) (fixtureOperationId "checkpoint") (IngestCheckpoint a.assignmentId intent [input] []))
          _ <- right =<< send (base + 1) "done-a" (RecordProgress a.assignmentId Done [] [])
          _ <- right =<< send (base + 2) "done-b" (RecordProgress b.assignmentId Done [] [])
          _ <- right =<< send (base + 3) "propose" (ProposeCompletion (CompletionProposal (revision (base + 3)) (revision 0) (revision 0) [artifact "artifact"] [input.key] []))
          send (base + 4) "accept" AcceptCompletion >>= (@?= Left ObjectiveInvalidEvidence)
          current <- get env objective
          map (.verification.disposition) current.evidence @?= [ResultObserved],
      testCase "unresolved effects block otherwise complete acceptance and source forgery advances no cursor" $
        withObjective fixture \env admission objective -> do
          (a, b, intent, _, input, _) <- checkpointPair env admission objective
          let base = revisionNumber intent.expected.revision
              send expected key command = run env (O.executeCommand ownerHost objective (revision expected) (fixtureOperationId key) command)
              unresolved = UnresolvedOperation a.assignmentId origin (fixtureOperationId "unsettled-effect")
          run env (O.executeInternal ownerHost objective (revision base) (fixtureOperationId "forged") (IngestCheckpoint a.assignmentId (intent & #events .~ []) [input] [])) >>= (@?= Left ObjectiveConflict)
          count env "shikigami.objective_cursors" >>= (@?= 0)
          _ <- right =<< run env (O.executeInternal ownerHost objective (revision base) (fixtureOperationId "checkpoint") (IngestCheckpoint a.assignmentId intent [input] [unresolved]))
          _ <- right =<< send (base + 1) "done-a" (RecordProgress a.assignmentId Done [] [])
          _ <- right =<< send (base + 2) "done-b" (RecordProgress b.assignmentId Done [] [])
          _ <- right =<< send (base + 3) "attest" (RecordEvidence a.assignmentId (Attestation (evidenceKey "human-check") (criterionKey "human") (artifact "artifact") (statement "reviewed") False))
          _ <- right =<< send (base + 4) "propose" (ProposeCompletion (CompletionProposal (revision (base + 4)) (revision 0) (revision 0) [artifact "artifact"] [evidenceKey "human-check"] []))
          send (base + 5) "accept" AcceptCompletion >>= (@?= Left ObjectiveUnresolved),
      testCase "terminal objectives reconcile authentic accepted results while refusing fresh public progress" $
        withObjective fixture \env admission objective -> do
          now <- getCurrentTime
          let key = objectiveAssignment "late-result"
              admitted = admission & #scope . #workerKey .~ "late-result" & #objective .~ S.referenceFor objective key
          (_, session) <- right =<< run env (Sessions.openSession admitted)
          let assignment = draft now "late-result" & #sessionId .~ Just session.sessionId & #owner .~ session.owner
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId "graph") (SetAssignments [assignment]))
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 1) (fixtureOperationId "parent") (GrantMember (RecordedAgent admission.context.identity) [Coordinator]))
          access <- right =<< run env (Sessions.authorizeSession session.sessionId admission.context.identity (pure (Right ())))
          before <- get env objective
          initialVersion <- right (S.versionFor before key)
          let instruction = WS.Instruction 1 WS.FollowUp (fixtureInstruction "accepted before cancellation") initialVersion.revision initialVersion.assignmentRevision initialVersion.criteriaRevision Nothing
          (_, message) <- right =<< run env (Sessions.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (fixtureOperationId "send") instruction)
          _ <- right =<< run env (Sessions.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (fixtureOperationId "start") message.assignmentId)
          (_, result) <- right =<< run env (Sessions.recordResult access (fixtureRevision 2) (fixtureRevision 0) (fixtureOperationId "result") (WS.AssignmentResult 1 message.assignmentId WS.AssignmentSucceeded Nothing (Aeson.object []) ["artifact"]))
          _ <- right =<< run env (O.executeCommand ownerHost objective (revision 2) (fixtureOperationId "cancel") CancelObjective)
          cancelled <- get env objective
          version <- right (S.versionFor cancelled key)
          version.active @?= False
          (_, intent) <- right =<< run env (Sessions.prepareCheckpoint access (fixtureRevision 3) (fixtureRevision 0) (fixtureOperationId "prepare") version (fixtureRevision 0) (fixtureRevision 3))
          let evidence = ResultEvidence (evidenceKey "late") (criterionKey "human") (WorkerResult result (artifact "artifact")) False
          _ <- right =<< run env (O.executeInternal ownerHost objective (revision 3) (fixtureOperationId "reconcile") (IngestCheckpoint key intent [evidence] []))
          run env (O.executeCommand ownerHost objective (revision 4) (fixtureOperationId "fresh-progress") (RecordProgress key Working [] [])) >>= assertLeft
          current <- get env objective
          current.status @?= Cancelled
          length current.evidence @?= 1,
      testCase "process exits after commit without acknowledgement; reconnect recovers exactly one receipt" $
        withShikigamiFreshDatabase fixture \connection -> do
          env <- environment connection
          _ <- right =<< run env Catalog.registerProjectionCatalog
          executable <- getExecutablePath
          (Just input, Nothing, Nothing, child) <- createProcess (proc executable ["--objective-commit-and-exit", "+RTS", "-N2", "-RTS"]) {std_in = CreatePipe, std_out = NoStream, std_err = Inherit}
          Lazy.hPutStrLn input (Aeson.encode connection)
          hClose input
          waitForProcess child >>= (@?= ExitFailure 91)
          fresh <- environment connection
          receipt <- right =<< run fresh (O.createObjective ownerHost (fixtureOperationId "lost-create") (Just origin) request)
          current <- right =<< run fresh (O.readObjective ownerHost receipt.objectiveId)
          current.revision @?= revision 1
          replay <- right =<< run fresh (O.executeCommand ownerHost receipt.objectiveId (revision 0) (fixtureOperationId "lost-edit") (ReviseInstructions (instructions "committed-before-exit")))
          replay.revision @?= revision 1
          count fresh "shikigami.objectives" >>= (@?= 1)
          count fresh "shikigami.objective_origins" >>= (@?= 1)
          count fresh "shikigami.objective_receipts" >>= (@?= 2)
    ]

owner :: AccessPrincipal
owner = VerifiedCaller "owner"

ownerHost :: O.ObjectiveHost
ownerHost = host owner

host :: AccessPrincipal -> O.ObjectiveHost
host actor = O.ObjectiveHost ((defaultObjectiveSettings & #enabled .~ (True))) (pure (Right actor)) allowAllActionAuthorizerForTests (\_ _ -> pure (Right ())) (\_ _ -> pure (Right ())) (\_ -> pure (Left ObjectiveInvalidEvidence))

request :: CreateRequest
request = CreateRequest (title "deliver") (goal "integrated goal") (instructions "instructions") [Criterion (criterionKey "human") (description "review integration") HumanVerifiable False] []

origin :: CreationOrigin
origin = ExecutionOrigin "recorded-run" "recorded-execution" (fixtureOperationId "accepted-operation")

draft :: UTCTime -> Text -> AssignmentDraft
draft now key = AssignmentDraft (objectiveAssignment key) (instructions "work") [] (compatibilityIdentity (fixtureAgentName "worker")) Pending Nothing (Just (fixtureRootId "session-root")) (Just (addUTCTime 3600 now))

withDatabase :: DatabaseFixture -> (AppEnv -> IO a) -> IO a
withDatabase fixture callback = withShikigamiFreshDatabase fixture \connection -> do
  env <- environment connection
  _ <- right =<< run env Catalog.registerProjectionCatalog
  callback env

environment :: Text -> IO AppEnv
environment connection = do
  tracer <- noopTracer
  pure (AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing)

withObjective :: DatabaseFixture -> (AppEnv -> WS.SessionAdmission -> ObjectiveId -> IO a) -> IO a
withObjective fixture callback = SessionsFixture.withFixture fixture \env admission _ -> do
  receipt <- right =<< run env (O.createObjective ownerHost (fixtureOperationId "create") (Just origin) request)
  callback env admission receipt.objectiveId

get :: AppEnv -> ObjectiveId -> IO Objective
get env objective = right =<< run env (O.readObjective ownerHost objective)

checkpointPair :: AppEnv -> WS.SessionAdmission -> ObjectiveId -> IO (AssignmentDraft, AssignmentDraft, CP.CheckpointIntent, CP.CheckpointIntent, EvidenceInput, EvidenceInput)
checkpointPair env admission objective = do
  now <- getCurrentTime
  let new key = admission & #scope . #workerKey .~ key & #objective .~ S.referenceFor objective (objectiveAssignment key)
  (_, sa) <- right =<< run env (Sessions.openSession (new "a"))
  (_, sb) <- right =<< run env (Sessions.openSession (new "b"))
  let a = draft now "a" & #sessionId .~ Just sa.sessionId & #owner .~ sa.owner
      b = draft now "b" & #sessionId .~ Just sb.sessionId & #owner .~ sb.owner
  _ <- right =<< run env (O.executeCommand ownerHost objective (revision 0) (fixtureOperationId "graph") (SetAssignments [a, b]))
  _ <- right =<< run env (O.executeCommand ownerHost objective (revision 1) (fixtureOperationId "grant-parent") (GrantMember (RecordedAgent admission.context.identity) [Coordinator]))
  current <- get env objective
  (first, inputA) <- checkpoint env admission.context.identity objective current a "evidence-a"
  (second, inputB) <- checkpoint env admission.context.identity objective current b "evidence-b"
  pure (a, b, first, second, inputA, inputB)

checkpoint :: AppEnv -> AgentIdentity -> ObjectiveId -> Objective -> AssignmentDraft -> Text -> IO (CP.CheckpointIntent, EvidenceInput)
checkpoint env actor _ current assignment key = do
  session <- maybe (assertFailure "missing fixture session" >> fail "unreachable") pure assignment.sessionId
  access <- right =<< run env (Sessions.authorizeSession session actor (pure (Right ())))
  version <- right (S.versionFor current assignment.assignmentId)
  let instruction = WS.Instruction 1 WS.FollowUp (fixtureInstruction "perform") version.revision version.assignmentRevision version.criteriaRevision Nothing
  (_, message) <- right =<< run env (Sessions.acceptMessage access (fixtureRevision 0) (fixtureRevision 0) (fixtureOperationId "send") instruction)
  _ <- right =<< run env (Sessions.startAssignment access (fixtureRevision 1) (fixtureRevision 0) (fixtureOperationId "start") message.assignmentId)
  let result = WS.AssignmentResult 1 message.assignmentId WS.AssignmentSucceeded Nothing (Aeson.object []) ["artifact"]
  (_, receipt) <- right =<< run env (Sessions.recordResult access (fixtureRevision 2) (fixtureRevision 0) (fixtureOperationId "result") result)
  (_, intent) <- right =<< run env (Sessions.prepareCheckpoint access (fixtureRevision 3) (fixtureRevision 0) (fixtureOperationId "prepare") version (fixtureRevision 0) (fixtureRevision 3))
  pure (intent, ResultEvidence (evidenceKey key) (criterionKey "human") (WorkerResult receipt (artifact "artifact")) False)

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

assertLeft :: (Show a) => Either ObjectiveError a -> IO ()
assertLeft = either (const (pure ())) (assertFailure . show)

count :: AppEnv -> Text -> IO Int64
count env table = run env (runTransaction (Tx.statement () (preparable ("SELECT count(*) FROM " <> table) E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))))

objectiveEventCount :: AppEnv -> IO Int
objectiveEventCount env = run env (length <$> StoreRead.readCategory (StoreTypes.CategoryName "objectiveLifecycle") (StoreTypes.GlobalPosition 0) 100)

sql :: AppEnv -> Text -> IO ()
sql env statement = run env (runTransaction (Tx.sql (Text.encodeUtf8 statement)))

replaceJson :: AppEnv -> Text -> Aeson.Value -> IO ()
replaceJson env query value = run env (runTransaction (Tx.statement value (preparable query (E.param (E.nonNullable E.jsonb)) D.noResult)))

replaceOwnedRow :: AppEnv -> Text -> Text -> Text -> Aeson.Value -> IO ()
replaceOwnedRow env query first second value = run env (runTransaction (Tx.statement (first, second, value) (preparable query (contrazip3 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.jsonb))) D.noResult)))

readOwnedJson :: AppEnv -> Text -> Text -> Text -> IO Aeson.Value
readOwnedJson env query first second = run env (runTransaction (Tx.statement (first, second) (preparable query (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text))) (D.singleRow (D.column (D.nonNullable D.jsonb))))))

-- No application acknowledgement escapes this process. The parent reopens the
-- database after exit and recovers both immutable receipts by their original keys.
crashWriter :: IO ()
crashWriter = do
  connection <- right . Aeson.eitherDecode =<< Lazy.getContents
  env <- environment connection
  created <- right =<< run env (O.createObjective ownerHost (fixtureOperationId "lost-create") (Just origin) request)
  _ <- right =<< run env (O.executeCommand ownerHost created.objectiveId (revision 0) (fixtureOperationId "lost-edit") (ReviseInstructions (instructions "committed-before-exit")))
  exitWith (ExitFailure 91)

criterionKey :: Text -> CriterionKey
criterionKey = either (error . show) id . parseCriterionKey

evidenceKey :: Text -> EvidenceKey
evidenceKey = either (error . show) id . parseEvidenceKey

revision :: Integer -> StateRevision scope
revision = either (error . show) id . parseRevision

objectiveAssignment :: Text -> ObjectiveAssignmentId
objectiveAssignment = either (error . show) id . parseObjectiveAssignmentId

artifact :: Text -> ArtifactRef
artifact = either (error . show) id . parseArtifactRef

title :: Text -> Title
title = either (error . show) id . parseTitle

goal :: Text -> Goal
goal = either (error . show) id . parseGoal

instructions :: Text -> Instructions
instructions = either (error . show) id . parseInstructions

description :: Text -> CriterionDescription
description = either (error . show) id . parseCriterionDescription

statement :: Text -> AttestationStatement
statement = either (error . show) id . parseAttestationStatement

nextAction :: Text -> NextAction
nextAction = either (error . show) id . parseNextAction

limitation :: Text -> CompletionLimitation
limitation = either (error . show) id . parseCompletionLimitation

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureInstruction :: Text -> InstructionText
fixtureInstruction value = either (error . show) id (parseInstructionText value)

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

module Shikigami.ObjectiveStoreSpec (tests, crashWriter) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (SomeException, try)
import Data.Aeson qualified as Aeson
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
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests, denyAllActionAuthorizer)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Principal (AgentIdentity (..), compatibilityIdentity, mkAgentPrincipal)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.Execution.Identity (ExecutionRootId (..), OperationId (..))
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Objective.Capability qualified as O
import Shikigami.Objective.Command
import Shikigami.Objective.Store qualified as S
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.WorkerSession.Checkpoint qualified as CP
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
    [ testCase "public writers at one revision produce one transition and retained conflict" $
        withObjective fixture \env _ objective -> do
          let write key text = run env (O.executeCommand ownerHost objective 0 (OperationId key) (ReviseInstructions text))
          (left, rightResult) <- concurrently (write "left" "left") (write "right" "right")
          length (rights [left, rightResult]) @?= 1
          length (filter (== Left ObjectiveConflict) [left, rightResult]) @?= 1
          current <- get env objective
          current.revision @?= 1
          let (key, text) = if isLeft left then ("left", "left") else ("right", "right")
          -- Even a newly edited envelope cannot convert the old rejection.
          run env (O.executeCommand ownerHost objective 1 (OperationId key) (ReviseInstructions text)) >>= (@?= Left ObjectiveConflict)
          count env "shikigami.objective_receipts" >>= (@?= 3),
      testCase "accepted retries recover original receipt after progress and reject changed payload" $
        withObjective fixture \env _ objective -> do
          first <- right =<< run env (O.executeCommand ownerHost objective 0 (OperationId "edit") (ReviseInstructions "new"))
          _ <- right =<< run env (O.executeCommand ownerHost objective 1 (OperationId "next") (SetNextAction ["continue"]))
          run env (O.executeCommand ownerHost objective 0 (OperationId "edit") (ReviseInstructions "new")) >>= (@?= Right first)
          run env (O.executeCommand ownerHost objective 0 (OperationId "edit") (ReviseInstructions "different")) >>= (@?= Left ObjectiveConflict)
          run env (O.readCommandReceipt ownerHost objective (OperationId "edit")) >>= (@?= Right (Just (Right first))),
      testCase "creation is creator-scoped, concurrent and atomically retains origin and membership" $
        withDatabase fixture \env -> do
          let create = run env (O.createObjective ownerHost (OperationId "create") (Just origin) request)
          (left, rightResult) <- concurrently create create
          first <- right left
          rightResult @?= Right first
          run env (O.createObjective ownerHost (OperationId "create") (Just origin) request) >>= (@?= Right first)
          count env "shikigami.objectives" >>= (@?= 1)
          count env "shikigami.objective_origins" >>= (@?= 1)
          current <- get env first.objectiveId
          current.members @?= [Member owner [Owner, Coordinator, Completer]]
          other <- right =<< run env (O.createObjective (host (VerifiedCaller "other")) (OperationId "create") Nothing request)
          assertBool "creator scopes differ" (first.objectiveId /= other.objectiveId)
          run env (O.readObjective (host (VerifiedCaller "other")) first.objectiveId) >>= (@?= Left ObjectiveDenied),
      testCase "creation rollback leaves no objective, origin, receipt or lifecycle event" $
        withDatabase fixture \env -> do
          sql env "CREATE FUNCTION shikigami.reject_objective_origin() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''injected origin failure''; END'"
          sql env "CREATE TRIGGER reject_origin BEFORE INSERT ON shikigami.objective_origins FOR EACH ROW EXECUTE FUNCTION shikigami.reject_objective_origin()"
          _ <- try @SomeException (run env (O.createObjective ownerHost (OperationId "create") (Just origin) request))
          mapM_ (\table -> count env table >>= (@?= 0)) ["shikigami.objectives", "shikigami.objective_origins", "shikigami.objective_receipts", "shikigami.objective_payloads"]
          sql env "DROP TRIGGER reject_origin ON shikigami.objective_origins"
          _ <- right =<< run env (O.createObjective ownerHost (OperationId "create") (Just origin) request)
          count env "shikigami.objectives" >>= (@?= 1),
      testCase "receipt failure rolls back evidence, revision and lifecycle append" $
        withObjective fixture \env _ objective -> do
          now <- getCurrentTime
          _ <- right =<< run env (O.executeCommand ownerHost objective 0 (OperationId "graph") (SetAssignments [draft now "a"]))
          let input = Attestation "check" "human" "artifact" "reviewed integration" False
          sql env "CREATE FUNCTION shikigami.reject_objective_receipt() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''injected receipt failure''; END'"
          sql env "CREATE TRIGGER reject_receipt BEFORE INSERT ON shikigami.objective_receipts FOR EACH ROW EXECUTE FUNCTION shikigami.reject_objective_receipt()"
          _ <- try @SomeException (run env (O.executeCommand ownerHost objective 1 (OperationId "evidence") (RecordEvidence (ObjectiveAssignmentId "a") input)))
          current <- get env objective
          current.revision @?= 1
          current.evidence @?= []
          count env "shikigami.objective_payloads" >>= (@?= 2)
          sql env "DROP TRIGGER reject_receipt ON shikigami.objective_receipts"
          _ <- right =<< run env (O.executeCommand ownerHost objective 1 (OperationId "evidence") (RecordEvidence (ObjectiveAssignmentId "a") input))
          current' <- get env objective
          length current'.evidence @?= 1,
      testCase "revoked membership denies both stale writes and retained receipt disclosure" $
        withObjective fixture \env _ objective -> do
          let collaborator = VerifiedCaller "coordinator"
              collaboratorHost = host collaborator
          _ <- right =<< run env (O.executeCommand ownerHost objective 0 (OperationId "grant") (GrantMember collaborator [Coordinator]))
          _ <- right =<< run env (O.executeCommand collaboratorHost objective 1 (OperationId "edit") (SetNextAction ["next"]))
          _ <- right =<< run env (O.executeCommand ownerHost objective 2 (OperationId "revoke") (RevokeMember collaborator))
          run env (O.executeCommand collaboratorHost objective 1 (OperationId "edit") (SetNextAction ["next"])) >>= (@?= Left ObjectiveDenied)
          run env (O.readCommandReceipt collaboratorHost objective (OperationId "edit")) >>= (@?= Left ObjectiveDenied)
          run env (O.executeCommand collaboratorHost objective 3 (OperationId "new") (SetNextAction [])) >>= (@?= Left ObjectiveDenied),
      testCase "revocation race cannot commit a later unauthorized edit" $
        withObjective fixture \env _ objective -> do
          let collaborator = VerifiedCaller "coordinator"
          _ <- right =<< run env (O.executeCommand ownerHost objective 0 (OperationId "grant") (GrantMember collaborator [Coordinator]))
          (revocation, edit) <-
            concurrently
              (run env (O.executeCommand ownerHost objective 1 (OperationId "revoke") (RevokeMember collaborator)))
              (run env (O.executeCommand (host collaborator) objective 1 (OperationId "edit") (SetNextAction ["next"])))
          case revocation of
            Right _ -> edit @?= Left ObjectiveDenied
            Left ObjectiveConflict -> do
              assertBool "edit won before revocation" (not (isLeft edit))
              _ <- right =<< run env (O.executeCommand ownerHost objective 2 (OperationId "revoke-new") (RevokeMember collaborator))
              pure ()
            other -> assertFailure (show other)
          run env (O.executeCommand (host collaborator) objective 1 (OperationId "edit") (SetNextAction ["next"])) >>= (@?= Left ObjectiveDenied),
      testCase "readers and workers cannot accept completion or grant access" $
        withObjective fixture \env _ objective -> do
          let reader = VerifiedCaller "reader"
          _ <- right =<< run env (O.executeCommand ownerHost objective 0 (OperationId "grant") (GrantMember reader [Reader]))
          _ <- right =<< run env (O.readObjective (host reader) objective)
          forM_ [AcceptCompletion, GrantMember (VerifiedCaller "intruder") [Coordinator], ReviseInstructions "inject"] \command ->
            run env (O.executeCommand (host reader) objective 1 (OperationId "denied") command) >>= (@?= Left ObjectiveDenied),
      testCase "disabled tracking, default-deny agents and fresh action denial fail closed" $
        withDatabase fixture \env -> do
          let agent = RecordedAgent (VerifiedIdentity (either (error . show) id (mkAgentPrincipal "agent_creator")))
              agentHost = host agent
              granted = agentHost {O.settings = defaultObjectiveSettings {enabled = True, agentCreation = ["agent_creator"]}}
          run env (O.createObjective agentHost (OperationId "create") Nothing request) >>= (@?= Left ObjectiveDenied)
          run env (O.createObjective (ownerHost {O.settings = defaultObjectiveSettings}) (OperationId "create") Nothing request) >>= (@?= Left ObjectiveDenied)
          run env (O.createObjective (granted {O.actions = denyAllActionAuthorizer}) (OperationId "create") Nothing request) >>= (@?= Left ObjectiveDenied)
          first <- right =<< run env (O.createObjective granted (OperationId "create") Nothing request)
          run env (O.readObjective ownerHost first.objectiveId) >>= (@?= Left ObjectiveDenied),
      testCase "graphs, stale epochs, assignment identity reuse and terminal progress fail without changing state" $
        withObjective fixture \env _ objective -> do
          now <- getCurrentTime
          let a = draft now "a"
              b = draft now "b"
          forM_ (zip [1 .. 3 :: Int] [[a & #dependencies .~ [b.assignmentId], b & #dependencies .~ [a.assignmentId]], [a & #dependencies .~ [b.assignmentId]], [a, a]]) \(caseNumber, graph) -> do
            result <- run env (O.executeCommand ownerHost objective 0 (OperationId (Text.pack (show caseNumber))) (SetAssignments graph))
            assertBool "bad graph rejected" (isLeft result)
          _ <- right =<< run env (O.executeCommand ownerHost objective 0 (OperationId "graph") (SetAssignments [a]))
          run env (O.executeInternal ownerHost objective 1 (OperationId "transfer") (TransferOwnership a.assignmentId 99 a.owner)) >>= (@?= Left ObjectiveConflict)
          run env (O.executeCommand ownerHost objective 1 (OperationId "delete") (SetAssignments [])) >>= assertLeft
          current <- get env objective
          current.revision @?= 1
          _ <- right =<< run env (O.executeCommand ownerHost objective 1 (OperationId "cancel") CancelObjective)
          run env (O.executeCommand ownerHost objective 2 (OperationId "progress") (RecordProgress a.assignmentId Done [] [])) >>= assertLeft
          _ <- right =<< run env (O.executeCommand ownerHost objective 2 (OperationId "grant-after-cancel") (GrantMember (VerifiedCaller "auditor") [Reader]))
          current' <- get env objective
          current'.status @?= Cancelled,
      testCase "integrated acceptance requires current checks and authorized attestation" $
        withObjective fixture \env _ objective -> do
          now <- getCurrentTime
          let a = draft now "a" & #rootId .~ Nothing & #cutoff .~ Nothing
              send revision key command = run env (O.executeCommand ownerHost objective revision (OperationId key) command)
          _ <- right =<< send 0 "graph" (SetAssignments [a])
          _ <- right =<< send 1 "done" (RecordProgress a.assignmentId Done [] [])
          let missing = CompletionProposal 2 0 0 ["artifact"] [] []
          _ <- right =<< send 2 "propose-missing" (ProposeCompletion missing)
          send 3 "accept-missing" AcceptCompletion >>= (@?= Left ObjectiveInvalidEvidence)
          _ <- right =<< send 3 "attest" (RecordEvidence a.assignmentId (Attestation "check" "human" "artifact" "reviewed integrated journey" False))
          _ <- right =<< send 4 "propose" (ProposeCompletion (CompletionProposal 4 0 0 ["artifact"] ["check"] ["known limitation"]))
          _ <- right =<< send 5 "revise" (ReviseInstructions "new instructions")
          send 6 "stale-accept" AcceptCompletion >>= (@?= Left ObjectiveConflict)
          _ <- right =<< send 6 "new-attest" (RecordEvidence a.assignmentId (Attestation "new-check" "human" "artifact" "reviewed again" False))
          _ <- right =<< send 7 "new-proposal" (ProposeCompletion (CompletionProposal 7 1 0 ["artifact"] ["new-check"] []))
          _ <- right =<< send 8 "accept" AcceptCompletion
          current <- get env objective
          current.status @?= Completed
          length current.evidence @?= 2
          fmap (.approvingAuthority) current.acceptance @?= Just owner,
      testCase "sibling checkpoints commit from one base, real result projects and retries survive invalidation" $
        withObjective fixture \env admission objective -> do
          (a, b, firstIntent, secondIntent, firstInput, secondInput) <- checkpointPair env admission objective
          let base = firstIntent.expected.revision
              commit key intent input keyText = run env (O.executeInternal ownerHost objective base (OperationId keyText) (IngestCheckpoint key intent [input] []))
          (left, rightResult) <- concurrently (commit a.assignmentId firstIntent firstInput "checkpoint-a") (commit b.assignmentId secondIntent secondInput "checkpoint-b")
          first <- right left
          second <- right rightResult
          assertBool "distinct advancing receipts" (first.revision /= second.revision && all (> base) [first.revision, second.revision])
          current <- get env objective
          version <- right (S.versionFor current a.assignmentId)
          version.assignmentRevision @?= firstIntent.expected.assignmentRevision + 1
          version.owner @?= a.owner
          Just version.rootId @?= a.rootId
          run env (O.readObjectiveVersion ownerHost (S.referenceFor objective a.assignmentId)) >>= (@?= Right version)
          length current.evidence @?= 2
          _ <- right =<< run env (O.executeCommand ownerHost objective current.revision (OperationId "instructions") (ReviseInstructions "changed"))
          commit a.assignmentId firstIntent firstInput "checkpoint-a" >>= (@?= Right first)
          run env (O.executeInternal ownerHost objective base (OperationId "stale-new") (IngestCheckpoint a.assignmentId firstIntent [firstInput] [])) >>= (@?= Left ObjectiveConflict),
      testCase "instruction and block/unblock cycles never revive prepared checkpoints or advance cursors" $
        withObjective fixture \env admission objective -> do
          (a, _, intent, _, input, _) <- checkpointPair env admission objective
          let base = intent.expected.revision
          _ <- right =<< run env (O.executeCommand ownerHost objective base (OperationId "instructions") (ReviseInstructions "changed"))
          _ <- right =<< run env (O.executeCommand ownerHost objective (base + 1) (OperationId "restore") (ReviseInstructions "instructions"))
          run env (O.executeInternal ownerHost objective base (OperationId "stale") (IngestCheckpoint a.assignmentId intent [input] [])) >>= (@?= Left ObjectiveConflict)
          count env "shikigami.objective_cursors" >>= (@?= 0)
          _ <- right =<< run env (O.executeCommand ownerHost objective (base + 2) (OperationId "block") (SetBlocked True))
          _ <- right =<< run env (O.executeCommand ownerHost objective (base + 3) (OperationId "unblock") (SetBlocked False))
          run env (O.executeInternal ownerHost objective base (OperationId "stale-after-unblock") (IngestCheckpoint a.assignmentId intent [input] [])) >>= (@?= Left ObjectiveConflict)
          count env "shikigami.objective_cursors" >>= (@?= 0),
      testCase "workers update only their own assignments and cannot attest or grant" $
        withObjective fixture \env _ objective -> do
          now <- getCurrentTime
          principal <- right (mkAgentPrincipal "agent_worker")
          let identity = VerifiedIdentity principal
              workerHost = host (RecordedAgent identity)
              own = draft now "own" & #owner .~ identity
              other = draft now "other"
          _ <- right =<< run env (O.executeCommand ownerHost objective 0 (OperationId "graph") (SetAssignments [own, other]))
          _ <- right =<< run env (O.executeCommand ownerHost objective 1 (OperationId "grant") (GrantMember (RecordedAgent identity) [Worker]))
          _ <- right =<< run env (O.executeCommand workerHost objective 2 (OperationId "own") (RecordProgress own.assignmentId Working [] []))
          forM_ [RecordProgress other.assignmentId Done [] [], RecordEvidence own.assignmentId (Attestation "forged" "human" "artifact" "trust me" False), GrantMember (VerifiedCaller "friend") [Coordinator]] \command ->
            run env (O.executeCommand workerHost objective 3 (OperationId "denied") command) >>= (@?= Left ObjectiveDenied),
      testCase "automatic completion requires verifier-backed criterion and journey evidence" $
        withObjective fixture \env _ objective -> do
          now <- getCurrentTime
          let assignment = draft now "a"
              reference = RetainedResult "verifier-run" "verifier-execution" "sha256:retained-result" "artifact"
              verifiedHost = ownerHost {O.verifyResult = \source -> pure (if source == reference then Right (EvidenceVerification CheckPassed (Just "auto") True) else Left ObjectiveInvalidEvidence)}
              send revision key command = run env (O.executeCommand verifiedHost objective revision (OperationId key) command)
          _ <- right =<< send 0 "criteria" (ReviseCriteria [Criterion "auto" "verified journey" Automatic True])
          _ <- right =<< send 1 "graph" (SetAssignments [assignment & #state .~ Done])
          -- A fabricated result cannot acquire a verifier disposition.
          send 2 "fake" (RecordEvidence assignment.assignmentId (ResultEvidence "fake" "auto" (RetainedResult "fake-run" "fake" "fake" "artifact") True)) >>= (@?= Left ObjectiveInvalidEvidence)
          evidenceReceipt <- right =<< send 2 "verified" (RecordEvidence assignment.assignmentId (ResultEvidence "verified" "auto" reference True))
          -- Recovery does not contact an unavailable evidence owner again.
          run env (O.executeCommand ownerHost objective 2 (OperationId "verified") (RecordEvidence assignment.assignmentId (ResultEvidence "verified" "auto" reference True))) >>= (@?= Right evidenceReceipt)
          _ <- right =<< send 3 "propose" (ProposeCompletion (CompletionProposal 3 0 1 ["artifact"] ["verified"] []))
          _ <- right =<< send 4 "accept" AcceptCompletion
          current <- get env objective
          current.status @?= Completed,
      testCase "child success is observed evidence and cannot substitute for a verifier" $
        withObjective fixture \env admission objective -> do
          (a, b, intent, _, input, _) <- checkpointPair env admission objective
          let base = intent.expected.revision
              send revision key command = run env (O.executeCommand ownerHost objective revision (OperationId key) command)
          _ <- right =<< run env (O.executeInternal ownerHost objective base (OperationId "checkpoint") (IngestCheckpoint a.assignmentId intent [input] []))
          _ <- right =<< send (base + 1) "done-a" (RecordProgress a.assignmentId Done [] [])
          _ <- right =<< send (base + 2) "done-b" (RecordProgress b.assignmentId Done [] [])
          _ <- right =<< send (base + 3) "propose" (ProposeCompletion (CompletionProposal (base + 3) 0 0 ["artifact"] [input.key] []))
          send (base + 4) "accept" AcceptCompletion >>= (@?= Left ObjectiveInvalidEvidence)
          current <- get env objective
          map (.verification.disposition) current.evidence @?= [ResultObserved],
      testCase "unresolved effects block otherwise complete acceptance and source forgery advances no cursor" $
        withObjective fixture \env admission objective -> do
          (a, b, intent, _, input, _) <- checkpointPair env admission objective
          let base = intent.expected.revision
              send revision key command = run env (O.executeCommand ownerHost objective revision (OperationId key) command)
              unresolved = UnresolvedOperation a.assignmentId origin (OperationId "unsettled-effect")
          run env (O.executeInternal ownerHost objective base (OperationId "forged") (IngestCheckpoint a.assignmentId (intent & #events .~ []) [input] [])) >>= (@?= Left ObjectiveConflict)
          count env "shikigami.objective_cursors" >>= (@?= 0)
          _ <- right =<< run env (O.executeInternal ownerHost objective base (OperationId "checkpoint") (IngestCheckpoint a.assignmentId intent [input] [unresolved]))
          _ <- right =<< send (base + 1) "done-a" (RecordProgress a.assignmentId Done [] [])
          _ <- right =<< send (base + 2) "done-b" (RecordProgress b.assignmentId Done [] [])
          _ <- right =<< send (base + 3) "attest" (RecordEvidence a.assignmentId (Attestation "human-check" "human" "artifact" "reviewed" False))
          _ <- right =<< send (base + 4) "propose" (ProposeCompletion (CompletionProposal (base + 4) 0 0 ["artifact"] ["human-check"] []))
          send (base + 5) "accept" AcceptCompletion >>= (@?= Left ObjectiveUnresolved),
      testCase "terminal objectives reconcile authentic accepted results while refusing fresh public progress" $
        withObjective fixture \env admission objective -> do
          now <- getCurrentTime
          let key = ObjectiveAssignmentId "late-result"
              admitted = admission & #scope . #workerKey .~ "late-result" & #objective .~ S.referenceFor objective key
          (_, session) <- right =<< run env (Sessions.openSession admitted)
          let assignment = draft now "late-result" & #sessionId .~ Just session.sessionId & #owner .~ session.owner
          _ <- right =<< run env (O.executeCommand ownerHost objective 0 (OperationId "graph") (SetAssignments [assignment]))
          _ <- right =<< run env (O.executeCommand ownerHost objective 1 (OperationId "parent") (GrantMember (RecordedAgent admission.context.identity) [Coordinator]))
          access <- right =<< run env (Sessions.authorizeSession session.sessionId admission.context.identity (pure (Right ())))
          before <- get env objective
          initialVersion <- right (S.versionFor before key)
          let instruction = WS.Instruction 1 WS.FollowUp "accepted before cancellation" initialVersion.revision initialVersion.assignmentRevision initialVersion.criteriaRevision Nothing
          (_, message) <- right =<< run env (Sessions.acceptMessage access 0 0 (OperationId "send") instruction)
          _ <- right =<< run env (Sessions.startAssignment access 1 0 (OperationId "start") message.assignmentId)
          (_, result) <- right =<< run env (Sessions.recordResult access 2 0 (OperationId "result") (WS.AssignmentResult 1 message.assignmentId WS.AssignmentSucceeded Nothing (Aeson.object []) ["artifact"]))
          _ <- right =<< run env (O.executeCommand ownerHost objective 2 (OperationId "cancel") CancelObjective)
          cancelled <- get env objective
          version <- right (S.versionFor cancelled key)
          version.active @?= False
          (_, intent) <- right =<< run env (Sessions.prepareCheckpoint access 3 0 (OperationId "prepare") version 0 3)
          let evidence = ResultEvidence "late" "human" (WorkerResult result "artifact") False
          _ <- right =<< run env (O.executeInternal ownerHost objective 3 (OperationId "reconcile") (IngestCheckpoint key intent [evidence] []))
          run env (O.executeCommand ownerHost objective 4 (OperationId "fresh-progress") (RecordProgress key Working [] [])) >>= assertLeft
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
          receipt <- right =<< run fresh (O.createObjective ownerHost (OperationId "lost-create") (Just origin) request)
          current <- right =<< run fresh (O.readObjective ownerHost receipt.objectiveId)
          current.revision @?= 1
          replay <- right =<< run fresh (O.executeCommand ownerHost receipt.objectiveId 0 (OperationId "lost-edit") (ReviseInstructions "committed-before-exit"))
          replay.revision @?= 1
          count fresh "shikigami.objectives" >>= (@?= 1)
          count fresh "shikigami.objective_origins" >>= (@?= 1)
          count fresh "shikigami.objective_receipts" >>= (@?= 2)
    ]

owner :: AccessPrincipal
owner = VerifiedCaller "owner"

ownerHost :: O.ObjectiveHost
ownerHost = host owner

host :: AccessPrincipal -> O.ObjectiveHost
host actor = O.ObjectiveHost (defaultObjectiveSettings {enabled = True}) (pure (Right actor)) allowAllActionAuthorizerForTests (\_ _ -> pure (Right ())) (\_ _ -> pure (Right ())) (\_ -> pure (Left ObjectiveInvalidEvidence))

request :: CreateRequest
request = CreateRequest "deliver" "integrated goal" "instructions" [Criterion "human" "review integration" HumanVerifiable False] []

origin :: CreationOrigin
origin = ExecutionOrigin "recorded-run" "recorded-execution" (OperationId "accepted-operation")

draft :: UTCTime -> Text -> AssignmentDraft
draft now key = AssignmentDraft (ObjectiveAssignmentId key) "work" [] (compatibilityIdentity "worker") Pending Nothing (Just (ExecutionRootId "session-root")) (Just (addUTCTime 3600 now))

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
  receipt <- right =<< run env (O.createObjective ownerHost (OperationId "create") (Just origin) request)
  callback env admission receipt.objectiveId

get :: AppEnv -> ObjectiveId -> IO Objective
get env objective = right =<< run env (O.readObjective ownerHost objective)

checkpointPair :: AppEnv -> WS.SessionAdmission -> ObjectiveId -> IO (AssignmentDraft, AssignmentDraft, CP.CheckpointIntent, CP.CheckpointIntent, EvidenceInput, EvidenceInput)
checkpointPair env admission objective = do
  now <- getCurrentTime
  let new key = admission & #scope . #workerKey .~ key & #objective .~ S.referenceFor objective (ObjectiveAssignmentId key)
  (_, sa) <- right =<< run env (Sessions.openSession (new "a"))
  (_, sb) <- right =<< run env (Sessions.openSession (new "b"))
  let a = draft now "a" & #sessionId .~ Just sa.sessionId & #owner .~ sa.owner
      b = draft now "b" & #sessionId .~ Just sb.sessionId & #owner .~ sb.owner
  _ <- right =<< run env (O.executeCommand ownerHost objective 0 (OperationId "graph") (SetAssignments [a, b]))
  _ <- right =<< run env (O.executeCommand ownerHost objective 1 (OperationId "grant-parent") (GrantMember (RecordedAgent admission.context.identity) [Coordinator]))
  current <- get env objective
  (first, inputA) <- checkpoint env admission.context.identity objective current a "evidence-a"
  (second, inputB) <- checkpoint env admission.context.identity objective current b "evidence-b"
  pure (a, b, first, second, inputA, inputB)

checkpoint :: AppEnv -> AgentIdentity -> ObjectiveId -> Objective -> AssignmentDraft -> Text -> IO (CP.CheckpointIntent, EvidenceInput)
checkpoint env actor _ current assignment key = do
  session <- maybe (assertFailure "missing fixture session" >> fail "unreachable") pure assignment.sessionId
  access <- right =<< run env (Sessions.authorizeSession session actor (pure (Right ())))
  version <- right (S.versionFor current assignment.assignmentId)
  let instruction = WS.Instruction 1 WS.FollowUp "perform" version.revision version.assignmentRevision version.criteriaRevision Nothing
  (_, message) <- right =<< run env (Sessions.acceptMessage access 0 0 (OperationId "send") instruction)
  _ <- right =<< run env (Sessions.startAssignment access 1 0 (OperationId "start") message.assignmentId)
  let result = WS.AssignmentResult 1 message.assignmentId WS.AssignmentSucceeded Nothing (Aeson.object []) ["artifact"]
  (_, receipt) <- right =<< run env (Sessions.recordResult access 2 0 (OperationId "result") result)
  (_, intent) <- right =<< run env (Sessions.prepareCheckpoint access 3 0 (OperationId "prepare") version 0 3)
  pure (intent, ResultEvidence key "human" (WorkerResult receipt "artifact") False)

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

assertLeft :: (Show a) => Either ObjectiveError a -> IO ()
assertLeft = either (const (pure ())) (assertFailure . show)

count :: AppEnv -> Text -> IO Int64
count env table = run env (runTransaction (Tx.statement () (preparable ("SELECT count(*) FROM " <> table) E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))))

sql :: AppEnv -> Text -> IO ()
sql env statement = run env (runTransaction (Tx.sql (Text.encodeUtf8 statement)))

-- No application acknowledgement escapes this process. The parent reopens the
-- database after exit and recovers both immutable receipts by their original keys.
crashWriter :: IO ()
crashWriter = do
  connection <- right . Aeson.eitherDecode =<< Lazy.getContents
  env <- environment connection
  created <- right =<< run env (O.createObjective ownerHost (OperationId "lost-create") (Just origin) request)
  _ <- right =<< run env (O.executeCommand ownerHost created.objectiveId 0 (OperationId "lost-edit") (ReviseInstructions "committed-before-exit"))
  exitWith (ExitFailure 91)

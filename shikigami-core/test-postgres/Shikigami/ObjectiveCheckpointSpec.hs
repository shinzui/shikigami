module Shikigami.ObjectiveCheckpointSpec (tests) where

import Contravariant.Extras (contrazip2)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.List (find)
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests, denyAllActionAuthorizer)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity, compatibilityIdentity)
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Fixture.ExecutionIdentity (fixtureOperationId)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Objective.Capability qualified as O
import Shikigami.Objective.Checkpoint (checkpointOperation, checkpointProvider)
import Shikigami.Objective.Command
import Shikigami.Objective.Ownership (ownershipProvider)
import Shikigami.Objective.Store qualified as Objectives
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.WorkerSession.Checkpoint qualified as CP
import Shikigami.WorkerSession.Handoff qualified as Handoff
import Shikigami.WorkerSession.Input qualified as Input
import Shikigami.WorkerSession.Integration qualified as Integration
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Transfer qualified as Transfer
import Shikigami.WorkerSession.Types qualified as WS
import Shikigami.WorkerSession.Workflow (SessionRuntime (..))
import Shikigami.WorkerSessionStoreSpec qualified as Fixture
import Shikigami.Workspace.Value (workspaceCoordinate)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "ObjectiveCheckpoint"
    [ testCase "sibling results converge through lost acknowledgement and local cursor failure" $
        withPair fixture \env objective actor a b -> do
          provider <- pure (checkpointProvider env actor (host (RecordedAgent actor)))
          versionA <- right =<< provider.current a.objective
          versionB <- right =<< provider.current b.objective
          versionA.revision @?= versionB.revision
          first <- prepare env provider a
          second <- prepare env provider b
          first.expected.revision @?= second.expected.revision
          dropped <- newIORef False
          let lossy =
                CP.CheckpointProvider
                  provider.current
                  ( \intent -> do
                      result <- provider.commit intent
                      wasDropped <- atomicModifyIORef' dropped (\prior -> (True, prior))
                      pure (if wasDropped then result else CP.CheckpointUnresolved)
                  )
              integrate chosen admission = run env (Integration.integrateEvents (runtime env chosen) (WS.sessionIdFor admission) (fixtureOperationId "checkpoint"))
          integrate lossy a >>= (@?= Right Integration.EventsPending)
          afterFirst <- get env objective
          afterFirst.revision @?= advanceRevision first.expected.revision
          length afterFirst.reportedResults @?= 1
          assertBool "reported output is not criterion evidence" (null afterFirst.evidence && isNothing afterFirst.acceptance)
          consumed env a >>= (@?= initialRevision)
          -- Objective commit already happened. Failing the separate local cursor
          -- acknowledgement must not duplicate it or consume another event batch.
          sql env "CREATE FUNCTION shikigami.reject_checkpoint_ack_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF (NEW.state->>'consumedCursor')::bigint > (OLD.state->>'consumedCursor')::bigint THEN RAISE EXCEPTION 'injected cursor acknowledgement failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER reject_checkpoint_ack_fixture BEFORE UPDATE ON shikigami.worker_sessions FOR EACH ROW EXECUTE FUNCTION shikigami.reject_checkpoint_ack_fixture()"
          failed <- integrate provider a
          assertBool "local cursor failure is visible" (isLeft failed)
          consumed env a >>= (@?= initialRevision)
          get env objective >>= (@?= afterFirst)
          sql env "DROP TRIGGER reject_checkpoint_ack_fixture ON shikigami.worker_sessions"
          let restarted = checkpointProvider env actor (host (RecordedAgent actor))
          acceptedA <- integrated =<< integrate restarted a
          acceptedB <- integrated =<< integrate restarted b
          assertBool "both receipts match their retained requests" (CP.matchesReceipt first acceptedA && CP.matchesReceipt second acceptedB)
          acceptedB.revision @?= advanceRevision acceptedA.revision
          final <- get env objective
          length final.reportedResults @?= 2
          map (.assignmentId) final.reportedResults @?= map assignment ["a", "b"]
          assertBool "artifacts are retained observations" (all ((== [artifact "artifact"]) . (.artifacts)) final.reportedResults)
          forM_ [a, b] \admission -> consumed env admission >>= (@?= revision 3)
          -- Even instruction invalidation cannot make an accepted request new.
          _ <- right =<< run env (O.executeCommand ownerHost objective final.revision (fixtureOperationId "changed") (ReviseInstructions (instructions "changed")))
          restarted.commit first >>= (@?= CP.CheckpointAccepted acceptedA)
          restarted.commit second >>= (@?= CP.CheckpointAccepted acceptedB)
          integrate restarted a >>= (@?= Right (Integration.EventsIntegrated acceptedA (revision 3)))
          current <- get env objective
          current.reportedResults @?= final.reportedResults
          current.revision @?= advanceRevision final.revision,
      testCase "instruction changes and reverts retain definitive conflicts without source consumption" $
        withPair fixture \env objective actor a _ -> do
          let provider = checkpointProvider env actor (host (RecordedAgent actor))
              integrate = run env (Integration.integrateEvents (runtime env provider) (WS.sessionIdFor a) (fixtureOperationId "checkpoint"))
          intent <- prepare env provider a
          _ <- right =<< run env (O.executeCommand ownerHost objective intent.expected.revision (fixtureOperationId "change") (ReviseInstructions (instructions "different")))
          integrate >>= (@?= Right Integration.EventsConflict)
          consumed env a >>= (@?= initialRevision)
          first <- get env objective
          assertBool "no reported result or evidence" (null first.reportedResults && null first.evidence)
          _ <- right =<< run env (O.executeCommand ownerHost objective first.revision (fixtureOperationId "revert") (ReviseInstructions (instructions "instructions")))
          integrate >>= (@?= Right Integration.EventsConflict)
          current <- get env objective
          current.revision @?= advanceRevision first.revision
          current.reportedResults @?= []
          consumed env a >>= (@?= initialRevision)
          access <- right =<< run env (Sessions.authorizeSession intent.sessionId actor (pure (Right ())))
          run env (Sessions.readCheckpointIntent access intent.operationId) >>= (@?= Right intent)
          run env (O.readInternalReceipt (host (RecordedAgent actor)) objective intent.expected.revision (checkpointOperation intent) (ProjectCheckpoint (assignment "a") intent)) >>= (@?= Right (Just (Left ObjectiveConflict))),
      testCase "current reads require coordinator authority and the original live resource root" $
        withPair fixture \env objective actor a _ -> do
          let agentHost = host (RecordedAgent actor)
              provider = checkpointProvider env actor agentHost
          version <- right =<< provider.current a.objective
          root <- right =<< run env (Roots.inspectRoot version.rootId)
          version.cutoff @?= root.envelope.cutoff
          denied <- (checkpointProvider env actor (agentHost & #actions .~ denyAllActionAuthorizer)).current a.objective
          assertBool "exact action denial" (isLeft denied)
          substituted <- (checkpointProvider env actor ownerHost).current a.objective
          assertBool "another authenticated actor cannot borrow a callback" (isLeft substituted)
          _ <- right =<< run env (Roots.setRootControl version.rootId root.revision Resources.StopWork Nothing)
          inactive <- right =<< provider.current a.objective
          inactive.active @?= Input.ObjectiveInactive
          current <- get env objective
          _ <- right =<< run env (O.executeCommand ownerHost objective current.revision (fixtureOperationId "reader") (GrantMember (RecordedAgent actor) [Reader]))
          stale <- provider.current a.objective
          assertBool "membership alone cannot admit a child" (isLeft stale),
      testCase "unknown and corrupt sources remain pending without a rejection and recover the original intent" $
        withPair fixture \env objective actor a _ -> do
          let agentHost = host (RecordedAgent actor)
              provider = checkpointProvider env actor agentHost
          intent <- prepare env provider a
          let original = case intent.events of [_, _, event] -> event; _ -> error "missing result event"
              changed = WS.EventReceipt original.cursor (WS.SessionClosedEvent WS.Failed)
              writeEvent value = run env (runTransaction (Tx.statement ((WS.sessionIdFor a).value, toJSON value) (preparable "UPDATE shikigami.worker_session_events SET state=$2 WHERE session_id=$1 AND cursor=3" (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.jsonb))) D.noResult)))
          writeEvent changed
          provider.commit intent >>= (@?= CP.CheckpointUnavailable)
          run env (O.readInternalReceipt agentHost objective intent.expected.revision (checkpointOperation intent) (ProjectCheckpoint (assignment "a") intent)) >>= (@?= Right Nothing)
          writeEvent original
          sql env "ALTER TABLE shikigami.worker_session_results RENAME TO missing_checkpoint_results_fixture"
          provider.commit intent >>= (@?= CP.CheckpointUnavailable)
          sql env "ALTER TABLE shikigami.missing_checkpoint_results_fixture RENAME TO worker_session_results"
          run env (O.readInternalReceipt agentHost objective intent.expected.revision (checkpointOperation intent) (ProjectCheckpoint (assignment "a") intent)) >>= (@?= Right Nothing)
          current <- get env objective
          current.revision @?= intent.expected.revision
          current.reportedResults @?= []
          consumed env a >>= (@?= initialRevision)
          receipt <- integrated =<< run env (Integration.integrateEvents (runtime env provider) (WS.sessionIdFor a) intent.operationId)
          assertBool "same retained operation recovers" (CP.matchesReceipt intent receipt),
      testCase "retained trusted fence changes one owner and recovers before recontacting the fence provider" $
        withPair fixture \env objective actor a _ -> do
          let agentHost = host (RecordedAgent actor)
              checkpoints = checkpointProvider env actor agentHost
          checkpoint <- prepare env checkpoints a
          accepted <- integrated =<< run env (Integration.integrateEvents (runtime env checkpoints) (WS.sessionIdFor a) (fixtureOperationId "checkpoint"))
          version <- right =<< checkpoints.current a.objective
          access <- right =<< run env (Sessions.authorizeSession (WS.sessionIdFor a) actor (pure (Right ())))
          before <- state env a
          let workspace = Transfer.WorkspaceRef (workspaceCoordinate "deterministic-fence-fixture") (workspaceCoordinate "private-a")
              successor = checked mkAgentName "worker-b"
          (_, intent) <- right =<< run env (Sessions.requestTransfer access before.revision before.epoch (fixtureOperationId "handoff") version workspace successor (compatibilityIdentity successor))
          let proof = Transfer.FenceProof V1 workspace intent.operationId (Transfer.transferFingerprint intent) intent.oldEpoch intent.newEpoch (Input.providerReceiptFor "settled-fixture-only" (toJSON intent))
              -- This fixture qualifies only the objective/session fence protocol.
              -- It makes no claim about stopping processes or workspace writes.
              fenceFixture = Transfer.WorkspaceProvider (\candidate -> pure (if candidate == intent then Transfer.FencedAndSettled proof else Transfer.FenceConflict)) (\_ _ _ _ _ -> pure (Left "fixture does not qualify writes"))
              ownership = ownershipProvider env actor agentHost (Just fenceFixture)
          ownership.transfer intent proof >>= (@?= Transfer.OwnershipUnavailable)
          get env objective >>= \current -> current.revision @?= version.revision
          dropped <- newIORef False
          let lossy =
                Transfer.OwnershipProvider
                  ( \candidate fence -> do
                      result <- ownership.transfer candidate fence
                      first <- atomicModifyIORef' dropped (\old -> (True, not old))
                      pure (if first then Transfer.OwnershipUnresolved else result)
                  )
              services = Handoff.TransferServices (runtime env checkpoints) (Just fenceFixture) (Just lossy)
          run env (Handoff.resumeHandoff services (WS.sessionIdFor a)) >>= (@?= Right Handoff.HandoffPending)
          transferred <- get env objective
          let addressed = find ((== assignment "a") . (.definition.assignmentId)) transferred.assignments
          fmap (.definition.owner) addressed @?= Just intent.newOwner
          fmap (.ownerEpoch) addressed @?= Just intent.newEpoch
          transferred.reportedResults @?= [ReportedResult (assignment "a") (case checkpoint.events of [_, _, WS.EventReceipt _ (WS.ResultAvailable result)] -> result; _ -> error "result event missing") [artifact "artifact"]]
          stillOld <- state env a
          stillOld.owner @?= intent.oldOwner
          let unavailableFence = Transfer.WorkspaceProvider (\_ -> assertFailure "accepted ownership retry recontacted the workspace" >> pure Transfer.FenceUnavailable) (\_ _ _ _ _ -> pure (Left "unavailable"))
              restartedOwner = ownershipProvider env actor agentHost Nothing
              restartedServices = Handoff.TransferServices (runtime env checkpoints) (Just unavailableFence) (Just restartedOwner)
          run env (Handoff.resumeHandoff restartedServices (WS.sessionIdFor a)) >>= (@?= Right (Handoff.HandoffEstablished intent.newOwner intent.newEpoch))
          checkpoints.commit checkpoint >>= (@?= CP.CheckpointAccepted accepted)
          get env objective >>= (@?= transferred)
          current <- state env a
          current.owner @?= intent.newOwner
          current.epoch @?= intent.newEpoch,
      testCase "old objective JSON omits observations and decodes without inventing them" $
        withPair fixture \env objective _ _ _ -> do
          current <- get env objective
          case toJSON current of
            Aeson.Object fields -> do
              assertBool "empty observation field retains old wire shape" (not (KeyMap.member "reportedResults" fields))
              Aeson.fromJSON (Aeson.Object fields) @?= Aeson.Success current
            _ -> assertFailure "objective must be an object"
    ]

-- Both source producers and the provider use real session/objective stores.
-- The inherited fixture supplies only an admitted resource root and agent values.
withPair :: DatabaseFixture -> (AppEnv -> ObjectiveId -> AgentIdentity -> WS.SessionAdmission -> WS.SessionAdmission -> IO a) -> IO a
withPair fixture callback = Fixture.withFixture fixture \env seed _ -> do
  created <- right =<< run env (O.createObjective ownerHost (fixtureOperationId "create") Nothing (CreateRequest (checked parseTitle "deliver") (checked parseGoal "goal") (instructions "instructions") [Criterion (checked parseCriterionKey "review") (checked parseCriterionDescription "review") HumanVerifiable JourneyOptional] []))
  now <- getCurrentTime
  let make key = seed & #worker .~ checked mkAgentName ("worker-" <> key) & #delegator . #delegates .~ map (checked mkAgentName) ["worker-a", "worker-b"] & #scope . #workerKey .~ Input.workerCoordinate key & #objective .~ Objectives.referenceFor created.objectiveId (assignment key) & #identity .~ compatibilityIdentity (checked mkAgentName ("worker-" <> key))
      a = make "a"
      b = make "b"
      draft key admission = AssignmentDraft (assignment key) (instructions "work") [] admission.identity Pending Nothing admission.context.executionRootId (Just (addUTCTime 7200 now))
  forM_ [a, b] \admission -> void (right =<< run env (Sessions.openSession admission))
  _ <- right =<< run env (O.executeCommand ownerHost created.objectiveId initialRevision (fixtureOperationId "graph") (SetAssignments [draft "a" a, draft "b" b]))
  _ <- right =<< run env (O.executeCommand ownerHost created.objectiveId (revision 1) (fixtureOperationId "grant") (GrantMember (RecordedAgent seed.context.identity) [Coordinator]))
  callback env created.objectiveId seed.context.identity a b

prepare :: AppEnv -> CP.CheckpointProvider -> WS.SessionAdmission -> IO CP.CheckpointIntent
prepare env provider admission = do
  let session = WS.sessionIdFor admission
      actor = admission.context.identity
  access <- right =<< run env (Sessions.authorizeSession session actor (pure (Right ())))
  version <- right =<< provider.current admission.objective
  (_, message) <- right =<< run env (Sessions.acceptMessage access initialRevision initialRevision (fixtureOperationId "send") (WS.Instruction V1 WS.FollowUp (checked Input.parseInstructionText "perform") version.revision version.assignmentRevision version.criteriaRevision Nothing))
  _ <- right =<< run env (Sessions.startAssignment access (revision 1) initialRevision (fixtureOperationId "start") message.assignmentId)
  _ <- right =<< run env (Sessions.recordResult access (revision 2) initialRevision (fixtureOperationId "result") (WS.AssignmentResult V1 message.assignmentId WS.AssignmentSucceeded Nothing Aeson.Null [Input.artifactReference "artifact"]))
  snd <$> (right =<< run env (Sessions.prepareCheckpoint access (revision 3) initialRevision (fixtureOperationId "checkpoint") version initialRevision (revision 3)))

runtime :: AppEnv -> CP.CheckpointProvider -> SessionRuntime
runtime env provider = SessionRuntime env [] disabledDirectoryHandle (const (pure (Right ()))) (Just provider)

consumed :: AppEnv -> WS.SessionAdmission -> IO (StateRevision "worker-event")
consumed env admission = do
  saved <- right =<< run env (Sessions.inspectSession (WS.sessionIdFor admission))
  maybe (fail "missing retained session") (pure . (.consumedCursor) . fst) saved

state :: AppEnv -> WS.SessionAdmission -> IO WS.SessionState
state env admission = do
  saved <- right =<< run env (Sessions.inspectSession (WS.sessionIdFor admission))
  maybe (fail "missing retained session") (pure . fst) saved

integrated :: Either WS.SessionError Integration.IntegrationOutcome -> IO CP.CheckpointReceipt
integrated result =
  right result >>= \case
    Integration.EventsIntegrated receipt cursor | cursor == revision 3 -> pure receipt
    other -> assertFailure (show other) >> fail "checkpoint did not converge"

get :: AppEnv -> ObjectiveId -> IO Objective
get env objective = right =<< run env (O.readObjective ownerHost objective)

ownerHost :: O.ObjectiveHost
ownerHost = host (VerifiedCaller (checked parseCallerId "owner"))

host :: AccessPrincipal -> O.ObjectiveHost
host actor = O.ObjectiveHost (defaultObjectiveSettings & #enabled .~ ObjectivesEnabled) (pure (Right actor)) allowAllActionAuthorizerForTests (\_ _ -> pure (Left ObjectiveDenied)) (\_ _ -> pure (Left ObjectiveDenied)) (\_ -> pure (Left ObjectiveInvalidEvidence))

sql :: AppEnv -> ByteString -> IO ()
sql env query = run env (runTransaction (Tx.sql query))

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

checked :: (Show e) => (a -> Either e b) -> a -> b
checked parser = either (error . show) id . parser

assignment :: Text -> ObjectiveAssignmentId
assignment = checked parseObjectiveAssignmentId

instructions :: Text -> Instructions
instructions = checked parseInstructions

artifact :: Text -> ArtifactRef
artifact = checked parseArtifactRef

revision :: Integer -> StateRevision scope
revision = checked parseRevision

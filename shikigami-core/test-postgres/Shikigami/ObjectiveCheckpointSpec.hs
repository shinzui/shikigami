module Shikigami.ObjectiveCheckpointSpec (tests) where

import Contravariant.Extras (contrazip2)
import Control.Concurrent.Async (concurrently)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.List (find, nub)
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow (StepName (..), runWorkflowWith, step)
import Keiro.Workflow qualified as Native
import Keiro.Workflow.Gc (WorkflowGcPolicy (..), gcWorkflowsOnce)
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests, denyAllActionAuthorizer)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (CoordinatingSkill), defaultDelegationBudget)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity, compatibilityIdentity)
import Shikigami.Agent.Run.Key (parseRunKey)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), TriggerKind (TriggeredByEvent), runJobWorkflowId)
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Delegation.BudgetStore qualified as Budgets
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Selection (ExecutionSelection, ExecutionSelectionFailure)
import Shikigami.Fixture.ExecutionIdentity (fixtureOperationId)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Objective.Association qualified as Association
import Shikigami.Objective.Capability qualified as O
import Shikigami.Objective.Checkpoint (checkpointOperation, checkpointProvider, checkpointRejection)
import Shikigami.Objective.Command
import Shikigami.Objective.Coordination (coordinationAuthority)
import Shikigami.Objective.Ownership (ownershipProvider)
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Runtime qualified as ObjectiveRuntime
import Shikigami.Objective.Store qualified as Objectives
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.RouterWorkflowSpec qualified as RouterFixture
import Shikigami.WorkerSession.Capability qualified as Worker
import Shikigami.WorkerSession.Checkpoint qualified as CP
import Shikigami.WorkerSession.Handoff (TransferServices (..))
import Shikigami.WorkerSession.Handoff qualified as Handoff
import Shikigami.WorkerSession.Input qualified as Input
import Shikigami.WorkerSession.Integration qualified as Integration
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Transfer qualified as Transfer
import Shikigami.WorkerSession.Types qualified as WS
import Shikigami.WorkerSession.Workflow (SessionRuntime (..))
import Shikigami.WorkerSessionStoreSpec qualified as Fixture
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)
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
          let retired = checkpointProvider env actor (host (RecordedAgent actor) & #settings . #enabled .~ ObjectivesDisabled)
          retired.commit first >>= (@?= CP.CheckpointAccepted acceptedA)
          retired.current a.objective >>= \value -> assertBool "disabled tracking admits no fresh checkpoint version" (isLeft value)
          integrate restarted a >>= (@?= Right (Integration.EventsIntegrated acceptedA (revision 3)))
          current <- get env objective
          current.reportedResults @?= final.reportedResults
          current.revision @?= advanceRevision final.revision,
      testCase "concurrent sibling consumers preserve both results and explicitly reconcile a raced criteria change" $
        withPair fixture \env objective actor a b -> do
          let agentHost = host (RecordedAgent actor)
              provider = checkpointProvider env actor agentHost
              services = runtime env provider & #rejections .~ Just (\identity -> checkpointRejection env identity agentHost)
              integrate admission key = run env (Integration.integrateEvents services (WS.sessionIdFor admission) key)
          first <- prepare env provider a
          second <- prepare env provider b
          first.expected.revision @?= second.expected.revision
          (left, rightResult) <- concurrently (integrate a first.operationId) (integrate b second.operationId)
          receiptA <- integrated left
          receiptB <- integrated rightResult
          assertBool "independent commits have distinct increasing revisions" (receiptA.revision /= receiptB.revision && min receiptA.revision receiptB.revision == advanceRevision first.expected.revision)
          retained <- get env objective
          length retained.reportedResults @?= 2
          next <- prepareFollowing env provider a
          gate <- newEmptyMVar
          let criteria = [Criterion (checked parseCriterionKey "review") (checked parseCriterionDescription "review under revised integration criteria") HumanVerifiable JourneyOptional]
          (_, outcome) <-
            concurrently
              (do changed <- run env (O.executeCommand ownerHost objective retained.revision (fixtureOperationId "criteria-change") (ReviseCriteria criteria)); putMVar gate (); right changed)
              (takeMVar gate >> integrate a next.operationId)
          outcome @?= Right Integration.EventsConflict
          consumed env a >>= (@?= revision 3)
          changed <- get env objective
          changed.reportedResults @?= retained.reportedResults
          version <- right =<< provider.current a.objective
          metadata <- state env a
          let replacement = fixtureOperationId "criteria-revalidated"
              decision = CP.CheckpointRevalidation version.revision version.assignmentRevision version.criteriaRevision (checked Input.parseInstructionText "Revalidated the retained output against the changed criteria; it remains an observation")
          run env (Integration.reconcileEvents services (WS.sessionIdFor a) metadata.revision metadata.epoch replacement next.operationId decision) >>= (@?= Right replacement)
          result <- right =<< integrate a (fixtureOperationId "recover-revalidated-criteria")
          case result of
            Integration.EventsIntegrated receipt cursor -> do
              cursor @?= revision 6
              receipt.operationId @?= replacement
            _ -> assertFailure (show result)
          final <- get env objective
          length final.reportedResults @?= 2
          assertBool "the sibling's already accepted result is unchanged" (filter ((== assignment "b") . (.assignmentId)) final.reportedResults == filter ((== assignment "b") . (.assignmentId)) retained.reportedResults)
          assertBool "revalidated observations cannot complete the objective" (isNothing final.acceptance && null final.evidence),
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
      testCase "explicit revalidation supersedes only a retained rejection and advances no consumed cursor" $
        withPair fixture \env objective actor a _ -> do
          let agentHost = host (RecordedAgent actor)
              provider = checkpointProvider env actor agentHost
              qualified = runtime env provider & #rejections .~ Just (\identity -> checkpointRejection env identity agentHost)
              session = WS.sessionIdFor a
              oldKey = fixtureOperationId "checkpoint"
              replacementKey = fixtureOperationId "revalidated-checkpoint"
          original <- prepare env provider a
          _ <- right =<< run env (O.executeCommand ownerHost objective original.expected.revision (fixtureOperationId "change") (ReviseInstructions (instructions "revised meaning")))
          run env (Integration.integrateEvents qualified session oldKey) >>= (@?= Right Integration.EventsConflict)
          current <- right =<< provider.current a.objective
          before <- state env a
          let decision = CP.CheckpointRevalidation current.revision current.assignmentRevision current.criteriaRevision (checked Input.parseInstructionText "I rechecked the retained results against the revised instructions")
              reconcile runtimeValue selected = run env (Integration.reconcileEvents runtimeValue session before.revision before.epoch replacementKey oldKey selected)
          reconcile qualified (decision & #assignmentRevision .~ advanceRevision decision.assignmentRevision) >>= assertLeft
          consumed env a >>= (@?= initialRevision)
          sql env "CREATE FUNCTION shikigami.reject_supersession_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected supersession publication failure'; END $$; CREATE TRIGGER reject_supersession_fixture BEFORE INSERT ON shikigami.worker_session_commands FOR EACH ROW EXECUTE FUNCTION shikigami.reject_supersession_fixture()"
          reconcile qualified decision >>= assertLeft
          afterFailure <- state env a
          afterFailure @?= before
          sql env "DROP TRIGGER reject_supersession_fixture ON shikigami.worker_session_commands"
          reconcile qualified decision >>= (@?= Right replacementKey)
          retained <- state env a
          retained.checkpointIntent @?= Just replacementKey
          retained.consumedCursor @?= initialRevision
          retained.eventCursor @?= advanceRevision before.eventCursor
          -- An accepted reconciliation retry keeps its original replacement even
          -- if fresh proof/configuration is subsequently unavailable.
          reconcile (qualified & #rejections .~ Nothing & #checkpoints .~ Nothing) decision >>= (@?= Right replacementKey)
          access <- right =<< run env (Sessions.authorizeSession session actor (pure (Right ())))
          run env (Sessions.readCheckpointIntent access oldKey) >>= (@?= Right original)
          accepted <- integrated =<< run env (Integration.integrateEvents qualified session (fixtureOperationId "new-integrator-call"))
          accepted.operationId @?= replacementKey
          updated <- get env objective
          length updated.reportedResults @?= 1
          updated.revision @?= advanceRevision current.revision
          consumed env a >>= (@?= revision 3)
          -- The supersession notification remains a separate later source fact.
          following <- run env (Integration.integrateEvents qualified session (fixtureOperationId "consume-supersession-event"))
          case following of Right (Integration.EventsIntegrated _ cursor) -> cursor @?= revision 4; _ -> assertFailure (show following),
      testCase "an accepted or unknown checkpoint cannot be superseded" $
        withPair fixture \env _ actor a _ -> do
          let agentHost = host (RecordedAgent actor)
              provider = checkpointProvider env actor agentHost
              qualified = runtime env provider & #rejections .~ Just (\identity -> checkpointRejection env identity agentHost)
              session = WS.sessionIdFor a
          original <- prepare env provider a
          before <- state env a
          let decision = CP.CheckpointRevalidation original.expected.revision original.expected.assignmentRevision original.expected.criteriaRevision (checked Input.parseInstructionText "explicit review")
              attempt = run env (Integration.reconcileEvents qualified session before.revision before.epoch (fixtureOperationId "supersede") original.operationId decision)
          attempt >>= assertLeft
          getPending <- state env a
          getPending.checkpointIntent @?= Just original.operationId
          accepted <- provider.commit original
          case accepted of CP.CheckpointAccepted _ -> pure (); _ -> assertFailure (show accepted)
          attempt >>= assertLeft
          retained <- state env a
          retained.checkpointIntent @?= Just original.operationId
          retained.consumedCursor @?= initialRevision,
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
      testCase "coordination scopes retain native admission, root and limits across source GC and configuration changes" $
        withPair fixture \env objective actor a _ -> do
          (coordinator, sourceAgent) <- retainCoordinatorSource env objective actor a
          let settings = defaultObjectiveSettings & #enabled .~ ObjectivesEnabled
              workers = map RouterFixture.successSpecialist ["worker-a", "worker-b"]
              authority = coordinationAuthority env settings disabledDirectoryHandle allowAllActionAuthorizerForTests workers defaultDelegationBudget
          initial <- right =<< authority.admit coordinator
          scope <- maybe (fail "objective coordinator scope absent") pure initial
          let configured = ObjectiveRuntime.coordinationHost env settings disabledDirectoryHandle allowAllActionAuthorizerForTests workers defaultDelegationBudget Nothing
          grant <- right =<< run env (Worker.resolveGrant configured allowAllActionAuthorizerForTests coordinator (Just (Worker.scopeFingerprint scope)))
          permit <- maybe (fail "configured coordinator grant missing") pure grant
          found <- forM (zip scope.workers ["find-a", "find-b"]) \(slot, key) -> do
            reply <- right =<< run env (Worker.executeCommand configured allowAllActionAuthorizerForTests permit (fixtureOperationId key) (Worker.FindWorker slot.workerKey))
            case reply of Worker.WorkerFound state -> pure state; _ -> fail "configured worker was not found"
          assertBool "configured workers have distinct private session scopes" (length (nub (map (.sessionId) found)) == 2)
          map (.owner) found @?= map (.identity) scope.workers
          scope.run @?= coordinator
          scope.agent @?= sourceAgent
          scope.context.executionRootId @?= coordinator.rootId
          budget <- maybe (fail "shared budget was not retained") pure scope.context.delegationBudgetId
          budget @?= Objectives.coordinatorBudgetId objective actor
          let rootId = fromMaybe (error "missing root") coordinator.rootId
              child = WorkflowId "scope-budget-child"
          reservedAt <- getCurrentTime
          _ <- right =<< run env (Budgets.reserveEnrolledDelegationSlots rootId budget Nothing (child :| []) reservedAt)
          beforeReacquire <- right =<< run env (Roots.inspectRoot rootId)
          map (.identity) scope.workers @?= map (compatibilityIdentity . checked mkAgentName) ["worker-a", "worker-b"]
          assertBool "workers address separate assignment references" (length (nub (map (.objective) scope.workers)) == 2)
          goal <- get env objective
          assertBool "scope admission binds only the original resource root" (all ((== coordinator.rootId) . (.definition.rootId)) goal.assignments)
          root <- right =<< run env (Roots.inspectRoot (fromMaybe (error "missing root") coordinator.rootId))
          assertBool "assignment cutoffs stay within the resource envelope" (all (maybe False (<= root.envelope.cutoff) . (.definition.cutoff)) goal.assignments)
          now <- getCurrentTime
          _ <- run env (gcWorkflowsOnce (addUTCTime 1 now) (WorkflowGcPolicy 0 10))
          let changed = coordinationAuthority env settings disabledDirectoryHandle allowAllActionAuthorizerForTests [] defaultDelegationBudget
          changed.reacquire coordinator (Worker.scopeFingerprint scope) >>= (@?= Right scope)
          changed.admit coordinator >>= (@?= Right (Just scope))
          _ <- right =<< run env (Budgets.reserveEnrolledDelegationSlots rootId budget Nothing (child :| []) now)
          run env (Roots.inspectRoot rootId) >>= (@?= Right beforeReacquire)
          let retired = coordinationAuthority env (settings & #enabled .~ ObjectivesDisabled) disabledDirectoryHandle allowAllActionAuthorizerForTests [] defaultDelegationBudget
          retired.reacquire coordinator (Worker.scopeFingerprint scope) >>= (@?= Right scope)
          retired.admit coordinator >>= (@?= Right Nothing)
          changed.reacquire (coordinator & #permittedAliases .~ Nothing) (Worker.scopeFingerprint scope) >>= assertScopeLeft
          _ <- right =<< run env (O.executeCommand ownerHost objective goal.revision (fixtureOperationId "revoke-coordinator") (RevokeMember (RecordedAgent actor)))
          changed.reacquire coordinator (Worker.scopeFingerprint scope) >>= assertScopeLeft,
      testCase "scope publication rolls back root attachment and refuses forged native coordinates" $
        withPair fixture \env objective actor a _ -> do
          (coordinator, _) <- retainCoordinatorSource env objective actor a
          let settings = defaultObjectiveSettings & #enabled .~ ObjectivesEnabled
              authority = coordinationAuthority env settings disabledDirectoryHandle allowAllActionAuthorizerForTests (map RouterFixture.successSpecialist ["worker-a", "worker-b"]) defaultDelegationBudget
          authority.admit (coordinator & #identity .~ compatibilityIdentity (checked mkAgentName "worker-a")) >>= assertScopeLeft
          authority.admit (coordinator & #rootId .~ Nothing) >>= assertScopeLeft
          authority.admit (coordinator & #permittedAliases .~ Nothing) >>= assertScopeLeft
          before <- get env objective
          sql env "CREATE FUNCTION shikigami.reject_scope_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected scope publication failure'; END $$; CREATE TRIGGER reject_scope_fixture BEFORE INSERT ON shikigami.objective_scopes FOR EACH ROW EXECUTE FUNCTION shikigami.reject_scope_fixture()"
          authority.admit coordinator >>= assertScopeLeft
          get env objective >>= (@?= before)
          now <- getCurrentTime
          let budget = Objectives.coordinatorBudgetId objective actor
          run env (Budgets.reserveDelegationSlot budget Nothing (WorkflowId "rollback-budget-probe") now) >>= (@?= Left (Budgets.DelegationBudgetLedgerMissing budget))
          sql env "DROP TRIGGER reject_scope_fixture ON shikigami.objective_scopes"
          scope <- right =<< authority.admit coordinator
          assertBool "same admission recovers after rollback" (isJust scope),
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
runtime env provider = SessionRuntime env [] disabledDirectoryHandle (const (pure (Right ()))) (Just (const provider)) Nothing

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

assertLeft :: (Show a) => Either WS.SessionError a -> IO ()
assertLeft = either (const (pure ())) (assertFailure . show)

-- The fixture publishes the native owner's accepted step values through Keiro,
-- using real association admission and a real resource root. No model input
-- supplies this context; scope persistence/recovery uses the production owner.
retainCoordinatorSource :: AppEnv -> ObjectiveId -> AgentIdentity -> WS.SessionAdmission -> IO (Worker.CoordinatorRun, AgentDecl)
retainCoordinatorSource env objective actor worker = do
  current <- get env objective
  let parent = AssignmentDraft (assignment "coordinator") (instructions "coordinate") [] actor Pending Nothing Nothing Nothing
      declaration = worker.delegator & #behavior .~ CoordinatingSkill (declarationCoordinate "../agents/skills/triage-note")
  _ <- right =<< run env (O.executeCommand ownerHost objective current.revision (fixtureOperationId "parent-assignment") (SetAssignments (map (.definition) current.assignments <> [parent])))
  forM_ (zip ["worker-a", "worker-b"] [4, 5]) \(name, next) -> do
    void (right =<< run env (O.executeCommand ownerHost objective (revision (next - 1)) (fixtureOperationId ("grant-" <> name)) (GrantMember (RecordedAgent (compatibilityIdentity (checked mkAgentName name))) [Worker])))
  now <- getCurrentTime
  memory <- maybe (fail "source session missing") pure worker.context.sessionId
  let reference = ObjectiveAssociation objective parent.assignmentId
      job = RunJob declaration.name actor TriggeredByEvent now Aeson.Null (checked parseRunKey "objective-coordinator-source") Nothing Nothing Nothing [declaration.name] Nothing worker.context.executionPermissions worker.context.executionRootId Nothing (Just reference) AgentWorkflowRoute
      workflow = runJobWorkflowId job
      coordinator = Worker.CoordinatorRun workflow actor memory worker.context.executionRootId worker.context.executionPermissions
  right =<< run env (runTransaction (Association.admitRunTx Association.NewRun (defaultObjectiveSettings & #enabled .~ ObjectivesEnabled) (VerifiedCaller (checked parseCallerId "owner")) actor workflow reference))
  outcome <-
    run
      env
      ( runWorkflowWith (shikigamiWorkflowRunOptions env) agentRunWorkflowName workflow do
          _ <- step (StepName "ingest-job") (pure job)
          _ <- step (StepName "lookup-agent") (pure (Just declaration))
          _ <- step (StepName "resolve-execution-selection") (pure (Right Nothing :: Either ExecutionSelectionFailure (Maybe ExecutionSelection)))
          _ <- step (StepName "open-session") (pure memory)
          pure ()
      )
  case outcome of Native.Completed () -> pure (); _ -> assertFailure "native source fixture did not complete"
  pure (coordinator, declaration)

assertScopeLeft :: (Show a) => Either Text a -> IO ()
assertScopeLeft = either (const (pure ())) (assertFailure . show)

prepareFollowing :: AppEnv -> CP.CheckpointProvider -> WS.SessionAdmission -> IO CP.CheckpointIntent
prepareFollowing env provider admission = do
  let session = WS.sessionIdFor admission
  access <- right =<< run env (Sessions.authorizeSession session admission.context.identity (pure (Right ())))
  before <- state env admission
  version <- right =<< provider.current admission.objective
  (_, message) <- right =<< run env (Sessions.acceptMessage access before.revision before.epoch (fixtureOperationId "following-send") (WS.Instruction V1 WS.FollowUp (checked Input.parseInstructionText "follow-up") version.revision version.assignmentRevision version.criteriaRevision Nothing))
  _ <- right =<< run env (Sessions.startAssignment access (advanceRevision before.revision) before.epoch (fixtureOperationId "following-start") message.assignmentId)
  _ <- right =<< run env (Sessions.recordResult access (advanceRevision (advanceRevision before.revision)) before.epoch (fixtureOperationId "following-result") (WS.AssignmentResult V1 message.assignmentId WS.AssignmentSucceeded Nothing Aeson.Null [Input.artifactReference "following-artifact"]))
  snd <$> (right =<< run env (Sessions.prepareCheckpoint access (advanceRevisions 3 before.revision) before.epoch (fixtureOperationId "following-checkpoint") version before.consumedCursor (advanceRevisions 3 before.eventCursor)))

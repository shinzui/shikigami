{-# LANGUAGE DataKinds #-}

-- | Retained coordinator grants are derived once from native run admission and
-- the objective owner. Reacquisition never reconstructs a scope from config.
module Shikigami.Objective.Coordination (coordinationAuthority, objectiveHost) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (catMaybes)
import Effectful (Eff)
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.Agent.CoordinationSource (AcceptedCoordinator (..), loadAcceptedCoordinator)
import Shikigami.Agent.Decl (AgentDecl (..), DelegationBudget, IdentityDecl (..), delegationBudgetNatural)
import Shikigami.Agent.DeclarationValue (agentEnabled)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Delegate.Depth (initialDepth)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Agent.RunJob (RunJob (..))
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Directory qualified as Directory
import Shikigami.Execution.Identity (operationIdWithPrefix)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Association qualified as Association
import Shikigami.Objective.Capability qualified as Capability
import Shikigami.Objective.Command
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Store qualified as Store
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.WorkerSession.Capability qualified as Worker
import Shikigami.WorkerSession.Input qualified as Input

objectiveHost :: ObjectiveSettings -> Directory.DirectoryHandle -> ActionAuthorizer -> AgentIdentity -> Capability.ObjectiveHost
objectiveHost settings directory actions identity = Capability.ObjectiveHost settings authenticate actions (\_ _ -> pure (Left ObjectiveDenied)) (\_ _ -> pure (Left ObjectiveDenied)) (\_ -> pure (Left ObjectiveInvalidEvidence))
  where
    authenticate = Directory.identityLifecycleAdmission directory identity <&> either (const (Left ObjectiveDenied)) (const (Right (RecordedAgent identity)))

coordinationAuthority :: AppEnv -> ObjectiveSettings -> Directory.DirectoryHandle -> ActionAuthorizer -> [AgentDecl] -> DelegationBudget -> Worker.CoordinationAuthority
coordinationAuthority env settings directory actions declarations budget = Worker.CoordinationAuthority admit reacquire
  where
    host run = objectiveHost settings directory actions run.identity
    owned :: Eff AppEffects (Either ObjectiveError a) -> IO (Either Text a)
    owned action =
      runAppIO env action <&> \case
        Right (Right value) -> Right value
        _ -> Left "objective coordination authority unavailable"
    reacquire run pinned = owned do
      saved <- Capability.lookupCoordinationScope (host run) run (Just pinned)
      pure (saved >>= maybe (Left ObjectiveMissing) Right)
    admit run
      | settings.enabled == ObjectivesDisabled = pure (Right Nothing)
      | otherwise = owned do
          reference <- runTransaction (Association.lookupRunTx run.runId)
          case reference of
            Left _ -> pure (Left ObjectiveUnavailable)
            Right Nothing -> pure (Right Nothing)
            Right (Just association) -> do
              saved <- Capability.lookupCoordinationScope (host run) run Nothing
              case saved of
                Left err -> pure (Left err)
                Right (Just scope) -> pure (Right (Just scope))
                Right Nothing -> fresh run association
    fresh run association = do
      let admittedHost = host run
      permission <- Capability.resolveAssignment admittedHost (Store.referenceFor association.objectiveId association.assignmentId)
      case permission of
        Left err -> pure (Left err)
        Right _ -> do
          source <- loadAcceptedCoordinator run
          current <- Capability.readObjective admittedHost association.objectiveId
          case (source, current) of
            (Right accepted, Right objective) | accepted.job.objective == Just association -> do
              slots <- liftIO (traverse (slotFor objective accepted) (filter ((/= association.assignmentId) . (.definition.assignmentId)) objective.assignments))
              case sequence slots >>= buildScope accepted . catMaybes of
                Left _ -> pure (Left ObjectiveDenied)
                Right scope -> do
                  let operation = operationIdWithPrefix ('c' :| "oordination-admit:") (versionedDigest "shikigami.objective-coordination-admission/1" (toJSON (run.runId.unWorkflowId, run.identity)))
                      verified =
                        admittedHost
                          & #verifyInternal
                          .~ ( \actor command -> case command of
                                 RetainCoordination key candidate | actor == RecordedAgent run.identity && key == association.assignmentId && candidate == scope -> do
                                   again <- runAppIO env (loadAcceptedCoordinator run)
                                   pure (case again of Right (Right value) | value == accepted -> Right (); _ -> Left ObjectiveUnavailable)
                                 _ -> pure (Left ObjectiveDenied)
                             )
                  retained <- Capability.executeInternal verified objective.objectiveId objective.revision operation (RetainCoordination association.assignmentId scope)
                  case retained of
                    Left err -> pure (Left err)
                    Right _ -> Capability.lookupCoordinationScope admittedHost run (Just (Worker.scopeFingerprint scope))
            (Left _, _) -> pure (Left ObjectiveDenied)
            (_, Left err) -> pure (Left err)
            _ -> pure (Left ObjectiveDenied)
    slotFor objective accepted assignment
      | assignment.definition.state `elem` [Done, Withdrawn] = pure (Right Nothing)
      | otherwise = do
          candidates <- forM (filter (\decl -> decl.name `elem` accepted.agent.delegates && agentEnabled decl.enabled) declarations) \decl -> do
            identity <- Directory.identityAdmission directory ((.principal) <$> decl.identity) decl.name
            pure ((decl.name,) <$> identity)
          let targets = [(name, identity) | Right (name, identity) <- candidates, identity == assignment.definition.owner]
              member = any (\entry -> entry.principal == RecordedAgent assignment.definition.owner && any (`elem` entry.roles) [Owner, Coordinator, Worker]) objective.members
          pure case targets of
            [(name, identity)] | member -> Right (Just (Worker.WorkerSlot (Input.workerCoordinate (objectiveAssignmentIdText assignment.definition.assignmentId)) name identity (Store.referenceFor objective.objectiveId assignment.definition.assignmentId) assignment.definition.sessionId))
            [] -> Right Nothing
            _ -> Left "ambiguous worker identity"
    buildScope accepted workers = do
      let run = accepted.run
          job = accepted.job
          agent = accepted.agent
          limit = case agent.delegationBudget of Just declared | delegationBudgetNatural declared < delegationBudgetNatural budget -> declared; _ -> budget
          bound = min 128 (toInteger (delegationBudgetNatural limit))
      unless (not (null workers) && toInteger (length workers) <= bound) (Left "worker slots exceed the admitted delegation budget")
      maximumSessions <- Input.parseSessionLimit bound
      maximumAssignments <- Input.parseSessionLimit (min 1000 (toInteger (delegationBudgetNatural limit)))
      mailbox <- Input.parseSessionLimit 4
      association <- maybe (Left "accepted run has no objective") Right job.objective
      let context = DelegateCtx (fromMaybe initialDepth job.delegationDepth) run.identity (Just run.sessionId) job.parentSessionId job.parentRunWorkflowId (if null job.lineage then [job.agentName] else job.lineage) run.permittedAliases run.rootId (Just (fromMaybe (Store.coordinatorBudgetId association.objectiveId run.identity) job.delegationBudgetId)) limit
          parent = Store.coordinatorParentScope association.objectiveId run.identity
      pure (Worker.CoordinationScope V1 run parent agent context workers maximumSessions maximumAssignments mailbox)

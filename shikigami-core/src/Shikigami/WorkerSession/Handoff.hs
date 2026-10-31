{-# LANGUAGE DataKinds #-}

-- | Durable handoff orchestration. The real owners must supply fencing,
-- reconciliation and versioned checkpoint effects; absence is explicit.
module Shikigami.WorkerSession.Handoff (TransferServices (..), TransferOutcome (..), requestHandoff, resumeHandoff) where

import Data.Aeson qualified as Aeson
import Data.List (find)
import Effectful (Eff)
import Effectful.Exception (trySync)
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..))
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.App (AppEffects)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Directory qualified as Directory
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript qualified as Execution
import Shikigami.Prelude
import Shikigami.StateRevision
import Shikigami.WorkerSession.Checkpoint (CheckpointProvider (..), ObjectiveVersion (..))
import Shikigami.WorkerSession.Store qualified as Store
import Shikigami.WorkerSession.Transfer
import Shikigami.WorkerSession.Types
import Shikigami.WorkerSession.Workflow (SessionRuntime (..), sessionAccess)

data TransferServices = TransferServices
  { sessions :: !SessionRuntime,
    workspaces :: !(Maybe WorkspaceProvider),
    ownership :: !(Maybe OwnershipProvider)
  }
  deriving stock (Generic)

data TransferOutcome = HandoffEstablished !AgentIdentity !(StateRevision "worker-owner") | HandoffPending | HandoffConflict | HandoffUnavailable
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

requestHandoff :: TransferServices -> WorkerSessionId -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> WorkspaceRef -> AgentName -> Eff AppEffects (Either SessionError TransferIntent)
requestHandoff services session revision epoch operation workspace target =
  sessionAccess services.sessions session >>= \case
    Left err -> pure (Left err)
    Right access ->
      Store.readTransferOperation access operation >>= \case
        Right intent | intent.oldEpoch == epoch && intent.workspace == workspace && intent.newWorker == target -> pure (Right intent)
        Right _ -> pure (Left MessageConflict)
        Left AssignmentMissing -> begin access
        Left err -> pure (Left err)
  where
    begin access = case (services.workspaces, services.ownership, services.sessions.checkpoints) of
      (Just _, Just _, Just checkpoints) ->
        Store.inspectSession session >>= \case
          Right (Just (_, binding)) -> case find (\decl -> decl.name == agentNameText target && decl.enabled) services.sessions.agents of
            Nothing -> pure (Left SessionOwnerRefused)
            Just declaration -> do
              identity <- liftIO (Directory.identityAdmission services.sessions.directory ((.principal) <$> declaration.identity) (agentNameText target))
              current <- trySync (liftIO (checkpoints.current binding.objective))
              now <- liftIO getCurrentTime
              case (identity, current) of
                (Right successor, Right (Right version)) | now < version.cutoff -> fmap snd <$> Store.requestTransfer access revision epoch operation version workspace target successor
                _ -> pure (Left SessionOwnerRefused)
          Right Nothing -> pure (Left SessionMissing)
          Left err -> pure (Left err)
      _ -> pure (Left (SessionInputRefused "workspace and objective ownership providers are unavailable"))

resumeHandoff :: TransferServices -> WorkerSessionId -> Eff AppEffects (Either SessionError TransferOutcome)
resumeHandoff services session = do
  sessionAccess services.sessions session >>= \case
    Left err -> pure (Left err)
    Right access ->
      Store.inspectSession session >>= \case
        Right (Just (state, _)) -> case state.handoff of
          Just progress | progress.stage == TransferEstablished -> pure (Right (HandoffEstablished state.owner state.epoch))
          Just _ -> case (services.workspaces, services.ownership) of
            (Just workspace, Just checkpoint) ->
              Store.readTransferIntent access >>= \case
                Left err -> pure (Left err)
                Right intent -> reconcile access state intent workspace checkpoint
            _ -> pure (Right HandoffUnavailable)
          _ -> pure (Left AssignmentMissing)
        Right Nothing -> pure (Left SessionMissing)
        Left err -> pure (Left err)
  where
    reconcile access state intent workspace checkpoint = do
      saved <- Store.readTransferFence access
      fenced <- case saved of
        Left err -> pure (Left err)
        Right (Just proof) -> pure (Right (Just proof))
        Right Nothing -> do
          marking <- Store.markTransferReconciling access state.revision state.epoch (key intent "reconciling" Aeson.Null) intent.operationId
          case marking of
            Left err -> pure (Left err)
            Right _ -> do
              observed <- trySync (liftIO (workspace.reconcile intent))
              let outcome = either (const FenceUnresolved) id observed
              refreshed <- Store.inspectSession session
              case refreshed of
                Right (Just (latest, _)) -> do
                  retained <- Store.retainTransferFence access latest.revision latest.epoch (key intent "fence" (toJSON outcome)) intent.operationId outcome
                  pure case retained of
                    Left err -> Left err
                    Right _ -> case outcome of FencedAndSettled proof -> Right (Just proof); _ -> Right Nothing
                Right Nothing -> pure (Left SessionMissing)
                Left err -> pure (Left err)
      case fenced of
        Left err -> pure (Left err)
        Right Nothing -> pure (Right HandoffPending)
        Right (Just proof) -> do
          metadata <- Store.inspectSession session
          case metadata of
            Right (Just (latest, _)) | isNothing latest.activeAssignment && isNothing latest.checkpointIntent -> do
              executions <- Store.assignmentExecutions access
              settled <- case executions of
                Left err -> pure (Left err)
                Right references -> do
                  facts <- traverse Execution.inspectExecution references
                  pure (Right (all (\case Right (Just (execution, binding, _)) -> binding.rootId == Just intent.rootId && execution.pendingReceipts == 0 && execution.phase `elem` [Execution.Succeeded, Execution.Failed, Execution.Cancelled]; _ -> False) facts))
              case settled of
                Left err -> pure (Left err)
                Right False -> pure (Right HandoffPending)
                Right True -> do
                  changed <- trySync (liftIO (checkpoint.transfer intent proof))
                  case changed of
                    Right (OwnershipAccepted receipt) -> do
                      fresh <- sessionAccess services.sessions session
                      current <- Store.inspectSession session
                      case (fresh, current) of
                        (Right permit, Right (Just (actual, _))) -> fmap (\(_, established) -> HandoffEstablished established.owner established.epoch) <$> Store.establishOwner permit actual.revision actual.epoch (key intent "establish" (toJSON receipt)) intent.operationId proof receipt
                        (Left err, _) -> pure (Left err)
                        (_, Left err) -> pure (Left err)
                        _ -> pure (Left SessionMissing)
                    Right OwnershipConflict -> pure (Right HandoffConflict)
                    Right OwnershipUnavailable -> pure (Right HandoffUnavailable)
                    _ -> pure (Right HandoffPending)
            Right (Just _) -> pure (Right HandoffPending)
            Right Nothing -> pure (Left SessionMissing)
            Left err -> pure (Left err)
    key intent label value = OperationId ("handoff-" <> label <> ":" <> versionedDigest "shikigami.worker-session-handoff-command/1" (toJSON (intent.operationId, value)))

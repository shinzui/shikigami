-- | A checkpoint owner may commit before its acknowledgement reaches us. Retry
-- the retained request, then atomically accept its receipt with the local cursor.
module Shikigami.WorkerSession.Integration (IntegrationOutcome (..), integrateEvents, reconcileEvents) where

import Data.List.NonEmpty (NonEmpty (..))
import Effectful (Eff)
import Effectful.Exception (trySync)
import Shikigami.App (AppEffects)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (OperationId, operationIdWithPrefix)
import Shikigami.Prelude
import Shikigami.StateRevision
import Shikigami.WorkerSession.Checkpoint
import Shikigami.WorkerSession.Store qualified as Store
import Shikigami.WorkerSession.Types
import Shikigami.WorkerSession.Workflow (SessionRuntime (..), sessionAccess)

data IntegrationOutcome = EventsIntegrated !CheckpointReceipt !(StateRevision "worker-event") | EventsPending | EventsConflict | EventsUnavailable | EventsCaughtUp !(StateRevision "worker-event")
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

integrateEvents :: SessionRuntime -> WorkerSessionId -> OperationId -> Eff AppEffects (Either SessionError IntegrationOutcome)
integrateEvents runtime session operation = case runtime.checkpoints of
  Nothing -> pure (Right EventsUnavailable)
  Just providers ->
    sessionAccess runtime session >>= \case
      Left err -> pure (Left err)
      Right access ->
        Store.inspectSession session >>= \case
          Right (Just (state, binding)) -> do
            let provider = providers binding.parentIdentity
            saved <- Store.readCheckpointIntent access operation
            prepared <- case saved of
              Right intent -> pure (Right (Just intent))
              Left AssignmentMissing | Just pending <- state.checkpointIntent -> fmap Just <$> Store.readCheckpointIntent access pending
              Left AssignmentMissing | isNothing state.checkpointIntent && state.eventCursor == state.consumedCursor -> pure (Right Nothing)
              Left AssignmentMissing | isNothing state.checkpointIntent -> do
                current <- trySync (liftIO (provider.current binding.objective))
                case current of
                  Right (Right version) -> fmap (Just . snd) <$> Store.prepareCheckpoint access state.revision state.epoch operation version state.consumedCursor (min state.eventCursor (advanceRevisions 100 state.consumedCursor))
                  _ -> pure (Left (SessionInputRefused "current checkpoint provider unavailable"))
              Left err -> pure (Left err)
            case prepared of
              Left err -> pure (Left err)
              Right Nothing -> pure (Right (EventsCaughtUp state.consumedCursor))
              Right (Just intent) -> do
                outcome <- trySync (liftIO (provider.commit intent))
                case outcome of
                  Right (CheckpointAccepted receipt) -> do
                    refreshed <- sessionAccess runtime session
                    metadata <- Store.inspectSession session
                    case (refreshed, metadata) of
                      (Right permit, Right (Just (latest, _))) -> fmap (const (EventsIntegrated receipt intent.throughCursor)) <$> Store.acceptCheckpointWith permit latest.revision latest.epoch (acknowledgement intent.operationId) intent.operationId receipt (pure (Right ()))
                      (Left err, _) -> pure (Left err)
                      (_, Left err) -> pure (Left err)
                      _ -> pure (Left SessionMissing)
                  Right CheckpointConflict -> pure (Right EventsConflict)
                  Right CheckpointUnavailable -> pure (Right EventsUnavailable)
                  _ -> pure (Right EventsPending)
          Right Nothing -> pure (Left SessionMissing)
          Left err -> pure (Left err)
  where
    acknowledgement accepted = operationIdWithPrefix ('c' :| "heckpoint-ack:") (versionedDigest "shikigami.worker-session-checkpoint-ack/1" (toJSON accepted))

-- | A parent decision supplies the revisions it has explicitly revalidated.
-- Unknown/accepted outcomes cannot supersede the retained intent.
reconcileEvents :: SessionRuntime -> WorkerSessionId -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> OperationId -> CheckpointRevalidation -> Eff AppEffects (Either SessionError OperationId)
reconcileEvents runtime session expected epoch operation previous decision = do
  access <- sessionAccess runtime session
  case access of
    Left err -> pure (Left err)
    Right permit -> do
      saved <- Store.readCheckpointSupersession permit epoch operation previous decision
      case saved of
        Left err -> pure (Left err)
        Right (Just intent) -> pure (Right intent.operationId)
        Right Nothing -> do
          original <- Store.readCheckpointIntent permit previous
          metadata <- Store.inspectSession session
          case (original, metadata, runtime.checkpoints, runtime.rejections) of
            (Right intent, Right (Just (_, binding)), Just providers, Just authorities) -> do
              proof <- trySync (liftIO (authorities binding.parentIdentity intent))
              version <- trySync (liftIO ((providers binding.parentIdentity).current binding.objective))
              case (proof, version) of
                (Right (Right rejection), Right (Right current)) -> fmap (\(_, replacement) -> replacement.operationId) <$> Store.supersedeCheckpoint permit expected epoch operation previous decision current rejection
                _ -> pure (Left (SessionInputRefused "checkpoint has no definitive rejection or current revalidation authority"))
            (Left err, _, _, _) -> pure (Left err)
            (_, Left err, _, _) -> pure (Left err)
            _ -> pure (Left (SessionInputRefused "checkpoint reconciliation authority is unavailable"))

-- | A checkpoint owner may commit before its acknowledgement reaches us. Retry
-- the retained request, then atomically accept its receipt with the local cursor.
module Shikigami.WorkerSession.Integration (IntegrationOutcome (..), integrateEvents) where

import Effectful (Eff)
import Effectful.Exception (trySync)
import Kioku.App (AppEffects)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Prelude
import Shikigami.WorkerSession.Checkpoint
import Shikigami.WorkerSession.Store qualified as Store
import Shikigami.WorkerSession.Types
import Shikigami.WorkerSession.Workflow (SessionRuntime (..), sessionAccess)

data IntegrationOutcome = EventsIntegrated !CheckpointReceipt !Integer | EventsPending | EventsConflict | EventsUnavailable | EventsCaughtUp !Integer
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

integrateEvents :: SessionRuntime -> WorkerSessionId -> OperationId -> Eff AppEffects (Either SessionError IntegrationOutcome)
integrateEvents runtime session operation = case runtime.checkpoints of
  Nothing -> pure (Right EventsUnavailable)
  Just provider ->
    sessionAccess runtime session >>= \case
      Left err -> pure (Left err)
      Right access ->
        Store.inspectSession session >>= \case
          Right (Just (state, binding)) -> do
            saved <- Store.readCheckpointIntent access operation
            prepared <- case saved of
              Right intent -> pure (Right (Just intent))
              Left AssignmentMissing | isNothing state.checkpointIntent && state.eventCursor == state.consumedCursor -> pure (Right Nothing)
              Left AssignmentMissing | isNothing state.checkpointIntent -> do
                current <- trySync (liftIO (provider.current binding.objective))
                case current of
                  Right (Right version) -> fmap (Just . snd) <$> Store.prepareCheckpoint access state.revision state.epoch operation version state.consumedCursor (min state.eventCursor (state.consumedCursor + 100))
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
                      (Right permit, Right (Just (latest, _))) -> fmap (const (EventsIntegrated receipt intent.throughCursor)) <$> Store.acceptCheckpointWith permit latest.revision latest.epoch acknowledgement operation receipt (pure (Right ()))
                      (Left err, _) -> pure (Left err)
                      (_, Left err) -> pure (Left err)
                      _ -> pure (Left SessionMissing)
                  Right CheckpointConflict -> pure (Right EventsConflict)
                  Right CheckpointUnavailable -> pure (Right EventsUnavailable)
                  _ -> pure (Right EventsPending)
          Right Nothing -> pure (Left SessionMissing)
          Left err -> pure (Left err)
  where
    acknowledgement = OperationId ("checkpoint-ack:" <> versionedDigest "shikigami.worker-session-checkpoint-ack/1" (toJSON operation))

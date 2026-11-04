{-# LANGUAGE DataKinds #-}

-- | Checkpoint revisions wake a coordinator without polling a model. Every
-- source publishes the same Boolean hint, so simultaneous findings converge.
module Shikigami.Coordination.Wake
  ( Listener (..),
    validateListener,
    prepareListener,
    registerTx,
    prepareCheckpointWakes,
    cutoffRequest,
    recheckRequest,
    cutoffFireAction,
    cutoffTimerKind,
  )
where

import Control.Exception (throw)
import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Data.UUID.V5 qualified as UUID
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (throwIO)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow (..), cancelTimer)
import Keiro.Workflow (JournalAppendOutcome (..), WorkflowError (..), WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), awakeableStepPrefix, currentGeneration, deterministicJournalId, prepareJournalAppend)
import Keiro.Workflow.Awakeable (AwakeableId, awakeableIdText, awakeableIdToUuid)
import Keiro.Workflow.Awakeable.Schema (AwakeableRow (..), AwakeableStatus (..), completeAwakeableTx, lookupAwakeable, lookupAwakeableStatusTx)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Objective.Types hiding (Completed)
import Shikigami.Prelude hiding ((.=))

data Listener = Listener
  { objectiveId :: !ObjectiveId,
    ownerName :: !WorkflowName,
    ownerId :: !WorkflowId,
    generation :: !Int,
    token :: !AwakeableId,
    after :: !(StateRevision "objective")
  }
  deriving stock (Eq, Generic)

instance ToJSON Listener where
  toJSON value = Aeson.object ["objectiveId" .= value.objectiveId, "ownerName" .= value.ownerName.unWorkflowName, "ownerId" .= value.ownerId.unWorkflowId, "generation" .= value.generation, "token" .= value.token, "after" .= value.after]

instance FromJSON Listener where
  parseJSON = Aeson.withObject "adaptive checkpoint listener" $ \o -> do
    value <- Listener <$> o .: "objectiveId" <*> (WorkflowName <$> o .: "ownerName") <*> (WorkflowId <$> o .: "ownerId") <*> o .: "generation" <*> o .: "token" <*> o .: "after"
    unless (value.generation >= 0 && value.generation <= 1000000) (fail "invalid adaptive generation")
    pure value

validateListener :: (Store :> es, IOE :> es) => Listener -> Eff es (Either ObjectiveError ())
validateListener listener = do
  current <- currentGeneration listener.ownerName listener.ownerId
  row <- lookupAwakeable (awakeableIdToUuid listener.token)
  pure $ case row of
    Just actual | current == listener.generation && actual.ownerWorkflowName == listener.ownerName.unWorkflowName && actual.ownerWorkflowId == listener.ownerId.unWorkflowId -> Right ()
    _ -> Left ObjectiveDenied

-- The caller holds the authenticated objective lock and has checked the native
-- parent/child admission. Register and catch up a missed revision atomically.
registerTx :: Listener -> StateRevision "objective" -> Transaction () -> Transaction (Either ObjectiveError ())
registerTx listener current notify = do
  count <- Tx.statement (toJSON listener) (preparable "SELECT count(*)::int FROM shikigami.adaptive_checkpoint_listeners WHERE objective_id=$1->>'objectiveId' AND (owner_name<>$1->>'ownerName' OR owner_id<>$1->>'ownerId')" jsonInput (D.singleRow (D.column (D.nonNullable D.int4))))
  if count >= 128
    then pure (Left (ObjectiveInvalid "adaptive checkpoint listener limit reached"))
    else do
      retained <- Tx.statement (toJSON listener) (preparable "INSERT INTO shikigami.adaptive_checkpoint_listeners(objective_id,owner_name,owner_id,generation,listener) VALUES ($1->>'objectiveId',$1->>'ownerName',$1->>'ownerId',($1->>'generation')::int,$1) ON CONFLICT (objective_id,owner_name,owner_id) DO UPDATE SET generation=EXCLUDED.generation,listener=EXCLUDED.listener WHERE shikigami.adaptive_checkpoint_listeners.generation < EXCLUDED.generation OR shikigami.adaptive_checkpoint_listeners.listener=EXCLUDED.listener RETURNING true" jsonInput (D.rowMaybe (D.column (D.nonNullable D.bool))))
      case retained of
        Just True -> when (current > listener.after) notify >> pure (Right ())
        _ -> pure (Left ObjectiveConflict)

prepareCheckpointWakes :: (Store :> es, IOE :> es) => ObjectiveId -> Eff es (Either ObjectiveError (StateRevision "objective" -> Transaction ()))
prepareCheckpointWakes objective = do
  values <- runTransaction (Tx.statement (objectiveIdText objective) (preparable "SELECT listener FROM shikigami.adaptive_checkpoint_listeners WHERE objective_id=$1 ORDER BY owner_name,owner_id LIMIT 129" textInput (D.rowList (D.column (D.nonNullable D.jsonb)))))
  let decoded = traverse (\value -> case Aeson.fromJSON value of Aeson.Success listener | listener.objectiveId == objective -> Right listener; _ -> Left ObjectiveUnavailable) values
  case decoded of
    Left err -> pure (Left err)
    Right listeners | length listeners > 128 -> pure (Left ObjectiveUnavailable)
    Right listeners -> do
      prepared <- traverse (\listener -> (listener.after,) <$> prepareListener listener) listeners
      pure (Right (\revision -> forM_ prepared (\(after, notify) -> when (revision > after) notify)))

prepareListener :: (Store :> es, IOE :> es) => Listener -> Eff es (Transaction ())
prepareListener listener = do
  valid <- validateListener listener
  case valid of
    Left _ -> pure (pure ())
    Right () -> do
      now <- liftIO getCurrentTime
      append <- prepareJournalAppend listener.ownerName listener.ownerId listener.generation (StepRecorded (awakeableStepPrefix <> awakeableIdText listener.token) (toJSON True) now)
      pure $ do
        transitioned <- completeAwakeableTx (awakeableIdToUuid listener.token) (toJSON True) now
        status <- lookupAwakeableStatusTx (awakeableIdToUuid listener.token)
        when (transitioned || status == Just Completed) $
          append >>= \case
            JournalAppendConflict {} -> Tx.condemn >> throw (WorkflowJournalAppendError "adaptive checkpoint wake conflicts with its retained hint")
            JournalAlreadyPresent value | value /= toJSON True -> Tx.condemn >> throw (WorkflowJournalAppendError "adaptive checkpoint wake payload differs")
            _ -> pure ()

cutoffTimerKind :: Text
cutoffTimerKind = "shikigami.adaptive-cutoff"

cutoffRequest :: Listener -> UTCTime -> TimerRequest
cutoffRequest listener cutoff =
  TimerRequest
    (TimerId (UUID.generateNamed UUID.namespaceURL (nameBytes (versionedDigest "shikigami.adaptive-cutoff/1" (toJSON listener)))))
    listener.ownerName.unWorkflowName
    listener.ownerId.unWorkflowId
    cutoff
    (Aeson.object ["kind" .= cutoffTimerKind, "listener" .= listener])

-- Administrative reconciliation retries do not invoke a model or launch work.
recheckRequest :: Listener -> UTCTime -> TimerRequest
recheckRequest listener now = TimerRequest (TimerId (UUID.generateNamed UUID.namespaceURL (nameBytes (versionedDigest "shikigami.adaptive-recheck/1" (toJSON listener))))) listener.ownerName.unWorkflowName listener.ownerId.unWorkflowId (addUTCTime 1 now) (Aeson.object ["kind" .= ("shikigami.adaptive-recheck" :: Text), "listener" .= listener])

cutoffFireAction :: (Store :> es, IOE :> es) => TimerRow -> Eff es (Maybe EventId)
cutoffFireAction row = case parseMaybe (Aeson.withObject "adaptive cutoff" (\o -> (,) <$> o .: "kind" <*> o .: "listener")) row.payload of
  Just (kind, listener) | kind `elem` [cutoffTimerKind, "shikigami.adaptive-recheck"] -> do
    valid <- validateListener listener
    case valid of
      Left _ -> void (cancelTimer row.timerId) >> pure Nothing
      Right () -> do
        notify <- prepareListener listener
        runTransaction notify
        pure (Just (deterministicJournalId listener.ownerName listener.ownerId listener.generation (awakeableStepPrefix <> awakeableIdText listener.token)))
  _ -> pure Nothing

textInput :: E.Params Text
textInput = E.param (E.nonNullable E.text)

jsonInput :: E.Params Aeson.Value
jsonInput = E.param (E.nonNullable E.jsonb)

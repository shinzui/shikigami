-- | Observation deadlines use the one Shikigami timer dispatcher. A timer is
-- owned by the generation that armed its opaque wake; it never signals a new
-- generation after rotation.
module Shikigami.Execution.Timer (armObservation, observationFireAction, observationTimerKind) where

import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Data.UUID.V5 qualified as UUID
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (throwIO)
import Hasql.Transaction qualified as Tx
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow (..), cancelTimer, scheduleTimerOnceTx)
import Keiro.Workflow (JournalAppendOutcome (..), Workflow, WorkflowError (..), WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), awakeableStepPrefix, currentGeneration, currentRunGeneration, currentWorkflow, deterministicJournalId, prepareJournalAppend)
import Keiro.Workflow.Awakeable (awakeableIdText, awakeableIdToUuid)
import Keiro.Workflow.Awakeable.Schema (AwakeableStatus (..), completeAwakeableTx, lookupAwakeableStatusTx)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId)
import Shikigami.Execution.Attempt
import Shikigami.Execution.Coordinate (executionGenerationInt)
import Shikigami.Prelude hiding ((.=))

data ObservationTimer = ObservationTimer
  { kind :: !Text,
    ownerName :: !WorkflowName,
    ownerId :: !WorkflowId,
    wake :: !ExecutionWake,
    reference :: !JobReference
  }
  deriving stock (Generic)

instance ToJSON ObservationTimer where
  toJSON value = Aeson.object ["kind" .= value.kind, "ownerName" .= value.ownerName.unWorkflowName, "ownerId" .= value.ownerId.unWorkflowId, "wake" .= value.wake, "reference" .= value.reference]

instance FromJSON ObservationTimer where
  parseJSON = Aeson.withObject "ObservationTimer" \fields -> ObservationTimer <$> fields .: "kind" <*> (WorkflowName <$> fields .: "ownerName") <*> (WorkflowId <$> fields .: "ownerId") <*> fields .: "wake" <*> fields .: "reference"

armObservation :: (Workflow :> es, Store :> es, IOE :> es) => ExecutionWake -> JobReference -> Eff es ()
armObservation wake reference = do
  (ownerName@(WorkflowName nameText), ownerId@(WorkflowId workflowText)) <- currentWorkflow
  generation <- currentRunGeneration
  now <- liftIO getCurrentTime
  let request =
        TimerRequest
          { timerId = TimerId (UUID.generateNamed UUID.namespaceURL (nameBytes (Text.intercalate ":" ["shikigami.execution-observation", nameText, workflowText, Text.pack (show generation)]))),
            processManagerName = nameText,
            correlationId = workflowText,
            fireAt = addUTCTime 60 now,
            payload = toJSON (ObservationTimer observationTimerKind ownerName ownerId wake reference)
          }
  void (runTransaction (scheduleTimerOnceTx request))

observationFireAction :: (Store :> es, IOE :> es) => TimerRow -> Eff es (Maybe EventId)
observationFireAction row = case (parseMaybe parseJSON row.payload :: Maybe ObservationTimer) of
  Just timer | timer.kind == observationTimerKind -> do
    generation <- currentGeneration timer.ownerName timer.ownerId
    if generation /= executionGenerationInt timer.wake.generation
      then void (cancelTimer row.timerId) >> pure Nothing
      else do
        now <- liftIO getCurrentTime
        let label = awakeableStepPrefix <> awakeableIdText timer.wake.token
            entryId = deterministicJournalId timer.ownerName timer.ownerId (executionGenerationInt timer.wake.generation) label
        append <- prepareJournalAppend timer.ownerName timer.ownerId (executionGenerationInt timer.wake.generation) (StepRecorded label (toJSON timer.reference) now)
        result <- runTransaction do
          transitioned <- completeAwakeableTx (awakeableIdToUuid timer.wake.token) (toJSON timer.reference) now
          status <- lookupAwakeableStatusTx (awakeableIdToUuid timer.wake.token)
          if transitioned || status == Just Completed
            then do
              outcome <- append
              case outcome of JournalAppendConflict {} -> Tx.condemn; _ -> pure ()
              pure (Just outcome)
            else pure Nothing
        case result of
          Just (JournalAppendConflict _) -> throwIO (WorkflowJournalAppendError "execution observation journal conflict")
          Just _ -> pure (Just entryId)
          Nothing -> void (cancelTimer row.timerId) >> pure Nothing
  _ -> pure Nothing

observationTimerKind :: Text
observationTimerKind = "shikigami.execution-observation"

-- | Observation deadlines use the one Shikigami timer dispatcher. A timer is
-- owned by the generation that armed its opaque wake; it never signals a new
-- generation after rotation.
module Shikigami.Execution.Timer (armObservation, observationFireAction, observationTimerKind) where

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
import Shikigami.Prelude

data ObservationTimer = ObservationTimer
  { kind :: !Text,
    ownerName :: !Text,
    ownerId :: !Text,
    wake :: !ExecutionWake,
    reference :: !JobReference
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON)

armObservation :: (Workflow :> es, Store :> es, IOE :> es) => ExecutionWake -> JobReference -> Eff es ()
armObservation wake reference = do
  (WorkflowName nameText, WorkflowId workflowText) <- currentWorkflow
  generation <- currentRunGeneration
  now <- liftIO getCurrentTime
  let request =
        TimerRequest
          { timerId = TimerId (UUID.generateNamed UUID.namespaceURL (nameBytes (Text.intercalate ":" ["shikigami.execution-observation", nameText, workflowText, Text.pack (show generation)]))),
            processManagerName = nameText,
            correlationId = workflowText,
            fireAt = addUTCTime 60 now,
            payload = toJSON (ObservationTimer observationTimerKind nameText workflowText wake reference)
          }
  void (runTransaction (scheduleTimerOnceTx request))

observationFireAction :: (Store :> es, IOE :> es) => TimerRow -> Eff es (Maybe EventId)
observationFireAction row = case (parseMaybe parseJSON row.payload :: Maybe ObservationTimer) of
  Just timer | timer.kind == observationTimerKind -> do
    generation <- currentGeneration (WorkflowName timer.ownerName) (WorkflowId timer.ownerId)
    if generation /= timer.wake.generation
      then void (cancelTimer row.timerId) >> pure Nothing
      else do
        now <- liftIO getCurrentTime
        let label = awakeableStepPrefix <> awakeableIdText timer.wake.token
            entryId = deterministicJournalId (WorkflowName timer.ownerName) (WorkflowId timer.ownerId) timer.wake.generation label
        append <- prepareJournalAppend (WorkflowName timer.ownerName) (WorkflowId timer.ownerId) timer.wake.generation (StepRecorded label (toJSON timer.reference) now)
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

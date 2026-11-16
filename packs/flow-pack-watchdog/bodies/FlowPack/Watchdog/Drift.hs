{-# LANGUAGE DataKinds #-}

-- | Bounded advisory cadence and metadata extraction. Callers supply only
-- liveness-eligible subjects; this module does not depend on the liveness ledger.
module FlowPack.Watchdog.Drift
  ( DriftCadence (..),
    DriftCheck (..),
    DriftStoreError (..),
    cadenceForGrant,
    dueForDrift,
    buildDriftInput,
    checksForAssessment,
  )
where

import Control.Monad (unless, void)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, withText, (.:), (.=))
import Data.List (nub, sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime)
import FlowPack.Watchdog.Grant
import FlowPack.Watchdog.Observation
import FlowPack.Watchdog.Program.Drift
import FlowPack.Watchdog.Types
import GHC.Generics (Generic)
import Shikigami.Duration (Duration, durationTime)
import Shikigami.Execution.Observation qualified as Execution
import Shikigami.Execution.Transcript (executionIdText)
import Shikigami.Objective.Observation (AssignmentObservation (..), ObjectiveObservation (..))
import Shikigami.Objective.Types qualified as Objective
import Shikigami.StateRevision (revisionNumber)

data DriftCadence = DriftCadence
  { interval :: !(Duration "watchdog-drift"),
    subjectsPerSweep :: !(WatchdogLimit "drift-subjects")
  }
  deriving stock (Eq, Show, Generic)

data DriftCheck = DriftCheck
  { subject :: !Subject,
    objective :: !Objective.ObjectiveId,
    checkedAt :: !UTCTime,
    mark :: !MarkDigest,
    category :: !DriftCategory
  }
  deriving stock (Eq, Show, Generic)

data DriftStoreError = DriftBounds | DriftCorrupt | DriftBindingConflict | DriftStale
  deriving stock (Eq, Show)

cadenceForGrant :: ObservationGrant -> Maybe DriftCadence
cadenceForGrant grant = DriftCadence (grantWindows grant).drift <$> grantDriftBudget grant

-- | Oldest due objective wins, with stable subject ordering inside the batch.
-- An accepted mark change never bypasses the minimum interval. Incomplete
-- relationships cannot support an assessment and are not eligible here.
dueForDrift :: DriftCadence -> UTCTime -> Map SubjectKey DriftCheck -> [SubjectObservation] -> Maybe (Objective.ObjectiveId, NonEmpty SubjectObservation)
dueForDrift cadence instant checks subjects
  | durationTime cadence.interval <= 0 || limitValue cadence.subjectsPerSweep > catalogSubjectMaximum || length (nub (map (.subject) subjects)) /= length subjects = Nothing
  | otherwise = case sortOn rank (Map.toList groups) of
      [] -> Nothing
      (objective, due) : _ -> (objective,) <$> NonEmpty.nonEmpty (take (limitValue cadence.subjectsPerSweep) (sortOn subjectRank due))
  where
    eligible = [(objective, [subject]) | subject <- subjects, subject.relationshipsComplete == Complete, Just objective <- [subject.objective], isDue subject objective]
    groups = Map.fromListWith (<>) eligible
    isDue subject objective = case Map.lookup (subjectKey subject.subject) checks of
      Nothing -> True
      Just previous -> previous.objective == objective && addUTCTime (durationTime cadence.interval) previous.checkedAt <= instant
    lastCheck subject = (.checkedAt) <$> Map.lookup (subjectKey subject.subject) checks
    subjectRank subject = (lastCheck subject, subjectKeyText (subjectKey subject.subject))
    rank (objective, due) = (case sort (map lastCheck due) of first : _ -> first; [] -> Nothing, Objective.objectiveIdText objective)

-- Goal/criteria prose is copied as untrusted data; protected instructions,
-- arguments and results are not represented in these owner observations.
buildDriftInput :: WatchdogLimit "drift-subjects" -> ObjectiveObservation -> NonEmpty SubjectObservation -> Either Text DriftInput
buildDriftInput limit objective subjects = do
  unless (objective.status `elem` [Objective.Open, Objective.Blocked] && objective.relationshipsComplete) (Left "objective scope is inactive or incomplete")
  unless (all (\subject -> subject.objective == Just objective.objectiveId && subject.relationshipsComplete == Complete) subjects) (Left "drift subjects are outside the complete objective scope")
  validateDriftInput (DriftInput objective.objectiveId objective.revision (Objective.goalText objective.goal) criteria (fmap inputFor subjects) limit)
  where
    criteria = [CriterionSummary criterion.key (Objective.criterionDescriptionText criterion.description) criterion.kind criterion.journeyRequired | criterion <- objective.criteria]
    inputFor subject = DriftSubjectInput subject.subject (assignmentFor subject) operations [] evidence
      where
        executions = executionsOf subject.metadata
        sampled = take 32 (sortOn (\(execution, operation) -> (executionIdText execution.executionId, negate (revisionNumber operation.position))) [(execution, operation) | execution <- executions, operation <- execution.operations])
        operations = [OperationSummary operation.position operation.specification | (_, operation) <- sampled]
        references = nub ([ExecutionEvidence execution.executionId execution.cursor | (execution, _) <- sampled] <> NonEmpty.toList subject.evidence)
        evidence = case take 64 references of first : rest -> first :| rest; [] -> subject.evidence
    assignmentFor subject = case subject.subject of
      WorkerSession identifier -> case [assignment.assignmentId | assignment <- objective.assignments, assignment.sessionId == Just identifier] of first : _ -> Just first; [] -> Nothing
      _ -> Nothing

-- The seal must match the full input commitment. Marks come from the frozen
-- observations of exactly the assessed subject set. EP-4 persists these checks and
-- the corresponding drift-family episode outcomes in the same transaction.
checksForAssessment :: UTCTime -> DriftInput -> NonEmpty SubjectObservation -> DriftAssessment -> Either DriftStoreError (NonEmpty DriftCheck)
checksForAssessment instant input subjects assessment = do
  unless (assessmentMatchesInput input assessment) (Left DriftBindingConflict)
  values <- traverse check (assessmentView assessment)
  unless (length (nub (map (.subject) (NonEmpty.toList subjects))) == NonEmpty.length subjects && NonEmpty.length subjects == NonEmpty.length values) (Left DriftBindingConflict)
  pure values
  where
    check answer = case filter ((== answer.subject) . (.subject)) (NonEmpty.toList subjects) of
      [observed] | observed.objective == Just input.objective && observed.relationshipsComplete == Complete -> Right (DriftCheck answer.subject input.objective instant (markDigest observed.mark) answer.category)
      _ -> Left DriftBindingConflict

executionsOf :: SubjectMetadata -> [Execution.ExecutionObservation]
executionsOf (ObjectiveMetadata _ _ _ executions) = executions
executionsOf (SessionMetadata _ executions) = executions
executionsOf (ExecutionMetadata execution) = [execution]

instance ToJSON DriftCadence where
  toJSON value = object ["interval" .= value.interval, "subjectsPerSweep" .= value.subjectsPerSweep]

instance FromJSON DriftCadence where
  parseJSON = withObject "DriftCadence" \fields -> DriftCadence <$> fields .: "interval" <*> fields .: "subjectsPerSweep"

instance ToJSON DriftCheck where
  toJSON value = object ["subject" .= value.subject, "objective" .= value.objective, "checkedAt" .= value.checkedAt, "mark" .= value.mark, "category" .= value.category]

instance FromJSON DriftCheck where
  parseJSON = withObject "DriftCheck" \fields -> DriftCheck <$> fields .: "subject" <*> fields .: "objective" <*> fields .: "checkedAt" <*> fields .: "mark" <*> fields .: "category"

instance ToJSON DriftStoreError where
  toJSON =
    toJSON . \case
      DriftBounds -> ("bounds" :: Text)
      DriftCorrupt -> "corrupt"
      DriftBindingConflict -> "binding-conflict"
      DriftStale -> "stale"

instance FromJSON DriftStoreError where
  parseJSON = withText "DriftStoreError" \case
    "bounds" -> pure DriftBounds
    "corrupt" -> pure DriftCorrupt
    "binding-conflict" -> pure DriftBindingConflict
    "stale" -> pure DriftStale
    _ -> fail "unknown drift refusal"

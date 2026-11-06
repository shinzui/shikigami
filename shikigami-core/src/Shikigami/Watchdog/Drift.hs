{-# LANGUAGE DataKinds #-}

-- | Bounded advisory cadence and metadata extraction. Callers supply only
-- liveness-eligible subjects; this module does not depend on the liveness ledger.
module Shikigami.Watchdog.Drift
  ( DriftCadence (..),
    DriftCheck (..),
    DriftStoreError (..),
    cadenceForGrant,
    dueForDrift,
    buildDriftInput,
    checksForAssessment,
    readDriftChecks,
    recordDriftChecks,
  )
where

import Control.Monad (unless, void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, except, runExceptT, throwE)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, withText, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.List (nub, sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Duration (Duration, durationTime)
import Shikigami.Execution.Observation qualified as Execution
import Shikigami.Execution.Transcript (executionIdText)
import Shikigami.Objective.Observation (AssignmentObservation (..), ObjectiveObservation (..))
import Shikigami.Objective.Types qualified as Objective
import Shikigami.Program.Decision.Drift
import Shikigami.StateRevision (revisionNumber)
import Shikigami.Watchdog.Grant
import Shikigami.Watchdog.Observation
import Shikigami.Watchdog.Types

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

type Checked = ExceptT DriftStoreError Transaction

atomic :: Checked a -> Transaction (Either DriftStoreError a)
atomic action = do
  result <- runExceptT action
  case result of Left _ -> Tx.condemn; Right _ -> pure ()
  pure result

decoded :: (FromJSON a) => Value -> Checked a
decoded value = except case Aeson.fromJSON value of Aeson.Success result -> Right result; _ -> Left DriftCorrupt

readDriftChecks :: NonEmpty SubjectKey -> Transaction (Either DriftStoreError (Map SubjectKey DriftCheck))
readDriftChecks keys = atomic do
  unless (NonEmpty.length keys <= 256) (throwE DriftBounds)
  rows <- lift (Tx.statement (toJSON keys) (preparable (checkProjection <> " WHERE subject_key IN (SELECT jsonb_array_elements_text($1)) ORDER BY subject_key") json (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb)))))
  values <-
    mapM
      ( \(key, value) -> do
          check <- decoded value
          unless (subjectKeyText (subjectKey check.subject) == key) (throwE DriftCorrupt)
          pure (subjectKey check.subject, check)
      )
      rows
  pure (Map.fromList values)

recordDriftChecks :: SweepId -> UTCTime -> NonEmpty DriftCheck -> Transaction (Either DriftStoreError ())
recordDriftChecks sweep instant checks = atomic do
  let values = NonEmpty.toList checks
      digest = versionedDigest "shikigami.watchdog-drift-checks/1" (object ["at" .= instant, "checks" .= checks])
      args = object ["sweep" .= sweep, "digest" .= digest]
  unless (length values <= catalogSubjectMaximum && length (nub (map (.subject) values)) == length values && all ((== instant) . (.checkedAt)) values) (throwE DriftBounds)
  void (lift (Tx.statement args (preparable "SELECT true FROM pg_advisory_xact_lock(hashtextextended('watchdog-drift/'||($1->>'sweep'),0))" json (D.singleRow (D.column (D.nonNullable D.bool))))))
  retained <- lift (Tx.statement args (preparable "SELECT input_digest FROM shikigami.watchdog_drift_receipts WHERE sweep_id=$1->>'sweep'" json (D.rowMaybe (D.column (D.nonNullable D.text)))))
  case retained of
    Just previous -> unless (previous == digest) (throwE DriftBindingConflict)
    Nothing -> do
      mapM_ (writeCheck sweep) (sortOn (subjectKeyText . subjectKey . (.subject)) values)
      lift (Tx.statement args (preparable "INSERT INTO shikigami.watchdog_drift_receipts(sweep_id,input_digest) VALUES ($1->>'sweep',$1->>'digest')" json D.noResult))

writeCheck :: SweepId -> DriftCheck -> Checked ()
writeCheck sweep check = do
  let args = object ["key" .= subjectKey check.subject, "subject" .= check.subject, "objective" .= check.objective, "at" .= check.checkedAt, "mark" .= check.mark, "category" .= categoryText check.category, "sweep" .= sweep]
  -- A subject lock also covers its first insertion, across different sweeps.
  void (lift (Tx.statement args (preparable "SELECT true FROM pg_advisory_xact_lock(hashtextextended('watchdog-drift-subject/'||($1->>'key'),0))" json (D.singleRow (D.column (D.nonNullable D.bool))))))
  previous <- lift (Tx.statement args (preparable ("SELECT jsonb_build_object('subject',subject,'objective',objective_id,'checkedAt',checked_at,'mark',mark_digest,'category',jsonb_build_object('kind',category)) FROM shikigami.watchdog_drift_checks WHERE subject_key=$1->>'key' FOR UPDATE") json (D.rowMaybe (D.column (D.nonNullable D.jsonb))))) >>= traverse decoded :: Checked (Maybe DriftCheck)
  case previous of
    Just retained -> do
      unless (retained.objective == check.objective && retained.subject == check.subject) (throwE DriftBindingConflict)
      unless (retained.checkedAt < check.checkedAt) (throwE DriftStale)
    Nothing -> pure ()
  lift (Tx.statement args (preparable "INSERT INTO shikigami.watchdog_drift_checks(subject_key,subject,objective_id,checked_at,mark_digest,category,sweep_id) VALUES ($1->>'key',$1->'subject',$1->>'objective',($1->>'at')::timestamptz,$1->>'mark',$1->>'category',$1->>'sweep') ON CONFLICT(subject_key) DO UPDATE SET checked_at=EXCLUDED.checked_at,mark_digest=EXCLUDED.mark_digest,category=EXCLUDED.category,sweep_id=EXCLUDED.sweep_id" json D.noResult))

json :: E.Params Value
json = E.param (E.nonNullable E.jsonb)

categoryText :: DriftCategory -> Text
categoryText WithinScope = "within-scope"
categoryText PossibleDrift = "possible-drift"
categoryText OutsideScope = "outside-scope"

checkProjection :: Text
checkProjection = "SELECT subject_key,jsonb_build_object('subject',subject,'objective',objective_id,'checkedAt',checked_at,'mark',mark_digest,'category',jsonb_build_object('kind',category)) FROM shikigami.watchdog_drift_checks"

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

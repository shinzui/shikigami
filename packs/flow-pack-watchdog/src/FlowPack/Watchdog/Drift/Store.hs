{-# LANGUAGE DataKinds #-}

-- | The retained drift checks: when each subject was last assessed, read
-- and written inside the sweep's own transactions.
module FlowPack.Watchdog.Drift.Store (readDriftChecks, recordDriftChecks) where

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
import FlowPack.Watchdog.Drift
import FlowPack.Watchdog.Program.Drift
import FlowPack.Watchdog.Types
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Decision.Contract (versionedDigest)

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

{-# LANGUAGE DataKinds #-}

-- | Retained sweep claims, frozen-input receipts and conservative coverage.
-- Every typed refusal condemns its transaction, including ignored refusals.
module Shikigami.Watchdog.Store
  ( module Shikigami.Watchdog.Ledger,
    PageOutcome (..),
    pageOutcomeView,
    openSweep,
    readSweep,
    closeSweep,
    recordSweepPage,
    readPriorMarks,
    readCoverage,
    writeCoverage,
    completePass,
  )
where

import Control.Monad (forM, unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (throwE)
import Data.Aeson (FromJSON, Value, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.List (nub, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isNothing)
import Data.Text (Text)
import Data.Time (UTCTime)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Observation qualified as Execution
import Shikigami.Execution.Transcript qualified as ExecutionOwner
import Shikigami.Objective.Observation qualified as Objective
import Shikigami.Objective.Types qualified as ObjectiveOwner
import Shikigami.Watchdog.Classify
import Shikigami.Watchdog.Episode (Finding, findingView)
import Shikigami.Watchdog.Episode qualified as Episode
import Shikigami.Watchdog.Grant
import Shikigami.Watchdog.Ledger
import Shikigami.Watchdog.Observation
import Shikigami.Watchdog.Store.Internal
import Shikigami.Watchdog.Types
import Shikigami.WorkerSession.Observation qualified as Session
import Shikigami.WorkerSession.Types qualified as SessionOwner

data PageOutcome = PageOutcome {notices :: ![Finding], opened :: !Word, continued :: !Word, closed :: !Word}
  deriving stock (Eq, Show)

pageOutcomeView :: PageOutcome -> PageOutcomeView
pageOutcomeView outcome = PageOutcomeView (map findingView outcome.notices) outcome.opened outcome.continued outcome.closed

openSweep :: SweepId -> SweepOrigin -> GrantSnapshot -> Transaction (Either WatchdogError SweepId)
openSweep proposed origin grant = atomic do
  let claim = claimKeyFor origin.principal grant.scope
      args = object ["claim" .= claim, "principal" .= origin.principal, "scope" .= grant.scope, "id" .= proposed, "name" .= origin.workflowName.unWorkflowName, "workflow" .= origin.workflowId.unWorkflowId, "origin" .= origin, "grant" .= grant, "dueAt" .= origin.dueAt]
  execute "INSERT INTO shikigami.watchdog_claims(claim_key,principal,scope) VALUES ($1->>'claim',$1->'principal',$1->'scope') ON CONFLICT DO NOTHING" args
  claimRow <- row "SELECT jsonb_build_object('active',active_sweep,'principal',principal,'scope',scope) FROM shikigami.watchdog_claims WHERE claim_key=$1->>'claim' FOR UPDATE" args >>= maybe (throwE LedgerCorrupt) pure
  (active, retainedPrincipal, retainedScope) <- decodeClaim claimRow
  unless (retainedPrincipal == origin.principal && retainedScope == grant.scope) (throwE LedgerBindingConflict)
  existing <- row (sweepProjection <> " WHERE workflow_name=$1->>'name' AND workflow_id=$1->>'workflow'") args >>= traverse decoded :: Checked (Maybe SweepView)
  case existing of
    Just previous -> do
      unless (previous.origin == origin && previous.grant == grant && previous.claimKey == claim) (throwE LedgerBindingConflict)
      when (isNothing previous.completedAt && active /= Just previous.sweepId) (throwE LedgerBindingConflict)
      pure previous.sweepId
    Nothing -> do
      case active of Just held -> throwE (SweepClaimHeld held); Nothing -> pure ()
      execute "INSERT INTO shikigami.watchdog_sweeps(sweep_id,workflow_name,workflow_id,origin,grant_snapshot,claim_key,due_at) VALUES ($1->>'id',$1->>'name',$1->>'workflow',$1->'origin',$1->'grant',$1->>'claim',($1->>'dueAt')::timestamptz) ON CONFLICT DO NOTHING" args
      saved <- requiredSweep proposed
      unless (saved.origin == origin && saved.grant == grant && saved.claimKey == claim && isNothing saved.completedAt) (throwE LedgerBindingConflict)
      execute "UPDATE shikigami.watchdog_claims SET active_sweep=$1->>'id' WHERE claim_key=$1->>'claim'" args
      execute "INSERT INTO shikigami.watchdog_coverage(claim_key,cursor,pass_started_at) VALUES ($1->>'claim',$1->'cursor',($1->>'at')::timestamptz) ON CONFLICT DO NOTHING" (object ["claim" .= claim, "cursor" .= initialCursor, "at" .= saved.openedAt])
      pure proposed

readSweep :: SweepId -> Transaction (Either WatchdogError (Maybe SweepView))
readSweep sweep = atomic (row (sweepProjection <> " WHERE sweep_id=$1->>'id'") (object ["id" .= sweep]) >>= traverse decoded)

closeSweep :: SweepId -> SweepSummary -> Transaction (Either WatchdogError UTCTime)
closeSweep sweep summary = atomic do
  saved <- lockSweep sweep
  case saved.completedAt of
    Just instant -> if saved.summary == Just summary then pure instant else throwE LedgerBindingConflict
    Nothing -> do
      requireClaim saved
      execute "UPDATE shikigami.watchdog_sweeps SET completed_at=clock_timestamp(),summary=$1->'summary' WHERE sweep_id=$1->>'id'" (object ["id" .= sweep, "summary" .= summary])
      execute "UPDATE shikigami.watchdog_claims SET active_sweep=NULL WHERE claim_key=$1->>'claim' AND active_sweep=$1->>'id'" (object ["claim" .= saved.claimKey, "id" .= sweep])
      actual <- requiredSweep sweep
      maybe (throwE LedgerCorrupt) pure actual.completedAt

recordSweepPage :: SweepId -> DetectionFamily -> UTCTime -> IdentityPool -> [Observed] -> Transaction (Either WatchdogError PageOutcome)
recordSweepPage sweep family instant (IdentityPool identities) observed = atomic do
  saved <- lockSweep sweep
  let operation = "page/" <> familyText family
      digest = versionedDigest "shikigami.watchdog-page/1" (object ["at" .= instant, "observed" .= observed])
  replay <- readReceipt sweep operation digest
  case replay of
    Just view -> restoreOutcome view
    Nothing -> do
      requireClaim saved
      unless (length observed <= 96 && length (nub (map (.subject) observed)) == length observed) (throwE LedgerBounds)
      unless (length identities >= length observed) (throwE IdentityPoolTooSmall)
      unless (length identities <= 96 && length (nub (map (.subject) identities)) == length identities && length (nub (map (.episode) identities)) == length identities && length (nub (map (.finding) identities)) == length identities) (throwE LedgerBindingConflict)
      results <- forM (sortOn (subjectKeyText . subjectKey . (.subject)) observed) \subject -> do
        allocated <- case filter ((== subjectKey subject.subject) . (.subject)) identities of [value] -> pure value; _ -> throwE IdentityPoolTooSmall
        unless (inScope saved.grant.scope subject.objective) (throwE LedgerBindingConflict)
        lockSubject subject.subject
        when (family == Liveness) (recordMark sweep instant subject)
        case subject.outcome of
          Clear ObservationUnknown -> pure (Nothing, 0, 0, 0)
          Clear verdict -> do
            reason <- case verdict of Progressing -> pure MadeProgress; Waiting _ -> pure LegitimatelyWaiting; Terminal -> pure OwnerTerminal; _ -> throwE LedgerBindingConflict
            closed <- Episode.closeFamily sweep family instant subject.subject reason
            pure (Nothing, 0, 0, closed)
          Detected detection -> do
            unless (familyFor detection.kind == family) (throwE LedgerBindingConflict)
            change <- Episode.recordDetection sweep instant allocated subject detection
            pure (change.notice, change.opened, change.continued, 0)
      let outcome = PageOutcome (catMaybes [notice | (notice, _, _, _) <- results]) (sum [count | (_, count, _, _) <- results]) (sum [count | (_, _, count, _) <- results]) (sum [count | (_, _, _, count) <- results])
      saveReceipt sweep operation digest (toJSON (pageOutcomeView outcome))
      pure outcome

restoreOutcome :: PageOutcomeView -> Checked PageOutcome
restoreOutcome view = PageOutcome <$> Episode.recoverFindings view.notices <*> pure view.opened <*> pure view.continued <*> pure view.closed

recordMark :: SweepId -> UTCTime -> Observed -> Checked ()
recordMark sweep instant observed = do
  existing <- priorMark (subjectKey observed.subject)
  unless (existing == observed.prior && maybe True (\prior -> prior.firstSeenAt <= prior.lastChangedAt && prior.lastChangedAt <= instant) existing) (throwE StaleObservation)
  newer <- row "SELECT to_jsonb(last_seen_at) FROM shikigami.watchdog_marks WHERE subject_key=$1->>'key' AND (last_seen_at>($1->>'at')::timestamptz OR (last_seen_at=($1->>'at')::timestamptz AND last_seen_sweep<>$1->>'sweep'))" (object ["key" .= subjectKey observed.subject, "at" .= instant, "sweep" .= sweep])
  unless (isNothing newer) (throwE StaleObservation)
  execute
    "INSERT INTO shikigami.watchdog_marks(subject_key,subject,objective_id,mark_digest,mark,first_seen_at,last_changed_at,last_seen_at,last_seen_sweep) VALUES ($1->>'key',$1->'subject',$1->>'objective',$1->>'digest',$1->'mark',($1->>'at')::timestamptz,($1->>'at')::timestamptz,($1->>'at')::timestamptz,$1->>'sweep') ON CONFLICT(subject_key) DO UPDATE SET subject=EXCLUDED.subject,objective_id=EXCLUDED.objective_id,mark=EXCLUDED.mark,mark_digest=EXCLUDED.mark_digest,last_changed_at=CASE WHEN shikigami.watchdog_marks.mark_digest=EXCLUDED.mark_digest THEN shikigami.watchdog_marks.last_changed_at ELSE EXCLUDED.last_changed_at END,last_seen_at=EXCLUDED.last_seen_at,last_seen_sweep=EXCLUDED.last_seen_sweep"
    (object ["key" .= subjectKey observed.subject, "subject" .= observed.subject, "objective" .= observed.objective, "digest" .= markDigest observed.mark, "mark" .= observed.mark, "at" .= instant, "sweep" .= sweep])

readPriorMarks :: NonEmpty SubjectKey -> Transaction (Either WatchdogError (Map SubjectKey PriorMark))
readPriorMarks keys = atomic do
  unless (NonEmpty.length keys <= 256) (throwE LedgerBounds)
  values <- rows "SELECT jsonb_build_array(subject_key,jsonb_build_object('digest',mark_digest,'firstSeenAt',first_seen_at,'lastChangedAt',last_changed_at)) FROM shikigami.watchdog_marks WHERE subject_key IN (SELECT jsonb_array_elements_text($1)) ORDER BY subject_key" (toJSON keys)
  Map.fromList <$> mapM decoded values

priorMark :: SubjectKey -> Checked (Maybe PriorMark)
priorMark key = row "SELECT jsonb_build_object('digest',mark_digest,'firstSeenAt',first_seen_at,'lastChangedAt',last_changed_at) FROM shikigami.watchdog_marks WHERE subject_key=$1->>'key' FOR UPDATE" (object ["key" .= key]) >>= traverse decoded

readCoverage :: AgentIdentity -> ObservationScope -> Transaction (Either WatchdogError (Maybe Coverage))
readCoverage principal scope = atomic (coverageFor (claimKeyFor principal scope))

coverageFor :: Text -> Checked (Maybe Coverage)
coverageFor claim = row "SELECT jsonb_build_object('cursor',cursor,'passStartedAt',pass_started_at,'lastPassCompletedAt',last_pass_completed_at) FROM shikigami.watchdog_coverage WHERE claim_key=$1->>'claim'" (object ["claim" .= claim]) >>= traverse decoded

writeCoverage :: SweepId -> UTCTime -> CoverageCursor -> PassCompletion -> Transaction (Either WatchdogError Coverage)
writeCoverage sweep instant cursor completion = atomic do
  saved <- lockSweep sweep
  let digest = versionedDigest "shikigami.watchdog-coverage/1" (object ["at" .= instant, "cursor" .= cursor, "completion" .= completion])
  replay <- readReceipt sweep "coverage" digest
  case replay of
    Just coverage -> pure coverage
    Nothing -> do
      requireClaim saved
      unless (cursor.scope == Just saved.grant.scope && (completion /= PassCompleted || (cursor.passClean && length (nub cursor.exhausted) == 3))) (throwE LedgerBindingConflict)
      execute "UPDATE shikigami.watchdog_coverage SET cursor=$1->'cursor' WHERE claim_key=$1->>'claim'" (object ["cursor" .= cursor, "claim" .= saved.claimKey])
      coverage <- coverageFor saved.claimKey >>= maybe (throwE LedgerCorrupt) pure
      saveReceipt sweep "coverage" digest (toJSON coverage)
      pure coverage

completePass :: SweepId -> ObservationPage -> Transaction (Either WatchdogError PassOutcome)
completePass sweep page = atomic do
  saved <- lockSweep sweep
  let digest = versionedDigest "shikigami.watchdog-pass/1" page
  replay <- readReceipt sweep "pass" digest
  case replay of
    Just outcome -> pure outcome
    Nothing -> do
      requireClaim saved
      unless (page.passCompleted == PassCompleted && page.cursor.passClean && length (nub page.cursor.exhausted) == 3 && null page.refusals && page.cursor.scope == Just saved.grant.scope) (throwE IncompletePass)
      coverage <- coverageFor saved.claimKey >>= maybe (throwE LedgerCorrupt) pure
      when (page.observedAt < coverage.passStartedAt) (throwE StaleObservation)
      let scopeIds = case saved.grant.scope of AllObjectives -> Nothing; SelectedObjectives ids -> Just (toJSON ids)
      candidates <-
        rows
          "SELECT DISTINCT e.subject FROM shikigami.watchdog_episodes e LEFT JOIN shikigami.watchdog_marks m USING(subject_key) WHERE e.closed_at IS NULL AND (m.last_seen_at IS NULL OR m.last_seen_at<($1->>'since')::timestamptz) AND ($1->'objectives'='null'::jsonb OR $1->'objectives' @> jsonb_build_array(e.objective_id)) ORDER BY e.subject LIMIT 97"
          (object ["since" .= coverage.passStartedAt, "objectives" .= scopeIds])
          >>= mapM decoded
      lift (Tx.sql "SET LOCAL statement_timeout='2000ms'")
      checks <- forM (sortOn (subjectKeyText . subjectKey) (take 96 candidates)) \subject -> do
        confirmation <- confirmInactive subject
        case confirmation of
          Just reason -> do
            closed <- Episode.closeConfirmed sweep page.observedAt subject reason
            pure (closed, Nothing)
          Nothing -> pure ([], Just (subjectKey subject))
      let unknown = catMaybes (map snd checks) <> map subjectKey (drop 96 candidates)
          outcome = PassOutcome (concatMap fst checks) unknown (null unknown)
      when outcome.complete (execute "UPDATE shikigami.watchdog_coverage SET pass_started_at=($1->>'at')::timestamptz,last_pass_completed_at=($1->>'at')::timestamptz WHERE claim_key=$1->>'claim'" (object ["at" .= page.observedAt, "claim" .= saved.claimKey]))
      saveReceipt sweep "pass" digest (toJSON outcome)
      pure outcome

-- Absence in an active population is never confirmation. These exact owner
-- reads include terminal rows and retain typed corruption/refusal results.
confirmInactive :: Subject -> Checked (Maybe ClosureReason)
confirmInactive (ObjectiveCoordinator identifier) = do
  observed <- lift (Objective.observeObjectivesFor (identifier :| []))
  pure case observed of
    Right [] -> Just OwnerVanished
    Right [(_, Right value)] | value.status `elem` [ObjectiveOwner.Completed, ObjectiveOwner.Cancelled] -> Just OwnerTerminal
    _ -> Nothing
confirmInactive (WorkerSession identifier) = do
  observed <- lift (Session.observeSessionsFor (identifier :| []))
  pure case observed of
    Right [] -> Just OwnerVanished
    Right [(_, Right value)] | value.phase `elem` [SessionOwner.Failed, SessionOwner.Cancelled] -> Just OwnerTerminal
    _ -> Nothing
confirmInactive (Execution identifier) = do
  observed <- lift (Execution.observeExecutionsFor (identifier :| []))
  pure case observed of
    Right [] -> Just OwnerVanished
    Right [(_, Right value)] | value.phase `elem` [ExecutionOwner.Succeeded, ExecutionOwner.Failed, ExecutionOwner.Cancelled] -> Just OwnerTerminal
    _ -> Nothing

inScope :: ObservationScope -> Maybe ObjectiveOwner.ObjectiveId -> Bool
inScope AllObjectives _ = True
inScope (SelectedObjectives ids) objective = maybe False (`elem` ids) objective

requiredSweep :: SweepId -> Checked SweepView
requiredSweep sweep = row (sweepProjection <> " WHERE sweep_id=$1->>'id'") (object ["id" .= sweep]) >>= maybe (throwE SweepMissing) decoded

lockSweep :: SweepId -> Checked SweepView
lockSweep sweep = do
  initial <- requiredSweep sweep
  _ <- row "SELECT jsonb_build_object('active',active_sweep) FROM shikigami.watchdog_claims WHERE claim_key=$1->>'claim' FOR UPDATE" (object ["claim" .= initial.claimKey]) >>= maybe (throwE LedgerCorrupt) pure
  row (sweepProjection <> " WHERE sweep_id=$1->>'id' FOR UPDATE") (object ["id" .= sweep]) >>= maybe (throwE SweepMissing) decoded

requireClaim :: SweepView -> Checked ()
requireClaim saved = do
  when (saved.completedAt /= Nothing) (throwE SweepClosed)
  actual <- row "SELECT jsonb_build_object('active',active_sweep,'principal',principal,'scope',scope) FROM shikigami.watchdog_claims WHERE claim_key=$1->>'claim'" (object ["claim" .= saved.claimKey]) >>= maybe (throwE LedgerCorrupt) decodeClaim
  unless (actual == (Just saved.sweepId, saved.origin.principal, saved.grant.scope)) (throwE LedgerBindingConflict)

decodeClaim :: Value -> Checked (Maybe SweepId, AgentIdentity, ObservationScope)
decodeClaim value = case (Aeson.fromJSON value :: Aeson.Result (Map Text Value)) of
  Aeson.Success fields -> do
    active <- decoded (Map.findWithDefault Aeson.Null "active" fields)
    principal <- decoded (Map.findWithDefault Aeson.Null "principal" fields)
    scope <- decoded (Map.findWithDefault Aeson.Null "scope" fields)
    pure (active, principal, scope)
  _ -> throwE LedgerCorrupt

readReceipt :: (FromJSON a) => SweepId -> Text -> Text -> Checked (Maybe a)
readReceipt sweep operation digest = do
  saved <- row "SELECT jsonb_build_array(input_digest,outcome) FROM shikigami.watchdog_receipts WHERE sweep_id=$1->>'sweep' AND operation=$1->>'operation'" (object ["sweep" .= sweep, "operation" .= operation])
  case saved of
    Nothing -> pure Nothing
    Just value -> do
      (retained, outcome) <- decoded value
      unless (retained == digest) (throwE LedgerBindingConflict)
      Just <$> decoded outcome

saveReceipt :: SweepId -> Text -> Text -> Value -> Checked ()
saveReceipt sweep operation digest outcome = execute "INSERT INTO shikigami.watchdog_receipts(sweep_id,operation,input_digest,outcome) VALUES ($1->>'sweep',$1->>'operation',$1->>'digest',$1->'outcome')" (object ["sweep" .= sweep, "operation" .= operation, "digest" .= digest, "outcome" .= outcome])

sweepProjection :: Text
sweepProjection = "SELECT jsonb_build_object('sweepId',sweep_id,'origin',origin,'grant',grant_snapshot,'claimKey',claim_key,'openedAt',opened_at,'completedAt',completed_at,'summary',summary) FROM shikigami.watchdog_sweeps"

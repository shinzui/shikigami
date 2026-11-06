-- | The only finding constructor is inside checked episode persistence. Public
-- views and persisted journal receipts do not themselves constitute findings.
module Shikigami.Watchdog.Episode
  ( Finding,
    findingView,
    EpisodeChange (..),
    recordDetection,
    closeFamily,
    closeConfirmed,
    recoverFindings,
    episodeProjection,
  )
where

import Control.Monad (unless)
import Control.Monad.Trans.Except (throwE)
import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Time (UTCTime)
import Shikigami.Watchdog.Classify
import Shikigami.Watchdog.Ledger
import Shikigami.Watchdog.Store.Internal
import Shikigami.Watchdog.Types

newtype Finding = Finding FindingView deriving stock (Eq, Show)

findingView :: Finding -> FindingView
findingView (Finding view) = view

data EpisodeChange = EpisodeChange {notice :: !(Maybe Finding), opened :: !Word, continued :: !Word}
  deriving stock (Eq, Show)

recordDetection :: SweepId -> UTCTime -> SubjectIdentity -> Observed -> Detection -> Checked EpisodeChange
recordDetection sweep instant identities observed detection = do
  unless (identities.subject == subjectKey observed.subject && detection.kind == detection.summary.kind && detection.window.observedAt == instant && detection.limit.relationshipsComplete == Complete && validDetection detection) (throwE LedgerBindingConflict)
  lockSubject observed.subject
  let digest = summaryDigest detection.summary
      binding = object ["subjectKey" .= subjectKey observed.subject, "kind" .= kindText detection.kind]
  existing <- row (episodeProjection <> " WHERE subject_key=$1->>'subjectKey' AND kind=$1->>'kind' AND closed_at IS NULL FOR UPDATE") binding >>= traverse decoded :: Checked (Maybe EpisodeView)
  case existing of
    Nothing -> do
      let episode = EpisodeView identities.episode observed.subject observed.objective detection.kind (familyFor detection.kind) instant sweep Nothing Nothing digest sweep 1
      execute
        "INSERT INTO shikigami.watchdog_episodes(episode_id,subject_key,subject,objective_id,kind,family,opened_at,opened_sweep,last_summary_digest,last_seen_sweep,notified_count) VALUES ($1->>'id',$1->>'key',$1->'subject',$1->>'objective',$1->>'kind',$1->>'family',($1->>'at')::timestamptz,$1->>'sweep',$1->>'digest',$1->>'sweep',1) ON CONFLICT DO NOTHING"
        (object ["id" .= episode.episodeId, "key" .= subjectKey observed.subject, "subject" .= observed.subject, "objective" .= observed.objective, "kind" .= kindText detection.kind, "family" .= familyText episode.family, "at" .= instant, "sweep" .= sweep, "digest" .= digest])
      retained <- row (episodeProjection <> " WHERE episode_id=$1->>'id'") (object ["id" .= episode.episodeId]) >>= maybe (throwE LedgerBindingConflict) decoded
      unless (retained == episode) (throwE LedgerBindingConflict)
      finding <- persistFinding sweep instant identities.finding episode.episodeId observed detection
      pure (EpisodeChange (Just finding) 1 0)
    Just episode -> do
      unless (episode.subject == observed.subject && episode.objective == observed.objective && episode.family == familyFor detection.kind) (throwE LedgerBindingConflict)
      if episode.lastSummaryDigest == digest
        then do
          execute "UPDATE shikigami.watchdog_episodes SET last_seen_sweep=$1->>'sweep' WHERE episode_id=$1->>'id'" (object ["sweep" .= sweep, "id" .= episode.episodeId])
          pure (EpisodeChange Nothing 0 1)
        else do
          finding <- persistFinding sweep instant identities.finding episode.episodeId observed detection
          execute "UPDATE shikigami.watchdog_episodes SET last_summary_digest=$1->>'digest',last_seen_sweep=$1->>'sweep',notified_count=notified_count+1 WHERE episode_id=$1->>'id'" (object ["digest" .= digest, "sweep" .= sweep, "id" .= episode.episodeId])
          pure (EpisodeChange (Just finding) 0 1)

validDetection :: Detection -> Bool
validDetection detection = case (detection.kind, detection.verdict, detection.summary.driftCategory) of
  (StuckWork, Stuck, Nothing) -> True
  (StuckCoordinatorWork, StuckCoordinator, Nothing) -> True
  (UnresolvedOutcome, Unresolved, Nothing) -> True
  (DriftWork, Progressing, Just category) -> category `elem` [PossibleDrift, OutsideScope]
  _ -> False

persistFinding :: SweepId -> UTCTime -> FindingId -> EpisodeId -> Observed -> Detection -> Checked Finding
persistFinding sweep instant identifier episode observed detection = do
  let view = FindingView identifier episode sweep observed.objective observed.subject detection.kind detection.evidence detection.window detection.limit
  execute
    "INSERT INTO shikigami.watchdog_findings(finding_id,episode_id,sweep_id,recorded_at,finding) VALUES ($1->>'id',$1->>'episode',$1->>'sweep',($1->>'at')::timestamptz,$1->'view') ON CONFLICT DO NOTHING"
    (object ["id" .= identifier, "episode" .= episode, "sweep" .= sweep, "at" .= instant, "view" .= view])
  actual <- row "SELECT finding FROM shikigami.watchdog_findings WHERE episode_id=$1->>'episode' AND sweep_id=$1->>'sweep'" (object ["episode" .= episode, "sweep" .= sweep]) >>= maybe (throwE LedgerBindingConflict) decoded
  unless (actual == view) (throwE LedgerBindingConflict)
  pure (Finding actual)

-- Retry reconstitutes the seal only after matching the retained finding row.
recoverFindings :: [FindingView] -> Checked [Finding]
recoverFindings = mapM \view -> do
  actual <- row "SELECT finding FROM shikigami.watchdog_findings WHERE finding_id=$1->>'id'" (object ["id" .= view.findingId]) >>= maybe (throwE LedgerCorrupt) decoded
  unless (actual == view) (throwE LedgerCorrupt)
  pure (Finding actual)

closeFamily :: SweepId -> DetectionFamily -> UTCTime -> Subject -> ClosureReason -> Checked Word
closeFamily sweep family instant subject reason = do
  closed <-
    rows
      "UPDATE shikigami.watchdog_episodes SET closed_at=($1->>'at')::timestamptz,closed_reason=$1->>'reason',last_seen_sweep=$1->>'sweep' WHERE subject_key=$1->>'key' AND family=$1->>'family' AND closed_at IS NULL RETURNING to_jsonb(episode_id)"
      (object ["at" .= instant, "reason" .= reason, "sweep" .= sweep, "key" .= subjectKey subject, "family" .= familyText family])
  pure (fromIntegral (length closed))

closeConfirmed :: SweepId -> UTCTime -> Subject -> ClosureReason -> Checked [EpisodeId]
closeConfirmed sweep instant subject reason = do
  lockSubject subject
  rows
    "UPDATE shikigami.watchdog_episodes SET closed_at=($1->>'at')::timestamptz,closed_reason=$1->>'reason',last_seen_sweep=$1->>'sweep' WHERE subject_key=$1->>'key' AND closed_at IS NULL RETURNING to_jsonb(episode_id)"
    (object ["at" .= instant, "reason" .= reason, "sweep" .= sweep, "key" .= subjectKey subject])
    >>= mapM decoded

episodeProjection :: Text
episodeProjection =
  """
  SELECT jsonb_build_object('episodeId',episode_id,'subject',subject,'objective',objective_id,
   'kind',jsonb_build_object('kind',kind),
   'family',jsonb_build_object('kind',family),
   'openedAt',opened_at,'openedSweep',opened_sweep,'closedAt',closed_at,'closedReason',closed_reason,
   'lastSummaryDigest',last_summary_digest,'lastSeenSweep',last_seen_sweep,'notifiedCount',notified_count)
  FROM shikigami.watchdog_episodes
  """

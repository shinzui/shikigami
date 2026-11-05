{-# LANGUAGE DataKinds #-}

-- | The only writer of the initiative tables. Every instant is a parameter
-- supplied from a journaled step value or the receipt path, and every write is
-- keyed, so a retried step converges rather than duplicating.
module Shikigami.Initiative.Ledger
  ( LedgerError (..),
    recordSkipTx,
    recordCandidateTx,
    candidateRecordedTx,
    markEvaluationStartedTx,
    markCandidateProposedTx,
    checkOwner,
    WindowUsage (..),
    Exhaustion (..),
    checkWindows,
    ProposalReceipt (..),
    ProposalDisposition (..),
    recordProposalTx,
    recordProposal,
    resolveProposal,
    readProposal,
    readPendingByKey,
    recordNotificationTx,
    listProposals,
    listCandidates,
    ObserverUsageView (..),
    observerUsage,
    countPendingProposals,
    pruneCandidatesBefore,
  )
where

import Contravariant.Extras (contrazip10, contrazip2, contrazip3, contrazip4, contrazip7)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.Time (addUTCTime)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Activity (ActivityId)
import Shikigami.Activity.Coordinate (activityCoordinate, activityCoordinateText)
import Shikigami.Agent.Principal (AgentPrincipal, mkAgentPrincipal, principalText)
import Shikigami.Duration (Duration, durationTime)
import Shikigami.Initiative.Settings (ObserverAllowance (..))
import Shikigami.Initiative.Types
import Shikigami.Objective.Keys (ObservedSource (..))
import Shikigami.Objective.Store (readObjectiveStatusTx)
import Shikigami.Objective.Types qualified as Objective
import Shikigami.Prelude hiding ((.=))
import Shikigami.StateRevision (StateRevision, advanceRevision, initialRevision, parseRevision, revisionNumber)

data LedgerError = LedgerCorrupt !Text | LedgerConflict | LedgerMissing
  deriving stock (Eq, Show)

-- | One bounded row per observer and activity. A skip never overwrites a verdict
-- that already moved past evaluation, and it carries no excerpt.
recordSkipTx :: AgentPrincipal -> UTCTime -> Maybe WorkflowId -> Either (SkipReason, ActivityId) (SkipReason, Observed) -> Transaction ()
recordSkipTx observer recordedAt run skip =
  Tx.statement
    ( principalText observer,
      activityCoordinateText activity,
      activityCoordinateText . (.source) <$> subject,
      activityCoordinateText . (.subjectKind) <$> subject,
      activityCoordinateText . (.subjectId) <$> subject,
      verdict,
      skipReasonText reason,
      proposalIdOf reason,
      fmap workflowText run,
      recordedAt
    )
    upsertSkip
  where
    (reason, activity, subject) = case skip of
      Left (why, identifier) -> (why, identifier, Nothing)
      Right (why, observed) -> (why, observed.activity, Just observed.subject)
    verdict = case reason of
      NotActionable -> "not-actionable"
      _ -> "skipped" :: Text
    proposalIdOf = \case
      AlreadyProposed proposal -> Just (proposalIdText proposal)
      _ -> Nothing

-- | The consumer writes this with the run's root and job. A redelivery keeps the
-- row it already has.
recordCandidateTx :: Candidate -> WorkflowId -> UTCTime -> Transaction ()
recordCandidateTx candidate run recordedAt =
  Tx.statement
    ( principalText facts.observer,
      activityCoordinateText facts.observed.activity,
      activityCoordinateText facts.observed.subject.source,
      activityCoordinateText facts.observed.subject.subjectKind,
      activityCoordinateText facts.observed.subject.subjectId,
      workflowText run,
      recordedAt
    )
    insertCandidate
  where
    facts = candidateFacts candidate

candidateRecordedTx :: AgentPrincipal -> ActivityId -> Transaction Bool
candidateRecordedTx observer activity =
  Tx.statement (principalText observer, activityCoordinateText activity) selectCandidateExists

-- | Spend the evaluation slot. Counting starts here, under the observer's anchor
-- lock, so concurrent runs cannot both take the last slot and a crashed retry
-- does not count itself.
markEvaluationStartedTx :: AgentPrincipal -> ActivityId -> UTCTime -> Transaction ()
markEvaluationStartedTx observer activity instant =
  Tx.statement (principalText observer, activityCoordinateText activity, instant) updateEvaluated

markCandidateProposedTx :: AgentPrincipal -> ActivityId -> ProposalId -> Transaction ()
markCandidateProposedTx observer activity proposal =
  Tx.statement (principalText observer, activityCoordinateText activity, proposalIdText proposal) updateProposed

-- | Is this source subject already somebody's? Pending proposals own it, as do
-- accepted or admitted ones whose objective is still open, and recent rejections
-- suppress it. An objective whose state cannot be read is treated as open: a
-- missed proposal is recoverable and a competing one is not.
checkOwner :: AgentPrincipal -> ObservedSource -> UTCTime -> Transaction (Either LedgerError (Either SkipReason ()))
checkOwner observer subject now = do
  pending <- Tx.statement key selectPendingId
  case pending of
    Just raw -> pure (either (const (Left (LedgerCorrupt "proposal id"))) (Right . Left . AlreadyProposed) (parseProposalId raw))
    Nothing -> do
      accepted <- Tx.statement key selectLatestAccepted
      owned <- case accepted of
        Nothing -> pure (Right Nothing)
        Just detail -> case Aeson.fromJSON detail of
          Aeson.Success (Accepted objective) -> Right <$> ownerIfOpen objective
          Aeson.Success (Admitted objective _) -> Right <$> ownerIfOpen objective
          _ -> pure (Left (LedgerCorrupt "proposal status"))
      case owned of
        Left problem -> pure (Left problem)
        Right (Just objective) -> pure (Right (Left (AlreadyOwned objective)))
        Right Nothing -> do
          suppressed <- Tx.statement (key, now) selectSuppression
          pure (Right (maybe (Right ()) (Left . Suppressed) suppressed))
  where
    key = proposalKeyText (proposalKeyFor observer subject)
    ownerIfOpen objective = do
      status <- readObjectiveStatusTx objective
      pure case status of
        Just (Right Objective.Completed) -> Nothing
        Just (Right Objective.Cancelled) -> Nothing
        Nothing -> Nothing
        _ -> Just objective

data WindowUsage = WindowUsage
  { evaluations :: !Int,
    proposals :: !Int,
    notifications :: !Int,
    exhausted :: ![Exhaustion]
  }
  deriving stock (Eq, Show)

data Exhaustion = EvaluationsAt !Int | ProposalsAt !Int | NotificationsAt !Int
  deriving stock (Eq, Show)

-- | Bounded indexed counts serialized by the observer's anchor row. The named
-- activity's own evaluation is not counted, so a retried step sees what it saw.
checkWindows :: ObserverAllowance -> Maybe ActivityId -> UTCTime -> Transaction WindowUsage
checkWindows allowance excluded now = do
  let observer = principalText allowance.principal
      since = addUTCTime (negate (durationTime allowance.window)) now
  Tx.statement observer insertAnchor
  Tx.statement observer lockAnchor
  evaluations <- fromIntegral <$> Tx.statement (observer, since, fmap activityCoordinateText excluded) countEvaluations
  proposals <- fromIntegral <$> Tx.statement (observer, since) countProposals
  notifications <- fromIntegral <$> Tx.statement (observer, since) countNotifications
  pure
    WindowUsage
      { evaluations,
        proposals,
        notifications,
        exhausted =
          [EvaluationsAt evaluations | evaluations >= initiativeLimitInt allowance.evaluationsPerWindow]
            <> [ProposalsAt proposals | proposals >= initiativeLimitInt allowance.proposalsPerWindow]
            <> [NotificationsAt notifications | notifications >= initiativeLimitInt allowance.notificationsPerWindow]
      }

data ProposalDisposition = Created | Converged
  deriving stock (Eq, Show)

data ProposalReceipt = ProposalReceipt
  { proposalId :: !ProposalId,
    disposition :: !ProposalDisposition,
    revision :: !(StateRevision "proposal")
  }
  deriving stock (Eq, Show)

-- | Converge on the pending row for the key. A row this same run wrote is its
-- own retry and stays 'Created'; another run's row wins and the supplied id is
-- discarded.
recordProposalTx :: ProposalId -> Candidate -> Assessment -> RequestedAuthority -> UTCTime -> Duration "initiative-proposal" -> WorkflowId -> Transaction (Either LedgerError ProposalReceipt)
recordProposalTx proposal candidate assessment requested now expiry run = do
  Tx.statement
    ( ( proposalIdText proposal,
        proposalKeyText key,
        principalText facts.observer,
        activityCoordinateText subject.source,
        activityCoordinateText subject.subjectKind,
        activityCoordinateText subject.subjectId,
        Aeson.toJSON (assessmentView assessment)
      ),
      ( Aeson.toJSON requested,
        Aeson.toJSON Pending,
        now,
        addUTCTime (durationTime expiry) now,
        revisionNumberInt (initialRevision @"proposal"),
        workflowText run
      )
    )
    insertProposal
  winner <- readPendingByKey key
  pure case winner of
    Left problem -> Left problem
    Right Nothing -> Left LedgerConflict
    Right (Just stored) ->
      Right
        ProposalReceipt
          { proposalId = stored.proposalId,
            disposition = if stored.proposalId == proposal || stored.runId == run then Created else Converged,
            revision = stored.revision
          }
  where
    facts = candidateFacts candidate
    subject = facts.observed.subject
    key = proposalKeyFor facts.observer subject

recordProposal :: (Store :> es) => ProposalId -> Candidate -> Assessment -> RequestedAuthority -> UTCTime -> Duration "initiative-proposal" -> WorkflowId -> Eff es (Either LedgerError ProposalReceipt)
recordProposal proposal candidate assessment requested now expiry run =
  runTransaction (recordProposalTx proposal candidate assessment requested now expiry run)

-- | Resolve a pending proposal at its exact revision. A retry whose earlier
-- attempt already committed the same resolution succeeds with that revision.
resolveProposal :: ProposalId -> StateRevision "proposal" -> ProposalStatus -> UTCTime -> Duration "initiative-suppression" -> Transaction (Either LedgerError (StateRevision "proposal"))
resolveProposal proposal expected status now suppression = do
  updated <-
    Tx.statement
      ( proposalIdText proposal,
        revisionNumberInt expected,
        proposalStatusTag status,
        Aeson.toJSON status,
        now,
        suppressedUntil
      )
      updateResolution
  case updated of
    Just stored -> pure (either (Left . LedgerCorrupt) Right (parseRevision (toInteger stored)))
    Nothing -> do
      current <- readProposal proposal
      pure case current of
        Left problem -> Left problem
        Right Nothing -> Left LedgerMissing
        Right (Just row)
          | proposalStatusTag row.status == proposalStatusTag status && row.revision == advanceRevision expected -> Right row.revision
          | otherwise -> Left LedgerConflict
  where
    suppressedUntil = case status of
      Rejected _ -> Just (addUTCTime (durationTime suppression) now)
      Expired _ -> Just (addUTCTime (durationTime suppression) now)
      _ -> Nothing

readProposal :: ProposalId -> Transaction (Either LedgerError (Maybe Proposal))
readProposal proposal = decodeMaybe <$> Tx.statement (proposalIdText proposal) selectProposal

readPendingByKey :: ProposalKey -> Transaction (Either LedgerError (Maybe Proposal))
readPendingByKey key = decodeMaybe <$> Tx.statement (proposalKeyText key) selectPendingProposal

-- | The ask left: it counts toward the observer's notification window.
recordNotificationTx :: ProposalId -> UTCTime -> Transaction ()
recordNotificationTx proposal instant = Tx.statement (proposalIdText proposal, instant) updateNotified

-- | One keyset page in proposal-id order, at most 100 rows. Lock-free.
listProposals :: Maybe AgentPrincipal -> Maybe Text -> Maybe ProposalId -> Int -> Transaction (Either LedgerError [ProposalView])
listProposals observer status after limit =
  fmap (map proposalView) . traverse decodeProposal
    <$> Tx.statement (principalText <$> observer, status, proposalIdText <$> after, pageSize limit) selectProposals

-- | One keyset page of an observer's candidates in recording order.
listCandidates :: AgentPrincipal -> Maybe UTCTime -> Maybe ActivityId -> Int -> Transaction [CandidateView]
listCandidates observer since after limit =
  Tx.statement (principalText observer, since, activityCoordinateText <$> after, pageSize limit) selectCandidates

pageSize :: Int -> Int64
pageSize = fromIntegral . max 1 . min 100

-- | What an operator reads: counts beside limits, and an explicit exhausted state.
-- An observer with no rows shows zero usage, so quiet is distinct from absent.
data ObserverUsageView = ObserverUsageView
  { observer :: !Text,
    evaluations :: !Int,
    evaluationsPerWindow :: !Int,
    proposals :: !Int,
    proposalsPerWindow :: !Int,
    notifications :: !Int,
    notificationsPerWindow :: !Int,
    windowSeconds :: !Double,
    exhausted :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The same arithmetic as 'checkWindows' without taking the observer's anchor.
observerUsage :: ObserverAllowance -> UTCTime -> Transaction ObserverUsageView
observerUsage allowance now = do
  let observer = principalText allowance.principal
      since = addUTCTime (negate (durationTime allowance.window)) now
  evaluations <- fromIntegral <$> Tx.statement (observer, since, Nothing) countEvaluations
  proposals <- fromIntegral <$> Tx.statement (observer, since) countProposals
  notifications <- fromIntegral <$> Tx.statement (observer, since) countNotifications
  let evaluationsPerWindow = initiativeLimitInt allowance.evaluationsPerWindow
      proposalsPerWindow = initiativeLimitInt allowance.proposalsPerWindow
      notificationsPerWindow = initiativeLimitInt allowance.notificationsPerWindow
  pure
    ObserverUsageView
      { observer,
        evaluations,
        evaluationsPerWindow,
        proposals,
        proposalsPerWindow,
        notifications,
        notificationsPerWindow,
        windowSeconds = realToFrac (durationTime allowance.window),
        exhausted =
          ["evaluations" | evaluations >= evaluationsPerWindow]
            <> ["proposals" | proposals >= proposalsPerWindow]
            <> ["notifications" | notifications >= notificationsPerWindow]
      }

countPendingProposals :: Transaction Int
countPendingProposals = fromIntegral <$> Tx.statement () selectPendingCount

-- | Delete terminal skips older than an instant, a bounded batch at a time. It
-- never touches an evaluating or proposed candidate, or any proposal.
pruneCandidatesBefore :: UTCTime -> Int -> Transaction Int
pruneCandidatesBefore before batch = fromIntegral <$> Tx.statement (before, fromIntegral (max 1 (min 10000 batch))) deleteTerminalCandidates

decodeMaybe :: Maybe ProposalRow -> Either LedgerError (Maybe Proposal)
decodeMaybe = traverse decodeProposal

decodeProposal :: ProposalRow -> Either LedgerError Proposal
decodeProposal row = do
  proposalId <- corrupt "proposal id" (parseProposalId row.proposalId)
  key <- corrupt "proposal key" (parseProposalKey row.key)
  observer <- corrupt "observer" (mkAgentPrincipal row.observer)
  assessment <- json "assessment" row.assessment
  requested <- json "requested authority" row.requested
  status <- json "status" row.status
  revision <- corrupt "revision" (parseRevision (toInteger row.revision))
  pure
    Proposal
      { proposalId,
        key,
        observer,
        subject =
          ObservedSource
            { source = activityCoordinate row.source,
              subjectKind = activityCoordinate row.subjectKind,
              subjectId = activityCoordinate row.subjectId
            },
        assessment,
        requested,
        status,
        proposedAt = row.proposedAt,
        expiresAt = row.expiresAt,
        resolvedAt = row.resolvedAt,
        suppressedUntil = row.suppressedUntil,
        revision,
        runId = WorkflowId row.runWorkflowId
      }
  where
    corrupt :: Text -> Either Text value -> Either LedgerError value
    corrupt label = either (const (Left (LedgerCorrupt label))) Right
    json :: (FromJSON value) => Text -> Aeson.Value -> Either LedgerError value
    json label value = case Aeson.fromJSON value of
      Aeson.Success decoded -> Right decoded
      Aeson.Error _ -> Left (LedgerCorrupt label)

data ProposalRow = ProposalRow
  { proposalId :: !Text,
    key :: !Text,
    observer :: !Text,
    source :: !Text,
    subjectKind :: !Text,
    subjectId :: !Text,
    assessment :: !Aeson.Value,
    requested :: !Aeson.Value,
    status :: !Aeson.Value,
    proposedAt :: !UTCTime,
    expiresAt :: !UTCTime,
    resolvedAt :: !(Maybe UTCTime),
    suppressedUntil :: !(Maybe UTCTime),
    revision :: !Int64,
    runWorkflowId :: !Text
  }

proposalRow :: D.Row ProposalRow
proposalRow =
  ProposalRow
    <$> text
    <*> text
    <*> text
    <*> text
    <*> text
    <*> text
    <*> json
    <*> json
    <*> json
    <*> instant
    <*> instant
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nonNullable D.int8)
    <*> text
  where
    text = D.column (D.nonNullable D.text)
    json = D.column (D.nonNullable D.jsonb)
    instant = D.column (D.nonNullable D.timestamptz)

proposalColumns :: Text
proposalColumns = "proposal_id,proposal_key,observer,source,subject_kind,subject_id,assessment,requested,status_detail,proposed_at,expires_at,resolved_at,suppressed_until,revision::bigint,run_workflow_id"

workflowText :: WorkflowId -> Text
workflowText (WorkflowId value) = value

revisionNumberInt :: StateRevision scope -> Int64
revisionNumberInt = fromInteger . revisionNumber

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

nullableText :: E.Params (Maybe Text)
nullableText = E.param (E.nullable E.text)

instantParam :: E.Params UTCTime
instantParam = E.param (E.nonNullable E.timestamptz)

jsonParam :: E.Params Aeson.Value
jsonParam = E.param (E.nonNullable E.jsonb)

upsertSkip :: Statement (Text, Text, Maybe Text, Maybe Text, Maybe Text, Text, Text, Maybe Text, Maybe Text, UTCTime) ()
upsertSkip =
  preparable
    "INSERT INTO shikigami.initiative_candidates (observer,activity_id,source,subject_kind,subject_id,verdict,skip_reason,proposal_id,run_workflow_id,recorded_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) ON CONFLICT (observer,activity_id) DO UPDATE SET verdict=EXCLUDED.verdict, skip_reason=EXCLUDED.skip_reason, proposal_id=EXCLUDED.proposal_id WHERE shikigami.initiative_candidates.verdict='evaluating'"
    (contrazip10 textParam textParam nullableText nullableText nullableText textParam textParam nullableText nullableText instantParam)
    D.noResult

insertCandidate :: Statement (Text, Text, Text, Text, Text, Text, UTCTime) ()
insertCandidate =
  preparable
    "INSERT INTO shikigami.initiative_candidates (observer,activity_id,source,subject_kind,subject_id,verdict,run_workflow_id,recorded_at) VALUES ($1,$2,$3,$4,$5,'evaluating',$6,$7) ON CONFLICT (observer,activity_id) DO NOTHING"
    (contrazip7 textParam textParam textParam textParam textParam textParam instantParam)
    D.noResult

selectCandidateExists :: Statement (Text, Text) Bool
selectCandidateExists =
  preparable
    "SELECT EXISTS (SELECT 1 FROM shikigami.initiative_candidates WHERE observer=$1 AND activity_id=$2)"
    (contrazip2 textParam textParam)
    (D.singleRow (D.column (D.nonNullable D.bool)))

updateEvaluated :: Statement (Text, Text, UTCTime) ()
updateEvaluated =
  preparable
    "UPDATE shikigami.initiative_candidates SET evaluated_at=COALESCE(evaluated_at,$3) WHERE observer=$1 AND activity_id=$2"
    (contrazip3 textParam textParam instantParam)
    D.noResult

updateProposed :: Statement (Text, Text, Text) ()
updateProposed =
  preparable
    "UPDATE shikigami.initiative_candidates SET verdict='proposed', proposal_id=$3, skip_reason=NULL WHERE observer=$1 AND activity_id=$2"
    (contrazip3 textParam textParam textParam)
    D.noResult

selectPendingId :: Statement Text (Maybe Text)
selectPendingId =
  preparable
    "SELECT proposal_id FROM shikigami.initiative_proposals WHERE proposal_key=$1 AND status='pending'"
    textParam
    (D.rowMaybe (D.column (D.nonNullable D.text)))

selectLatestAccepted :: Statement Text (Maybe Aeson.Value)
selectLatestAccepted =
  preparable
    "SELECT status_detail FROM shikigami.initiative_proposals WHERE proposal_key=$1 AND status IN ('accepted','admitted') ORDER BY proposed_at DESC, proposal_id DESC LIMIT 1"
    textParam
    (D.rowMaybe (D.column (D.nonNullable D.jsonb)))

selectSuppression :: Statement (Text, UTCTime) (Maybe UTCTime)
selectSuppression =
  preparable
    "SELECT suppressed_until FROM shikigami.initiative_proposals WHERE proposal_key=$1 AND status IN ('rejected','expired') AND suppressed_until > $2 ORDER BY suppressed_until DESC LIMIT 1"
    (contrazip2 textParam instantParam)
    (D.rowMaybe (D.column (D.nonNullable D.timestamptz)))

insertAnchor :: Statement Text ()
insertAnchor =
  preparable
    "INSERT INTO shikigami.initiative_observers (observer) VALUES ($1) ON CONFLICT (observer) DO NOTHING"
    textParam
    D.noResult

lockAnchor :: Statement Text ()
lockAnchor =
  preparable
    "SELECT observer FROM shikigami.initiative_observers WHERE observer=$1 FOR UPDATE"
    textParam
    D.noResult

countEvaluations :: Statement (Text, UTCTime, Maybe Text) Int64
countEvaluations =
  preparable
    "SELECT count(*) FROM shikigami.initiative_candidates WHERE observer=$1 AND evaluated_at > $2 AND ($3::text IS NULL OR activity_id <> $3)"
    (contrazip3 textParam instantParam nullableText)
    (D.singleRow (D.column (D.nonNullable D.int8)))

countProposals :: Statement (Text, UTCTime) Int64
countProposals =
  preparable
    "SELECT count(*) FROM shikigami.initiative_proposals WHERE observer=$1 AND proposed_at > $2"
    (contrazip2 textParam instantParam)
    (D.singleRow (D.column (D.nonNullable D.int8)))

countNotifications :: Statement (Text, UTCTime) Int64
countNotifications =
  preparable
    "SELECT count(*) FROM shikigami.initiative_proposals WHERE observer=$1 AND notified_at > $2"
    (contrazip2 textParam instantParam)
    (D.singleRow (D.column (D.nonNullable D.int8)))

insertProposal :: Statement ((Text, Text, Text, Text, Text, Text, Aeson.Value), (Aeson.Value, Aeson.Value, UTCTime, UTCTime, Int64, Text)) ()
insertProposal =
  preparable
    "INSERT INTO shikigami.initiative_proposals (proposal_id,proposal_key,observer,source,subject_kind,subject_id,assessment,requested,status,status_detail,proposed_at,expires_at,revision,run_workflow_id) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,'pending',$9,$10,$11,$12::bigint,$13) ON CONFLICT (proposal_key) WHERE status='pending' DO NOTHING"
    (contrazip2 (contrazip7 textParam textParam textParam textParam textParam textParam jsonParam) (contrazip6Local))
    D.noResult
  where
    contrazip6Local =
      (\(a, b, c, d, e, f) -> (a, (b, (c, (d, (e, f)))))) >$< contrazip2 jsonParam (contrazip2 jsonParam (contrazip2 instantParam (contrazip2 instantParam (contrazip2 (E.param (E.nonNullable E.int8)) textParam))))

updateResolution :: Statement (Text, Int64, Text, Aeson.Value, UTCTime, Maybe UTCTime) (Maybe Int64)
updateResolution =
  preparable
    "UPDATE shikigami.initiative_proposals SET status=$3, status_detail=$4, resolved_at=$5, suppressed_until=$6, revision=revision+1 WHERE proposal_id=$1 AND revision=$2::bigint AND status='pending' RETURNING revision::bigint"
    ((\(a, b, c, d, e, f) -> (a, (b, (c, (d, (e, f)))))) >$< contrazip2 textParam (contrazip2 (E.param (E.nonNullable E.int8)) (contrazip2 textParam (contrazip2 jsonParam (contrazip2 instantParam (E.param (E.nullable E.timestamptz)))))))
    (D.rowMaybe (D.column (D.nonNullable D.int8)))

selectProposal :: Statement Text (Maybe ProposalRow)
selectProposal =
  preparable
    ("SELECT " <> proposalColumns <> " FROM shikigami.initiative_proposals WHERE proposal_id=$1")
    textParam
    (D.rowMaybe proposalRow)

selectPendingProposal :: Statement Text (Maybe ProposalRow)
selectPendingProposal =
  preparable
    ("SELECT " <> proposalColumns <> " FROM shikigami.initiative_proposals WHERE proposal_key=$1 AND status='pending'")
    textParam
    (D.rowMaybe proposalRow)

updateNotified :: Statement (Text, UTCTime) ()
updateNotified =
  preparable
    "UPDATE shikigami.initiative_proposals SET notified_at=COALESCE(notified_at,$2) WHERE proposal_id=$1"
    (contrazip2 textParam instantParam)
    D.noResult

selectProposals :: Statement (Maybe Text, Maybe Text, Maybe Text, Int64) [ProposalRow]
selectProposals =
  preparable
    ("SELECT " <> proposalColumns <> " FROM shikigami.initiative_proposals WHERE ($1::text IS NULL OR observer=$1) AND ($2::text IS NULL OR status=$2) AND ($3::text IS NULL OR proposal_id > $3) ORDER BY proposal_id LIMIT $4")
    (contrazip4 nullableText nullableText nullableText (E.param (E.nonNullable E.int8)))
    (D.rowList proposalRow)

selectCandidates :: Statement (Text, Maybe UTCTime, Maybe Text, Int64) [CandidateView]
selectCandidates =
  preparable
    "SELECT observer,activity_id,source,subject_kind,subject_id,verdict,skip_reason,proposal_id,run_workflow_id,recorded_at FROM shikigami.initiative_candidates WHERE observer=$1 AND ($2::timestamptz IS NULL OR recorded_at >= $2) AND ($3::text IS NULL OR activity_id > $3) ORDER BY recorded_at, activity_id LIMIT $4"
    (contrazip4 textParam (E.param (E.nullable E.timestamptz)) nullableText (E.param (E.nonNullable E.int8)))
    ( D.rowList
        ( CandidateView
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nonNullable D.timestamptz)
        )
    )

selectPendingCount :: Statement () Int64
selectPendingCount =
  preparable
    "SELECT count(*) FROM shikigami.initiative_proposals WHERE status='pending'"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.int8)))

deleteTerminalCandidates :: Statement (UTCTime, Int64) Int64
deleteTerminalCandidates =
  preparable
    "DELETE FROM shikigami.initiative_candidates WHERE (observer,activity_id) IN (SELECT observer,activity_id FROM shikigami.initiative_candidates WHERE verdict IN ('skipped','not-actionable') AND recorded_at < $1 ORDER BY recorded_at LIMIT $2)"
    (contrazip2 instantParam (E.param (E.nonNullable E.int8)))
    D.rowsAffected

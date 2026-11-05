{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | The unrequested-work vocabulary, including the private constructors of the
-- sealed values. Only the pre-filter and the assessment validator import this
-- module; every other reader uses "Shikigami.Initiative.Types".
module Shikigami.Initiative.Types.Internal
  ( -- * Allocated identities
    ProposalId,
    newProposalId,
    parseProposalId,
    proposalIdText,
    proposalRefFor,
    StandingPolicyId,
    newStandingPolicyId,
    parseStandingPolicyId,
    standingPolicyIdText,

    -- * Closed vocabulary
    SourceKind (..),
    sourceKindText,
    parseSourceKind,
    ActionClass (..),
    actionClassText,
    parseActionClass,
    allActionClasses,
    SkipReason (..),
    skipReasonText,
    RefusalKind (..),
    refusalKindText,
    parseRefusalKind,
    ProposalStatus (..),
    proposalStatusTag,

    -- * Checked values
    Excerpt,
    parseExcerpt,
    excerptText,
    ExcerptDigest,
    excerptDigestFor,
    Confidence,
    parseConfidence,
    confidenceNumber,
    OutcomeText,
    parseOutcomeText,
    outcomeText,
    CriterionText,
    parseCriterionText,
    criterionText,
    InitiativeLimit,
    parseInitiativeLimit,
    initiativeLimitInt,

    -- * Evidence and keys
    EvidenceRef (..),
    ProposalKey,
    proposalKeyFor,
    proposalKeyText,
    parseProposalKey,
    Observed (..),
    observedSourceOf,

    -- * Sealed candidates and assessments
    AllowanceView (..),
    Candidate (..),
    CandidateFacts (..),
    candidateFacts,
    Assessment (..),
    AssessmentFacts (..),
    assessmentFacts,
    RequestedAuthority (..),

    -- * Durable proposals and read views
    Proposal (..),
    AssessmentView (..),
    assessmentView,
    CandidateView (..),
    candidateView,
    ProposalView (..),
    proposalView,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser)
import Data.Bifunctor (first)
import Data.Char (isControl, isHexDigit)
import Data.KindID.V7 qualified as KindID
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import GHC.TypeLits (Symbol)
import Keiro.Workflow.Types (WorkflowId (..))
import Shikigami.Activity (ActivityId, Actor)
import Shikigami.Activity.Coordinate (activityCoordinateText)
import Shikigami.Agent.Principal (AgentPrincipal, principalText)
import Shikigami.Decision.Contract (FailureCode)
import Shikigami.Duration (Duration)
import Shikigami.Execution.Coordinate (ExecutionDigest, executionDigest, executionDigestFor, executionDigestText)
import Shikigami.Execution.Resources (Limits)
import Shikigami.Generated.Nominals (ObjectiveId)
import Shikigami.Objective.Keys (ObservedSource (..), ProposalRef, parseProposalRef)
import Shikigami.Repository (RepositoryId, repositoryIdText)
import Shikigami.StateRevision (StateRevision, revisionNumber)

newtype ProposalId = ProposalId (KindID.KindID "shikigami_proposal")
  deriving stock (Eq, Ord, Show)

newProposalId :: IO ProposalId
newProposalId = ProposalId <$> KindID.genKindID @"shikigami_proposal"

parseProposalId :: Text -> Either Text ProposalId
parseProposalId input = do
  value <- first (const "invalid ProposalId encoding or prefix") (KindID.parseText @"shikigami_proposal" input)
  case KindID.checkKindID value of
    Just _ -> Left "ProposalId requires UUIDv7"
    Nothing
      | KindID.toText value == input -> Right (ProposalId value)
      | otherwise -> Left "ProposalId requires canonical encoding"

proposalIdText :: ProposalId -> Text
proposalIdText (ProposalId value) = KindID.toText value

instance ToJSON ProposalId where
  toJSON = toJSON . proposalIdText
  toEncoding = toEncoding . proposalIdText

instance FromJSON ProposalId where
  parseJSON = withText "ProposalId" (either (fail . Text.unpack) pure . parseProposalId)

-- | The objective owner links proposals nominally. A 'ProposalId' is already
-- canonical, so the reference parser accepting it is an invariant of this module.
proposalRefFor :: ProposalId -> ProposalRef
proposalRefFor identifier = case parseProposalRef (proposalIdText identifier) of
  Right reference -> reference
  Left problem -> error (Text.unpack problem)

newtype StandingPolicyId = StandingPolicyId (KindID.KindID "shikigami_standing_policy")
  deriving stock (Eq, Ord, Show)

newStandingPolicyId :: IO StandingPolicyId
newStandingPolicyId = StandingPolicyId <$> KindID.genKindID @"shikigami_standing_policy"

parseStandingPolicyId :: Text -> Either Text StandingPolicyId
parseStandingPolicyId input = do
  value <- first (const "invalid StandingPolicyId encoding or prefix") (KindID.parseText @"shikigami_standing_policy" input)
  case KindID.checkKindID value of
    Just _ -> Left "StandingPolicyId requires UUIDv7"
    Nothing
      | KindID.toText value == input -> Right (StandingPolicyId value)
      | otherwise -> Left "StandingPolicyId requires canonical encoding"

standingPolicyIdText :: StandingPolicyId -> Text
standingPolicyIdText (StandingPolicyId value) = KindID.toText value

instance ToJSON StandingPolicyId where
  toJSON = toJSON . standingPolicyIdText
  toEncoding = toEncoding . standingPolicyIdText

instance FromJSON StandingPolicyId where
  parseJSON = withText "StandingPolicyId" (either (fail . Text.unpack) pure . parseStandingPolicyId)

data SourceKind = IntercomConversation | MeetingTranscript | ChatFixture
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

sourceKindText :: SourceKind -> Text
sourceKindText = \case
  IntercomConversation -> "intercom-conversation"
  MeetingTranscript -> "meeting-transcript"
  ChatFixture -> "chat-fixture"

parseSourceKind :: Text -> Either Text SourceKind
parseSourceKind = \case
  "intercom-conversation" -> Right IntercomConversation
  "meeting-transcript" -> Right MeetingTranscript
  "chat-fixture" -> Right ChatFixture
  _ -> Left "unknown source kind"

instance ToJSON SourceKind where toJSON = toJSON . sourceKindText

instance FromJSON SourceKind where
  parseJSON = withText "source kind" (either (fail . Text.unpack) pure . parseSourceKind)

-- | What an unrequested objective may set out to do. There is deliberately no
-- publishing or merging constructor: no policy can express that permission.
data ActionClass = ReproduceAndDiagnose | DraftFix | DraftDocumentation
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

actionClassText :: ActionClass -> Text
actionClassText = \case
  ReproduceAndDiagnose -> "reproduce-and-diagnose"
  DraftFix -> "draft-fix"
  DraftDocumentation -> "draft-documentation"

parseActionClass :: Text -> Either Text ActionClass
parseActionClass = \case
  "reproduce-and-diagnose" -> Right ReproduceAndDiagnose
  "draft-fix" -> Right DraftFix
  "draft-documentation" -> Right DraftDocumentation
  _ -> Left "unknown action class"

allActionClasses :: NonEmpty ActionClass
allActionClasses = ReproduceAndDiagnose :| [DraftFix, DraftDocumentation]

instance ToJSON ActionClass where toJSON = toJSON . actionClassText

instance FromJSON ActionClass where
  parseJSON = withText "action class" (either (fail . Text.unpack) pure . parseActionClass)

data SkipReason
  = UnsupportedSource
  | AgentActor
  | ExcerptTooShort
  | ExcerptTooLong
  | NoObserverAllowance
  | SourceNotPermitted
  | NoRepositories
  | EvaluationsExhausted
  | ProposalsExhausted
  | NotificationsExhausted
  | AlreadyProposed !ProposalId
  | AlreadyOwned !ObjectiveId
  | -- | The ledger could not answer. Not evidence that nobody owns the subject.
    OwnerUnknown
  | Suppressed !UTCTime
  | NotActionable
  | DecisionRefused !FailureCode
  deriving stock (Eq, Show)

-- | The bounded tag, without payload, that ledger rows and metrics carry.
skipReasonText :: SkipReason -> Text
skipReasonText = \case
  UnsupportedSource -> "unsupported-source"
  AgentActor -> "agent-actor"
  ExcerptTooShort -> "excerpt-too-short"
  ExcerptTooLong -> "excerpt-too-long"
  NoObserverAllowance -> "no-observer-allowance"
  SourceNotPermitted -> "source-not-permitted"
  NoRepositories -> "no-repositories"
  EvaluationsExhausted -> "evaluations-exhausted"
  ProposalsExhausted -> "proposals-exhausted"
  NotificationsExhausted -> "notifications-exhausted"
  AlreadyProposed _ -> "already-proposed"
  AlreadyOwned _ -> "already-owned"
  OwnerUnknown -> "owner-unknown"
  Suppressed _ -> "suppressed"
  NotActionable -> "not-actionable"
  DecisionRefused _ -> "decision-refused"

instance ToJSON SkipReason where
  toJSON reason = object (("reason" .= skipReasonText reason) : payload)
    where
      payload = case reason of
        AlreadyProposed proposal -> ["proposalId" .= proposal]
        AlreadyOwned objective -> ["objectiveId" .= objective]
        Suppressed until' -> ["until" .= until']
        DecisionRefused code -> ["failure" .= code]
        _ -> []

instance FromJSON SkipReason where
  parseJSON = withObject "skip reason" \fields -> do
    tag <- fields .: "reason"
    case tag :: Text of
      "unsupported-source" -> pure UnsupportedSource
      "agent-actor" -> pure AgentActor
      "excerpt-too-short" -> pure ExcerptTooShort
      "excerpt-too-long" -> pure ExcerptTooLong
      "no-observer-allowance" -> pure NoObserverAllowance
      "source-not-permitted" -> pure SourceNotPermitted
      "no-repositories" -> pure NoRepositories
      "evaluations-exhausted" -> pure EvaluationsExhausted
      "proposals-exhausted" -> pure ProposalsExhausted
      "notifications-exhausted" -> pure NotificationsExhausted
      "already-proposed" -> AlreadyProposed <$> fields .: "proposalId"
      "already-owned" -> AlreadyOwned <$> fields .: "objectiveId"
      "owner-unknown" -> pure OwnerUnknown
      "suppressed" -> Suppressed <$> fields .: "until"
      "not-actionable" -> pure NotActionable
      "decision-refused" -> DecisionRefused <$> fields .: "failure"
      _ -> fail "unknown skip reason"

data RefusalKind = CreationDenied | AdmissionRefused | AcceptanceFailed
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

refusalKindText :: RefusalKind -> Text
refusalKindText = \case
  CreationDenied -> "creation-denied"
  AdmissionRefused -> "admission-refused"
  AcceptanceFailed -> "acceptance-failed"

parseRefusalKind :: Text -> Either Text RefusalKind
parseRefusalKind = \case
  "creation-denied" -> Right CreationDenied
  "admission-refused" -> Right AdmissionRefused
  "acceptance-failed" -> Right AcceptanceFailed
  _ -> Left "unknown refusal kind"

instance ToJSON RefusalKind where toJSON = toJSON . refusalKindText

instance FromJSON RefusalKind where
  parseJSON = withText "refusal kind" (either (fail . Text.unpack) pure . parseRefusalKind)

data ProposalStatus
  = Pending
  | Accepted !ObjectiveId
  | Admitted !ObjectiveId !StandingPolicyId
  | Rejected !UTCTime
  | Expired !UTCTime
  | Refused !RefusalKind
  deriving stock (Eq, Show)

proposalStatusTag :: ProposalStatus -> Text
proposalStatusTag = \case
  Pending -> "pending"
  Accepted _ -> "accepted"
  Admitted _ _ -> "admitted"
  Rejected _ -> "rejected"
  Expired _ -> "expired"
  Refused _ -> "refused"

instance ToJSON ProposalStatus where
  toJSON status = object (("status" .= proposalStatusTag status) : payload)
    where
      payload = case status of
        Pending -> []
        Accepted objective -> ["objectiveId" .= objective]
        Admitted objective policy -> ["objectiveId" .= objective, "policyId" .= policy]
        Rejected at -> ["at" .= at]
        Expired at -> ["at" .= at]
        Refused kind -> ["refusal" .= kind]

instance FromJSON ProposalStatus where
  parseJSON = withObject "proposal status" \fields -> do
    tag <- fields .: "status"
    case tag :: Text of
      "pending" -> pure Pending
      "accepted" -> Accepted <$> fields .: "objectiveId"
      "admitted" -> Admitted <$> fields .: "objectiveId" <*> fields .: "policyId"
      "rejected" -> Rejected <$> fields .: "at"
      "expired" -> Expired <$> fields .: "at"
      "refused" -> Refused <$> fields .: "refusal"
      _ -> fail "unknown proposal status"

-- | Observed text is evidence. It renders nowhere by accident and decodes from
-- no untrusted document: only the envelope adapter parses one.
newtype Excerpt = Excerpt Text
  deriving stock (Eq)

instance Show Excerpt where
  show _ = "Excerpt <protected>"

parseExcerpt :: Text -> Either Text Excerpt
parseExcerpt value
  | Text.null value || Text.length value > 8192 = Left "excerpt must contain 1..8192 characters"
  | Text.any disallowed value = Left "excerpt must not contain control characters"
  | otherwise = Right (Excerpt value)
  where
    disallowed c = isControl c && c /= '\n' && c /= '\t'

excerptText :: Excerpt -> Text
excerptText (Excerpt value) = value

instance ToJSON Excerpt where
  toJSON = toJSON . excerptText
  toEncoding = toEncoding . excerptText

type ExcerptDigest = ExecutionDigest "initiative-excerpt"

excerptDigestFor :: Excerpt -> ExcerptDigest
excerptDigestFor excerpt = executionDigestFor "shikigami.initiative-excerpt/1" (object ["excerpt" .= excerptText excerpt])

newtype Confidence = Confidence Double
  deriving stock (Eq, Ord, Show)

parseConfidence :: Double -> Either Text Confidence
parseConfidence value
  | isNaN value || isInfinite value || value < 0 || value > 1 = Left "confidence must be a finite number in 0..1"
  | otherwise = Right (Confidence value)

confidenceNumber :: Confidence -> Double
confidenceNumber (Confidence value) = value

instance ToJSON Confidence where
  toJSON = toJSON . confidenceNumber
  toEncoding = toEncoding . confidenceNumber

instance FromJSON Confidence where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseConfidence

boundedText :: Text -> Text -> Either Text Text
boundedText label value
  | Text.null value || Text.length value > 1024 = Left (label <> " must contain 1..1024 characters")
  | otherwise = Right value

newtype OutcomeText = OutcomeText Text
  deriving stock (Eq, Ord, Show)

parseOutcomeText :: Text -> Either Text OutcomeText
parseOutcomeText = fmap OutcomeText . boundedText "outcome"

outcomeText :: OutcomeText -> Text
outcomeText (OutcomeText value) = value

instance ToJSON OutcomeText where
  toJSON = toJSON . outcomeText
  toEncoding = toEncoding . outcomeText

instance FromJSON OutcomeText where
  parseJSON = withText "outcome" (either (fail . Text.unpack) pure . parseOutcomeText)

newtype CriterionText = CriterionText Text
  deriving stock (Eq, Ord, Show)

parseCriterionText :: Text -> Either Text CriterionText
parseCriterionText = fmap CriterionText . boundedText "criterion"

criterionText :: CriterionText -> Text
criterionText (CriterionText value) = value

instance ToJSON CriterionText where
  toJSON = toJSON . criterionText
  toEncoding = toEncoding . criterionText

instance FromJSON CriterionText where
  parseJSON = withText "criterion" (either (fail . Text.unpack) pure . parseCriterionText)

-- Scope roles keep limits with different policy meanings non-interchangeable.
type role InitiativeLimit nominal

newtype InitiativeLimit (scope :: Symbol) = InitiativeLimit Int
  deriving stock (Eq, Ord, Show)

parseInitiativeLimit :: Int -> Either Text (InitiativeLimit scope)
parseInitiativeLimit number
  | number > 0 && number <= 16777216 = Right (InitiativeLimit number)
  | otherwise = Left "initiative limits must be in 1..16777216"

initiativeLimitInt :: InitiativeLimit scope -> Int
initiativeLimitInt (InitiativeLimit value) = value

instance ToJSON (InitiativeLimit scope) where
  toJSON = toJSON . initiativeLimitInt
  toEncoding = toEncoding . initiativeLimitInt

instance FromJSON (InitiativeLimit scope) where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseInitiativeLimit

-- | Evidence is linked by coordinate and digest. It never carries a body.
data EvidenceRef = EvidenceRef
  { activity :: !ActivityId,
    subject :: !ObservedSource,
    occurredAt :: !UTCTime,
    digest :: !ExcerptDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype ProposalKey = ProposalKey (ExecutionDigest "proposal-key")
  deriving stock (Eq, Ord, Show)

-- | One observer and one source subject own at most one pending proposal. The
-- activity is absent on purpose: every restatement has a new one.
proposalKeyFor :: AgentPrincipal -> ObservedSource -> ProposalKey
proposalKeyFor observer subject =
  ProposalKey
    ( executionDigestFor
        "shikigami.proposal-key/1"
        ( object
            [ "observer" .= principalText observer,
              "source" .= subject.source,
              "subjectKind" .= subject.subjectKind,
              "subjectId" .= subject.subjectId
            ]
        )
    )

proposalKeyText :: ProposalKey -> Text
proposalKeyText (ProposalKey digest) = executionDigestText digest

parseProposalKey :: Text -> Either Text ProposalKey
parseProposalKey value
  | Text.length value == 71 && "sha256:" `Text.isPrefixOf` value && Text.all isHexDigit (Text.drop 7 value) = Right (ProposalKey (executionDigest value))
  | otherwise = Left "invalid proposal key"

instance ToJSON ProposalKey where
  toJSON = toJSON . proposalKeyText
  toEncoding = toEncoding . proposalKeyText

instance FromJSON ProposalKey where
  parseJSON = withText "proposal key" (either (fail . Text.unpack) pure . parseProposalKey)

-- | A bounded excerpt extracted from one envelope by a closed source adapter.
data Observed = Observed
  { activity :: !ActivityId,
    subject :: !ObservedSource,
    kind :: !SourceKind,
    actor :: !Actor,
    occurredAt :: !UTCTime,
    excerpt :: !Excerpt
  }
  deriving stock (Eq, Show)

observedSourceOf :: Observed -> ObservedSource
observedSourceOf observed = observed.subject

-- | The attention and spend figures a candidate was admitted under, as text and
-- numbers. It grants nothing and converts back to nothing.
data AllowanceView = AllowanceView
  { principal :: !Text,
    sources :: ![SourceKind],
    minimumExcerptLength :: !Int,
    evaluationsPerWindow :: !Int,
    proposalsPerWindow :: !Int,
    notificationsPerWindow :: !Int,
    windowSeconds :: !Double
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Minted only by 'Shikigami.Initiative.Prefilter.prefilter'.
newtype Candidate = Candidate CandidateFacts
  deriving stock (Eq, Show)

data CandidateFacts = CandidateFacts
  { observer :: !AgentPrincipal,
    observed :: !Observed,
    evidence :: !EvidenceRef,
    allowance :: !AllowanceView
  }
  deriving stock (Eq, Show)

candidateFacts :: Candidate -> CandidateFacts
candidateFacts (Candidate facts) = facts

-- | Minted only by the assessment validator, after every model-chosen field has
-- been checked against what the model was offered.
newtype Assessment = Assessment AssessmentFacts
  deriving stock (Eq, Show)

data AssessmentFacts = AssessmentFacts
  { outcome :: !OutcomeText,
    criteria :: !(NonEmpty CriterionText),
    repository :: !RepositoryId,
    actionClass :: !ActionClass,
    confidence :: !Confidence,
    evidence :: !(NonEmpty EvidenceRef)
  }
  deriving stock (Eq, Show)

assessmentFacts :: Assessment -> AssessmentFacts
assessmentFacts (Assessment facts) = facts

-- | What a proposal asks for. The human path funds nothing, so its limits are
-- empty; a standing policy supplies the real envelope at admission.
data RequestedAuthority = RequestedAuthority
  { repository :: !RepositoryId,
    actionClass :: !ActionClass,
    limits :: !Limits,
    objectiveWindow :: !(Duration "initiative-objective")
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AssessmentView = AssessmentView
  { outcome :: !Text,
    criteria :: ![Text],
    repository :: !Text,
    actionClass :: !Text,
    confidence :: !Double,
    evidence :: ![EvidenceRef]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

assessmentView :: Assessment -> AssessmentView
assessmentView assessment =
  AssessmentView
    { outcome = outcomeText facts.outcome,
      criteria = map criterionText (NonEmpty.toList facts.criteria),
      repository = repositoryIdText facts.repository,
      actionClass = actionClassText facts.actionClass,
      confidence = confidenceNumber facts.confidence,
      evidence = NonEmpty.toList facts.evidence
    }
  where
    facts = assessmentFacts assessment

data CandidateView = CandidateView
  { observer :: !Text,
    activity :: !Text,
    source :: !(Maybe Text),
    subjectKind :: !(Maybe Text),
    subjectId :: !(Maybe Text),
    verdict :: !Text,
    skipReason :: !(Maybe Text),
    proposalId :: !(Maybe Text),
    runWorkflowId :: !(Maybe Text),
    recordedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A candidate in evaluation, before any ledger row has given it another verdict.
candidateView :: UTCTime -> Candidate -> CandidateView
candidateView recordedAt candidate =
  CandidateView
    { observer = principalText facts.observer,
      activity = activityCoordinateText facts.observed.activity,
      source = Just (activityCoordinateText facts.observed.subject.source),
      subjectKind = Just (activityCoordinateText facts.observed.subject.subjectKind),
      subjectId = Just (activityCoordinateText facts.observed.subject.subjectId),
      verdict = "evaluating",
      skipReason = Nothing,
      proposalId = Nothing,
      runWorkflowId = Nothing,
      recordedAt
    }
  where
    facts = candidateFacts candidate

-- | One durable proposal, keyed by observer and source subject while pending.
data Proposal = Proposal
  { proposalId :: !ProposalId,
    key :: !ProposalKey,
    observer :: !AgentPrincipal,
    subject :: !ObservedSource,
    assessment :: !AssessmentView,
    requested :: !RequestedAuthority,
    status :: !ProposalStatus,
    proposedAt :: !UTCTime,
    expiresAt :: !UTCTime,
    resolvedAt :: !(Maybe UTCTime),
    suppressedUntil :: !(Maybe UTCTime),
    revision :: !(StateRevision "proposal"),
    runId :: !WorkflowId
  }
  deriving stock (Eq, Show)

data ProposalView = ProposalView
  { proposalId :: !Text,
    key :: !Text,
    observer :: !Text,
    source :: !Text,
    subjectKind :: !Text,
    subjectId :: !Text,
    assessment :: !AssessmentView,
    requested :: !RequestedAuthority,
    status :: !ProposalStatus,
    proposedAt :: !UTCTime,
    expiresAt :: !UTCTime,
    resolvedAt :: !(Maybe UTCTime),
    suppressedUntil :: !(Maybe UTCTime),
    revision :: !Integer,
    runWorkflowId :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ProposalView where
  toJSON view =
    object
      [ "proposalId" .= view.proposalId,
        "key" .= view.key,
        "observer" .= view.observer,
        "source" .= view.source,
        "subjectKind" .= view.subjectKind,
        "subjectId" .= view.subjectId,
        "assessment" .= view.assessment,
        "requested" .= view.requested,
        "status" .= view.status,
        "proposedAt" .= view.proposedAt,
        "expiresAt" .= view.expiresAt,
        "resolvedAt" .= view.resolvedAt,
        "suppressedUntil" .= view.suppressedUntil,
        "revision" .= view.revision,
        "runWorkflowId" .= view.runWorkflowId
      ]

instance FromJSON ProposalView where
  parseJSON = withObject "proposal view" \fields ->
    ProposalView
      <$> fields .: "proposalId"
      <*> fields .: "key"
      <*> fields .: "observer"
      <*> fields .: "source"
      <*> fields .: "subjectKind"
      <*> fields .: "subjectId"
      <*> fields .: "assessment"
      <*> fields .: "requested"
      <*> (fields .: "status" :: Parser ProposalStatus)
      <*> fields .: "proposedAt"
      <*> fields .: "expiresAt"
      <*> fields .:? "resolvedAt"
      <*> fields .:? "suppressedUntil"
      <*> fields .: "revision"
      <*> fields .: "runWorkflowId"

proposalView :: Proposal -> ProposalView
proposalView proposal =
  ProposalView
    { proposalId = proposalIdText proposal.proposalId,
      key = proposalKeyText proposal.key,
      observer = principalText proposal.observer,
      source = activityCoordinateText proposal.subject.source,
      subjectKind = activityCoordinateText proposal.subject.subjectKind,
      subjectId = activityCoordinateText proposal.subject.subjectId,
      assessment = proposal.assessment,
      requested = proposal.requested,
      status = proposal.status,
      proposedAt = proposal.proposedAt,
      expiresAt = proposal.expiresAt,
      resolvedAt = proposal.resolvedAt,
      suppressedUntil = proposal.suppressedUntil,
      revision = revisionNumber proposal.revision,
      runWorkflowId = case proposal.runId of WorkflowId workflow -> workflow
    }

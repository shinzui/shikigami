-- | Durable run-evidence lifecycle and the immutable facts bound to it.
--
-- The lifecycle is executed by the checked Keiro aggregate generated from
-- @domain/shikigami-run-evidence.keiro@. This module is the hand-owned facade:
-- it speaks in attestation and correlation types and exposes a typed rejection
-- instead of generated vertices and commands.
module Shikigami.Attestation.Evidence
  ( EvidencePhase (..),
    TransitionError (..),
    ReviewRequestId (..),
    RunEvidence (..),
    RunEvidenceId,
    mkRunEvidenceId,
    parseRunEvidenceId,
    runEvidenceIdText,
    requestEvidence,
    transitionEvidence,
  )
where

import Data.Generics.Labels ()
import Keiki.Core (RegFile)
import Keiki.Core qualified as Keiki
import Shikigami.Attestation.Agent (AgentArtifactSet, AgentVersionRef)
import Shikigami.Attestation.Profile (SanctionedExecutionProfileRef)
import Shikigami.Attestation.Reviewed (ReviewedArtifact)
import Shikigami.Generated.Nominals (RunEvidenceId, mkRunEvidenceId, parseRunEvidenceId, runEvidenceIdText)
import Shikigami.Log.Correlation (RunCorrelationId, renderRunCorrelationId)
import Shikigami.Prelude
import Shikigami.RunEvidence.Generated.Domain qualified as Generated
import Shikigami.RunEvidence.Generated.Transducer (runEvidenceTransducer)

-- | A run's monotonic evidence phase.
data EvidencePhase
  = Requested
  | ProfileResolved
  | Running
  | EvidenceSealed
  | Attested
  | NonConforming
  | Incomplete
  | Failed
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON EvidencePhase where toJSON = genericToJSON eventAesonOptions

instance FromJSON EvidencePhase where parseJSON = genericParseJSON eventAesonOptions

-- | The checked aggregate had no edge for this attempted phase change.
data TransitionError = IllegalTransition !EvidencePhase !EvidencePhase
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Opaque identity of the human review request bound to this run.
--
-- The caller supplies this value until
-- @docs/plans/14-approval-and-human-in-the-loop-end-to-end.md@ defines the
-- owning approval vocabulary.
newtype ReviewRequestId = ReviewRequestId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Evidence lifecycle plus every immutable fact committed when the profile is
-- resolved. Calls are added by the collection milestone; lifecycle comes first
-- so the aggregate can reject sealing and reopening independently of payload
-- storage.
data RunEvidence = RunEvidence
  { runEvidenceId :: !RunEvidenceId,
    runId :: !RunCorrelationId,
    phase :: !EvidencePhase,
    agentVersion :: !AgentVersionRef,
    artifacts :: !AgentArtifactSet,
    reviewed :: !ReviewedArtifact,
    profile :: !SanctionedExecutionProfileRef,
    reviewRequestId :: !ReviewRequestId,
    idempotencyKey :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | Create the requested record. The immutable binding arrives with the
-- command context and becomes durable only when 'ProfileResolved' is accepted.
requestEvidence ::
  RunEvidenceId ->
  RunCorrelationId ->
  AgentVersionRef ->
  AgentArtifactSet ->
  ReviewedArtifact ->
  SanctionedExecutionProfileRef ->
  ReviewRequestId ->
  Text ->
  RunEvidence
requestEvidence runEvidenceId runId agentVersion artifacts reviewed profile reviewRequestId idempotencyKey =
  RunEvidence
    { runEvidenceId,
      runId,
      phase = Requested,
      agentVersion,
      artifacts,
      reviewed,
      profile,
      reviewRequestId,
      idempotencyKey
    }

-- | Advance through the checked aggregate. Missing and terminal edges become a
-- typed error naming both phases; no parallel hand-written transition table is
-- used.
transitionEvidence :: RunEvidence -> EvidencePhase -> Either TransitionError RunEvidence
transitionEvidence evidence target = do
  command <- maybe (Left illegal) Right (commandFor evidence target)
  let (vertex, registers) = seedFor evidence
  case Keiki.stepDetailedEither runEvidenceTransducer (vertex, registers) command of
    Left _ -> Left illegal
    Right success
      | phaseFromVertex (Keiki.stepSuccessState success) == target ->
          Right (evidence & #phase .~ target)
      | otherwise -> Left illegal
  where
    illegal = IllegalTransition (phase evidence) target

seedFor :: RunEvidence -> (Generated.RunEvidenceVertex, RegFile Generated.RunEvidenceRegs)
seedFor evidence =
  case Keiki.applyEventsEither runEvidenceTransducer (Generated.RunEvidenceRequested, Generated.initialRunEvidenceRegs) (historyFor evidence) of
    Left _ -> error "RunEvidence canonical lifecycle history did not replay"
    Right settled -> settled

historyFor :: RunEvidence -> [Generated.RunEvidenceEvent]
historyFor evidence =
  case phase evidence of
    Requested -> []
    ProfileResolved -> [profileBound evidence]
    Running -> [profileBound evidence, collectionStarted evidence]
    EvidenceSealed -> [profileBound evidence, collectionStarted evidence, evidenceSealed evidence]
    Attested -> [profileBound evidence, collectionStarted evidence, evidenceSealed evidence, evidenceAttested evidence]
    NonConforming -> [profileBound evidence, collectionStarted evidence, evidenceNonConforming evidence]
    Incomplete -> [profileBound evidence, collectionStarted evidence, evidenceIncomplete evidence]
    Failed -> [profileBound evidence, collectionStarted evidence, evidenceFailed evidence]

commandFor :: RunEvidence -> EvidencePhase -> Maybe Generated.RunEvidenceCommand
commandFor evidence = \case
  Requested -> Nothing
  ProfileResolved -> Just (Generated.BindProfile (Generated.BindProfileData aggregateId correlationId))
  Running -> Just (Generated.StartCollection (Generated.StartCollectionData aggregateId correlationId))
  EvidenceSealed -> Just (Generated.SealEvidence (Generated.SealEvidenceData aggregateId correlationId))
  Attested -> Just (Generated.MarkAttested (Generated.MarkAttestedData aggregateId correlationId))
  NonConforming -> Just (Generated.MarkNonConforming (Generated.MarkNonConformingData aggregateId correlationId))
  Incomplete -> Just (Generated.MarkIncomplete (Generated.MarkIncompleteData aggregateId correlationId))
  Failed -> Just (Generated.MarkFailed (Generated.MarkFailedData aggregateId correlationId))
  where
    aggregateId = runEvidenceId evidence
    correlationId = renderRunCorrelationId (runId evidence)

profileBound :: RunEvidence -> Generated.RunEvidenceEvent
profileBound evidence =
  Generated.ProfileBound (Generated.ProfileBoundData (runEvidenceId evidence) (renderRunCorrelationId (runId evidence)))

collectionStarted :: RunEvidence -> Generated.RunEvidenceEvent
collectionStarted evidence =
  Generated.CollectionStarted (Generated.CollectionStartedData (runEvidenceId evidence) (renderRunCorrelationId (runId evidence)))

evidenceSealed :: RunEvidence -> Generated.RunEvidenceEvent
evidenceSealed evidence =
  Generated.EvidenceSealed (Generated.EvidenceSealedData (runEvidenceId evidence) (renderRunCorrelationId (runId evidence)))

evidenceAttested :: RunEvidence -> Generated.RunEvidenceEvent
evidenceAttested evidence =
  Generated.EvidenceAttested (Generated.EvidenceAttestedData (runEvidenceId evidence) (renderRunCorrelationId (runId evidence)))

evidenceNonConforming :: RunEvidence -> Generated.RunEvidenceEvent
evidenceNonConforming evidence =
  Generated.EvidenceNonConforming (Generated.EvidenceNonConformingData (runEvidenceId evidence) (renderRunCorrelationId (runId evidence)))

evidenceIncomplete :: RunEvidence -> Generated.RunEvidenceEvent
evidenceIncomplete evidence =
  Generated.EvidenceIncomplete (Generated.EvidenceIncompleteData (runEvidenceId evidence) (renderRunCorrelationId (runId evidence)))

evidenceFailed :: RunEvidence -> Generated.RunEvidenceEvent
evidenceFailed evidence =
  Generated.EvidenceFailed (Generated.EvidenceFailedData (runEvidenceId evidence) (renderRunCorrelationId (runId evidence)))

phaseFromVertex :: Generated.RunEvidenceVertex -> EvidencePhase
phaseFromVertex = \case
  Generated.RunEvidenceRequested -> Requested
  Generated.RunEvidenceProfileResolved -> ProfileResolved
  Generated.RunEvidenceRunning -> Running
  Generated.RunEvidenceEvidenceSealed -> EvidenceSealed
  Generated.RunEvidenceAttested -> Attested
  Generated.RunEvidenceNonConforming -> NonConforming
  Generated.RunEvidenceIncomplete -> Incomplete
  Generated.RunEvidenceFailed -> Failed

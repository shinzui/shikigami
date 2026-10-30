-- | Durable run-evidence lifecycle and the immutable facts bound to it.
--
-- The lifecycle is executed by the checked Keiro aggregate generated from
-- @domain/shikigami/run-evidence.keiro@. This module is the hand-owned facade:
-- it speaks in attestation and correlation types and exposes a typed rejection
-- instead of generated vertices and commands.
module Shikigami.Attestation.Evidence
  ( EvidencePhase (..),
    TransitionError (..),
    ReviewRequestId (..),
    CallRelationship (..),
    RecordedCallEvidence (..),
    ExpectedCall (..),
    ResultEvidence (..),
    EvidenceSource (..),
    configureEvidenceCall,
    newEvidenceCollector,
    collectEvidence,
    expectCall,
    recordCall,
    recordDeterministicStep,
    expectDelegatedChild,
    observeArtifactDigest,
    observeResultDigests,
    observeRuntimeMeasurements,
    RunDurationSeconds (..),
    PeakConcurrency (..),
    BehaviorTerminalState (..),
    RelevantChild (..),
    SealRefusal (..),
    prepareEvidenceClosure,
    sealEvidence,
    RunEvidence (..),
    RunEvidenceId,
    mkRunEvidenceId,
    parseRunEvidenceId,
    runEvidenceIdText,
    requestEvidence,
    evidenceTransitionCommand,
    transitionEvidence,
  )
where

import Baikai.Evidence qualified as Baikai
import Baikai.Options qualified as BaikaiOptions
import Baikai.Trace.Event qualified as Trace
import Baikai.Trace.Sink (TraceSink (..), multiSink)
import Data.Aeson (Value (String))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Keiki.Core (RegFile)
import Keiki.Core qualified as Keiki
import Keiro.Workflow.Types (WorkflowId)
import Kioku.Id (SessionId)
import Numeric.Natural (Natural)
import Shikigami.Agent.Approval (ReviewRequestId (..))
import Shikigami.Agent.Run.Key (RunKey)
import Shikigami.Attestation.Agent (AgentArtifactSet, AgentVersionRef)
import Shikigami.Attestation.Profile (SanctionedExecutionProfileRef)
import Shikigami.Attestation.Reviewed (DiffDigest, ResultDigest, ReviewedArtifact)
import Shikigami.Generated.Nominals (RunEvidenceId, mkRunEvidenceId, parseRunEvidenceId, runEvidenceIdText)
import Shikigami.Log.Correlation
  ( CallCorrelationId,
    RunCorrelationId,
    callCorrelationId,
    renderCallCorrelationId,
    renderRunCorrelationId,
  )
import Shikigami.Prelude
import Shikigami.RunEvidence.Generated.Domain qualified as Generated
import Shikigami.RunEvidence.Generated.Transducer (runEvidenceTransducer)
import Streamly.Data.Fold qualified as Fold

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

-- | How one correlatable call relates to another. Baikai owns the provider
-- evidence; Shikigami owns these durable run-local relationships.
data CallRelationship
  = RootCall
  | RetryOf !CallCorrelationId
  | FallbackFrom !CallCorrelationId
  | ContinuationOf !CallCorrelationId
  | ChildOf !CallCorrelationId
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Baikai's evidence paired with Shikigami's stable call identity.
data RecordedCallEvidence = RecordedCallEvidence
  { callId :: !CallCorrelationId,
    relationship :: !CallRelationship,
    resolvedModelId :: !Text,
    requestedAlias :: !(Maybe Text),
    evidence :: !Baikai.ModelCallEvidence
  }
  deriving stock (Eq, Show, Generic)

-- | A call known to the run before terminal evidence is collected.
data ExpectedCall = ExpectedCall
  { callId :: !CallCorrelationId,
    relationship :: !CallRelationship,
    attempt :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ResultEvidence = ResultEvidence
  { expectedDigest :: !ResultDigest,
    actualDigest :: !ResultDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Narrow collection seam. Production reads Baikai trace events; tests return
-- typed fixtures through the same functions.
data EvidenceSource = EvidenceSource
  { terminalCallsFor :: !(RunCorrelationId -> IO [RecordedCallEvidence]),
    meetsMinimumStrength :: !(Baikai.EvidenceStrength -> IO Bool)
  }

-- | Add the exact evidence request Baikai accepts to one call's options. The
-- correlation id is also carried in provider metadata, while Baikai continues
-- to generate and preserve its own globally unique call id.
configureEvidenceCall ::
  RunCorrelationId ->
  CallCorrelationId ->
  Natural ->
  Maybe Text ->
  Baikai.EvidenceStrength ->
  BaikaiOptions.Options ->
  BaikaiOptions.Options
configureEvidenceCall runId callId attempt supersedes minimumStrength options =
  options
    & #evidence
    .~ Just
      ( Baikai.evidenceRequest (renderRunCorrelationId runId)
          & #strictness
          .~ Baikai.EvidenceRequired minimumStrength
          & #attempt
          .~ attempt
          & #supersedes
          .~ supersedes
      )
    & #metadata
    %~ Map.insert "shikigami_call_id" (String (renderCallCorrelationId callId))

-- | Collect every terminal Baikai evidence event, fanning it out to an existing
-- trace sink when one was already configured. Ordinals are assigned in event
-- order and therefore remain stable for a deterministic call sequence.
newEvidenceCollector ::
  RunCorrelationId ->
  Text ->
  Int ->
  Baikai.EvidenceStrength ->
  Maybe TraceSink ->
  IO (TraceSink, EvidenceSource)
newEvidenceCollector runId stepName firstOrdinal maximumStrength existingSink = do
  records <- newIORef []
  let collector = TraceSink (Fold.drainMapM (capture records))
      sink = maybe collector (multiSink . (collector :) . pure) existingSink
      source =
        EvidenceSource
          { terminalCallsFor = \requestedRunId ->
              if requestedRunId == runId
                then correlateEvidence requestedRunId stepName firstOrdinal <$> readIORef records
                else pure [],
            meetsMinimumStrength = \minimumStrength -> pure (maximumStrength >= minimumStrength)
          }
  pure (sink, source)
  where
    capture records = \case
      Trace.CallEvidence {Trace.evidence} ->
        atomicModifyIORef' records (\current -> (current <> [evidence], ()))
      _ -> pure ()

-- | Read the source once and converge duplicate correlation ids by replacement.
collectEvidence :: EvidenceSource -> RunEvidence -> IO RunEvidence
collectEvidence EvidenceSource {terminalCallsFor} runEvidence = do
  collected <- terminalCallsFor ((.runId) runEvidence)
  pure (foldl' (flip recordCall) runEvidence collected)

-- | Declare one call that must eventually have terminal evidence.
expectCall :: ExpectedCall -> RunEvidence -> RunEvidence
expectCall expected runEvidence =
  runEvidence
    & #expectedCalls
    .~ upsertBy expectedCallId expected ((.expectedCalls) runEvidence)

-- | Record one terminal call. Replaying the same correlation id replaces its
-- row in place instead of manufacturing a duplicate.
recordCall :: RecordedCallEvidence -> RunEvidence -> RunEvidence
recordCall recorded runEvidence@RunEvidence {calls = currentCalls} =
  runEvidence
    & #calls
    .~ upsertBy recordedCallId recorded currentCalls

recordDeterministicStep :: Text -> RunEvidence -> RunEvidence
recordDeterministicStep step runEvidence =
  runEvidence
    & #deterministicSteps
    .~ stableNub ((.deterministicSteps) runEvidence <> [step])

expectDelegatedChild :: RunCorrelationId -> RunEvidence -> RunEvidence
expectDelegatedChild expectedChild runEvidence =
  runEvidence
    & #expectedChildRunIds
    .~ stableNub ((.expectedChildRunIds) runEvidence <> [expectedChild])

observeArtifactDigest :: DiffDigest -> RunEvidence -> RunEvidence
observeArtifactDigest observed runEvidence =
  runEvidence & #observedArtifactDigest .~ Just observed

observeResultDigests :: ResultDigest -> ResultDigest -> RunEvidence -> RunEvidence
observeResultDigests expected actual runEvidence =
  runEvidence & #resultEvidence .~ Just (ResultEvidence expected actual)

observeRuntimeMeasurements :: RunDurationSeconds -> PeakConcurrency -> RunEvidence -> RunEvidence
observeRuntimeMeasurements durationSeconds peakConcurrency runEvidence =
  runEvidence
    & #durationSeconds
    .~ Just durationSeconds
    & #peakConcurrency
    .~ Just peakConcurrency

data BehaviorTerminalState = BehaviorRunning | BehaviorSucceeded | BehaviorFailed
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A child discovered through the lineage already carried by 'RunJob'.
data RelevantChild = RelevantChild
  { childRunId :: !RunCorrelationId,
    parentRunWorkflowId :: !WorkflowId,
    parentSessionId :: !(Maybe SessionId),
    phase :: !EvidencePhase,
    calls :: ![RecordedCallEvidence]
  }
  deriving stock (Eq, Show, Generic)

data SealRefusal
  = PendingChild !Text
  | BehaviorNotTerminal
  | EvidenceNotRunning !EvidencePhase
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Seal only after the behavior and every relevant child have closed. Child
-- calls are folded into the parent closure with the same idempotent upsert used
-- for local calls.
sealEvidence ::
  RunEvidence ->
  BehaviorTerminalState ->
  [RelevantChild] ->
  Either SealRefusal RunEvidence
sealEvidence runEvidence@RunEvidence {phase = currentPhase} behavior relevantChildren
  | currentPhase == EvidenceSealed = Right runEvidence
  | otherwise = do
      closed <- prepareEvidenceClosure runEvidence behavior relevantChildren
      first
        (const (EvidenceNotRunning currentPhase))
        (transitionEvidence closed EvidenceSealed)

-- | Check closure and merge child evidence without choosing the compliance
-- outcome. 'sealEvidence' chooses 'EvidenceSealed'; the compliance evaluator
-- uses this same guard and may instead choose 'NonConforming'.
prepareEvidenceClosure ::
  RunEvidence ->
  BehaviorTerminalState ->
  [RelevantChild] ->
  Either SealRefusal RunEvidence
prepareEvidenceClosure runEvidence@RunEvidence {phase = currentPhase} behavior relevantChildren
  | currentPhase /= Running = Left (EvidenceNotRunning currentPhase)
  | behavior == BehaviorRunning = Left BehaviorNotTerminal
  | Just pending <- findPendingChild relevantChildren = Left (PendingChild pending)
  | otherwise =
      Right
        ( foldl' addChildCalls runEvidence relevantChildren
            & #delegatedChildren
            .~ relevantChildren
        )

addChildCalls :: RunEvidence -> RelevantChild -> RunEvidence
addChildCalls runEvidence RelevantChild {calls} =
  foldl' (flip recordCall) runEvidence calls

findPendingChild :: [RelevantChild] -> Maybe Text
findPendingChild relevantChildren =
  renderRunCorrelationId . (.childRunId) <$> find (not . childEvidenceClosed) relevantChildren

childEvidenceClosed :: RelevantChild -> Bool
childEvidenceClosed RelevantChild {phase} =
  phase `elem` [EvidenceSealed, Attested, NonConforming, Incomplete, Failed]

correlateEvidence ::
  RunCorrelationId ->
  Text ->
  Int ->
  [Baikai.ModelCallEvidence] ->
  [RecordedCallEvidence]
correlateEvidence runId stepName firstOrdinal = go firstOrdinal Map.empty
  where
    go _ _ [] = []
    go ordinal previousByBaikaiId (terminal : rest) =
      let supersedes = terminal ^. #supersedes
          baikaiCallId = terminal ^. #callId
          correlationId = callCorrelationId runId stepName ordinal
          relationship =
            case supersedes >>= (`Map.lookup` previousByBaikaiId) of
              Just previous -> RetryOf previous
              Nothing -> RootCall
          resolvedModelId =
            fromMaybe
              (Baikai.requestedModel terminal)
              (Baikai.observedValue (Baikai.observedModel terminal))
          recorded =
            RecordedCallEvidence
              { callId = correlationId,
                relationship,
                resolvedModelId,
                requestedAlias = Nothing,
                evidence = terminal
              }
          nextPrevious = Map.insert baikaiCallId correlationId previousByBaikaiId
       in recorded : go (ordinal + 1) nextPrevious rest

expectedCallId :: ExpectedCall -> CallCorrelationId
expectedCallId ExpectedCall {callId} = callId

recordedCallId :: RecordedCallEvidence -> CallCorrelationId
recordedCallId RecordedCallEvidence {callId} = callId

upsertBy :: (Eq key) => (value -> key) -> value -> [value] -> [value]
upsertBy keyOf value existing =
  case break ((== keyOf value) . keyOf) existing of
    (before, []) -> before <> [value]
    (before, _ : after) -> before <> (value : after)

stableNub :: (Eq value) => [value] -> [value]
stableNub = foldl' (\seen value -> if value `elem` seen then seen else seen <> [value]) []

-- | Nonnegative measurements keep unlike quantities distinct. Their JSON is
-- still a number; Natural rejects negative values at decoding.
newtype RunDurationSeconds = RunDurationSeconds Natural
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

newtype PeakConcurrency = PeakConcurrency Natural
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
    idempotencyKey :: !RunKey,
    expectedCalls :: ![ExpectedCall],
    calls :: ![RecordedCallEvidence],
    deterministicSteps :: ![Text],
    expectedChildRunIds :: ![RunCorrelationId],
    delegatedChildren :: ![RelevantChild],
    observedArtifactDigest :: !(Maybe DiffDigest),
    resultEvidence :: !(Maybe ResultEvidence),
    durationSeconds :: !(Maybe RunDurationSeconds),
    peakConcurrency :: !(Maybe PeakConcurrency)
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
  RunKey ->
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
      idempotencyKey,
      expectedCalls = [],
      calls = [],
      deterministicSteps = [],
      expectedChildRunIds = [],
      delegatedChildren = [],
      observedArtifactDigest = Nothing,
      resultEvidence = Nothing,
      durationSeconds = Nothing,
      peakConcurrency = Nothing
    }

-- | Advance through the checked aggregate. Missing and terminal edges become a
-- typed error naming both phases; no parallel hand-written transition table is
-- used.
transitionEvidence :: RunEvidence -> EvidencePhase -> Either TransitionError RunEvidence
transitionEvidence evidence@RunEvidence {phase = currentPhase} target = do
  command <- evidenceTransitionCommand evidence target
  let (vertex, registers) = seedFor evidence
  case Keiki.stepDetailedEither runEvidenceTransducer (vertex, registers) command of
    Left _ -> Left illegal
    Right success
      | phaseFromVertex (Keiki.stepSuccessState success) == target ->
          Right (evidence & #phase .~ target)
      | otherwise -> Left illegal
  where
    illegal = IllegalTransition currentPhase target

-- | Select the generated command for the same transition executed by
-- 'transitionEvidence'. Persistence uses this value with Keiro's command
-- runner, so the pure facade and the durable stream cannot choose different
-- lifecycle operations.
evidenceTransitionCommand :: RunEvidence -> EvidencePhase -> Either TransitionError Generated.RunEvidenceCommand
evidenceTransitionCommand evidence@RunEvidence {phase = currentPhase} target =
  maybe
    (Left (IllegalTransition currentPhase target))
    Right
    (commandFor evidence target)

seedFor :: RunEvidence -> (Generated.RunEvidenceVertex, RegFile Generated.RunEvidenceRegs)
seedFor evidence =
  case Keiki.applyEventsEither runEvidenceTransducer (Generated.RunEvidenceRequested, Generated.initialRunEvidenceRegs) (historyFor evidence) of
    Left _ -> error "RunEvidence canonical lifecycle history did not replay"
    Right settled -> settled

historyFor :: RunEvidence -> [Generated.RunEvidenceEvent]
historyFor evidence@RunEvidence {phase = currentPhase} =
  case currentPhase of
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
    aggregateId = (.runEvidenceId) evidence
    correlationId = renderRunCorrelationId ((.runId) evidence)

profileBound :: RunEvidence -> Generated.RunEvidenceEvent
profileBound evidence =
  Generated.ProfileBound (Generated.ProfileBoundData ((.runEvidenceId) evidence) (renderRunCorrelationId ((.runId) evidence)))

collectionStarted :: RunEvidence -> Generated.RunEvidenceEvent
collectionStarted evidence =
  Generated.CollectionStarted (Generated.CollectionStartedData ((.runEvidenceId) evidence) (renderRunCorrelationId ((.runId) evidence)))

evidenceSealed :: RunEvidence -> Generated.RunEvidenceEvent
evidenceSealed evidence =
  Generated.EvidenceSealed (Generated.EvidenceSealedData ((.runEvidenceId) evidence) (renderRunCorrelationId ((.runId) evidence)))

evidenceAttested :: RunEvidence -> Generated.RunEvidenceEvent
evidenceAttested evidence =
  Generated.EvidenceAttested (Generated.EvidenceAttestedData ((.runEvidenceId) evidence) (renderRunCorrelationId ((.runId) evidence)))

evidenceNonConforming :: RunEvidence -> Generated.RunEvidenceEvent
evidenceNonConforming evidence =
  Generated.EvidenceNonConforming (Generated.EvidenceNonConformingData ((.runEvidenceId) evidence) (renderRunCorrelationId ((.runId) evidence)))

evidenceIncomplete :: RunEvidence -> Generated.RunEvidenceEvent
evidenceIncomplete evidence =
  Generated.EvidenceIncomplete (Generated.EvidenceIncompleteData ((.runEvidenceId) evidence) (renderRunCorrelationId ((.runId) evidence)))

evidenceFailed :: RunEvidence -> Generated.RunEvidenceEvent
evidenceFailed evidence =
  Generated.EvidenceFailed (Generated.EvidenceFailedData ((.runEvidenceId) evidence) (renderRunCorrelationId ((.runId) evidence)))

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

-- | Atomic persistence and operator queries for run evidence.
--
-- The generated Keiro stream owns lifecycle truth. Each accepted lifecycle
-- event updates these SQL rows in the same transaction, giving operators a
-- direct run-id query without creating a second transition authority.
module Shikigami.Attestation.EvidenceStore
  ( EvidenceStore,
    postgresEvidenceStore,
    ComplianceVerdict (..),
    StoredRunEvidence (..),
    StoredCallEvidence (..),
    EvidencePersistenceError (..),
    persistEvidenceTransition,
    findRunEvidence,
  )
where

import Data.Aeson (Result (..), Value (..))
import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int32, Int64)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Keiro.Command (CommandError (..), defaultRunCommandOptions, runCommandWithSqlEvents)
import Keiro.Stream qualified as Stream
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Shikigami.Attestation.Compliance (ComplianceRollUp (..))
import Shikigami.Attestation.Compliance qualified as Compliance
import Shikigami.Attestation.Evidence
import Shikigami.Attestation.Reviewed (NonConformingReason)
import Shikigami.Log.Correlation (CallCorrelationId, RunCorrelationId, renderCallCorrelationId, renderRunCorrelationId)
import Shikigami.Prelude
import Shikigami.RunEvidence.Generated.EventStream (runEvidenceCategory, runEvidenceEventStream)

newtype EvidenceStore = EvidenceStore {pool :: Pool}

postgresEvidenceStore :: Pool -> EvidenceStore
postgresEvidenceStore = EvidenceStore

data ComplianceVerdict
  = VerdictSanctioned
  | VerdictNotSanctioned
  | VerdictIncomplete
  | VerdictFailed
  deriving stock (Eq, Show, Generic)

data StoredRunEvidence = StoredRunEvidence
  { runEvidenceId :: !RunEvidenceId,
    runId :: !Text,
    status :: !EvidencePhase,
    verdict :: !(Maybe ComplianceVerdict),
    reasons :: ![NonConformingReason],
    binding :: !Value,
    observations :: !Value,
    expectedCallCount :: !Int,
    recordedCallCount :: !Int,
    calls :: ![StoredCallEvidence]
  }
  deriving stock (Eq, Show, Generic)

data StoredCallEvidence = StoredCallEvidence
  { callId :: !Text,
    sourceRunId :: !Text,
    relationship :: !Text,
    relatedCallId :: !(Maybe Text),
    resolvedModelId :: !Text,
    requestedAlias :: !(Maybe Text),
    baikaiCallId :: !Text,
    attempt :: !Int64,
    callStatus :: !Text,
    evidenceStrength :: !Text,
    evidence :: !Value
  }
  deriving stock (Eq, Show, Generic)

data EvidencePersistenceError
  = InvalidEvidenceTransition !TransitionError
  | EvidenceCommandFailed !CommandError
  | MissingComplianceRollUp !EvidencePhase
  | VerdictDoesNotMatchPhase !EvidencePhase !Bool
  deriving stock (Eq, Show, Generic)

data RunProjection = RunProjection
  { runEvidenceId :: !Text,
    runId :: !Text,
    status :: !Text,
    verdict :: !(Maybe Text),
    reasons :: !Value,
    binding :: !Value,
    observations :: !Value,
    expectedCallCount :: !Int32,
    recordedCallCount :: !Int32
  }

data CallProjection = CallProjection
  { runId :: !Text,
    callId :: !Text,
    sourceRunId :: !Text,
    relationship :: !Text,
    relatedCallId :: !(Maybe Text),
    resolvedModelId :: !Text,
    requestedAlias :: !(Maybe Text),
    baikaiCallId :: !Text,
    attempt :: !Int64,
    callStatus :: !Text,
    evidenceStrength :: !Text,
    evidence :: !Value
  }

-- | Advance the checked aggregate and update its query projection atomically.
-- Repeating a transition after a process lost the committed response converges
-- when the stored row already has the requested phase.
persistEvidenceTransition ::
  ( IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es
  ) =>
  EvidenceStore ->
  RunEvidence ->
  EvidencePhase ->
  Maybe ComplianceRollUp ->
  Eff es (Either EvidencePersistenceError RunEvidence)
persistEvidenceTransition evidenceStore runEvidence@RunEvidence {runEvidenceId = aggregateId, runId = correlationId, phase = currentPhase} target rollUp
  | currentPhase == target = pure (Right runEvidence)
  | otherwise =
      case transitionEvidence runEvidence target of
        Left err -> pure (Left (InvalidEvidenceTransition err))
        Right advanced ->
          case validateVerdict target rollUp of
            Left err -> pure (Left err)
            Right () -> do
              let RunEvidence {runId = advancedRunId, calls = advancedCalls} = advanced
              let command =
                    either
                      (error . ("validated transition has no generated command: " <>) . show)
                      id
                      (evidenceTransitionCommand runEvidence target)
                  targetStream = Stream.entityStream runEvidenceCategory (runEvidenceIdText aggregateId)
                  projection = runProjection advanced rollUp
                  callProjections = callProjection (renderRunCorrelationId advancedRunId) <$> advancedCalls
              result <-
                runCommandWithSqlEvents
                  defaultRunCommandOptions
                  runEvidenceEventStream
                  targetStream
                  command
                  (\_ _ -> persistProjection projection callProjections)
              case result of
                Right _ -> pure (Right advanced)
                Left CommandRejected -> do
                  stored <- liftIO (findRunEvidence evidenceStore correlationId)
                  pure case stored of
                    Just StoredRunEvidence {runEvidenceId = storedAggregateId, status}
                      | storedAggregateId == aggregateId,
                        status == target ->
                          Right advanced
                    _ -> Left (EvidenceCommandFailed CommandRejected)
                Left err -> pure (Left (EvidenceCommandFailed err))

validateVerdict :: EvidencePhase -> Maybe ComplianceRollUp -> Either EvidencePersistenceError ()
validateVerdict target rollUp =
  case (target, (.sanctioned) <$> rollUp) of
    (EvidenceSealed, Nothing) -> Left (MissingComplianceRollUp target)
    (EvidenceSealed, Just False) -> Left (VerdictDoesNotMatchPhase target False)
    (Attested, Just False) -> Left (VerdictDoesNotMatchPhase target False)
    (NonConforming, Nothing) -> Left (MissingComplianceRollUp target)
    (NonConforming, Just True) -> Left (VerdictDoesNotMatchPhase target True)
    _ -> Right ()

persistProjection :: RunProjection -> [CallProjection] -> Tx.Transaction ()
persistProjection run calls = do
  void (Tx.statement run upsertRunStatement)
  traverse_ (\call -> Tx.statement call upsertCallStatement) calls

runProjection :: RunEvidence -> Maybe ComplianceRollUp -> RunProjection
runProjection runEvidence@RunEvidence {runEvidenceId, runId, phase, expectedCalls, calls} rollUp =
  RunProjection
    { runEvidenceId = runEvidenceIdText runEvidenceId,
      runId = renderRunCorrelationId runId,
      status = phaseText phase,
      verdict = verdictText <$> verdictFor phase rollUp,
      reasons = toJSON (maybe [] (.reasons) rollUp),
      binding = bindingValue runEvidence,
      observations = observationsValue runEvidence,
      expectedCallCount = fromIntegral (length expectedCalls),
      recordedCallCount = fromIntegral (length calls)
    }

verdictFor :: EvidencePhase -> Maybe ComplianceRollUp -> Maybe ComplianceVerdict
verdictFor phase rollUp =
  case (.sanctioned) <$> rollUp of
    Just True -> Just VerdictSanctioned
    Just False -> Just VerdictNotSanctioned
    Nothing -> case phase of
      EvidenceSealed -> Just VerdictSanctioned
      Attested -> Just VerdictSanctioned
      NonConforming -> Just VerdictNotSanctioned
      Incomplete -> Just VerdictIncomplete
      Failed -> Just VerdictFailed
      _ -> Nothing

bindingValue :: RunEvidence -> Value
bindingValue
  RunEvidence
    { agentVersion,
      artifacts,
      reviewed,
      profile,
      reviewRequestId,
      idempotencyKey
    } =
    Aeson.object
      [ "agentVersion" Aeson..= agentVersion,
        "artifacts" Aeson..= artifacts,
        "reviewed" Aeson..= reviewed,
        "profile" Aeson..= profile,
        "reviewRequestId" Aeson..= reviewRequestId,
        "idempotencyKey" Aeson..= idempotencyKey
      ]

observationsValue :: RunEvidence -> Value
observationsValue
  RunEvidence
    { expectedCalls,
      deterministicSteps,
      expectedChildRunIds,
      delegatedChildren,
      observedArtifactDigest,
      resultEvidence,
      durationSeconds,
      peakConcurrency
    } =
    Aeson.object
      [ "expectedCalls" Aeson..= expectedCalls,
        "deterministicSteps" Aeson..= deterministicSteps,
        "expectedChildRunIds" Aeson..= (renderRunCorrelationId <$> expectedChildRunIds),
        "delegatedChildren" Aeson..= (childValue <$> delegatedChildren),
        "observedArtifactDigest" Aeson..= observedArtifactDigest,
        "resultEvidence" Aeson..= resultEvidence,
        "durationSeconds" Aeson..= durationSeconds,
        "peakConcurrency" Aeson..= peakConcurrency
      ]

childValue :: RelevantChild -> Value
childValue RelevantChild {childRunId, parentRunWorkflowId, parentSessionId, phase, calls} =
  Aeson.object
    [ "childRunId" Aeson..= renderRunCorrelationId childRunId,
      "parentRunWorkflowId" Aeson..= parentRunWorkflowId.unWorkflowId,
      "parentSessionId" Aeson..= parentSessionId,
      "phase" Aeson..= phase,
      "callIds" Aeson..= (renderCallCorrelationId . recordedCallId <$> calls)
    ]

recordedCallId :: RecordedCallEvidence -> CallCorrelationId
recordedCallId RecordedCallEvidence {callId} = callId

callProjection :: Text -> RecordedCallEvidence -> CallProjection
callProjection ownerRunId RecordedCallEvidence {callId, relationship, resolvedModelId, requestedAlias, evidence = terminal} =
  let (relationshipText, relatedCallId) = relationshipParts relationship
      sourceRunId = terminal ^. #runId
      baikaiCallId = terminal ^. #callId
      attempt = terminal ^. #attempt
      status = terminal ^. #status
      strength = terminal ^. #strength
   in CallProjection
        { runId = ownerRunId,
          callId = renderCallCorrelationId callId,
          sourceRunId,
          relationship = relationshipText,
          relatedCallId,
          resolvedModelId,
          requestedAlias,
          baikaiCallId,
          attempt = fromIntegral attempt,
          callStatus = jsonString status,
          evidenceStrength = jsonString strength,
          evidence = toJSON terminal
        }

relationshipParts :: CallRelationship -> (Text, Maybe Text)
relationshipParts = \case
  RootCall -> ("root", Nothing)
  RetryOf previous -> ("retry", Just (renderCallCorrelationId previous))
  FallbackFrom previous -> ("fallback", Just (renderCallCorrelationId previous))
  ContinuationOf previous -> ("continuation", Just (renderCallCorrelationId previous))
  ChildOf parent -> ("child", Just (renderCallCorrelationId parent))

jsonString :: (ToJSON value) => value -> Text
jsonString value =
  case toJSON value of
    String rendered -> rendered
    other -> error ("expected JSON string encoding, got " <> show other)

phaseText :: EvidencePhase -> Text
phaseText = \case
  Requested -> "requested"
  ProfileResolved -> "profile-resolved"
  Running -> "running"
  EvidenceSealed -> "evidence-sealed"
  Attested -> "attested"
  NonConforming -> "non-conforming"
  Incomplete -> "incomplete"
  Failed -> "failed"

parsePhase :: Text -> Either Text EvidencePhase
parsePhase = \case
  "requested" -> Right Requested
  "profile-resolved" -> Right ProfileResolved
  "running" -> Right Running
  "evidence-sealed" -> Right EvidenceSealed
  "attested" -> Right Attested
  "non-conforming" -> Right NonConforming
  "incomplete" -> Right Incomplete
  "failed" -> Right Failed
  other -> Left ("unknown evidence phase " <> other)

verdictText :: ComplianceVerdict -> Text
verdictText = \case
  VerdictSanctioned -> "sanctioned"
  VerdictNotSanctioned -> "not-sanctioned"
  VerdictIncomplete -> "incomplete"
  VerdictFailed -> "failed"

parseVerdict :: Text -> Either Text ComplianceVerdict
parseVerdict = \case
  "sanctioned" -> Right VerdictSanctioned
  "not-sanctioned" -> Right VerdictNotSanctioned
  "incomplete" -> Right VerdictIncomplete
  "failed" -> Right VerdictFailed
  other -> Left ("unknown compliance verdict " <> other)

-- | Query the run projection and every accounted call by run correlation id.
findRunEvidence :: EvidenceStore -> RunCorrelationId -> IO (Maybe StoredRunEvidence)
findRunEvidence EvidenceStore {pool} requestedRunId = do
  let renderedRunId = renderRunCorrelationId requestedRunId
  queryResult <-
    Pool.use
      pool
      ( TxSessions.transaction
          TxSessions.RepeatableRead
          TxSessions.Read
          (findRunTransaction renderedRunId)
      )
  stored <- either (ioError . userError . show) pure queryResult
  case stored of
    Nothing -> pure Nothing
    Just (raw, storedCalls) -> Just <$> decodeStoredRun raw storedCalls

findRunTransaction :: Text -> Tx.Transaction (Maybe (RawStoredRun, [StoredCallEvidence]))
findRunTransaction renderedRunId = do
  storedRun <- Tx.statement renderedRunId findRunStatement
  case storedRun of
    Nothing -> pure Nothing
    Just raw -> do
      storedCalls <- Tx.statement renderedRunId findCallsStatement
      pure (Just (raw, storedCalls))

type RawStoredRun = (Text, Text, Text, Maybe Text, Value, Value, Value, Int32, Int32)

decodeStoredRun :: RawStoredRun -> [StoredCallEvidence] -> IO StoredRunEvidence
decodeStoredRun (rawAggregateId, runId, statusText, verdictValue, reasonValue, binding, observations, expectedCount, recordedCount) calls = do
  runEvidenceId <- either (ioError . userError . Text.unpack) pure (parseRunEvidenceId rawAggregateId)
  status <- either (ioError . userError . Text.unpack) pure (parsePhase statusText)
  verdict <- either (ioError . userError . Text.unpack) pure (traverse parseVerdict verdictValue)
  reasons <-
    case fromJSON reasonValue of
      Success decoded -> pure decoded
      Error err -> ioError (userError ("cannot decode run-evidence reasons: " <> err))
  pure
    StoredRunEvidence
      { runEvidenceId,
        runId,
        status,
        verdict,
        reasons,
        binding,
        observations,
        expectedCallCount = fromIntegral expectedCount,
        recordedCallCount = fromIntegral recordedCount,
        calls
      }

upsertRunStatement :: Statement RunProjection Text
upsertRunStatement =
  preparable
    """
    INSERT INTO shikigami.run_evidence
      (run_evidence_id, run_id, status, verdict, reasons, binding, observations,
       expected_call_count, recorded_call_count)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
    ON CONFLICT (run_id) DO UPDATE SET
      status = EXCLUDED.status,
      verdict = COALESCE(EXCLUDED.verdict, shikigami.run_evidence.verdict),
      reasons = CASE
        WHEN EXCLUDED.verdict IS NULL THEN shikigami.run_evidence.reasons
        ELSE EXCLUDED.reasons
      END,
      binding = EXCLUDED.binding,
      observations = EXCLUDED.observations,
      expected_call_count = EXCLUDED.expected_call_count,
      recorded_call_count = EXCLUDED.recorded_call_count,
      updated_at = now()
    WHERE shikigami.run_evidence.run_evidence_id = EXCLUDED.run_evidence_id
    RETURNING run_id
    """
    ( ((\RunProjection {runEvidenceId} -> runEvidenceId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\RunProjection {runId} -> runId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\RunProjection {status} -> status) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\RunProjection {verdict} -> verdict) >$< Encoders.param (Encoders.nullable Encoders.text))
        <> ((\RunProjection {reasons} -> reasons) >$< Encoders.param (Encoders.nonNullable Encoders.jsonb))
        <> ((\RunProjection {binding} -> binding) >$< Encoders.param (Encoders.nonNullable Encoders.jsonb))
        <> ((\RunProjection {observations} -> observations) >$< Encoders.param (Encoders.nonNullable Encoders.jsonb))
        <> ((\RunProjection {expectedCallCount} -> expectedCallCount) >$< Encoders.param (Encoders.nonNullable Encoders.int4))
        <> ((\RunProjection {recordedCallCount} -> recordedCallCount) >$< Encoders.param (Encoders.nonNullable Encoders.int4))
    )
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))

upsertCallStatement :: Statement CallProjection ()
upsertCallStatement =
  preparable
    """
    INSERT INTO shikigami.run_evidence_calls
      (run_id, call_id, source_run_id, relationship, related_call_id,
       resolved_model_id, requested_alias, baikai_call_id, attempt,
       call_status, evidence_strength, evidence)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
    ON CONFLICT (run_id, call_id) DO UPDATE SET
      source_run_id = EXCLUDED.source_run_id,
      relationship = EXCLUDED.relationship,
      related_call_id = EXCLUDED.related_call_id,
      resolved_model_id = EXCLUDED.resolved_model_id,
      requested_alias = EXCLUDED.requested_alias,
      baikai_call_id = EXCLUDED.baikai_call_id,
      attempt = EXCLUDED.attempt,
      call_status = EXCLUDED.call_status,
      evidence_strength = EXCLUDED.evidence_strength,
      evidence = EXCLUDED.evidence,
      updated_at = now()
    """
    ( ((\CallProjection {runId} -> runId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\CallProjection {callId} -> callId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\CallProjection {sourceRunId} -> sourceRunId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\CallProjection {relationship} -> relationship) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\CallProjection {relatedCallId} -> relatedCallId) >$< Encoders.param (Encoders.nullable Encoders.text))
        <> ((\CallProjection {resolvedModelId} -> resolvedModelId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\CallProjection {requestedAlias} -> requestedAlias) >$< Encoders.param (Encoders.nullable Encoders.text))
        <> ((\CallProjection {baikaiCallId} -> baikaiCallId) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\CallProjection {attempt} -> attempt) >$< Encoders.param (Encoders.nonNullable Encoders.int8))
        <> ((\CallProjection {callStatus} -> callStatus) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\CallProjection {evidenceStrength} -> evidenceStrength) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\CallProjection {evidence} -> evidence) >$< Encoders.param (Encoders.nonNullable Encoders.jsonb))
    )
    Decoders.noResult

findRunStatement :: Statement Text (Maybe RawStoredRun)
findRunStatement =
  preparable
    """
    SELECT run_evidence_id, run_id, status, verdict, reasons, binding,
           observations, expected_call_count, recorded_call_count
      FROM shikigami.run_evidence
     WHERE run_id = $1
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    ( Decoders.rowMaybe
        ( (,,,,,,,,)
            <$> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.jsonb)
            <*> Decoders.column (Decoders.nonNullable Decoders.jsonb)
            <*> Decoders.column (Decoders.nonNullable Decoders.jsonb)
            <*> Decoders.column (Decoders.nonNullable Decoders.int4)
            <*> Decoders.column (Decoders.nonNullable Decoders.int4)
        )
    )

findCallsStatement :: Statement Text [StoredCallEvidence]
findCallsStatement =
  preparable
    """
    SELECT call_id, source_run_id, relationship, related_call_id,
           resolved_model_id, requested_alias, baikai_call_id, attempt,
           call_status, evidence_strength, evidence
      FROM shikigami.run_evidence_calls
     WHERE run_id = $1
     ORDER BY call_id
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    ( Decoders.rowList
        ( StoredCallEvidence
            <$> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.int8)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.jsonb)
        )
    )

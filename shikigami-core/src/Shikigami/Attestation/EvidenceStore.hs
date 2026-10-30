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
    persistEvidenceTransitionFacts,
    findRunEvidence,
  )
where

import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Command (CommandError (..))
import Keiro.Projection (ProjectionCommandOutcome (..), runCommandWithCatalogProjections)
import Keiro.Projection.Catalog qualified as ProjectionCatalog
import Keiro.ReadModel (runQuery)
import Keiro.ReadModel.Rebuild (RebuildRunId)
import Keiro.Stream qualified as Stream
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect (Store, runStorePool)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Shikigami.App (CommandEffects, commandOptions)
import Shikigami.Attestation.CallFacts (CallComplianceFacts (..))
import Shikigami.Attestation.Compliance (ComplianceRollUp (..))
import Shikigami.Attestation.Evidence
import Shikigami.Log.Correlation (CallCorrelationId, RunCorrelationId, renderCallCorrelationId, renderRunCorrelationId)
import Shikigami.Prelude hiding ((.=))
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.RunEvidence.Generated.EventStream (runEvidenceCategory, runEvidenceEventStream)
import Shikigami.RunEvidence.Query
import Shikigami.RunEvidenceLookup.Generated.ReadModel (runEvidenceLookupReadModel)

newtype EvidenceStore = EvidenceStore {store :: KirokuStore}

postgresEvidenceStore :: KirokuStore -> EvidenceStore
postgresEvidenceStore = EvidenceStore

data EvidencePersistenceError
  = InvalidEvidenceTransition !TransitionError
  | EvidenceCommandFailed !CommandError
  | EvidenceProjectionFenced !ProjectionCatalog.RebuildGroupId !RebuildRunId
  | EvidenceProjectionUnregistered !ProjectionCatalog.RebuildGroupId
  | EvidenceProjectionRevisionUnavailable !ProjectionCatalog.RebuildGroupId !ProjectionCatalog.ProjectionRevisionId
  | EvidenceProjectionBindingInvalid !ProjectionCatalog.RebuildGroupId !ProjectionCatalog.ProjectionRevisionId !Text
  | EvidenceProjectionCatalogMismatch !ProjectionCatalog.SourceId
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
  deriving stock (Generic)

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
    KirokuStoreResource :> es,
    CommandEffects es
  ) =>
  EvidenceStore ->
  RunEvidence ->
  EvidencePhase ->
  Maybe ComplianceRollUp ->
  Eff es (Either EvidencePersistenceError RunEvidence)
persistEvidenceTransition = persistEvidenceTransitionUsing Nothing

-- | Restarted finalization retains exact stored provider JSON while the common
-- evaluator consumes normalized facts. No typed provider decoder is involved.
persistEvidenceTransitionFacts ::
  (IOE :> es, Store :> es, Error StoreError :> es, KirokuStoreResource :> es, CommandEffects es) =>
  [(CallComplianceFacts, Value)] ->
  EvidenceStore ->
  RunEvidence ->
  EvidencePhase ->
  Maybe ComplianceRollUp ->
  Eff es (Either EvidencePersistenceError RunEvidence)
persistEvidenceTransitionFacts facts = persistEvidenceTransitionUsing (Just facts)

persistEvidenceTransitionUsing ::
  (IOE :> es, Store :> es, Error StoreError :> es, KirokuStoreResource :> es, CommandEffects es) =>
  Maybe [(CallComplianceFacts, Value)] ->
  EvidenceStore ->
  RunEvidence ->
  EvidencePhase ->
  Maybe ComplianceRollUp ->
  Eff es (Either EvidencePersistenceError RunEvidence)
persistEvidenceTransitionUsing recovered evidenceStore runEvidence@RunEvidence {runEvidenceId = aggregateId, runId = correlationId, phase = currentPhase} target rollUp
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
                  originalProjection = runProjection advanced rollUp
                  projection = case recovered of
                    Nothing -> originalProjection
                    Just facts -> originalProjection & #recordedCallCount .~ fromIntegral (length facts)
                  callProjections = case recovered of
                    Nothing -> callProjection (renderRunCorrelationId advancedRunId) <$> advancedCalls
                    Just facts -> [factsProjection (renderRunCorrelationId advancedRunId) fact raw | (fact, raw) <- facts]
              let (catalog, projectionSet) = Catalog.withLiveEvidence (\_ _ -> persistProjection projection callProjections)
              options <- commandOptions
              result <-
                runCommandWithCatalogProjections
                  options
                  runEvidenceEventStream
                  targetStream
                  command
                  catalog
                  projectionSet
              case result of
                Right (ProjectionCommandApplied _) -> pure (Right advanced)
                Right (ProjectionCommandFenced group run) -> pure (Left (EvidenceProjectionFenced group run))
                Right (ProjectionCommandGroupUnregistered group) -> pure (Left (EvidenceProjectionUnregistered group))
                Right (ProjectionCommandServingRevisionUnavailable group revision) -> pure (Left (EvidenceProjectionRevisionUnavailable group revision))
                Right (ProjectionCommandServingBindingInvalid group revision detail) -> pure (Left (EvidenceProjectionBindingInvalid group revision detail))
                Right (ProjectionCommandCatalogMismatch source) -> pure (Left (EvidenceProjectionCatalogMismatch source))
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
      [ "agentVersion" .= agentVersion,
        "artifacts" .= artifacts,
        "reviewed" .= reviewed,
        "profile" .= profile,
        "reviewRequestId" .= reviewRequestId,
        "idempotencyKey" .= idempotencyKey
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
      [ "expectedCalls" .= expectedCalls,
        "deterministicSteps" .= deterministicSteps,
        "expectedChildRunIds" .= (renderRunCorrelationId <$> expectedChildRunIds),
        "delegatedChildren" .= (childValue <$> delegatedChildren),
        "observedArtifactDigest" .= observedArtifactDigest,
        "resultEvidence" .= resultEvidence,
        "durationSeconds" .= durationSeconds,
        "peakConcurrency" .= peakConcurrency
      ]

childValue :: RelevantChild -> Value
childValue RelevantChild {childRunId, parentRunWorkflowId, parentSessionId, phase, calls} =
  Aeson.object
    [ "childRunId" .= renderRunCorrelationId childRunId,
      "parentRunWorkflowId" .= parentRunWorkflowId.unWorkflowId,
      "parentSessionId" .= parentSessionId,
      "phase" .= phase,
      "callIds" .= (renderCallCorrelationId . recordedCallId <$> calls)
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

factsProjection :: Text -> CallComplianceFacts -> Value -> CallProjection
factsProjection ownerRunId facts raw =
  let (relationshipText, relatedCallId) = relationshipParts facts.relationship
   in CallProjection
        { runId = ownerRunId,
          callId = renderCallCorrelationId facts.callId,
          sourceRunId = facts.providerRunId,
          relationship = relationshipText,
          relatedCallId,
          resolvedModelId = facts.resolvedModelId,
          requestedAlias = facts.requestedAlias,
          baikaiCallId = facts.providerCallId,
          attempt = fromIntegral facts.attempt,
          callStatus = jsonString facts.status,
          evidenceStrength = jsonString facts.strength,
          evidence = raw
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

verdictText :: ComplianceVerdict -> Text
verdictText = \case
  VerdictSanctioned -> "sanctioned"
  VerdictNotSanctioned -> "not-sanctioned"
  VerdictIncomplete -> "incomplete"
  VerdictFailed -> "failed"

-- | Query the run projection and every accounted call by run correlation id.
findRunEvidence :: EvidenceStore -> RunCorrelationId -> IO (Maybe StoredRunEvidence)
findRunEvidence EvidenceStore {store} requestedRunId = do
  result <-
    runEff . runErrorNoCallStack @StoreError . runStorePool store $
      runQuery Nothing runEvidenceLookupReadModel (renderRunCorrelationId requestedRunId)
  queried <- either (ioError . userError . show) pure result
  stored <- either (ioError . userError . show) pure queried
  traverse (uncurry decodeStoredRun) stored

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

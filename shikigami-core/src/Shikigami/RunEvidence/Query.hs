-- | SQL query adapters for the catalog-owned live evidence tables.
module Shikigami.RunEvidence.Query
  ( ComplianceVerdict (..),
    StoredRunEvidence (..),
    StoredCallEvidence (..),
    RawStoredRun,
    findRunTransaction,
    decodeStoredRun,
  )
where

import Data.Aeson (Result (..), Value, fromJSON)
import Data.Int (Int32, Int64)
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Shikigami.Attestation.Evidence (EvidencePhase (..), RunEvidenceId, parseRunEvidenceId)
import Shikigami.Attestation.Reviewed (NonConformingReason)
import Shikigami.Prelude

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

parseVerdict :: Text -> Either Text ComplianceVerdict
parseVerdict = \case
  "sanctioned" -> Right VerdictSanctioned
  "not-sanctioned" -> Right VerdictNotSanctioned
  "incomplete" -> Right VerdictIncomplete
  "failed" -> Right VerdictFailed
  other -> Left ("unknown compliance verdict " <> other)

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

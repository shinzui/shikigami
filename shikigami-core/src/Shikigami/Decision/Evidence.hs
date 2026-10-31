-- | Append-only actual-attempt accounting. A run-row lock serializes admission,
-- terminal convergence and report refresh across workers and connections.
module Shikigami.Decision.Evidence
  ( DecisionEvidenceStore,
    postgresDecisionEvidenceStore,
    ensureInvocation,
    decisionCallHooks,
    DecisionEvidenceReport (..),
    StoredDecisionCall (..),
    readDecisionReport,
    finalizeDecisionReport,
    listDecisionCalls,
  )
where

import Baikai.Evidence qualified as Baikai
import Control.Lens ((&), (.~))
import Data.Aeson (FromJSON, Result (..), ToJSON, Value (..), fromJSON, object, toJSON, (.=))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as Sessions
import Numeric.Natural (Natural)
import Shikigami.Attestation.CallFacts
import Shikigami.Attestation.Compliance (ComplianceRollUp, evaluateCallFacts)
import Shikigami.Attestation.Evidence (CallRelationship (RootCall), ExpectedCall (..))
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile (..))
import Shikigami.Behavior.Provider.Coordinate (providerCoordinateText)
import Shikigami.Decision.Contract
import Shikigami.Log.Correlation (RunCorrelationId, callCorrelationId, renderCallCorrelationId, renderRunCorrelationId, runCorrelationId)

newtype DecisionEvidenceStore = DecisionEvidenceStore Pool

postgresDecisionEvidenceStore :: Pool -> DecisionEvidenceStore
postgresDecisionEvidenceStore = DecisionEvidenceStore

data StoredDecisionCall = StoredDecisionCall
  { callId :: !DecisionCallId,
    correlationId :: !Text,
    invocationId :: !Text,
    ordinal :: !DecisionCallOrdinal,
    model :: !ModelDescriptor,
    terminal :: !(Maybe CallTerminal),
    facts :: !(Maybe CallComplianceFacts),
    evidence :: !(Maybe Value)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data DecisionEvidenceReport = DecisionEvidenceReport
  { format :: !Natural,
    runId :: !RunCorrelationId,
    profile :: !(Maybe ResolvedProfile),
    invocations :: ![Value],
    calls :: ![StoredDecisionCall],
    complete :: !Bool,
    assessment :: !(Maybe ComplianceRollUp)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- An invocation binding deliberately omits its input: the journal owns it. The
-- commitment still detects reuse with different input without storing prompts.
invocationBinding :: PreparedDecision -> Value
invocationBinding prepared =
  object
    [ "format" .= (1 :: Int),
      "identity" .= prepared.identity,
      "runId" .= prepared.runId,
      "workflowId" .= prepared.workflowId,
      "generation" .= prepared.generation,
      "label" .= prepared.label,
      "program" .= prepared.program,
      "model" .= prepared.model,
      "policy" .= prepared.policy,
      "inputDigest" .= versionedDigest "shikigami.decision-input/1" prepared.input
    ]

ensureInvocation :: DecisionEvidenceStore -> Maybe ResolvedProfile -> PreparedDecision -> IO (Either DecisionFailure ())
ensureInvocation store profile prepared = transaction store (ensureTx profile prepared)

ensureTx :: Maybe ResolvedProfile -> PreparedDecision -> Tx.Transaction (Either DecisionFailure ())
ensureTx profile prepared = do
  let binding = invocationBinding prepared
      run = object ["runId" .= prepared.runId, "profile" .= profile]
  Tx.statement run insertRun
  (storedProfile, _) <- Tx.statement (renderRunCorrelationId prepared.runId) lockRun
  if storedProfile /= toJSON profile || prepared.policy /= ((\p -> p.ref) <$> profile)
    then pure (refuse ContractMismatch "decision run profile binding conflicts")
    else do
      Tx.statement binding insertInvocation
      stored <- Tx.statement prepared.identity findInvocation
      pure (if stored == binding then Right () else refuse ContractMismatch "decision invocation immutable binding conflicts")

decisionCallHooks :: DecisionEvidenceStore -> Maybe ResolvedProfile -> DecisionCallHooks
decisionCallHooks store profile = DecisionCallHooks begin finish
  where
    begin context = do
      -- Entity allocation is outside retryable SQL transactions. Run ordinal and
      -- expectation commit together under the database lock.
      token <- newAttemptToken firstDecisionCallOrdinal
      transaction store do
        ensured <- ensureTx profile context.prepared
        case ensured of
          Left err -> pure (Left err)
          Right () -> do
            let prepared = context.prepared
            (_, started) <- Tx.statement (renderRunCorrelationId prepared.runId) lockRun
            now <- Tx.statement () currentTime
            previous <- Tx.statement (renderRunCorrelationId prepared.runId) allCalls
            case decodeCalls previous of
              Left err -> pure (Left err)
              Right calls -> case admit now started profile calls >> first (const (decisionFailure CallLimitExceeded "decision call ordinal exhausted")) (parseDecisionCallOrdinal (toInteger (length calls) + 1)) of
                Left err -> pure (Left err)
                Right ordinal -> do
                  let correlation = callCorrelationId prepared.runId (decisionCallIdText (attemptId token)) 0
                      row =
                        object
                          [ "callId" .= attemptId token,
                            "correlationId" .= renderCallCorrelationId correlation,
                            "runId" .= prepared.runId,
                            "invocationId" .= prepared.identity,
                            "ordinal" .= ordinal,
                            "model" .= context.effectiveModel
                          ]
                  if context.effectiveModel /= prepared.model
                    then pure (refuse ContractMismatch "decision attempt tuple differs from preparation")
                    else do
                      Tx.statement row insertAttempt
                      -- Preserve the allocated ID while assigning the serialized ordinal.
                      pure (Right (withAttemptOrdinal ordinal token))
    finish token terminal evidence = transaction store do
      found <- Tx.statement (decisionCallIdText (attemptId token)) findAttemptForUpdate
      case found of
        Nothing -> pure (refuse EvidenceFailure "unknown decision attempt")
        Just (runId, _invocationId, ordinal, modelJson, oldTerminal) -> do
          _ <- Tx.statement runId lockRun
          case decode modelJson of
            Left err -> pure (Left err)
            Right (model :: ModelDescriptor) -> do
              let correlation = callCorrelationId (runCorrelationId runId) (decisionCallIdText (attemptId token)) 0
                  facts =
                    ( \ev ->
                        factsFromTerminal
                          correlation
                          RootCall
                          (fromMaybe (providerCoordinateText model.modelId) (Baikai.observedValue ev.observedModel))
                          Nothing
                          ev
                    )
                      <$> evidence
                  normalized = (\fact -> (fact & #relationshipKnown .~ (False))) <$> facts
                  payload = object ["terminal" .= terminal, "facts" .= normalized, "evidence" .= (toJSON <$> evidence)]
              if toInteger ordinal /= toInteger (decisionCallOrdinalNumber (attemptOrdinal token))
                then pure (refuse ContractMismatch "decision attempt ordinal differs")
                else
                  if terminal == CallSucceeded && isNothing evidence
                    then pure (refuse EvidenceFailure "successful decision attempt lacks provider evidence")
                    else case oldTerminal of
                      Just previous | previous /= payload -> pure (refuse EvidenceFailure "decision terminal conflicts with stored evidence")
                      Just _ -> pure (Right ())
                      Nothing -> do
                        Tx.statement (object ["callId" .= attemptId token, "payload" .= payload]) updateTerminal
                        pure (Right ())

-- | Bounded run-wide admission includes unresolved/unknown spending from prior
-- processes. A capped resource cannot be treated as zero when its facts are lost.
admit :: UTCTime -> UTCTime -> Maybe ResolvedProfile -> [StoredDecisionCall] -> Either DecisionFailure ()
admit now started profile calls
  | length calls >= 10000 = refuse CallLimitExceeded "decision run attempt hard limit reached"
  | otherwise = case profile of
      Nothing -> Right ()
      Just pinned -> do
        let limits = pinned.profile.limits
            facts = [fact | call <- calls, Just fact <- [call.facts]]
            unresolved = any (isNothing . (\call -> call.terminal)) calls
            unknownTokens = unresolved || length facts /= length calls || any (isNothing . (\fact -> fact.tokens)) facts
            unknownCost = unresolved || length facts /= length calls || any (\fact -> fact.costUncertain || isNothing fact.costMicroUsd) facts
            tokens = sum [n | fact <- facts, Just n <- [fact.tokens]]
            cost = sum [n | fact <- facts, Just n <- [fact.costMicroUsd]]
        check (maybe False (length calls >=) limits.maxCalls) "decision run call budget exhausted"
        check (maybe False (\seconds -> diffUTCTime now started >= fromIntegral seconds) limits.maxDurationSeconds) "decision run duration exhausted"
        check (isJust limits.maxTokens && (unknownTokens || maybe False (tokens >=) (fromIntegral <$> limits.maxTokens))) "decision token accounting is exhausted or uncertain"
        check (isJust limits.maxCostMicroUsd && (unknownCost || maybe False (cost >=) (fromInteger <$> limits.maxCostMicroUsd))) "decision cost accounting is exhausted or uncertain"
        check (maybe False (\maximum -> length [() | call <- calls, isNothing call.terminal] >= maximum) limits.maxConcurrency) "decision run concurrency limit reached"
  where
    check True detail = refuse CallLimitExceeded detail
    check False _ = Right ()

readDecisionReport :: DecisionEvidenceStore -> RunCorrelationId -> IO (Either DecisionFailure (Maybe DecisionEvidenceReport))
readDecisionReport store runId = transaction store (reportTx runId)

finalizeDecisionReport :: DecisionEvidenceStore -> RunCorrelationId -> IO (Either DecisionFailure (Maybe DecisionEvidenceReport))
finalizeDecisionReport store runId = transaction store do
  report <- reportTx runId
  case report of
    Right (Just value) -> Tx.statement (object ["runId" .= runId, "report" .= value]) saveReport
    _ -> pure ()
  pure report

reportTx :: RunCorrelationId -> Tx.Transaction (Either DecisionFailure (Maybe DecisionEvidenceReport))
reportTx runId = do
  found <- Tx.statement (renderRunCorrelationId runId) maybeRun
  case found of
    Nothing -> pure (Right Nothing)
    Just rawProfile -> do
      _ <- Tx.statement (renderRunCorrelationId runId) lockRun
      raw <- Tx.statement (renderRunCorrelationId runId) allCalls
      invocations <- Tx.statement (renderRunCorrelationId runId) findInvocations
      pure do
        profile <- decode rawProfile
        calls <- decodeCalls raw
        whenTooManyInvocations invocations
        let facts = [facts | call <- calls, Just facts <- [call.facts]]
            expected = [ExpectedCall (callCorrelationId runId (decisionCallIdText call.callId) 0) RootCall (decisionCallOrdinalNumber call.ordinal) | call <- calls]
        Right
          ( Just
              ( DecisionEvidenceReport
                  1
                  runId
                  profile
                  invocations
                  calls
                  (all (\call -> isJust call.terminal && isJust call.facts && isJust call.evidence) calls)
                  ((\p -> evaluateCallFacts p.profile expected facts) <$> profile)
              )
          )

-- | Detail pages are bounded independently of the report's 10,000-attempt run
-- cap. Stable run ordinals are the cursor, so concurrent inserts cannot reorder.
listDecisionCalls :: DecisionEvidenceStore -> RunCorrelationId -> Natural -> Int -> IO (Either DecisionFailure [StoredDecisionCall])
listDecisionCalls store runId after limit = transaction store do
  rows <- Tx.statement (object ["runId" .= runId, "after" .= min 10000 after, "limit" .= max 1 (min 200 limit)]) callPage
  pure (decodeCalls rows)

transaction :: DecisionEvidenceStore -> Tx.Transaction (Either DecisionFailure a) -> IO (Either DecisionFailure a)
transaction (DecisionEvidenceStore pool) tx = do
  result <- Pool.use pool (Sessions.transaction Sessions.ReadCommitted Sessions.Write tx)
  pure (either (const (refuse EvidenceFailure "decision evidence persistence is unavailable")) id result)

decode :: (FromJSON a) => Value -> Either DecisionFailure a
decode value = case fromJSON value of
  Success decoded -> Right decoded
  Error _ -> refuse UnsupportedVersion "decision evidence facts or binding version is unsupported"

decodeCalls :: [Value] -> Either DecisionFailure [StoredDecisionCall]
decodeCalls values
  | length values > 10000 = refuse CallLimitExceeded "decision run exceeds bounded report capacity"
  | otherwise = traverse decode values

refuse :: FailureCode -> Text -> Either DecisionFailure a
refuse code = Left . decisionFailure code

jsonInput :: E.Params Value
jsonInput = E.param (E.nonNullable E.jsonb)

textInput :: E.Params Text
textInput = E.param (E.nonNullable E.text)

jsonOutput :: D.Result Value
jsonOutput = D.singleRow (D.column (D.nonNullable D.jsonb))

jsonRows :: D.Result [Value]
jsonRows = D.rowList (D.column (D.nonNullable D.jsonb))

insertRun :: Statement Value ()
insertRun = preparable "INSERT INTO shikigami.decision_runs(run_id,profile) VALUES ($1->>'runId',$1->'profile') ON CONFLICT DO NOTHING" jsonInput D.noResult

lockRun :: Statement Text (Value, UTCTime)
lockRun = preparable "SELECT profile,started_at FROM shikigami.decision_runs WHERE run_id=$1 FOR UPDATE" textInput (D.singleRow ((,) <$> D.column (D.nonNullable D.jsonb) <*> D.column (D.nonNullable D.timestamptz)))

maybeRun :: Statement Text (Maybe Value)
maybeRun = preparable "SELECT profile FROM shikigami.decision_runs WHERE run_id=$1" textInput (D.rowMaybe (D.column (D.nonNullable D.jsonb)))

insertInvocation :: Statement Value ()
insertInvocation = preparable "INSERT INTO shikigami.decision_invocations(invocation_id,run_id,binding) VALUES ($1->>'identity',$1->>'runId',$1) ON CONFLICT DO NOTHING" jsonInput D.noResult

findInvocation :: Statement Text Value
findInvocation = preparable "SELECT binding FROM shikigami.decision_invocations WHERE invocation_id=$1" textInput jsonOutput

insertAttempt :: Statement Value ()
insertAttempt = preparable "WITH invalidate AS (UPDATE shikigami.decision_runs SET report=NULL WHERE run_id=$1->>'runId') INSERT INTO shikigami.decision_attempts(call_id,correlation_id,run_id,invocation_id,ordinal,effective_model) VALUES ($1->>'callId',$1->>'correlationId',$1->>'runId',$1->>'invocationId',($1->>'ordinal')::bigint,$1->'model')" jsonInput D.noResult

findAttemptForUpdate :: Statement Text (Maybe (Text, Text, Int64, Value, Maybe Value))
findAttemptForUpdate = preparable "SELECT run_id,invocation_id,ordinal,effective_model,terminal FROM shikigami.decision_attempts WHERE call_id=$1 FOR UPDATE" textInput (D.rowMaybe ((,,,,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.jsonb) <*> D.column (D.nullable D.jsonb)))

updateTerminal :: Statement Value ()
updateTerminal = preparable "UPDATE shikigami.decision_attempts SET terminal=$1->'payload', facts=NULLIF($1->'payload'->'facts','null'::jsonb),evidence=NULLIF($1->'payload'->'evidence','null'::jsonb),finished_at=clock_timestamp() WHERE call_id=$1->>'callId'" jsonInput D.noResult

saveReport :: Statement Value ()
saveReport = preparable "UPDATE shikigami.decision_runs SET report=$1->'report' WHERE run_id=$1->>'runId'" jsonInput D.noResult

findInvocations :: Statement Text [Value]
findInvocations = preparable "SELECT binding FROM shikigami.decision_invocations WHERE run_id=$1 ORDER BY invocation_id LIMIT 10001" textInput jsonRows

callProjection :: Text
callProjection = "jsonb_build_object('callId',call_id,'correlationId',correlation_id,'invocationId',invocation_id,'ordinal',ordinal,'model',effective_model,'terminal',terminal->'terminal','facts',facts,'evidence',evidence)"

allCalls :: Statement Text [Value]
allCalls = preparable ("SELECT " <> callProjection <> " FROM shikigami.decision_attempts WHERE run_id=$1 ORDER BY ordinal LIMIT 10001") textInput jsonRows

callPage :: Statement Value [Value]
callPage = preparable ("SELECT " <> callProjection <> " FROM shikigami.decision_attempts WHERE run_id=$1->>'runId' AND ordinal>($1->>'after')::bigint ORDER BY ordinal LIMIT ($1->>'limit')::integer") jsonInput jsonRows

currentTime :: Statement () UTCTime
currentTime = preparable "SELECT clock_timestamp()" E.noParams (D.singleRow (D.column (D.nonNullable D.timestamptz)))

whenTooManyInvocations :: [Value] -> Either DecisionFailure ()
whenTooManyInvocations rows
  | length rows > 10000 = refuse CallLimitExceeded "decision invocation report capacity exceeded"
  | otherwise = Right ()

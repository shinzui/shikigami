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
    readDecisionReportTx,
    finalizeDecisionReport,
    listDecisionCalls,
    listDecisionCallsTx,
  )
where

import Baikai.Evidence qualified as Baikai
import Control.Lens ((&), (.~))
import Data.Aeson (FromJSON (..), Result (..), ToJSON (..), Value (..), fromJSON, object, withObject, withText, (.:), (.=))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Time (UTCTime, diffUTCTime)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as Sessions
import Keiro.Workflow.Types (WorkflowId (..))
import Numeric.Natural (Natural)
import Shikigami.Attestation.CallFacts
import Shikigami.Attestation.Compliance (ComplianceRollUp, evaluateCallFacts)
import Shikigami.Attestation.Evidence (CallRelationship (RootCall), ExpectedCall (..))
import Shikigami.Attestation.PolicyValue
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile, ResolvedProfileView (..), resolvedProfileView)
import Shikigami.Behavior.Provider.Coordinate (providerCoordinateText)
import Shikigami.Decision.Contract
import Shikigami.Log.Correlation (CallCorrelationId, RunCorrelationId, callCorrelationId, renderCallCorrelationId, renderRunCorrelationId, runCorrelationId)

newtype DecisionEvidenceStore = DecisionEvidenceStore Pool

postgresDecisionEvidenceStore :: Pool -> DecisionEvidenceStore
postgresDecisionEvidenceStore = DecisionEvidenceStore

data StoredDecisionCall = StoredDecisionCall
  { callId :: !DecisionCallId,
    correlationId :: !CallCorrelationId,
    invocationId :: !DecisionPreparationId,
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

-- Input remains in the protected journal. This separate commitment is not a
-- preparation identity or authority to dispatch a provider call.
newtype InvocationInputDigest = InvocationInputDigest Text
  deriving stock (Eq, Show)

instance ToJSON InvocationInputDigest where
  toJSON (InvocationInputDigest value) = toJSON value

instance FromJSON InvocationInputDigest where
  parseJSON = withText "decision input commitment" \value -> case parseProgramParameterDigest value of
    Left _ -> fail "invalid decision input commitment"
    Right digest -> pure (InvocationInputDigest (programParameterDigestText digest))

data InvocationBinding = InvocationBinding
  { identity :: !DecisionPreparationId,
    runId :: !RunCorrelationId,
    workflowId :: !WorkflowId,
    generation :: !DecisionGeneration,
    label :: !DecisionSlotLabel,
    program :: !ProgramDescriptor,
    model :: !ModelDescriptor,
    policy :: !(Maybe Profile.SanctionedExecutionProfileRef),
    inputDigest :: !InvocationInputDigest
  }
  deriving stock (Eq, Show)

instance ToJSON InvocationBinding where
  toJSON value = object ["format" .= (1 :: Int), "identity" .= value.identity, "runId" .= value.runId, "workflowId" .= value.workflowId.unWorkflowId, "generation" .= value.generation, "label" .= value.label, "program" .= value.program, "model" .= value.model, "policy" .= value.policy, "inputDigest" .= value.inputDigest]

instance FromJSON InvocationBinding where
  parseJSON = withObject "decision invocation binding" \o -> do
    format <- o .: "format"
    if format /= (1 :: Int)
      then fail "unsupported decision invocation format"
      else InvocationBinding <$> o .: "identity" <*> o .: "runId" <*> (WorkflowId <$> o .: "workflowId") <*> o .: "generation" <*> o .: "label" <*> o .: "program" <*> o .: "model" <*> o .: "policy" <*> o .: "inputDigest"

invocationBinding :: PreparedDecision -> InvocationBinding
invocationBinding prepared = InvocationBinding prepared.identity prepared.runId prepared.workflowId prepared.generation prepared.label prepared.program prepared.model prepared.policy (InvocationInputDigest (versionedDigest "shikigami.decision-input/1" prepared.input))

-- SQL transfer representations are consumed only by decodeCall. Keep the whole
-- terminal envelope: SQL JSON extraction could hide a present malformed value.
data RawCall = RawCall
  { runId :: !Text,
    callId :: !Text,
    correlationId :: !Text,
    invocationId :: !Text,
    ordinal :: !Int64,
    model :: !Value,
    terminal :: !(Maybe Value),
    facts :: !(Maybe Value),
    evidence :: !(Maybe Value)
  }

data TerminalEnvelope = TerminalEnvelope
  { terminal :: !CallTerminal,
    facts :: !(Maybe Value),
    evidence :: !(Maybe Value)
  }

instance FromJSON TerminalEnvelope where
  parseJSON = withObject "decision terminal envelope" \o -> TerminalEnvelope <$> o .: "terminal" <*> o .: "facts" <*> o .: "evidence"

ensureInvocation :: DecisionEvidenceStore -> Maybe ResolvedProfile -> PreparedDecision -> IO (Either DecisionFailure ())
ensureInvocation store profile prepared = transaction store (ensureTx profile prepared)

ensureTx :: Maybe ResolvedProfile -> PreparedDecision -> Tx.Transaction (Either DecisionFailure ())
ensureTx profile prepared = do
  let binding = invocationBinding prepared
      run = object ["runId" .= prepared.runId, "profile" .= profile]
  Tx.statement run insertRun
  (rawProfile, _) <- Tx.statement (renderRunCorrelationId prepared.runId) lockRun
  retainedBindings <- readInvocationsTx prepared.runId
  storedProfile <- checkedRead do
    actual <- decodeProfile rawProfile
    bindings <- retainedBindings
    validateInvocationPolicies actual bindings
    pure actual
  case storedProfile of
    Left err -> pure (Left err)
    Right actual
      | rawProfile /= toJSON profile || actual /= profile || prepared.policy /= ((\p -> (resolvedProfileView p).ref) <$> profile) -> pure (refuse ContractMismatch "decision run profile binding conflicts")
      | otherwise -> do
          Tx.statement (toJSON binding) insertInvocation
          stored <- readInvocationTx prepared.identity
          pure do
            (raw, actualBinding) <- stored
            if raw == toJSON binding && actualBinding == binding then Right () else refuse ContractMismatch "decision invocation immutable binding conflicts"

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
            previous <- Tx.statement (renderRunCorrelationId prepared.runId) allCalls >>= checkedRead . decodeCalls
            case previous of
              Left err -> pure (Left err)
              Right calls -> do
                associated <- checkCallBindingsTx prepared.runId calls
                case associated >> admit now started profile calls >> first (const (decisionFailure CallLimitExceeded "decision call ordinal exhausted")) (parseDecisionCallOrdinal (toInteger (length calls) + 1)) of
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
        Just raw -> do
          _ <- Tx.statement raw.runId lockRun
          current <- checkedRead (decodeCall raw)
          case current of
            Left err -> pure (Left err)
            Right actual -> do
              associated <- checkCallBindingsTx (runCorrelationId raw.runId) [actual]
              case associated of
                Left err -> pure (Left err)
                Right () -> finishActual token terminal evidence raw actual
    finishActual :: AttemptToken -> CallTerminal -> Maybe Baikai.ModelCallEvidence -> RawCall -> StoredDecisionCall -> Tx.Transaction (Either DecisionFailure ())
    finishActual token terminal evidence raw actual = do
      let model = actual.model
          correlation = actual.correlationId
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
      if actual.ordinal /= attemptOrdinal token
        then pure (refuse ContractMismatch "decision attempt ordinal differs")
        else
          if terminal == CallSucceeded && isNothing evidence
            then pure (refuse EvidenceFailure "successful decision attempt lacks provider evidence")
            else case raw.terminal of
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
        let limits = (resolvedProfileView pinned).profile.limits
            facts = [fact | call <- calls, Just fact <- [call.facts]]
            unresolved = any (isNothing . (\call -> call.terminal)) calls
            unknownTokens = unresolved || length facts /= length calls || any (isNothing . (\fact -> fact.tokens)) facts
            unknownCost = unresolved || length facts /= length calls || any (\fact -> fact.costUncertain || isNothing fact.costMicroUsd) facts
            tokens = sum [n | fact <- facts, Just n <- [fact.tokens]]
            cost = sum [n | fact <- facts, Just n <- [fact.costMicroUsd]]
        check (maybe False (length calls >=) (ceilingValue <$> limits.maxCalls)) "decision run call budget exhausted"
        check (maybe False (\seconds -> diffUTCTime now started >= fromIntegral seconds) (ceilingValue <$> limits.maxDurationSeconds)) "decision run duration exhausted"
        check (isJust limits.maxTokens && (unknownTokens || maybe False (tokens >=) (fromIntegral . ceilingValue <$> limits.maxTokens))) "decision token accounting is exhausted or uncertain"
        check (isJust limits.maxCostMicroUsd && (unknownCost || maybe False (cost >=) (fromInteger . ceilingValue <$> limits.maxCostMicroUsd))) "decision cost accounting is exhausted or uncertain"
        check (maybe False (\maximum -> length [() | call <- calls, isNothing call.terminal] >= maximum) (ceilingValue <$> limits.maxConcurrency)) "decision run concurrency limit reached"
  where
    check True detail = refuse CallLimitExceeded detail
    check False _ = Right ()

readDecisionReport :: DecisionEvidenceStore -> RunCorrelationId -> IO (Either DecisionFailure (Maybe DecisionEvidenceReport))
readDecisionReport store runId = transaction store (reportTx runId)

readDecisionReportTx :: RunCorrelationId -> Tx.Transaction (Either DecisionFailure (Maybe DecisionEvidenceReport))
readDecisionReportTx = reportTx

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
      checkedRead do
        profile <- decodeProfile rawProfile
        calls <- decodeCalls raw
        whenTooManyInvocations invocations
        verified <- traverse checkInvocation invocations
        validateInvocationPolicies profile verified
        mapM_ (validateCallBinding (invocationIndex verified)) calls
        let facts = [facts | call <- calls, Just facts <- [call.facts]]
            expected = [ExpectedCall (callCorrelationId runId (decisionCallIdText call.callId) 0) RootCall (decisionCallOrdinalNumber call.ordinal) | call <- calls]
        Right
          ( Just
              ( DecisionEvidenceReport
                  1
                  runId
                  profile
                  (map fst verified)
                  calls
                  (all (\call -> isJust call.terminal && isJust call.facts && isJust call.evidence) calls)
                  ((\p -> evaluateCallFacts (resolvedProfileView p).profile expected facts) <$> profile)
              )
          )

-- | Detail pages are bounded independently of the report's 10,000-attempt run
-- cap. Stable run ordinals are the cursor, so concurrent inserts cannot reorder.
listDecisionCalls :: DecisionEvidenceStore -> RunCorrelationId -> Natural -> Int -> IO (Either DecisionFailure [StoredDecisionCall])
listDecisionCalls store runId after limit = transaction store (listDecisionCallsTx runId after limit)

listDecisionCallsTx :: RunCorrelationId -> Natural -> Int -> Tx.Transaction (Either DecisionFailure [StoredDecisionCall])
listDecisionCallsTx runId after limit = do
  rows <- Tx.statement (object ["runId" .= runId, "after" .= min 10000 after, "limit" .= max 1 (min 200 limit)]) callPage
  parsed <- checkedRead (decodeCalls rows)
  case parsed of
    Left err -> pure (Left err)
    Right calls -> do
      associated <- checkCallBindingsTx runId calls
      pure (calls <$ associated)

transaction :: DecisionEvidenceStore -> Tx.Transaction (Either DecisionFailure a) -> IO (Either DecisionFailure a)
transaction (DecisionEvidenceStore pool) tx = do
  result <- Pool.use pool (Sessions.transaction Sessions.ReadCommitted Sessions.Write tx)
  pure (either (const (refuse EvidenceFailure "decision evidence persistence is unavailable")) id result)

decode :: (FromJSON a) => Value -> Either DecisionFailure a
decode value = case fromJSON value of
  Success decoded -> Right decoded
  Error _ -> refuse UnsupportedVersion "decision evidence facts or binding version is unsupported"

checkedRead :: Either DecisionFailure a -> Tx.Transaction (Either DecisionFailure a)
checkedRead result = case result of
  Left _ -> Tx.condemn >> pure result
  Right _ -> pure result

decodeProfile :: Value -> Either DecisionFailure (Maybe ResolvedProfile)
decodeProfile = decode

checkInvocation :: (Value, Either DecisionFailure InvocationBinding) -> Either DecisionFailure (Value, InvocationBinding)
checkInvocation (raw, parsed) = (raw,) <$> parsed

decodeCall :: RawCall -> Either DecisionFailure StoredDecisionCall
decodeCall raw = do
  identifier <- first (const (decisionFailure UnsupportedVersion "invalid retained decision call identity")) (parseDecisionCallId raw.callId)
  invocation <- first (const (decisionFailure UnsupportedVersion "invalid retained decision preparation identity")) (parseDecisionPreparationId raw.invocationId)
  ordinal <- first (const (decisionFailure UnsupportedVersion "invalid retained decision ordinal")) (parseDecisionCallOrdinal (toInteger raw.ordinal))
  model <- decode raw.model
  let correlation = callCorrelationId (runCorrelationId raw.runId) raw.callId 0
  if renderCallCorrelationId correlation /= raw.correlationId
    then refuse UnsupportedVersion "inconsistent retained decision correlation"
    else case raw.terminal of
      Nothing
        | isNothing raw.facts && isNothing raw.evidence -> Right (StoredDecisionCall identifier correlation invocation ordinal model Nothing Nothing Nothing)
        | otherwise -> refuse UnsupportedVersion "decision facts without a terminal envelope"
      Just value -> do
        envelope <- decode @TerminalEnvelope value
        if envelope.facts /= raw.facts || envelope.evidence /= raw.evidence
          then refuse UnsupportedVersion "inconsistent retained decision terminal columns"
          else do
            facts <- traverse decode raw.facts
            if (envelope.terminal == CallSucceeded && isNothing raw.evidence) || isJust facts /= isJust raw.evidence || any (\fact -> fact.callId /= correlation || fact.relationship /= RootCall || fact.relationshipKnown) facts
              then refuse UnsupportedVersion "inconsistent retained decision terminal facts"
              else Right (StoredDecisionCall identifier correlation invocation ordinal model (Just envelope.terminal) facts raw.evidence)

validateCallBinding :: Map.Map DecisionPreparationId InvocationBinding -> StoredDecisionCall -> Either DecisionFailure ()
validateCallBinding bindings call = case Map.lookup call.invocationId bindings of
  Just binding | binding.model == call.model -> Right ()
  _ -> refuse UnsupportedVersion "missing or inconsistent decision invocation association"

invocationIndex :: [(Value, InvocationBinding)] -> Map.Map DecisionPreparationId InvocationBinding
invocationIndex = Map.fromList . map (\(_, binding) -> (binding.identity, binding))

readInvocationTx :: DecisionPreparationId -> Tx.Transaction (Either DecisionFailure (Value, InvocationBinding))
readInvocationTx identifier = do
  retained <- Tx.statement (decisionPreparationIdText identifier) findInvocation
  checkedRead (maybe (refuse UnsupportedVersion "missing retained decision invocation") checkInvocation retained)

readInvocationsTx :: RunCorrelationId -> Tx.Transaction (Either DecisionFailure [(Value, InvocationBinding)])
readInvocationsTx runId = do
  retained <- Tx.statement (renderRunCorrelationId runId) findInvocations
  checkedRead do
    whenTooManyInvocations retained
    traverse checkInvocation retained

checkCallBindingsTx :: RunCorrelationId -> [StoredDecisionCall] -> Tx.Transaction (Either DecisionFailure ())
checkCallBindingsTx runId calls = do
  rawProfile <- Tx.statement (renderRunCorrelationId runId) maybeRun
  retained <- readInvocationsTx runId
  checkedRead do
    bindings <- retained
    profile <- case rawProfile of
      Just raw -> decodeProfile raw
      Nothing | null calls && null bindings -> Right Nothing
      Nothing -> refuse UnsupportedVersion "missing retained decision run"
    validateInvocationPolicies profile bindings
    mapM_ (validateCallBinding (invocationIndex bindings)) calls

validateInvocationPolicies :: Maybe ResolvedProfile -> [(Value, InvocationBinding)] -> Either DecisionFailure ()
validateInvocationPolicies profile bindings
  | all (\(_, binding) -> binding.policy == ((\value -> (resolvedProfileView value).ref) <$> profile)) bindings = Right ()
  | otherwise = refuse UnsupportedVersion "inconsistent retained decision invocation policy"

decodeCalls :: [RawCall] -> Either DecisionFailure [StoredDecisionCall]
decodeCalls values
  | length values > 10000 = refuse CallLimitExceeded "decision run exceeds bounded report capacity"
  | otherwise = traverse decodeCall values

refuse :: FailureCode -> Text -> Either DecisionFailure a
refuse code = Left . decisionFailure code

jsonInput :: E.Params Value
jsonInput = E.param (E.nonNullable E.jsonb)

textInput :: E.Params Text
textInput = E.param (E.nonNullable E.text)

insertRun :: Statement Value ()
insertRun = preparable "INSERT INTO shikigami.decision_runs(run_id,profile) VALUES ($1->>'runId',$1->'profile') ON CONFLICT DO NOTHING" jsonInput D.noResult

lockRun :: Statement Text (Value, UTCTime)
lockRun = preparable "SELECT profile,started_at FROM shikigami.decision_runs WHERE run_id=$1 FOR UPDATE" textInput (D.singleRow ((,) <$> D.column (D.nonNullable D.jsonb) <*> D.column (D.nonNullable D.timestamptz)))

maybeRun :: Statement Text (Maybe Value)
maybeRun = preparable "SELECT profile FROM shikigami.decision_runs WHERE run_id=$1" textInput (D.rowMaybe (D.column (D.nonNullable D.jsonb)))

insertInvocation :: Statement Value ()
insertInvocation = preparable "INSERT INTO shikigami.decision_invocations(invocation_id,run_id,binding) VALUES ($1->>'identity',$1->>'runId',$1) ON CONFLICT DO NOTHING" jsonInput D.noResult

invocationRow :: D.Row (Value, Either DecisionFailure InvocationBinding)
invocationRow = check <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb)
  where
    check identifier run raw =
      ( raw,
        do
          binding <- decode raw
          if decisionPreparationIdText binding.identity == identifier && renderRunCorrelationId binding.runId == run
            then Right binding
            else refuse UnsupportedVersion "inconsistent retained decision invocation coordinates"
      )

findInvocation :: Statement Text (Maybe (Value, Either DecisionFailure InvocationBinding))
findInvocation = preparable "SELECT invocation_id,run_id,binding FROM shikigami.decision_invocations WHERE invocation_id=$1" textInput (D.rowMaybe invocationRow)

insertAttempt :: Statement Value ()
insertAttempt = preparable "WITH invalidate AS (UPDATE shikigami.decision_runs SET report=NULL WHERE run_id=$1->>'runId') INSERT INTO shikigami.decision_attempts(call_id,correlation_id,run_id,invocation_id,ordinal,effective_model) VALUES ($1->>'callId',$1->>'correlationId',$1->>'runId',$1->>'invocationId',($1->>'ordinal')::bigint,$1->'model')" jsonInput D.noResult

findAttemptForUpdate :: Statement Text (Maybe RawCall)
findAttemptForUpdate = preparable ("SELECT " <> callColumns <> " FROM shikigami.decision_attempts WHERE call_id=$1 FOR UPDATE") textInput (D.rowMaybe callRow)

updateTerminal :: Statement Value ()
updateTerminal = preparable "UPDATE shikigami.decision_attempts SET terminal=$1->'payload', facts=NULLIF($1->'payload'->'facts','null'::jsonb),evidence=NULLIF($1->'payload'->'evidence','null'::jsonb),finished_at=clock_timestamp() WHERE call_id=$1->>'callId'" jsonInput D.noResult

saveReport :: Statement Value ()
saveReport = preparable "UPDATE shikigami.decision_runs SET report=$1->'report' WHERE run_id=$1->>'runId'" jsonInput D.noResult

findInvocations :: Statement Text [(Value, Either DecisionFailure InvocationBinding)]
findInvocations = preparable "SELECT invocation_id,run_id,binding FROM shikigami.decision_invocations WHERE run_id=$1 ORDER BY invocation_id LIMIT 10001" textInput (D.rowList invocationRow)

callColumns :: Text
callColumns = "run_id,call_id,correlation_id,invocation_id,ordinal,effective_model,terminal,facts,evidence"

callRow :: D.Row RawCall
callRow = RawCall <$> text <*> text <*> text <*> text <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.jsonb) <*> optional <*> optional <*> optional
  where
    text = D.column (D.nonNullable D.text)
    optional = D.column (D.nullable D.jsonb)

allCalls :: Statement Text [RawCall]
allCalls = preparable ("SELECT " <> callColumns <> " FROM shikigami.decision_attempts WHERE run_id=$1 ORDER BY ordinal LIMIT 10001") textInput (D.rowList callRow)

callPage :: Statement Value [RawCall]
callPage = preparable ("SELECT " <> callColumns <> " FROM shikigami.decision_attempts WHERE run_id=$1->>'runId' AND ordinal>($1->>'after')::bigint ORDER BY ordinal LIMIT ($1->>'limit')::integer") jsonInput (D.rowList callRow)

currentTime :: Statement () UTCTime
currentTime = preparable "SELECT clock_timestamp()" E.noParams (D.singleRow (D.column (D.nonNullable D.timestamptz)))

whenTooManyInvocations :: [a] -> Either DecisionFailure ()
whenTooManyInvocations rows
  | length rows > 10000 = refuse CallLimitExceeded "decision invocation report capacity exceeded"
  | otherwise = Right ()

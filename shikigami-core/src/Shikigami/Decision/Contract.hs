{-# LANGUAGE DataKinds #-}

-- | Shikigami-owned wire contracts. Executables, prompts and credentials never
-- belong in these descriptors; preparation alone contains the validated input.
module Shikigami.Decision.Contract
  ( ModelAlias (..),
    ProgramDescriptor (..),
    ModelDescriptor (..),
    DecisionSlot (..),
    DecisionPolicySnapshot (..),
    PreparedDecision (..),
    DecisionOutcome (..),
    FailureCode (..),
    DecisionFailure,
    decisionFailure,
    failureCode,
    renderDecisionFailure,
    versionedDigest,
    DecisionCallContext (..),
    DecisionCallHooks (..),
    AttemptToken,
    DecisionCallId,
    parseDecisionCallId,
    decisionCallIdText,
    DecisionCallOrdinal,
    parseDecisionCallOrdinal,
    decisionCallOrdinalNumber,
    firstDecisionCallOrdinal,
    newAttemptToken,
    attemptId,
    attemptOrdinal,
    withAttemptOrdinal,
    CallTerminal (..),
    MemoryCall (..),
    newMemoryCallHooks,
  )
where

import Baikai.Evidence (ModelCallEvidence, commitmentDigest)
import Baikai.ThinkingLevel (ThinkingLevel)
import Control.Concurrent.MVar (modifyMVar, newMVar, readMVar)
import Control.Lens ((&), (.~))
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, withText, (.:), (.=))
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.Types (Parser)
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.KindID.V7 qualified as KindID
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Shikigami.Attestation.Profile (SanctionedExecutionProfileRef)
import Shikigami.Log.Correlation (RunCorrelationId)

newtype ModelAlias = ModelAlias Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | An immutable registration includes opaque code identity as well as all
-- serializable state. Equal request hashes cannot stand in for this identity.
data ProgramDescriptor = ProgramDescriptor
  { programId :: !Text,
    version :: !Text,
    implementationDigest :: !Text,
    inputSchemaVersion :: !Text,
    resultSchemaVersion :: !Text,
    validatorVersion :: !Text,
    parameterFormat :: !Natural,
    parameterDigest :: !Text,
    derivationVersion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON ProgramDescriptor where
  parseJSON = withObject "ProgramDescriptor" \o -> do
    parameterFormat <- o .: "parameterFormat"
    if parameterFormat /= (1 :: Natural)
      then fail "unsupported decision parameter format"
      else
        ProgramDescriptor
          <$> o .: "programId"
          <*> o .: "version"
          <*> o .: "implementationDigest"
          <*> o .: "inputSchemaVersion"
          <*> o .: "resultSchemaVersion"
          <*> o .: "validatorVersion"
          <*> pure parameterFormat
          <*> o .: "parameterDigest"
          <*> o .: "derivationVersion"

-- | Public metadata shared with whole-run selection. Binding versions describe
-- authority/endpoint semantics, not individual secret rotations.
data ModelDescriptor = ModelDescriptor
  { alias :: !ModelAlias,
    version :: !Text,
    digest :: !Text,
    provider :: !Text,
    api :: !Text,
    endpointClass :: !Text,
    modelId :: !Text,
    thinking :: !(Maybe ThinkingLevel),
    bindingId :: !Text,
    bindingVersion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data DecisionSlot = DecisionSlot
  { label :: !Text,
    programs :: ![ProgramDescriptor],
    models :: ![ModelAlias]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data DecisionPolicySnapshot = DecisionPolicySnapshot
  { slots :: ![DecisionSlot],
    models :: ![ModelDescriptor],
    policy :: !(Maybe SanctionedExecutionProfileRef)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON DecisionPolicySnapshot where
  toJSON DecisionPolicySnapshot {slots, models, policy} =
    object
      ["format" .= (1 :: Int), "slots" .= slots, "models" .= models, "policy" .= policy]

instance FromJSON DecisionPolicySnapshot where
  parseJSON = withObject "DecisionPolicySnapshot" \o -> do
    requireV1 o
    DecisionPolicySnapshot <$> o .: "slots" <*> o .: "models" <*> o .: "policy"

data PreparedDecision = PreparedDecision
  { identity :: !Text,
    runId :: !RunCorrelationId,
    workflowId :: !Text,
    generation :: !Natural,
    label :: !Text,
    program :: !ProgramDescriptor,
    input :: !Value,
    model :: !ModelDescriptor,
    policy :: !(Maybe SanctionedExecutionProfileRef)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A committed result is decoded by a retained pure codec, without executing
-- the program or reapplying a deployment's current domain validator.
data DecisionOutcome = DecisionOutcome
  { preparationId :: !Text,
    program :: !ProgramDescriptor,
    result :: !(Either DecisionFailure Value),
    attempts :: ![DecisionCallId]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON DecisionOutcome where
  toJSON DecisionOutcome {preparationId, program, result, attempts} =
    object
      [ "format" .= (1 :: Int),
        "preparationId" .= preparationId,
        "program" .= program,
        "result" .= result,
        "attempts" .= attempts
      ]

instance FromJSON DecisionOutcome where
  parseJSON = withObject "DecisionOutcome" \o -> do
    requireV1 o
    DecisionOutcome <$> o .: "preparationId" <*> o .: "program" <*> o .: "result" <*> o .: "attempts"

requireV1 :: KeyMap Value -> Parser ()
requireV1 o = do
  version <- o .: "format"
  if version == (1 :: Int) then pure () else fail "unsupported decision envelope version"

data FailureCode
  = UnknownProgram
  | ContractMismatch
  | InvalidInput
  | UnknownModel
  | ForbiddenModel
  | UnavailableModel
  | UnavailablePinnedImplementation
  | OutputDecodeFailure
  | OutputValidationFailure
  | ProviderFailure
  | EvidenceFailure
  | InvalidSlot
  | UnsupportedVersion
  | CallLimitExceeded
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data DecisionFailure = DecisionFailure !FailureCode !Text
  deriving stock (Eq, Show)

instance ToJSON DecisionFailure where
  toJSON (DecisionFailure code detail) = toJSON (code, detail)

instance FromJSON DecisionFailure where
  parseJSON value = do
    (code, detail) <- parseJSON value
    pure (decisionFailure code detail)

-- | Callers supply an application-owned diagnostic, never raw provider errors.
decisionFailure :: FailureCode -> Text -> DecisionFailure
decisionFailure code = DecisionFailure code . Text.take 512

failureCode :: DecisionFailure -> FailureCode
failureCode (DecisionFailure code _) = code

renderDecisionFailure :: DecisionFailure -> Text
renderDecisionFailure (DecisionFailure _ detail) = detail

versionedDigest :: (ToJSON a) => Text -> a -> Text
versionedDigest domain value = commitmentDigest (object ["domain" .= domain, "value" .= value])

data DecisionCallContext = DecisionCallContext
  { prepared :: !PreparedDecision,
    effectiveModel :: !ModelDescriptor
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Tokens are created freshly before admission and persisted by beginCall.
-- A store must verify ownership and expectation before accepting any finish.
data AttemptToken = AttemptToken !DecisionCallId !DecisionCallOrdinal
  deriving stock (Eq, Ord, Show)

-- | The application allocates the retained expectation, independently of the
-- provider's own evidence call ID. Parsing never confers completion authority.
newtype DecisionCallId = DecisionCallId (KindID.KindID "shikigami_decision_call")
  deriving stock (Eq, Ord, Show)

parseDecisionCallId :: Text -> Either Text DecisionCallId
parseDecisionCallId input = do
  value <- first (const "invalid decision call ID encoding or prefix") (KindID.parseText @"shikigami_decision_call" input)
  case KindID.checkKindID value of
    Just _ -> Left "decision call ID requires UUIDv7"
    Nothing
      | KindID.toText value == input -> Right (DecisionCallId value)
      | otherwise -> Left "decision call ID requires canonical encoding"

decisionCallIdText :: DecisionCallId -> Text
decisionCallIdText (DecisionCallId value) = KindID.toText value

instance ToJSON DecisionCallId where
  toJSON = toJSON . decisionCallIdText
  toEncoding = toEncoding . decisionCallIdText

instance FromJSON DecisionCallId where
  parseJSON = withText "decision call ID" (either (fail . Text.unpack) pure . parseDecisionCallId)

-- | A run-wide one-based SQL position, separate from selection-call ordinals.
newtype DecisionCallOrdinal = DecisionCallOrdinal Int64
  deriving stock (Eq, Ord, Show)

parseDecisionCallOrdinal :: Integer -> Either Text DecisionCallOrdinal
parseDecisionCallOrdinal number
  | number > 0 && number <= toInteger (maxBound :: Int64) = Right (DecisionCallOrdinal (fromInteger number))
  | otherwise = Left "decision call ordinal must be positive and fit signed int64"

firstDecisionCallOrdinal :: DecisionCallOrdinal
firstDecisionCallOrdinal = DecisionCallOrdinal 1

decisionCallOrdinalNumber :: DecisionCallOrdinal -> Natural
decisionCallOrdinalNumber (DecisionCallOrdinal number) = fromIntegral number

instance ToJSON DecisionCallOrdinal where
  toJSON = toJSON . decisionCallOrdinalNumber
  toEncoding = toEncoding . decisionCallOrdinalNumber

instance FromJSON DecisionCallOrdinal where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseDecisionCallOrdinal

newAttemptToken :: DecisionCallOrdinal -> IO AttemptToken
newAttemptToken ordinal = (\identifier -> AttemptToken (DecisionCallId identifier) ordinal) <$> KindID.genKindID @"shikigami_decision_call"

attemptId :: AttemptToken -> DecisionCallId
attemptId (AttemptToken value _) = value

attemptOrdinal :: AttemptToken -> DecisionCallOrdinal
attemptOrdinal (AttemptToken _ ordinal) = ordinal

-- | A durable allocator assigns the ordinal under its serialization lock.
-- Completion still verifies token ownership and the stored ordinal.
withAttemptOrdinal :: DecisionCallOrdinal -> AttemptToken -> AttemptToken
withAttemptOrdinal ordinal (AttemptToken value _) = AttemptToken value ordinal

data CallTerminal = CallSucceeded | CallFailed | CallUnknown
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data DecisionCallHooks = DecisionCallHooks
  { beginCall :: !(DecisionCallContext -> IO (Either DecisionFailure AttemptToken)),
    finishCall :: !(AttemptToken -> CallTerminal -> Maybe ModelCallEvidence -> IO (Either DecisionFailure ()))
  }
  deriving stock (Generic)

-- | Test implementation with the production convergence contract. Missing
-- evidence and cancellation never become a successful terminal.
data MemoryCall = MemoryCall
  { context :: !DecisionCallContext,
    terminal :: !(Maybe (CallTerminal, Maybe Value))
  }
  deriving stock (Eq, Show, Generic)

newMemoryCallHooks :: IO (DecisionCallHooks, IO (Map.Map DecisionCallId MemoryCall))
newMemoryCallHooks = do
  calls <- newMVar Map.empty
  let begin context = modifyMVar calls \current -> do
        case parseDecisionCallOrdinal (toInteger (Map.size current) + 1) of
          Left _ -> pure (current, Left (decisionFailure CallLimitExceeded "decision call ordinal exhausted"))
          Right ordinal -> do
            token <- newAttemptToken ordinal
            pure (Map.insert (attemptId token) (ordinal, MemoryCall context Nothing) current, Right token)
      finish token status evidence = modifyMVar calls \current -> do
        let payload = (status, toJSON <$> evidence)
            refuse = pure (current, Left (decisionFailure EvidenceFailure "decision attempt terminal refused"))
        case Map.lookup (attemptId token) current of
          Nothing -> refuse
          Just (ordinal, call)
            | ordinal /= attemptOrdinal token -> refuse
            | status == CallSucceeded && evidence == Nothing -> refuse
            | Just previous <- call.terminal, previous /= payload -> refuse
            | otherwise -> pure (Map.insert (attemptId token) (ordinal, call & #terminal .~ Just payload) current, Right ())
  pure (DecisionCallHooks begin finish, fmap (fmap snd) (readMVar calls))

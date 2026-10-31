{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Shikigami-owned wire contracts. Executables, prompts and credentials never
-- belong in these descriptors; preparation alone contains the validated input.
module Shikigami.Decision.Contract
  ( ModelAlias,
    parseModelAlias,
    modelAliasFromNonEmpty,
    modelAliasText,
    ProgramDescriptor (..),
    ProgramIdentity,
    parseProgramIdentity,
    programIdentityText,
    ProgramParameterFormat (..),
    ProgramParameterDigest,
    parseProgramParameterDigest,
    programParameterDigest,
    programParameterDigestText,
    ModelRegistration,
    parseModelRegistration,
    modelRegistrationText,
    ModelDescriptorDigest,
    parseModelDescriptorDigest,
    modelDescriptorDigest,
    modelDescriptorDigestText,
    ModelDescriptor (..),
    DecisionSlotLabel,
    parseDecisionSlotLabel,
    decisionSlotLabelText,
    triageDecisionSlot,
    investigationDecisionSlot,
    DecisionPreparationId,
    parseDecisionPreparationId,
    decisionPreparationId,
    decisionPreparationIdText,
    DecisionGeneration,
    parseDecisionGeneration,
    decisionGenerationNumber,
    initialDecisionGeneration,
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
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, withText, (.:), (.:?), (.=))
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
import GHC.TypeLits (Symbol)
import Keiro.Workflow.Types (WorkflowId (..))
import Numeric.Natural (Natural)
import Shikigami.Attestation.Profile (SanctionedExecutionProfileRef)
import Shikigami.Behavior.Provider.Coordinate
import Shikigami.Decision.ModelAlias
import Shikigami.Log.Correlation (RunCorrelationId)

-- | Immutable operator/program registration coordinates. Each field has a
-- nominal scope; opaque versions and implementation labels are not assumed to
-- use a particular versioning scheme or digest algorithm.
type role ProgramIdentity nominal

newtype ProgramIdentity (scope :: Symbol) = ProgramIdentity Text
  deriving stock (Eq, Ord, Show)

parseProgramIdentity :: Text -> Either Text (ProgramIdentity scope)
parseProgramIdentity value
  | Text.null value = Left "decision program identity must not be empty"
  | otherwise = Right (ProgramIdentity value)

programIdentityText :: ProgramIdentity scope -> Text
programIdentityText (ProgramIdentity value) = value

instance ToJSON (ProgramIdentity scope) where
  toJSON = toJSON . programIdentityText
  toEncoding = toEncoding . programIdentityText

instance FromJSON (ProgramIdentity scope) where
  parseJSON = withText "decision program identity" (either (fail . Text.unpack) pure . parseProgramIdentity)

data ProgramParameterFormat = ParametersV1
  deriving stock (Eq, Show)

instance ToJSON ProgramParameterFormat where
  toJSON ParametersV1 = toJSON (1 :: Int)
  toEncoding ParametersV1 = toEncoding (1 :: Int)

instance FromJSON ProgramParameterFormat where
  parseJSON value = do
    number <- parseJSON @Integer value
    if number == 1 then pure ParametersV1 else fail "unsupported decision parameter format"

-- | Unlike the supplied implementation label, this commitment has a concrete
-- producer: versionedDigest over the effective parameter state below.
newtype ProgramParameterDigest = ProgramParameterDigest Text
  deriving stock (Eq, Ord, Show)

parseProgramParameterDigest :: Text -> Either Text ProgramParameterDigest
parseProgramParameterDigest value
  | Text.length value == 71 && "sha256:" `Text.isPrefixOf` value && Text.all hex (Text.drop 7 value) = Right (ProgramParameterDigest value)
  | otherwise = Left "decision parameter digest requires sha256 and 64 lowercase hexadecimal digits"
  where
    hex character = (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')

programParameterDigest :: Value -> ProgramParameterDigest
programParameterDigest = ProgramParameterDigest . versionedDigest "shikigami.decision-parameters/1"

programParameterDigestText :: ProgramParameterDigest -> Text
programParameterDigestText (ProgramParameterDigest value) = value

instance ToJSON ProgramParameterDigest where
  toJSON = toJSON . programParameterDigestText
  toEncoding = toEncoding . programParameterDigestText

instance FromJSON ProgramParameterDigest where
  parseJSON = withText "decision parameter digest" (either (fail . Text.unpack) pure . parseProgramParameterDigest)

-- | An immutable registration includes opaque code identity as well as all
-- serializable state. Equal request hashes cannot stand in for this identity.
data ProgramDescriptor = ProgramDescriptor
  { programId :: !(ProgramIdentity "program-id"),
    version :: !(ProgramIdentity "program-version"),
    implementationDigest :: !(ProgramIdentity "implementation-digest"),
    inputSchemaVersion :: !(ProgramIdentity "input-schema-version"),
    resultSchemaVersion :: !(ProgramIdentity "result-schema-version"),
    validatorVersion :: !(ProgramIdentity "validator-version"),
    parameterFormat :: !ProgramParameterFormat,
    parameterDigest :: !ProgramParameterDigest,
    derivationVersion :: !(ProgramIdentity "derivation-version")
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON ProgramDescriptor where
  parseJSON = withObject "ProgramDescriptor" \o -> do
    parameterFormat <- o .: "parameterFormat"
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

-- | Supplied immutable registration coordinates, distinct from program
-- registration and model aliases. Opaque versions do not imply SemVer or hashes.
type role ModelRegistration nominal

newtype ModelRegistration (scope :: Symbol) = ModelRegistration Text
  deriving stock (Eq, Ord, Show)

parseModelRegistration :: Text -> Either Text (ModelRegistration scope)
parseModelRegistration value
  | Text.null value = Left "model registration coordinate must not be empty"
  | otherwise = Right (ModelRegistration value)

modelRegistrationText :: ModelRegistration scope -> Text
modelRegistrationText (ModelRegistration value) = value

instance ToJSON (ModelRegistration scope) where
  toJSON = toJSON . modelRegistrationText
  toEncoding = toEncoding . modelRegistrationText

instance FromJSON (ModelRegistration scope) where
  parseJSON = withText "model registration coordinate" (either (fail . Text.unpack) pure . parseModelRegistration)

-- | The actual commitment computed over the complete credential-free binding.
newtype ModelDescriptorDigest = ModelDescriptorDigest Text
  deriving stock (Eq, Ord, Show)

parseModelDescriptorDigest :: Text -> Either Text ModelDescriptorDigest
parseModelDescriptorDigest value
  | Text.length value == 71 && "sha256:" `Text.isPrefixOf` value && Text.all hex (Text.drop 7 value) = Right (ModelDescriptorDigest value)
  | otherwise = Left "model descriptor digest requires sha256 and 64 lowercase hexadecimal digits"
  where
    hex character = (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')

modelDescriptorDigest :: Value -> ModelDescriptorDigest
modelDescriptorDigest = ModelDescriptorDigest . versionedDigest "shikigami.decision-model/1"

modelDescriptorDigestText :: ModelDescriptorDigest -> Text
modelDescriptorDigestText (ModelDescriptorDigest value) = value

instance ToJSON ModelDescriptorDigest where
  toJSON = toJSON . modelDescriptorDigestText
  toEncoding = toEncoding . modelDescriptorDigestText

instance FromJSON ModelDescriptorDigest where
  parseJSON = withText "model descriptor digest" (either (fail . Text.unpack) pure . parseModelDescriptorDigest)

-- | Public metadata shared with whole-run selection. Binding versions describe
-- authority/endpoint semantics, not individual secret rotations.
data ModelDescriptor = ModelDescriptor
  { alias :: !ModelAlias,
    version :: !(ModelRegistration "model-version"),
    digest :: !ModelDescriptorDigest,
    provider :: !(ProviderCoordinate "provider-name"),
    api :: !(ProviderCoordinate "provider-api"),
    endpointClass :: !(ProviderCoordinate "endpoint-class"),
    modelId :: !(ProviderCoordinate "provider-model-id"),
    thinking :: !(Maybe ThinkingLevel),
    bindingId :: !(ModelRegistration "credential-binding-id"),
    bindingVersion :: !(ModelRegistration "credential-binding-version")
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The existing slot grammar, independently of the currently compiled slots.
newtype DecisionSlotLabel = DecisionSlotLabel Text
  deriving stock (Eq, Ord, Show)

parseDecisionSlotLabel :: Text -> Either Text DecisionSlotLabel
parseDecisionSlotLabel value = case Text.uncons value of
  Just (firstCharacter, rest) | asciiAlphaNum firstCharacter && Text.all asciiWord rest -> Right (DecisionSlotLabel value)
  _ -> Left "decision slot label requires an ASCII alphanumeric start and ASCII alphanumeric, hyphen or underscore suffix"
  where
    asciiAlphaNum c = c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
    asciiWord c = asciiAlphaNum c || c == '-' || c == '_'

decisionSlotLabelText :: DecisionSlotLabel -> Text
decisionSlotLabelText (DecisionSlotLabel value) = value

triageDecisionSlot, investigationDecisionSlot :: DecisionSlotLabel
triageDecisionSlot = DecisionSlotLabel "triage"
investigationDecisionSlot = DecisionSlotLabel "investigate"

instance ToJSON DecisionSlotLabel where
  toJSON = toJSON . decisionSlotLabelText
  toEncoding = toEncoding . decisionSlotLabelText

instance FromJSON DecisionSlotLabel where
  parseJSON = withText "decision slot label" (either (fail . Text.unpack) pure . parseDecisionSlotLabel)

-- | A commitment to a preparation, not an allocated entity or workflow id.
newtype DecisionPreparationId = DecisionPreparationId Text
  deriving stock (Eq, Ord, Show)

parseDecisionPreparationId :: Text -> Either Text DecisionPreparationId
parseDecisionPreparationId value = first (const "decision preparation commitment requires sha256 and 64 lowercase hexadecimal digits") (DecisionPreparationId . programParameterDigestText <$> parseProgramParameterDigest value)

decisionPreparationId :: Value -> DecisionPreparationId
decisionPreparationId = DecisionPreparationId . versionedDigest "shikigami.prepared-decision/1"

decisionPreparationIdText :: DecisionPreparationId -> Text
decisionPreparationIdText (DecisionPreparationId value) = value

instance ToJSON DecisionPreparationId where
  toJSON = toJSON . decisionPreparationIdText
  toEncoding = toEncoding . decisionPreparationIdText

instance FromJSON DecisionPreparationId where
  parseJSON = withText "decision preparation commitment" (either (fail . Text.unpack) pure . parseDecisionPreparationId)

-- | Keiro supplies an Int generation. Retained JSON keeps its existing Natural
-- domain: no new upper bound or numeric representation is introduced here.
newtype DecisionGeneration = DecisionGeneration Natural
  deriving stock (Eq, Ord, Show)

parseDecisionGeneration :: Integer -> Either Text DecisionGeneration
parseDecisionGeneration value
  | value >= 0 = Right (DecisionGeneration (fromInteger value))
  | otherwise = Left "decision generation must not be negative"

decisionGenerationNumber :: DecisionGeneration -> Natural
decisionGenerationNumber (DecisionGeneration value) = value

initialDecisionGeneration :: DecisionGeneration
initialDecisionGeneration = DecisionGeneration 0

instance ToJSON DecisionGeneration where
  toJSON = toJSON . decisionGenerationNumber
  toEncoding = toEncoding . decisionGenerationNumber

instance FromJSON DecisionGeneration where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseDecisionGeneration

data DecisionSlot = DecisionSlot
  { label :: !DecisionSlotLabel,
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
  { identity :: !DecisionPreparationId,
    runId :: !RunCorrelationId,
    workflowId :: !WorkflowId,
    generation :: !DecisionGeneration,
    label :: !DecisionSlotLabel,
    program :: !ProgramDescriptor,
    input :: !Value,
    model :: !ModelDescriptor,
    policy :: !(Maybe SanctionedExecutionProfileRef)
  }
  deriving stock (Eq, Show, Generic)

-- Keiro owns WorkflowId and exposes no JSON codec. This adapter preserves the
-- historical string, including its admitted compatibility coordinates.
instance ToJSON PreparedDecision where
  toJSON value = object ["identity" .= value.identity, "runId" .= value.runId, "workflowId" .= value.workflowId.unWorkflowId, "generation" .= value.generation, "label" .= value.label, "program" .= value.program, "input" .= value.input, "model" .= value.model, "policy" .= value.policy]

instance FromJSON PreparedDecision where
  parseJSON = withObject "PreparedDecision" \o -> PreparedDecision <$> o .: "identity" <*> o .: "runId" <*> (WorkflowId <$> o .: "workflowId") <*> o .: "generation" <*> o .: "label" <*> o .: "program" <*> o .: "input" <*> o .: "model" <*> o .:? "policy"

-- | A committed result is decoded by a retained pure codec, without executing
-- the program or reapplying a deployment's current domain validator.
data DecisionOutcome = DecisionOutcome
  { preparationId :: !DecisionPreparationId,
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

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
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.:), (.=))
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.Types (Parser)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
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
    attempts :: ![Text]
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
  deriving stock (Eq, Show, Generic)

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
data AttemptToken = AttemptToken !Text !Natural
  deriving stock (Eq, Ord, Show)

newAttemptToken :: Natural -> IO AttemptToken
newAttemptToken ordinal = (\uuid -> AttemptToken (UUID.toText uuid) ordinal) <$> UUID.nextRandom

attemptId :: AttemptToken -> Text
attemptId (AttemptToken value _) = value

attemptOrdinal :: AttemptToken -> Natural
attemptOrdinal (AttemptToken _ ordinal) = ordinal

-- | A durable allocator assigns the ordinal under its serialization lock.
-- Completion still verifies token ownership and the stored ordinal.
withAttemptOrdinal :: Natural -> AttemptToken -> AttemptToken
withAttemptOrdinal ordinal (AttemptToken value _) = AttemptToken value ordinal

data CallTerminal = CallSucceeded | CallFailed | CallUnknown
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data DecisionCallHooks = DecisionCallHooks
  { beginCall :: DecisionCallContext -> IO (Either DecisionFailure AttemptToken),
    finishCall :: AttemptToken -> CallTerminal -> Maybe ModelCallEvidence -> IO (Either DecisionFailure ())
  }

-- | Test implementation with the production convergence contract. Missing
-- evidence and cancellation never become a successful terminal.
data MemoryCall = MemoryCall
  { context :: !DecisionCallContext,
    terminal :: !(Maybe (CallTerminal, Maybe Value))
  }
  deriving stock (Eq, Show)

newMemoryCallHooks :: IO (DecisionCallHooks, IO (Map.Map Text MemoryCall))
newMemoryCallHooks = do
  calls <- newMVar Map.empty
  let begin context = modifyMVar calls \current -> do
        token <- newAttemptToken (fromIntegral (Map.size current) + 1)
        pure (Map.insert (attemptId token) (MemoryCall context Nothing) current, Right token)
      finish token status evidence = modifyMVar calls \current -> do
        let payload = (status, toJSON <$> evidence)
            refuse = pure (current, Left (decisionFailure EvidenceFailure "decision attempt terminal refused"))
        case Map.lookup (attemptId token) current of
          Nothing -> refuse
          Just call
            | status == CallSucceeded && evidence == Nothing -> refuse
            | Just previous <- call.terminal, previous /= payload -> refuse
            | otherwise -> pure (Map.insert (attemptId token) (call {terminal = Just payload}) current, Right ())
  pure (DecisionCallHooks begin finish, readMVar calls)

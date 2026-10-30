{-# LANGUAGE GADTs #-}

-- | Immutable typed programs, separate from the unrestricted legacy Task registry.
module Shikigami.Program.Decision
  ( DecisionProgramRef,
    descriptor,
    RegisteredProgram,
    registerProgram,
    programRef,
    executable,
    registeredCodec,
    registeredParameterState,
    validateInput,
    validateResult,
    ResultCodec,
    jsonResultCodec,
    resultCodec,
    encodeResult,
    decodeResult,
    SomeProgram (..),
    ProgramRegistry,
    programRegistry,
    lookupProgram,
    resolveProgramRef,
    programDescriptors,
    SomeResultCodec (..),
    ResultCodecRegistry,
    resultCodecRegistry,
    retainedCodec,
    lookupResultCodec,
    effectiveParameterState,
  )
where

import Data.Aeson (FromJSON, Result (..), ToJSON, Value, fromJSON, object, toJSON, (.=))
import Data.Kind (Type)
import Data.List (find, nub)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Typeable (Typeable, cast)
import Shikigami.Decision.Contract
import Shikumi.Program (Params (..), Program (..), nodeInstructionsIndexed, programParams)
import Shikumi.Signature qualified as Signature

type role DecisionProgramRef nominal nominal

newtype DecisionProgramRef (i :: Type) (o :: Type) = DecisionProgramRef ProgramDescriptor
  deriving stock (Eq, Show)

descriptor :: DecisionProgramRef i o -> ProgramDescriptor
descriptor (DecisionProgramRef value) = value

-- | A stored-result codec has no validator or executable dependency. Retain it
-- when retiring an implementation; replay must preserve a committed decision.
data ResultCodec o = ResultCodec
  { encode :: !(o -> Value),
    decode :: !(Value -> Either DecisionFailure o)
  }

-- | Retain explicit historical decoders when a current FromJSON instance changes.
resultCodec :: (o -> Value) -> (Value -> Either DecisionFailure o) -> ResultCodec o
resultCodec = ResultCodec

jsonResultCodec :: (ToJSON o, FromJSON o) => ResultCodec o
jsonResultCodec = ResultCodec toJSON \value -> case fromJSON value of
  Success result -> Right result
  Error _ -> Left (decisionFailure OutputDecodeFailure "stored decision result does not match its retained codec")

encodeResult :: ResultCodec o -> o -> Value
encodeResult codec = codec.encode

decodeResult :: ResultCodec o -> Value -> Either DecisionFailure o
decodeResult codec = codec.decode

data RegisteredProgram i o = RegisteredProgram
  { ref :: !(DecisionProgramRef i o),
    program :: !(Program i o),
    codec :: !(ResultCodec o),
    parameterState :: !Value,
    inputValidator :: !(i -> Either Text i),
    resultValidator :: !(o -> Either Text o)
  }

-- | Registration computes the state commitment rather than trusting a caller's
-- digest. localState binds defaults used by pure derivation; its opaque code
-- remains covered by implementationDigest and derivationVersion.
registerProgram ::
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Value ->
  Program i o ->
  ResultCodec o ->
  (i -> Either Text i) ->
  (o -> Either Text o) ->
  Either DecisionFailure (RegisteredProgram i o)
registerProgram programId version implementationDigest inputSchemaVersion resultSchemaVersion validatorVersion derivationVersion localState program codec inputValidator resultValidator
  | any Text.null [programId, version, implementationDigest, inputSchemaVersion, resultSchemaVersion, validatorVersion, derivationVersion] =
      Left (decisionFailure ContractMismatch "decision registration identities must be nonempty")
  | hasSignatureDemos program =
      Left (decisionFailure ContractMismatch "decision demonstrations must be registered in Params")
  | otherwise =
      Right
        RegisteredProgram
          { ref =
              DecisionProgramRef
                ProgramDescriptor
                  { programId,
                    version,
                    implementationDigest,
                    inputSchemaVersion,
                    resultSchemaVersion,
                    validatorVersion,
                    parameterFormat = 1,
                    parameterDigest = versionedDigest "shikigami.decision-parameters/1" (effectiveParameterState program localState),
                    derivationVersion
                  },
            program,
            codec,
            parameterState = effectiveParameterState program localState,
            inputValidator,
            resultValidator
          }

-- | Params includes instruction overrides and ordered demos. Resolve base
-- instructions explicitly, so changing a default changes the commitment too.
effectiveParameterState :: Program i o -> Value -> Value
effectiveParameterState program localState =
  object
    [ "format" .= (1 :: Int),
      "nodes" .= zipWith effective (nodeInstructionsIndexed program) (programParams program),
      "localDerivationState" .= localState
    ]
  where
    effective base Params {instructionOverride, demos} =
      object
        ["instruction" .= fromMaybe base instructionOverride, "demos" .= demos]

-- The upstream existential Predict dictionaries do not include ToJSON for
-- signature demos. Keeping demos in serializable Params closes that blind spot.
hasSignatureDemos :: Program i o -> Bool
hasSignatureDemos = \case
  Predict sig _ -> not (null (Signature.getDemos sig))
  PredictCaptured _ sig _ -> not (null (Signature.getDemos sig))
  Compose a b -> hasSignatureDemos a || hasSignatureDemos b
  FMap _ p -> hasSignatureDemos p
  Map _ p -> hasSignatureDemos p
  Parallel a b -> hasSignatureDemos a || hasSignatureDemos b
  Retry _ p -> hasSignatureDemos p
  RetryWhen _ _ p -> hasSignatureDemos p
  Validate _ p -> hasSignatureDemos p
  MajorityVote _ _ _ p -> hasSignatureDemos p
  Ensemble ps _ -> any hasSignatureDemos ps
  Embed _ -> False

programRef :: RegisteredProgram i o -> DecisionProgramRef i o
programRef registered = registered.ref

executable :: RegisteredProgram i o -> Program i o
executable registered = registered.program

registeredCodec :: RegisteredProgram i o -> ResultCodec o
registeredCodec registered = registered.codec

registeredParameterState :: RegisteredProgram i o -> Value
registeredParameterState registered = registered.parameterState

validateInput :: RegisteredProgram i o -> i -> Either DecisionFailure i
validateInput registered = either (const (Left (decisionFailure InvalidInput "decision input rejected"))) Right . registered.inputValidator

validateResult :: RegisteredProgram i o -> o -> Either DecisionFailure o
validateResult registered = either (const (Left (decisionFailure OutputValidationFailure "decision result rejected"))) Right . registered.resultValidator

data SomeProgram where
  SomeProgram :: (Typeable i, Typeable o) => RegisteredProgram i o -> SomeProgram

newtype ProgramRegistry = ProgramRegistry [SomeProgram]

programRegistry :: [SomeProgram] -> Either DecisionFailure ProgramRegistry
programRegistry entries
  | length keys /= length (nub keys) = Left (decisionFailure ContractMismatch "duplicate immutable decision program/version")
  | otherwise = Right (ProgramRegistry entries)
  where
    keys = [(d.programId, d.version) | SomeProgram registered <- entries, let d = descriptor (programRef registered)]

programDescriptors :: ProgramRegistry -> [ProgramDescriptor]
programDescriptors (ProgramRegistry entries) = [descriptor (programRef registered) | SomeProgram registered <- entries]

lookupProgram :: forall i o. (Typeable i, Typeable o) => ProgramRegistry -> DecisionProgramRef i o -> Either DecisionFailure (RegisteredProgram i o)
lookupProgram (ProgramRegistry entries) requested = go entries
  where
    wanted = descriptor requested
    go [] = Left (decisionFailure UnavailablePinnedImplementation "pinned decision implementation is unavailable")
    go (SomeProgram registered : rest)
      | actual.programId /= wanted.programId || actual.version /= wanted.version = go rest
      | actual /= wanted = Left (decisionFailure ContractMismatch "pinned decision contract differs from its registration")
      | otherwise = maybe (Left (decisionFailure ContractMismatch "decision input/result type witnesses differ")) Right (cast registered)
      where
        actual = descriptor (programRef registered)

data SomeResultCodec where
  SomeResultCodec :: (Typeable o) => ProgramDescriptor -> ResultCodec o -> SomeResultCodec

newtype ResultCodecRegistry = ResultCodecRegistry [SomeResultCodec]

retainedCodec :: (Typeable o) => RegisteredProgram i o -> SomeResultCodec
retainedCodec registered = SomeResultCodec (descriptor registered.ref) registered.codec

resultCodecRegistry :: [SomeResultCodec] -> Either DecisionFailure ResultCodecRegistry
resultCodecRegistry entries
  | length keys /= length (nub keys) = Left (decisionFailure ContractMismatch "duplicate retained decision codec")
  | otherwise = Right (ResultCodecRegistry entries)
  where
    keys = [(d.programId, d.version) | SomeResultCodec d _ <- entries]

lookupResultCodec :: forall o. (Typeable o) => ResultCodecRegistry -> ProgramDescriptor -> Either DecisionFailure (ResultCodec o)
lookupResultCodec (ResultCodecRegistry entries) wanted =
  case find matches entries of
    Nothing -> Left (decisionFailure UnsupportedVersion "retained decision result codec is unavailable")
    Just (SomeResultCodec actual codec)
      | actual /= wanted -> Left (decisionFailure ContractMismatch "stored decision result contract differs")
      | otherwise -> maybe (Left (decisionFailure ContractMismatch "stored decision result type differs")) Right (cast codec)
  where
    matches (SomeResultCodec actual _) = actual.programId == wanted.programId && actual.version == wanted.version

-- | Recover a typed reference to a pinned descriptor after replay. The registry
-- checks both identity and Haskell witnesses before returning it.
resolveProgramRef :: (Typeable i, Typeable o) => ProgramRegistry -> ProgramDescriptor -> Either DecisionFailure (DecisionProgramRef i o)
resolveProgramRef registry pinned = do
  let ref = DecisionProgramRef pinned
  _ <- lookupProgram registry ref
  pure ref

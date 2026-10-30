module Shikigami.PracticeReviewSpec (tests) where

import Control.Monad (forM_)
import Data.Aeson (FromJSON (..), Value (..), eitherDecode, eitherDecodeStrict', encode, withObject, (.:), (.:?))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty qualified as NonEmpty
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector ((!?), (//))
import Data.Vector qualified as Vector
import Shikigami.PracticeReview
  ( PracticeKey (..),
    PracticeReviewClassification (..),
    PracticeReviewResolution (..),
    PracticeReviewTrigger,
    PracticeReviewVerdict (..),
    ResolutionId,
    ResolutionOutcome (..),
    ReviewId (..),
    deriveResolutionId,
    deriveReviewId,
    validateResolution,
    validateTrigger,
    validateVerdict,
    validatedTriggerValue,
  )
import Shikigami.Repository
  ( mkRelativePath,
    mkRevision,
    relativePathText,
    revisionText,
  )
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "practice review"
    [ repositoryContractTests,
      triggerContractTests,
      verdictContractTests,
      resolutionContractTests,
      invalidFixtureTests
    ]

repositoryContractTests :: TestTree
repositoryContractTests =
  testGroup
    "repository contract"
    [ testCase "accepts one full lowercase 40-hex revision" do
        revision <- expectRight (mkRevision "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        revisionText revision @?= "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      testCase "rejects a branch, uppercase SHA, and short SHA" do
        expectLeft (mkRevision "main")
        expectLeft (mkRevision "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        expectLeft (mkRevision "aaaaaaaa"),
      testCase "normalizes safe repository-relative paths" do
        path <- expectRight (mkRelativePath "docs//adr/./0008-review.md")
        relativePathText path @?= "docs/adr/0008-review.md",
      testCase "rejects absolute, traversal, and backslash paths" do
        expectLeft (mkRelativePath "/docs/adr/0008-review.md")
        expectLeft (mkRelativePath "docs/../secrets")
        expectLeft (mkRelativePath "docs\\adr\\0008-review.md")
    ]

triggerContractTests :: TestTree
triggerContractTests =
  testGroup
    "trigger contract"
    [ testCase "decodes, validates, and round-trips the version-1 trigger fixture" do
        bytes <- readFixture "trigger-valid.json"
        trigger <- decodeStrictOrFail @PracticeReviewTrigger bytes
        decodedAgain <- decodeLazyOrFail @PracticeReviewTrigger (encode trigger)
        decodedAgain @?= trigger
        validated <- expectRight (validateTrigger trigger)
        validatedTriggerValue validated @?= trigger,
      testCase "rejects a producer-selected specialist" do
        bytes <- readFixture "trigger-valid.json"
        value <- decodeStrictOrFail @Value bytes
        case value of
          Object object -> do
            let forbidden = Object (KeyMap.insert "specialist" (String "producer-choice") object)
            case eitherDecode @PracticeReviewTrigger (encode forbidden) of
              Left _ -> pure ()
              Right _ -> assertFailure "trigger decoder accepted a specialist field"
          _ -> assertFailure "trigger fixture is not a JSON object",
      testCase "derives a pinned ReviewId from normalized identity inputs" do
        bytes <- readFixture "trigger-valid.json"
        trigger <- decodeStrictOrFail @PracticeReviewTrigger bytes
        let expected = ReviewId "b717afda-1273-54d4-8241-4d66330e3fd3"
        deriveReviewId trigger (PracticeKey "opentelemetry") "opentelemetry-practice-reviewer" @?= expected
        deriveReviewId trigger (PracticeKey " OpenTelemetry ") " OPENTELEMETRY-PRACTICE-REVIEWER " @?= expected,
      testCase "reference ordering does not change identity but a material trigger key does" do
        bytes <- readFixture "trigger-valid.json"
        trigger <- decodeStrictOrFail @PracticeReviewTrigger bytes
        value <- decodeStrictOrFail @Value bytes
        reorderedValue <- expectRight (reverseArrayAt ["adoptions", "0", "references"] value)
        reordered <- decodeLazyOrFail @PracticeReviewTrigger (encode reorderedValue)
        changedValue <- expectRight (setPointer ["targetRange", "head"] (String "ffffffffffffffffffffffffffffffffffffffff") value)
        changedKeyValue <- expectRight (setPointer ["idempotencyKey"] (String "mori:practice-review:target:repo_target:ffffffffffffffffffffffffffffffffffffffff") changedValue)
        changed <- decodeLazyOrFail @PracticeReviewTrigger (encode changedKeyValue)
        let originalId = deriveReviewIdFromFixture trigger
        deriveReviewIdFromFixture reordered @?= originalId
        assertBool "a changed material trigger key must produce a new ReviewId" (deriveReviewIdFromFixture changed /= originalId),
      testCase "validation accumulates independent trigger errors" do
        value <- readFixtureValue "trigger-valid.json"
        badSchema <- expectRight (setPointer ["schemaVersion"] (Number 2) value)
        blankKey <- expectRight (setPointer ["idempotencyKey"] (String " ") badSchema)
        noPaths <- expectRight (setPointer ["changedDecisionPaths"] (Array Vector.empty) blankKey)
        noAdoptions <- expectRight (setPointer ["adoptions"] (Array Vector.empty) noPaths)
        trigger <- decodeLazyOrFail @PracticeReviewTrigger (encode noAdoptions)
        case validateTrigger trigger of
          Left problems -> assertBool "expected at least four independent errors" (NonEmpty.length problems >= 4)
          Right _ -> assertFailure "multiply invalid trigger unexpectedly validated"
    ]

verdictContractTests :: TestTree
verdictContractTests =
  testGroup
    "verdict contract"
    [ testCase "round-trips and validates exactly the five classifications" do
        bytes <- readFixture "verdicts-valid.json"
        verdicts <- decodeStrictOrFail @[PracticeReviewVerdict] bytes
        fmap verdictClassification verdicts
          @?= [Consistent, TargetSuspect, ReferenceSuspect, LegitimateException, Unresolved]
        decodedAgain <- decodeLazyOrFail @[PracticeReviewVerdict] (encode verdicts)
        decodedAgain @?= verdicts
        forM_ verdicts (expectRight . validateVerdict)
    ]

resolutionContractTests :: TestTree
resolutionContractTests =
  testGroup
    "resolution contract"
    [ testCase "round-trips and validates exactly the four outcomes" do
        bytes <- readFixture "resolutions-valid.json"
        resolutions <- decodeStrictOrFail @[PracticeReviewResolution] bytes
        fmap resolutionOutcome resolutions @?= [Accepted, Rejected, Narrowed, Superseded]
        decodedAgain <- decodeLazyOrFail @[PracticeReviewResolution] (encode resolutions)
        decodedAgain @?= resolutions
        forM_ resolutions (expectRight . validateResolution)
        case resolutions of
          firstResolution : _ ->
            resolutionIdentity firstResolution
              @?= deriveResolutionId
                (ReviewId "be79e848-6ce5-5fef-a5c8-bce0596f3784")
                "resolution-command-accepted"
          [] -> assertFailure "resolution fixture array is empty"
    ]

invalidFixtureTests :: TestTree
invalidFixtureTests =
  testGroup
    "invalid fixtures"
    [ testCase "rejects every declared malformed or inconsistent payload" do
        triggerBase <- readFixtureValue "trigger-valid.json"
        verdictBase <- readFixtureValue "verdicts-valid.json"
        resolutionBase <- readFixtureValue "resolutions-valid.json"
        invalidBytes <- readFixture "invalid-cases.json"
        fixtures <- decodeStrictOrFail @[InvalidFixture] invalidBytes
        forM_ fixtures \fixture -> do
          payload <- expectRight (materializeInvalid triggerBase verdictBase resolutionBase fixture)
          assertInvalidRejected fixture payload
    ]

verdictClassification :: PracticeReviewVerdict -> PracticeReviewClassification
verdictClassification PracticeReviewVerdict {classification} = classification

resolutionOutcome :: PracticeReviewResolution -> ResolutionOutcome
resolutionOutcome PracticeReviewResolution {outcome} = outcome

resolutionIdentity :: PracticeReviewResolution -> ResolutionId
resolutionIdentity PracticeReviewResolution {resolutionId} = resolutionId

deriveReviewIdFromFixture :: PracticeReviewTrigger -> ReviewId
deriveReviewIdFromFixture trigger =
  deriveReviewId trigger (PracticeKey "opentelemetry") "opentelemetry-practice-reviewer"

data InvalidFixture = InvalidFixture
  { name :: !Text,
    base :: !Text,
    at :: !(Maybe Int),
    operation :: !Text,
    pointer :: !Text,
    replacement :: !(Maybe Value),
    expected :: !Text
  }
  deriving stock (Eq, Show)

instance FromJSON InvalidFixture where
  parseJSON = withObject "InvalidFixture" \object ->
    InvalidFixture
      <$> object .: "name"
      <*> object .: "base"
      <*> object .:? "at"
      <*> object .: "operation"
      <*> object .: "pointer"
      <*> object .:? "replacement"
      <*> object .: "expected"

readFixture :: FilePath -> IO ByteString.ByteString
readFixture name = do
  root <- repositoryRoot
  ByteString.readFile (root </> "fixtures" </> "practice-review" </> name)

readFixtureValue :: FilePath -> IO Value
readFixtureValue name = readFixture name >>= decodeStrictOrFail

repositoryRoot :: IO FilePath
repositoryRoot = go [".", ".."]
  where
    go [] = assertFailure "cannot find cabal.project from the working directory"
    go (candidate : rest) = do
      exists <- doesFileExist (candidate </> "cabal.project")
      if exists then pure candidate else go rest

materializeInvalid :: Value -> Value -> Value -> InvalidFixture -> Either String Value
materializeInvalid triggerBase verdictBase resolutionBase InvalidFixture {base, at, operation, pointer, replacement} = do
  baseValue <-
    case base of
      "trigger" -> pure triggerBase
      "verdicts" -> selectArrayValue "verdicts" at verdictBase
      "resolutions" -> selectArrayValue "resolutions" at resolutionBase
      "literal" -> pure Null
      _ -> Left ("unknown invalid-fixture base: " <> Text.unpack base)
  applyOperation operation (pointerSegments pointer) replacement baseValue

selectArrayValue :: String -> Maybe Int -> Value -> Either String Value
selectArrayValue label (Just itemIndex) (Array values) =
  maybe (Left (label <> " fixture index is out of range")) Right (values !? itemIndex)
selectArrayValue label Nothing _ = Left (label <> " invalid fixture requires an at index")
selectArrayValue label _ _ = Left (label <> " base is not an array")

pointerSegments :: Text -> [Text]
pointerSegments "" = []
pointerSegments pointer = fmap unescapePointer (drop 1 (Text.splitOn "/" pointer))
  where
    unescapePointer = Text.replace "~1" "/" . Text.replace "~0" "~"

applyOperation :: Text -> [Text] -> Maybe Value -> Value -> Either String Value
applyOperation operation segments replacement =
  alterPointer segments (alter operation replacement)

alter :: Text -> Maybe Value -> Maybe Value -> Either String (Maybe Value)
alter "add" (Just replacement) _ = Right (Just replacement)
alter "replace" (Just replacement) (Just _) = Right (Just replacement)
alter "replace" _ Nothing = Left "replace pointer does not exist"
alter "remove" _ (Just _) = Right Nothing
alter "remove" _ Nothing = Left "remove pointer does not exist"
alter operation _ _ = Left ("invalid fixture operation is incomplete or unknown: " <> Text.unpack operation)

alterPointer :: [Text] -> (Maybe Value -> Either String (Maybe Value)) -> Value -> Either String Value
alterPointer [] modify current =
  modify (Just current) >>= maybe (Left "cannot remove the document root") Right
alterPointer [segment] modify (Object object) = do
  let key = Key.fromText segment
  updated <- modify (KeyMap.lookup key object)
  pure
    ( Object
        ( case updated of
            Nothing -> KeyMap.delete key object
            Just value -> KeyMap.insert key value object
        )
    )
alterPointer (segment : rest) modify (Object object) = do
  let key = Key.fromText segment
  child <- maybe (Left ("object pointer segment does not exist: " <> Text.unpack segment)) Right (KeyMap.lookup key object)
  updated <- alterPointer rest modify child
  pure (Object (KeyMap.insert key updated object))
alterPointer (segment : rest) modify (Array values) = do
  itemIndex <- parseArrayIndex segment
  child <- maybe (Left "array pointer index is out of range") Right (values !? itemIndex)
  updated <- alterPointer rest modify child
  pure (Array (values // [(itemIndex, updated)]))
alterPointer _ _ _ = Left "pointer traversed through a scalar JSON value"

parseArrayIndex :: Text -> Either String Int
parseArrayIndex segment =
  case reads (Text.unpack segment) of
    [(itemIndex, "")] | itemIndex >= 0 -> Right itemIndex
    _ -> Left ("array pointer segment is not a non-negative index: " <> Text.unpack segment)

setPointer :: [Text] -> Value -> Value -> Either String Value
setPointer segments replacement = alterPointer segments (const (Right (Just replacement)))

reverseArrayAt :: [Text] -> Value -> Either String Value
reverseArrayAt segments =
  alterPointer segments \case
    Just (Array values) -> Right (Just (Array (Vector.reverse values)))
    _ -> Left "reverse pointer does not name an array"

assertInvalidRejected :: InvalidFixture -> Value -> IO ()
assertInvalidRejected InvalidFixture {name, expected} payload =
  case expected of
    "trigger-decode" -> expectDecodeFailure (Proxy @PracticeReviewTrigger) name payload
    "trigger-validation" -> expectValidationFailure name validateTrigger payload
    "verdict-decode" -> expectDecodeFailure (Proxy @PracticeReviewVerdict) name payload
    "verdict-validation" -> expectValidationFailure name validateVerdict payload
    "resolution-decode" -> expectDecodeFailure (Proxy @PracticeReviewResolution) name payload
    "resolution-validation" -> expectValidationFailure name validateResolution payload
    _ -> assertFailure ("unknown invalid-fixture expectation for " <> Text.unpack name <> ": " <> Text.unpack expected)

expectDecodeFailure :: forall value. (FromJSON value) => Proxy value -> Text -> Value -> IO ()
expectDecodeFailure _ name payload =
  case eitherDecode @value (encode payload) of
    Left _ -> pure ()
    Right _ -> assertFailure (Text.unpack name <> ": payload unexpectedly decoded")

expectValidationFailure :: forall raw valid error. (FromJSON raw) => Text -> (raw -> Either error valid) -> Value -> IO ()
expectValidationFailure name validate payload =
  case eitherDecode @raw (encode payload) of
    Left problem -> assertFailure (Text.unpack name <> ": payload failed to decode before validation: " <> problem)
    Right raw ->
      case validate raw of
        Left _ -> pure ()
        Right _ -> assertFailure (Text.unpack name <> ": payload unexpectedly validated")

decodeStrictOrFail :: forall value. (FromJSON value) => ByteString.ByteString -> IO value
decodeStrictOrFail = either (assertFailure . ("fixture did not decode: " <>)) pure . eitherDecodeStrict'

decodeLazyOrFail :: forall value. (FromJSON value) => LazyByteString.ByteString -> IO value
decodeLazyOrFail = either (assertFailure . ("encoded value did not decode: " <>)) pure . eitherDecode

expectRight :: (Show error) => Either error value -> IO value
expectRight = either (assertFailure . ("expected Right, got Left: " <>) . show) pure

expectLeft :: (Show value) => Either error value -> IO ()
expectLeft = either (const (pure ())) (assertFailure . ("expected Left, got Right: " <>) . show)

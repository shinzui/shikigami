module Shikigami.PracticeReviewSpec (tests) where

import Control.Monad (forM_)
import Data.Aeson (FromJSON (..), ToJSON, Value (..), eitherDecode, eitherDecodeStrict', encode, withObject, (.:), (.:?))
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
  ( PracticeReviewClassification (..),
    PracticeReviewResolution (..),
    PracticeReviewTrigger,
    PracticeReviewVerdict (..),
    ResolutionOutcome (..),
    parseResolutionId,
    parseReviewId,
    resolutionIdText,
    reviewIdText,
    validateResolution,
    validateTrigger,
    validateVerdict,
    validatedTriggerValue,
  )
import Shikigami.PracticeReview qualified as Review
import Shikigami.PracticeReview.Capability qualified as Capability
import Shikigami.PracticeReview.Identity (newResolutionId, newReviewId)
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
    [ scalarValueTests,
      repositoryContractTests,
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
        fixtureWire <- decodeStrictOrFail @Value bytes
        encode trigger @?= encode fixtureWire
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
      testCase "allocated review and resolution IDs are distinct canonical UUIDv7 domains" do
        first <- newReviewId
        second <- newReviewId
        resolution <- newResolutionId
        assertBool "allocations collided" (first /= second)
        parseReviewId (reviewIdText first) @?= Right first
        parseResolutionId (resolutionIdText resolution) @?= Right resolution
        eitherDecode (encode first) @?= Right first
        eitherDecode (encode resolution) @?= Right resolution
        expectLeft (parseReviewId (resolutionIdText resolution))
        expectLeft (parseResolutionId (reviewIdText first))
        expectLeft (parseReviewId "b717afda-1273-54d4-8241-4d66330e3fd3")
        expectLeft (parseReviewId "shikigami_practice_review_5q2yqxm4kkaka84gadcrsgwfyk")
        expectLeft (parseResolutionId "shikigami_practice_review_resolution_5q2yqxm4kkaka84gadcrsgwfyk")
        expectLeft (parseReviewId (" " <> reviewIdText first)),
      testCase "validation accumulates independent trigger errors" do
        value <- readFixtureValue "trigger-valid.json"
        badSchema <- expectRight (setPointer ["schemaVersion"] (Number 2) value)
        expectDecodeFailure (Proxy @PracticeReviewTrigger) "unsupported schema" badSchema
        blankKey <- expectRight (setPointer ["idempotencyKey"] (String " ") value)
        expectDecodeFailure (Proxy @PracticeReviewTrigger) "blank producer key" blankKey
        noPaths <- expectRight (setPointer ["changedDecisionPaths"] (Array Vector.empty) value)
        noAdoptions <- expectRight (setPointer ["adoptions"] (Array Vector.empty) noPaths)
        trigger <- decodeLazyOrFail @PracticeReviewTrigger (encode noAdoptions)
        case validateTrigger trigger of
          Left problems -> assertBool "expected at least two independent composite errors" (NonEmpty.length problems >= 2)
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
        fixtureWire <- decodeStrictOrFail @Value bytes
        encode verdicts @?= encode fixtureWire
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
        fixtureWire <- decodeStrictOrFail @Value bytes
        encode resolutions @?= encode fixtureWire
        forM_ resolutions (expectRight . validateResolution)
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

scalarValueTests :: TestTree
scalarValueTests =
  testGroup
    "checked review values"
    [ testCase "review text units preserve exact strings and refuse blank values" do
        assertTextValue Review.parsePracticeKey Review.practiceKeyText
        assertTextValue Review.parseDependencyName Review.dependencyNameText
        assertTextValue Review.parseDocumentId Review.documentIdText
        assertTextValue Review.parseTriggerKey Review.triggerKeyText
        assertTextValue Review.parseResolutionKey Review.resolutionKeyText
        assertTextValue Review.parseOwnerPrincipal Review.ownerPrincipalText
        assertTextValue Review.parseEvidenceId Review.evidenceIdText
        assertTextValue Review.parseClaimId Review.claimIdText
        assertTextValue Review.parseContentHash Review.contentHashText
        Review.claimIdText (Review.evidenceProblemClaimId 1) @?= "evidence-problem-001",
      testCase "attention owner sets preserve components and configuration bytes" do
        recipients <- expectRight (Capability.parseAttentionRecipientMap "owner-b+owner-a=recipient_review")
        Capability.renderAttentionRecipientMap recipients @?= "owner-a+owner-b=recipient_review"
        owners <- traverse (expectRight . Review.parseOwnerPrincipal) ["owner-b", "owner-a"]
        fmap Capability.attentionRecipientText (Capability.lookupAttentionRecipient recipients owners) @?= Just "recipient_review"
        joined <- expectRight (Review.parseOwnerPrincipal "owner-a+owner-b")
        Capability.lookupAttentionRecipient recipients [joined] @?= Nothing,
      testCase "confidence retains bounded integer percentage bytes" do
        Review.confidencePercent Review.zeroConfidence @?= 0
        forM_ [0, 73, 100] \number -> do
          value <- expectRight (Review.parseConfidence number)
          Review.confidencePercent value @?= fromInteger number
          encode value @?= encode number
          eitherDecode (encode value) @?= Right value
        forM_ [-1, 101, 100000000000000000000] (expectLeft . Review.parseConfidence)
        forM_ ["-1", "101", "1.5", "\"95\""] \raw -> expectLeft (eitherDecode @Review.Confidence raw)
    ]

assertTextValue :: forall value. (Eq value, Show value, ToJSON value, FromJSON value) => (Text -> Either Text value) -> (value -> Text) -> IO ()
assertTextValue parse render = do
  forM_ ["label:a", " 名前 "] \raw -> do
    value <- expectRight (parse raw)
    render value @?= raw
    encode value @?= encode raw
    eitherDecode (encode value) @?= Right value
  forM_ ["", " ", "\t\n"] \raw -> do
    expectLeft (parse raw)
    expectLeft (eitherDecode @value (encode raw))

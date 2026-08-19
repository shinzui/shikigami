module Shikigami.PracticeReviewSpec (tests) where

import Data.Aeson (FromJSON, Value (Object, String), eitherDecode, eitherDecodeStrict', encode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Shikigami.PracticeReview
  ( PracticeReviewClassification (..),
    PracticeReviewResolution (..),
    PracticeReviewTrigger,
    PracticeReviewVerdict (..),
    ResolutionOutcome (..),
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
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "practice review"
    [ repositoryContractTests,
      triggerContractTests,
      verdictContractTests,
      resolutionContractTests
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
    [ testCase "decodes and round-trips the version-1 trigger fixture" do
        bytes <- readFixture "trigger-valid.json"
        trigger <- decodeStrictOrFail @PracticeReviewTrigger bytes
        decodedAgain <- decodeLazyOrFail @PracticeReviewTrigger (encode trigger)
        decodedAgain @?= trigger,
      testCase "rejects a producer-selected specialist" do
        bytes <- readFixture "trigger-valid.json"
        value <- decodeStrictOrFail @Value bytes
        case value of
          Object object -> do
            let forbidden = Object (KeyMap.insert "specialist" (String "producer-choice") object)
            case eitherDecode @PracticeReviewTrigger (encode forbidden) of
              Left _ -> pure ()
              Right _ -> assertFailure "trigger decoder accepted a specialist field"
          _ -> assertFailure "trigger fixture is not a JSON object"
    ]

verdictContractTests :: TestTree
verdictContractTests =
  testGroup
    "verdict contract"
    [ testCase "round-trips fixtures for exactly the five classifications" do
        bytes <- readFixture "verdicts-valid.json"
        verdicts <- decodeStrictOrFail @[PracticeReviewVerdict] bytes
        fmap verdictClassification verdicts
          @?= [Consistent, TargetSuspect, ReferenceSuspect, LegitimateException, Unresolved]
        decodedAgain <- decodeLazyOrFail @[PracticeReviewVerdict] (encode verdicts)
        decodedAgain @?= verdicts
    ]

resolutionContractTests :: TestTree
resolutionContractTests =
  testGroup
    "resolution contract"
    [ testCase "round-trips fixtures for exactly the four outcomes" do
        bytes <- readFixture "resolutions-valid.json"
        resolutions <- decodeStrictOrFail @[PracticeReviewResolution] bytes
        fmap resolutionOutcome resolutions @?= [Accepted, Rejected, Narrowed, Superseded]
        decodedAgain <- decodeLazyOrFail @[PracticeReviewResolution] (encode resolutions)
        decodedAgain @?= resolutions
    ]

verdictClassification :: PracticeReviewVerdict -> PracticeReviewClassification
verdictClassification PracticeReviewVerdict {classification} = classification

resolutionOutcome :: PracticeReviewResolution -> ResolutionOutcome
resolutionOutcome PracticeReviewResolution {outcome} = outcome

readFixture :: FilePath -> IO ByteString.ByteString
readFixture name = do
  root <- repositoryRoot
  ByteString.readFile (root </> "fixtures" </> "practice-review" </> name)

repositoryRoot :: IO FilePath
repositoryRoot = go [".", ".."]
  where
    go [] = assertFailure "cannot find cabal.project from the working directory"
    go (candidate : rest) = do
      exists <- doesFileExist (candidate </> "cabal.project")
      if exists then pure candidate else go rest

decodeStrictOrFail :: forall a. (FromJSON a) => ByteString.ByteString -> IO a
decodeStrictOrFail = either (assertFailure . ("fixture did not decode: " <>)) pure . eitherDecodeStrict'

decodeLazyOrFail :: forall a. (FromJSON a) => LazyByteString.ByteString -> IO a
decodeLazyOrFail = either (assertFailure . ("encoded value did not decode: " <>)) pure . eitherDecode

expectRight :: (Show error) => Either error value -> IO value
expectRight = either (assertFailure . ("expected Right, got Left: " <>) . show) pure

expectLeft :: (Show value) => Either error value -> IO ()
expectLeft = either (const (pure ())) (assertFailure . ("expected Left, got Right: " <>) . show)

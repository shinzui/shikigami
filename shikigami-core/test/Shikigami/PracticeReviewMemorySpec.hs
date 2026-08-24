module Shikigami.PracticeReviewMemorySpec (tests) where

import Data.Aeson (FromJSON, eitherDecodeStrict')
import Data.ByteString qualified as ByteString
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.Id (idText)
import Shikigami.PracticeReview
  ( Applicability (..),
    PracticeKey (..),
    PracticeReviewResolution (..),
    PracticeReviewVerdict (..),
    ProjectRef (..),
    ResolutionId (..),
    ReviewId (..),
    ValidatedPracticeReviewResolution,
    ValidatedPracticeReviewVerdict,
    validateResolution,
    validateVerdict,
    validatedResolutionValue,
    validatedVerdictValue,
  )
import Shikigami.PracticeReview.Memory
  ( PracticeReviewMemoryEnvelope (..),
    ReviewRecallContext (..),
    appliesTo,
    decodePracticeReviewMemory,
    encodePracticeReviewMemory,
    practiceReviewTags,
    provisionalMemoryId,
    resolvedMemoryId,
  )
import Shikigami.Repository (RelativePath, RepositoryId (..), mkRelativePath)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "PracticeReviewMemory"
    [ envelopeTests,
      identityTests,
      applicabilityTests,
      tagTests
    ]

envelopeTests :: TestTree
envelopeTests =
  testGroup
    "envelopes"
    [ testCase "round-trips validated provisional and resolved version-1 content" do
        (verdicts, resolutions) <- readValidatedContracts
        verdict <- itemAt "target-suspect verdict" 1 verdicts
        resolution <- itemAt "accepted resolution" 0 resolutions
        let provisional = ProvisionalReview verdict
            resolved = ResolvedReview verdict resolution
        decodePracticeReviewMemory (encodePracticeReviewMemory provisional) @?= Right provisional
        decodePracticeReviewMemory (encodePracticeReviewMemory resolved) @?= Right resolved,
      testCase "rejects an unknown envelope version" do
        (verdicts, _) <- readValidatedContracts
        verdict <- itemAt "target-suspect verdict" 1 verdicts
        let encoded = encodePracticeReviewMemory (ProvisionalReview verdict)
            unknown = Text.replace "\"schemaVersion\":1" "\"schemaVersion\":2" encoded
        assertBool "unknown version must fail" (isLeft (decodePracticeReviewMemory unknown)),
      testCase "rejects a resolved envelope whose review ids disagree" do
        (verdicts, resolutions) <- readValidatedContracts
        verdict <- itemAt "target-suspect verdict" 1 verdicts
        rejectedForAnotherReview <- itemAt "rejected resolution" 1 resolutions
        let malformed = encodePracticeReviewMemory (ResolvedReview verdict rejectedForAnotherReview)
        assertBool "mismatched review ids must fail" (isLeft (decodePracticeReviewMemory malformed))
    ]

identityTests :: TestTree
identityTests =
  testGroup
    "logical ids"
    [ testCase "provisional ReviewId mapping has a frozen vector" do
        idText (provisionalMemoryId (ReviewId "be79e848-6ce5-5fef-a5c8-bce0596f3784"))
          @?= "kioku_memory_0gg1z2ykx0ah8tcjndjjv6d3ds",
      testCase "resolved ResolutionId mapping has a frozen vector" do
        idText (resolvedMemoryId (ResolutionId "e2b49500-7d39-5f99-8cc9-fde8dbc18853"))
          @?= "kioku_memory_2kxg1vkpjjbt3arkd5s8y8hxvm"
    ]

applicabilityTests :: TestTree
applicabilityTests =
  testGroup
    "applicability"
    [ testCase "matches normalized project, path prefix, dependency, and practice" do
        parent <- expectRight (mkRelativePath "src/Regulated")
        child <- expectRight (mkRelativePath "src/Regulated/Adapter.hs")
        let scope = boundedApplicability parent
            context = recallContext (Just child) (Set.singleton " HS-OPENTELEMETRY-API ")
        assertBool "all dimensions match" (appliesTo scope context),
      testCase "path matching observes segment boundaries" do
        parent <- expectRight (mkRelativePath "src/Foo")
        child <- expectRight (mkRelativePath "src/Foo/Bar.hs")
        sibling <- expectRight (mkRelativePath "src/Foobar.hs")
        assertBool "child path matches" (appliesTo (pathOnly parent) (recallContext (Just child) Set.empty))
        assertBool "textual-but-not-segment prefix misses" (not (appliesTo (pathOnly parent) (recallContext (Just sibling) Set.empty))),
      testCase "empty dimensions are wildcards and populated dimensions exclude mismatches" do
        path <- expectRight (mkRelativePath "docs/adr/0001.md")
        assertBool "fully empty scope is a wildcard" (appliesTo emptyApplicability (recallContext (Just path) Set.empty))
        let wrongProject = Applicability [ProjectRef "other" (RepositoryId "repo_other")] [] [] []
            wrongPractice = Applicability [] [] [] [PracticeKey "logging"]
            wrongDependency = Applicability [] [] ["other-package"] []
            context = recallContext (Just path) (Set.singleton "hs-opentelemetry-api")
        assertBool "project mismatch excludes" (not (appliesTo wrongProject context))
        assertBool "practice mismatch excludes" (not (appliesTo wrongPractice context))
        assertBool "dependency mismatch excludes" (not (appliesTo wrongDependency context))
    ]

tagTests :: TestTree
tagTests =
  testGroup
    "tags"
    [ testCase "provisional tags duplicate stable lookup identities" do
        (verdicts, _) <- readValidatedContracts
        verdict <- itemAt "target-suspect verdict" 1 verdicts
        let tags = practiceReviewTags (ProvisionalReview verdict)
            PracticeReviewVerdict {reviewId = ReviewId reviewId} = validatedVerdictValue verdict
        assertBool "state tag" (Set.member "state:provisional" tags)
        assertBool "practice tag" (Set.member "practice:opentelemetry" tags)
        assertBool "review tag" (Set.member ("review:" <> reviewId) tags)
        assertBool "target repository tag" (Set.member "project:repo_target" tags)
        assertBool "classification tag" (Set.member "classification:target-suspect" tags),
      testCase "resolved tags add resolution and outcome identities deterministically" do
        (verdicts, resolutions) <- readValidatedContracts
        verdict <- itemAt "target-suspect verdict" 1 verdicts
        resolution <- itemAt "accepted resolution" 0 resolutions
        let envelope = ResolvedReview verdict resolution
            tags = practiceReviewTags envelope
            PracticeReviewResolution {resolutionId = ResolutionId resolutionId} = validatedResolutionValue resolution
        practiceReviewTags envelope @?= tags
        assertBool "resolved state" (Set.member "state:resolved" tags)
        assertBool "resolution id" (Set.member ("resolution:" <> resolutionId) tags)
        assertBool "accepted outcome" (Set.member "outcome:accepted" tags)
    ]

boundedApplicability :: RelativePath -> Applicability
boundedApplicability path =
  Applicability
    { projects = [ProjectRef "target" (RepositoryId "repo_target")],
      paths = [path],
      dependencies = ["hs-opentelemetry-api"],
      practices = [PracticeKey "opentelemetry"]
    }

pathOnly :: RelativePath -> Applicability
pathOnly path = Applicability [] [path] [] []

emptyApplicability :: Applicability
emptyApplicability = Applicability [] [] [] []

recallContext :: Maybe RelativePath -> Set.Set Text -> ReviewRecallContext
recallContext path dependencies =
  ReviewRecallContext
    { project = ProjectRef "target" (RepositoryId "repo_target"),
      path,
      dependencies,
      practice = PracticeKey "opentelemetry"
    }

readValidatedContracts :: IO ([ValidatedPracticeReviewVerdict], [ValidatedPracticeReviewResolution])
readValidatedContracts = do
  rawVerdicts <- readFixture "verdicts-valid.json" >>= decodeOrFail
  rawResolutions <- readFixture "resolutions-valid.json" >>= decodeOrFail
  verdicts <- traverse (expectRight . validateVerdict) rawVerdicts
  resolutions <- traverse (expectRight . validateResolution) rawResolutions
  pure (verdicts, resolutions)

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

decodeOrFail :: (FromJSON value) => ByteString.ByteString -> IO value
decodeOrFail bytes =
  case eitherDecodeStrict' bytes of
    Left err -> assertFailure err
    Right value -> pure value

itemAt :: String -> Int -> [value] -> IO value
itemAt label index values =
  case drop index values of
    value : _ -> pure value
    [] -> assertFailure (label <> " fixture is missing")

expectRight :: (Show error) => Either error value -> IO value
expectRight = \case
  Left err -> assertFailure (show err)
  Right value -> pure value

isLeft :: Either left right -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False

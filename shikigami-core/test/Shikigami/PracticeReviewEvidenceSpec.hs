module Shikigami.PracticeReviewEvidenceSpec (tests) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString8
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Shikigami.PracticeReview
  ( ContentHash (..),
    EvidenceItem (..),
    EvidenceRole (..),
    ProjectRef (..),
  )
import Shikigami.PracticeReview.Evidence
  ( EvidenceLimits,
    EvidenceProblem (..),
    EvidenceSource (..),
    PinnedContent (..),
    PinnedDiff (..),
    PinnedProvenance (..),
    ValidatedPinnedDiff (..),
    mkEvidenceLimits,
    mkRedactionRule,
    validatePinnedContent,
    validatePinnedDiff,
  )
import Shikigami.Repository
  ( RelativePath,
    RepoRef (..),
    RepositoryId (..),
    Revision,
    mkRelativePath,
    mkRevision,
    relativePathText,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "practice review evidence"
    [ testCase "accepts an exact pinned blob and redacts its bounded excerpt" do
        let result = validatePinnedContent testLimits TargetEvidence targetProject targetRef decisionPath validBlob
        case result of
          Left problem -> assertFailure ("expected valid evidence, got " <> show problem)
          Right EvidenceSource {citation = EvidenceItem {role}, excerpt} -> do
            assertEqual "role" TargetEvidence role
            assertEqual "secret is removed" "token=[REDACTED]\n" excerpt,
      testCase "rejects a provenance repository mismatch" do
        assertProblem
          isProvenanceMismatch
          ( validatePinnedContent
              testLimits
              TargetEvidence
              targetProject
              targetRef
              decisionPath
              (blob "repo_other" headSha "docs/adr/0001.md" "oid_target" 21 "token=fixture-secret\n")
          ),
      testCase "rejects a branch in returned provenance" do
        assertProblem
          isInvalidRevision
          ( validatePinnedContent
              testLimits
              TargetEvidence
              targetProject
              targetRef
              decisionPath
              (blob "repo_target" "main" "docs/adr/0001.md" "oid_target" 21 "token=fixture-secret\n")
          ),
      testCase "rejects a returned traversal path" do
        assertProblem
          isInvalidPath
          ( validatePinnedContent
              testLimits
              TargetEvidence
              targetProject
              targetRef
              decisionPath
              (blob "repo_target" headSha "../docs/adr/0001.md" "oid_target" 21 "token=fixture-secret\n")
          ),
      testCase "rejects an absent content hash" do
        assertProblem
          isMissingHash
          ( validatePinnedContent
              testLimits
              TargetEvidence
              targetProject
              targetRef
              decisionPath
              (blob "repo_target" headSha "docs/adr/0001.md" "" 21 "token=fixture-secret\n")
          ),
      testCase "rejects a false declared byte count" do
        assertProblem
          isSizeMismatch
          ( validatePinnedContent
              testLimits
              TargetEvidence
              targetProject
              targetRef
              decisionPath
              (blob "repo_target" headSha "docs/adr/0001.md" "oid_target" 20 "token=fixture-secret\n")
          ),
      testCase "rejects a blob above the configured byte limit" do
        assertProblem
          isLimitExceeded
          ( validatePinnedContent
              tinyLimits
              TargetEvidence
              targetProject
              targetRef
              decisionPath
              validBlob
          ),
      testCase "normalizes a pinned diff's changed paths" do
        case validatePinnedDiff testLimits targetRepository baseCommit headCommit Nothing validDiff of
          Left problem -> assertFailure ("expected valid diff, got " <> show problem)
          Right ValidatedPinnedDiff {changedPaths} ->
            assertEqual "changed paths" ["docs/adr/0001.md", "cabal.project"] (relativePathText <$> changedPaths),
      testCase "rejects a diff with too many changed paths" do
        let response = diff ["one", "two", "three"] baseSha headSha
        assertProblem isLimitExceeded (validatePinnedDiff twoPathLimits targetRepository baseCommit headCommit Nothing response),
      testCase "rejects a traversal path discovered from a diff" do
        let response = diff ["../escape"] baseSha headSha
        assertProblem isInvalidPath (validatePinnedDiff testLimits targetRepository baseCommit headCommit Nothing response)
    ]

testLimits :: EvidenceLimits
testLimits = limits 1024 4096 20 4 20 200 [redaction "fixture-secret"]

tinyLimits :: EvidenceLimits
tinyLimits = limits 10 4096 20 4 20 200 []

twoPathLimits :: EvidenceLimits
twoPathLimits = limits 1024 4096 2 4 20 200 []

limits :: Int -> Int -> Int -> Int -> Int -> Int -> [Text] -> EvidenceLimits
limits blobBytes diffBytes paths pages matches excerpt redactionNeedles =
  case traverse mkRedactionRule redactionNeedles >>= mkEvidenceLimits blobBytes diffBytes paths pages matches excerpt of
    Left problem -> error (show problem)
    Right value -> value

redaction :: Text -> Text
redaction = id

targetProject :: ProjectRef
targetProject = ProjectRef {name = "target", repository = targetRepository}

targetRepository :: RepositoryId
targetRepository = RepositoryId "repo_target"

targetRef :: RepoRef
targetRef = RepoRef {repository = targetRepository, revision = headCommit}

decisionPath :: RelativePath
decisionPath = relativePath "docs/adr/0001.md"

baseCommit :: Revision
baseCommit = parseRevision baseSha

headCommit :: Revision
headCommit = parseRevision headSha

baseSha :: Text
baseSha = "1111111111111111111111111111111111111111"

headSha :: Text
headSha = "2222222222222222222222222222222222222222"

observedAt :: UTCTime
observedAt = UTCTime (fromGregorian 2026 8 26) (secondsToDiffTime 0)

validBlob :: PinnedContent
validBlob = blob "repo_target" headSha "docs/adr/0001.md" "oid_target" 21 "token=fixture-secret\n"

blob :: Text -> Text -> Text -> Text -> Int -> ByteString -> PinnedContent
blob repository revision path contentHash declaredSize bytes =
  PinnedContent
    { provenance =
        PinnedProvenance
          { repository = RepositoryId repository,
            revision,
            mirrorObservedAt = observedAt
          },
      path,
      contentHash = ContentHash contentHash,
      declaredSize,
      bytes
    }

validDiff :: PinnedDiff
validDiff = diff ["docs/adr/0001.md", "./cabal.project"] baseSha headSha

diff :: [Text] -> Text -> Text -> PinnedDiff
diff changedPaths baseRevision headRevision =
  let bytes = ByteString8.pack "diff --git a/docs/adr/0001.md b/docs/adr/0001.md\n"
   in PinnedDiff
        { provenance =
            PinnedProvenance
              { repository = targetRepository,
                revision = headRevision,
                mirrorObservedAt = observedAt
              },
          baseRevision,
          headRevision,
          path = Nothing,
          changedPaths,
          contentHash = ContentHash "sha256:diff",
          declaredSize = ByteString8.length bytes,
          bytes
        }

parseRevision :: Text -> Revision
parseRevision raw =
  case mkRevision raw of
    Left problem -> error (show problem)
    Right value -> value

relativePath :: Text -> RelativePath
relativePath raw =
  case mkRelativePath raw of
    Left problem -> error (show problem)
    Right value -> value

assertProblem :: (EvidenceProblem -> Bool) -> Either EvidenceProblem value -> IO ()
assertProblem predicate = \case
  Left problem -> assertBool ("unexpected problem: " <> show problem) (predicate problem)
  Right _ -> assertFailure "expected validation to fail"

isProvenanceMismatch :: EvidenceProblem -> Bool
isProvenanceMismatch (ProvenanceMismatch _ _ _ _ _) = True
isProvenanceMismatch _ = False

isInvalidRevision :: EvidenceProblem -> Bool
isInvalidRevision (InvalidPinnedRevision _ _ _) = True
isInvalidRevision _ = False

isInvalidPath :: EvidenceProblem -> Bool
isInvalidPath (InvalidReturnedPath _ _ _) = True
isInvalidPath _ = False

isMissingHash :: EvidenceProblem -> Bool
isMissingHash (MissingContentHash _ _) = True
isMissingHash _ = False

isSizeMismatch :: EvidenceProblem -> Bool
isSizeMismatch (ContentSizeMismatch _ _ _ _) = True
isSizeMismatch _ = False

isLimitExceeded :: EvidenceProblem -> Bool
isLimitExceeded (EvidenceLimitExceeded _ _ _ _) = True
isLimitExceeded _ = False

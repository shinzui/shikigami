module Shikigami.PracticeReviewEvidenceSpec (tests) where

import Control.Lens ((^.))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString8
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Shikigami.PracticeReview
  ( Applicability (..),
    ContentHash (..),
    EvidenceItem (..),
    EvidenceRole (..),
    OwnerPrincipal (..),
    PracticeAdoptionBinding (..),
    PracticeKey (..),
    PracticeReviewResolution (..),
    PracticeReviewTrigger (..),
    PracticeReviewTriggerKind (..),
    ProjectRef (..),
    RegisteredPracticeReference (..),
    RegisteredUpstreamProject (..),
    ResolutionOutcome (..),
    ReviewId (..),
    ReviewMode (..),
    ReviewOwners (..),
    RevisionChangeKind (..),
    RevisionRange (..),
    ValidatedPracticeReviewResolution,
    ValidatedPracticeReviewTrigger,
    deriveResolutionId,
    practiceReviewSchemaVersion,
    validateResolution,
    validateTrigger,
  )
import Shikigami.PracticeReview.Evidence
  ( DependencyPinResolver (..),
    EvidenceBundle (..),
    EvidenceCompleteness (..),
    EvidenceLimits,
    EvidenceProblem (..),
    EvidenceQuery,
    EvidenceReadError (..),
    EvidenceReader (..),
    EvidenceSource (..),
    PageRequest,
    PinnedContent (..),
    PinnedDiff (..),
    PinnedMatch (..),
    PinnedMatchPage (..),
    PinnedProvenance (..),
    PinnedTreePage (..),
    UpstreamSelection (..),
    ValidatedPinnedDiff (..),
    acquireEvidence,
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
    revisionText,
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
        assertProblem isInvalidPath (validatePinnedDiff testLimits targetRepository baseCommit headCommit Nothing response),
      testCase "acquires pinned target, practice, upstream, and applicable prior evidence" do
        bundle <- acquireEvidence testLimits fixtureReader compatiblePinResolver validatedTrigger adoptionBinding priorResolutionFixtures
        case bundle of
          EvidenceBundle {target, references, upstream, priorResolutions, problems, completeness} -> do
            assertEqual "complete" Complete completeness
            assertEqual "no problems" [] problems
            assertEqual "target sources" [headSha, headSha] (sourceRevision <$> target)
            assertEqual "practice source" [practiceSha1] (sourceRevision <$> references)
            assertEqual "upstream source" [upstreamSha2] (sourceRevision <$> upstream)
            assertEqual "accepted and rejected prior evidence retained" [Accepted, Rejected] (resolutionOutcome <$> priorResolutions),
      testCase "rejects mixed revisions for one practice repository" do
        bundle <- acquireEvidence testLimits fixtureReader compatiblePinResolver (validatedTriggerFor mixedRevisionBinding) mixedRevisionBinding []
        assertEqual "incomplete" Incomplete (bundle ^. #completeness)
        assertBool "mixed revisions reported" (any isMixedRevisions (bundle ^. #problems)),
      testCase "reports an incompatible upstream pin without fabricating source" do
        bundle <- acquireEvidence testLimits fixtureReader incompatiblePinResolver validatedTrigger adoptionBinding []
        assertEqual "incomplete" Incomplete (bundle ^. #completeness)
        assertEqual "no upstream evidence" [] (bundle ^. #upstream)
        assertBool "incompatible version reported" (any isIncompatibleVersion (bundle ^. #problems))
    ]

validatedTrigger :: ValidatedPracticeReviewTrigger
validatedTrigger = validatedTriggerFor adoptionBinding

validatedTriggerFor :: PracticeAdoptionBinding -> ValidatedPracticeReviewTrigger
validatedTriggerFor binding =
  case validateTrigger
    PracticeReviewTrigger
      { schemaVersion = practiceReviewSchemaVersion,
        triggerKind = TargetChange,
        idempotencyKey = "trigger-practice-evidence",
        target = targetProject,
        targetRange = RevisionRange {changeKind = Modified, before = Just baseCommit, head = headCommit},
        changedDecisionPaths = [decisionPath],
        adoptions = [binding],
        referenceChange = Nothing,
        priorReviewId = Nothing
      } of
    Left problems -> error (show problems)
    Right value -> value

adoptionBinding :: PracticeAdoptionBinding
adoptionBinding = bindingWithReferences [practiceReference1]

mixedRevisionBinding :: PracticeAdoptionBinding
mixedRevisionBinding = bindingWithReferences [practiceReference1, practiceReference2]

bindingWithReferences :: [RegisteredPracticeReference] -> PracticeAdoptionBinding
bindingWithReferences references =
  PracticeAdoptionBinding
    { practice = PracticeKey "practice-1",
      references,
      claimedApplicability = Applicability [targetProject] [] [] [PracticeKey "practice-1"],
      mode = Advisory,
      owners =
        ReviewOwners
          { targetOwner = OwnerPrincipal "principal-target",
            practiceOwner = OwnerPrincipal "principal-practice",
            triageOwner = OwnerPrincipal "principal-triage",
            exceptionApprover = Nothing
          },
      upstreamProjects =
        [ RegisteredUpstreamProject
            { project = upstreamProject,
              dependency = "libfoo"
            }
        ]
    }

practiceReference1 :: RegisteredPracticeReference
practiceReference1 =
  RegisteredPracticeReference
    { project = practiceProject,
      provenance = practiceRef1,
      documentIds = ["PRACTICE-1"]
    }

practiceReference2 :: RegisteredPracticeReference
practiceReference2 =
  RegisteredPracticeReference
    { project = practiceProject,
      provenance = practiceRef2,
      documentIds = ["PRACTICE-1"]
    }

practiceProject :: ProjectRef
practiceProject = ProjectRef {name = "practice", repository = RepositoryId "repo_practice"}

upstreamProject :: ProjectRef
upstreamProject = ProjectRef {name = "libfoo", repository = RepositoryId "repo_upstream"}

practiceRef1 :: RepoRef
practiceRef1 = RepoRef {repository = practiceProject ^. #repository, revision = parseRevision practiceSha1}

practiceRef2 :: RepoRef
practiceRef2 = RepoRef {repository = practiceProject ^. #repository, revision = parseRevision practiceSha2}

upstreamRef2 :: RepoRef
upstreamRef2 = RepoRef {repository = upstreamProject ^. #repository, revision = parseRevision upstreamSha2}

practiceSha1 :: Text
practiceSha1 = "3333333333333333333333333333333333333333"

practiceSha2 :: Text
practiceSha2 = "4444444444444444444444444444444444444444"

upstreamSha2 :: Text
upstreamSha2 = "5555555555555555555555555555555555555555"

compatiblePinResolver :: DependencyPinResolver
compatiblePinResolver =
  DependencyPinResolver
    { resolvePin = \RegisteredUpstreamProject {dependency} inputs ->
        if dependency == "libfoo" && any (ByteString8.isInfixOf "libfoo ==2.0" . snd) inputs
          then
            Right
              UpstreamSelection
                { mutableRef = "v2.0.0",
                  paths = [relativePath "src/Foo.hs"]
                }
          else Left "target does not carry a compatible libfoo pin"
    }

incompatiblePinResolver :: DependencyPinResolver
incompatiblePinResolver =
  DependencyPinResolver
    { resolvePin = \_ _ -> Left "target pin 1.0 is outside the registered 2.x range"
    }

fixtureReader :: EvidenceReader
fixtureReader =
  EvidenceReader
    { resolveRef = fixtureResolveRef,
      readBlob = fixtureReadBlob,
      readDiff = fixtureReadDiff,
      readTree = \reference _ _ ->
        pure
          ( Right
              PinnedTreePage
                { provenance = provenanceFor reference,
                  entries = [],
                  nextCursor = Nothing
                }
          ),
      grep = fixtureGrep
    }

fixtureResolveRef :: RepositoryId -> Text -> IO (Either EvidenceReadError RepoRef)
fixtureResolveRef repository mutableRef
  | repository == upstreamProject ^. #repository && mutableRef == "v2.0.0" = pure (Right upstreamRef2)
  | otherwise = pure (Left (InvalidContentRequest ("unknown fixture ref: " <> mutableRef)))

fixtureReadBlob :: RepoRef -> RelativePath -> IO (Either EvidenceReadError PinnedContent)
fixtureReadBlob reference path =
  pure case (reference ^. #repository, revisionText (reference ^. #revision), relativePathText path) of
    (RepositoryId "repo_target", revision, "docs/adr/0001.md")
      | revision == headSha -> Right (fixtureBlob reference path "oid-target-t2" "# Target T2\n")
    (RepositoryId "repo_target", revision, "cabal.project")
      | revision == headSha -> Right (fixtureBlob reference path "oid-target-manifest-t2" "libfoo ==2.0\n")
    (RepositoryId "repo_practice", revision, "docs/practices/PRACTICE-1.md")
      | revision == practiceSha1 -> Right (fixtureBlob reference path "oid-practice-p1" "# PRACTICE-1 P1\n")
      | revision == practiceSha2 -> Right (fixtureBlob reference path "oid-practice-p2" "# PRACTICE-1 P2\n")
    (RepositoryId "repo_upstream", revision, "src/Foo.hs")
      | revision == upstreamSha2 -> Right (fixtureBlob reference path "oid-upstream-u2" "module Foo where\n")
    (repository, revision, rawPath) -> Left (ContentNotFound repository revision rawPath)

fixtureReadDiff :: RepositoryId -> Revision -> Revision -> Maybe RelativePath -> IO (Either EvidenceReadError PinnedDiff)
fixtureReadDiff repository base requestedHead path
  | repository == targetRepository && base == baseCommit && requestedHead == headCommit && path == Nothing =
      pure (Right validDiff)
  | otherwise = pure (Left (InvalidContentRequest "unknown fixture diff"))

fixtureGrep :: RepoRef -> EvidenceQuery -> PageRequest -> IO (Either EvidenceReadError PinnedMatchPage)
fixtureGrep reference _ _
  | reference == practiceRef1 || reference == practiceRef2 =
      pure
        ( Right
            PinnedMatchPage
              { provenance = provenanceFor reference,
                matches = [PinnedMatch {path = "docs/practices/PRACTICE-1.md", lineNumber = 1, line = "# PRACTICE-1"}],
                nextCursor = Nothing
              }
        )
  | otherwise = pure (Left (InvalidContentRequest "unknown fixture grep"))

fixtureBlob :: RepoRef -> RelativePath -> Text -> ByteString -> PinnedContent
fixtureBlob reference path contentHash bytes =
  PinnedContent
    { provenance = provenanceFor reference,
      path = relativePathText path,
      contentHash = ContentHash contentHash,
      declaredSize = ByteString8.length bytes,
      bytes
    }

provenanceFor :: RepoRef -> PinnedProvenance
provenanceFor reference =
  PinnedProvenance
    { repository = reference ^. #repository,
      revision = revisionText (reference ^. #revision),
      mirrorObservedAt = observedAt
    }

sourceRevision :: EvidenceSource -> Text
sourceRevision source = revisionText (source ^. #citation . #content . #provenance . #revision)

priorResolutionFixtures :: [ValidatedPracticeReviewResolution]
priorResolutionFixtures =
  [ validatedResolution Accepted (Just (Applicability [] [relativePath "docs/adr"] [] [])) "accept-in-scope",
    validatedResolution Narrowed (Just (Applicability [] [relativePath "src/unrelated"] [] [])) "narrow-out-of-scope",
    validatedResolution Rejected Nothing "reject-audit",
    validatedResolution Superseded Nothing "superseded"
  ]

validatedResolution :: ResolutionOutcome -> Maybe Applicability -> Text -> ValidatedPracticeReviewResolution
validatedResolution outcome resultingApplicability commandKey =
  case validateResolution rawResolution of
    Left problems -> error (show problems)
    Right value -> value
  where
    reviewId = ReviewId "review-prior"
    rawResolution =
      PracticeReviewResolution
        { schemaVersion = practiceReviewSchemaVersion,
          resolutionId = deriveResolutionId reviewId commandKey,
          idempotencyKey = commandKey,
          reviewId,
          outcome,
          resolver = OwnerPrincipal "principal-resolver",
          reason = "fixture resolution",
          resolvedAt = observedAt,
          resultingApplicability,
          supersedingReviewId =
            case outcome of
              Superseded -> Just (ReviewId "review-newer")
              _ -> Nothing
        }

resolutionOutcome :: PracticeReviewResolution -> ResolutionOutcome
resolutionOutcome PracticeReviewResolution {outcome} = outcome

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

isMixedRevisions :: EvidenceProblem -> Bool
isMixedRevisions (MixedReferenceRevisions _ _) = True
isMixedRevisions _ = False

isIncompatibleVersion :: EvidenceProblem -> Bool
isIncompatibleVersion (IncompatibleUpstreamVersion _ _) = True
isIncompatibleVersion _ = False

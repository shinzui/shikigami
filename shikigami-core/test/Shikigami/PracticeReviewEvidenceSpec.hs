module Shikigami.PracticeReviewEvidenceSpec
  ( tests,
    completeDependencyPinResolver,
    completeEvidenceReader,
    completeOpenTelemetryReferenceChangeTrigger,
    completeOpenTelemetryTrigger,
    completeReferenceRevision,
  )
where

import Control.Lens ((^.))
import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString8
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Shikigami.PracticeReview
  ( Applicability (..),
    ChangedReference (..),
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
    validatedTriggerValue,
  )
import Shikigami.PracticeReview.Evidence
  ( DependencyPinResolver (..),
    EvidenceBundle (..),
    EvidenceCompleteness (..),
    EvidenceCursor (..),
    EvidenceLimits,
    EvidenceProblem (..),
    EvidenceQuery,
    EvidenceReadError (..),
    EvidenceReader (..),
    EvidenceSource (..),
    PageRequest (..),
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
    summarizeEvidenceBundle,
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
import System.Directory (doesFileExist)
import System.FilePath ((</>))
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
            assertEqual "target blob ids" [targetDecisionBlob2, targetManifestBlob2] (sourceHash <$> target)
            assertEqual "practice blob id" [practiceBlob1] (sourceHash <$> references)
            assertEqual "upstream blob id" [upstreamBlob2] (sourceHash <$> upstream)
            assertEqual "accepted and rejected prior evidence retained" [Accepted, Rejected] (resolutionOutcome <$> priorResolutions),
      testCase "switching P1 to P2 changes only practice provenance" do
        let binding = bindingWithReferences [practiceReference2]
        bundle <- acquireEvidence testLimits fixtureReader compatiblePinResolver (validatedTriggerFor binding) binding []
        assertEqual "complete" Complete (bundle ^. #completeness)
        assertEqual "target remains T2" [headSha, headSha] (sourceRevision <$> (bundle ^. #target))
        assertEqual "practice advances to P2" [practiceSha2] (sourceRevision <$> (bundle ^. #references))
        assertEqual "upstream remains U2" [upstreamSha2] (sourceRevision <$> (bundle ^. #upstream)),
      testCase "an added target does not ask the reader for a diff" do
        diffCalls <- newIORef 0
        let binding = bindingWithoutUpstream
        bundle <- acquireEvidence testLimits (countingDiffReader diffCalls) compatiblePinResolver (validatedAddedTriggerFor binding) binding []
        calls <- readIORef diffCalls
        assertEqual "no base/head diff for an added object" 0 calls
        assertEqual "added ADR is still acquired" ["docs/adr/0001.md"] (sourcePath <$> (bundle ^. #target)),
      testCase "rejects mixed revisions for one practice repository" do
        bundle <- acquireEvidence testLimits fixtureReader compatiblePinResolver (validatedTriggerFor mixedRevisionBinding) mixedRevisionBinding []
        assertEqual "incomplete" Incomplete (bundle ^. #completeness)
        assertBool "mixed revisions reported" (any isMixedRevisions (bundle ^. #problems)),
      testCase "reports an incompatible upstream pin without fabricating source" do
        bundle <- acquireEvidence testLimits fixtureReader incompatiblePinResolver validatedTrigger adoptionBinding []
        assertEqual "incomplete" Incomplete (bundle ^. #completeness)
        assertEqual "no upstream evidence" [] (bundle ^. #upstream)
        assertBool "incompatible version reported" (any isIncompatibleVersion (bundle ^. #problems)),
      testCase "reports a missing upstream tag as incompatible" do
        bundle <- acquireEvidence testLimits staleRefReader compatiblePinResolver validatedTrigger adoptionBinding []
        assertEqual "incomplete" Incomplete (bundle ^. #completeness)
        assertEqual "no fabricated upstream evidence" [] (bundle ^. #upstream)
        assertBool "stale tag reported" (any isIncompatibleVersion (bundle ^. #problems)),
      testCase "rejects P2 bytes stamped as P1" do
        bundle <- acquireEvidence testLimits mismatchedPracticeReader compatiblePinResolver validatedTrigger adoptionBinding []
        assertEqual "incomplete" Incomplete (bundle ^. #completeness)
        assertEqual "mismatched practice omitted" [] (bundle ^. #references)
        assertBool "provenance mismatch reported" (any isProvenanceMismatch (bundle ^. #problems)),
      testCase "retains successful sources when a required target blob is missing" do
        bundle <- acquireEvidence testLimits missingTargetReader compatiblePinResolver validatedTrigger adoptionBinding []
        assertEqual "incomplete" Incomplete (bundle ^. #completeness)
        assertEqual "manifest remains available" ["cabal.project"] (sourcePath <$> (bundle ^. #target))
        assertBool "missing target reported" (any isReadFailure (bundle ^. #problems)),
      testCase "stops reference discovery at the grep page ceiling" do
        bundle <- acquireEvidence testLimits endlessGrepReader compatiblePinResolver validatedTrigger adoptionBinding []
        assertEqual "incomplete" Incomplete (bundle ^. #completeness)
        assertBool "page limit reported" (any isGrepPageLimit (bundle ^. #problems)),
      testCase "log-safe summaries never contain excerpts" do
        let leaky = EvidenceSource {citation = validEvidenceSource ^. #citation, mirrorObservedAt = observedAt, excerpt = "fixture-secret"}
            bundle = EvidenceBundle {target = [leaky], references = [], upstream = [], priorResolutions = [], problems = [], completeness = Complete}
            rendered = Text.pack (show (summarizeEvidenceBundle bundle))
        assertBool "summary excludes secret excerpt" (not ("fixture-secret" `Text.isInfixOf` rendered)),
      testCase "versioned evidence bundles round-trip structured acquisition problems" do
        let problem = ReadFailed targetRepository (Just headSha) (Just "docs/adr/0001.md") (ContentPlaneUnavailable "fixture unavailable") True
            bundle = EvidenceBundle {target = [validEvidenceSource], references = [], upstream = [], priorResolutions = [], problems = [problem], completeness = Incomplete}
        case eitherDecode (encode bundle) of
          Left detail -> assertFailure detail
          Right decoded -> assertEqual "round-trip" bundle decoded,
      testCase "evidence bundle decoder rejects unknown schema versions" do
        let encoded =
              encode
                ( object
                    [ "schemaVersion" .= (2 :: Int),
                      "target" .= ([validEvidenceSource] :: [EvidenceSource]),
                      "references" .= ([] :: [EvidenceSource]),
                      "upstream" .= ([] :: [EvidenceSource]),
                      "priorResolutions" .= ([] :: [PracticeReviewResolution]),
                      "problems" .= ([] :: [EvidenceProblem]),
                      "completeness" .= Complete
                    ]
                )
        case eitherDecode @EvidenceBundle encoded of
          Left _ -> pure ()
          Right _ -> assertFailure "unknown evidence schema version decoded",
      testCase "checked-in fixture manifest carries every pinned commit" do
        manifest <- readContentPlaneFixture "manifest.json"
        let expectedRevisions = [baseSha, headSha, practiceSha1, practiceSha2, upstreamSha1, upstreamSha2]
        assertBool "all expected revisions are pinned" (all (`ByteString8.isInfixOf` manifest) (ByteString8.pack . Text.unpack <$> expectedRevisions))
    ]

-- | Shared complete content-plane fixture for orchestration tests. It uses the
-- same immutable snapshots exercised by the evidence contract tests while
-- presenting the production specialist's OpenTelemetry adoption vocabulary.
completeOpenTelemetryTrigger :: Text -> PracticeReviewTrigger
completeOpenTelemetryTrigger triggerKey =
  validatedTriggerValue $ validateOpenTelemetryTrigger openTelemetryBinding
  where
    openTelemetryBinding =
      PracticeAdoptionBinding
        { practice = PracticeKey "opentelemetry",
          references = [practiceReference1],
          claimedApplicability = Applicability [targetProject] [] ["libfoo"] [PracticeKey "opentelemetry"],
          mode = Advisory,
          owners =
            ReviewOwners
              { targetOwner = OwnerPrincipal "team-example-service",
                practiceOwner = OwnerPrincipal "team-haskell-platform",
                triageOwner = OwnerPrincipal "architecture-council",
                exceptionApprover = Just (OwnerPrincipal "architecture-council")
              },
          upstreamProjects = [RegisteredUpstreamProject {project = upstreamProject, dependency = "libfoo"}]
        }

    validateOpenTelemetryTrigger binding =
      case validateTrigger
        PracticeReviewTrigger
          { schemaVersion = practiceReviewSchemaVersion,
            triggerKind = TargetChange,
            idempotencyKey = triggerKey,
            target = targetProject,
            targetRange = RevisionRange {changeKind = Modified, before = Just baseCommit, head = headCommit},
            changedDecisionPaths = [decisionPath],
            adoptions = [binding],
            referenceChange = Nothing,
            priorReviewId = Nothing
          } of
        Left problems -> error (show problems)
        Right value -> value

completeOpenTelemetryReferenceChangeTrigger :: Text -> ReviewId -> PracticeReviewTrigger
completeOpenTelemetryReferenceChangeTrigger triggerKey prior =
  case validateTrigger changed of
    Left problems -> error (show problems)
    Right value -> validatedTriggerValue value
  where
    original@PracticeReviewTrigger {adoptions} = completeOpenTelemetryTrigger triggerKey
    changed =
      original
        { triggerKind = ReferenceChange,
          adoptions =
            [ changedReferenceBinding binding
            | binding <- adoptions
            ],
          referenceChange =
            Just
              ChangedReference
                { project = practiceProject,
                  range = RevisionRange {changeKind = Modified, before = Just (parseRevision practiceSha1), head = parseRevision practiceSha2},
                  changedPaths = [relativePath "docs/practices/PRACTICE-1.md"]
                },
          priorReviewId = Just prior
        }

    changedReferenceBinding PracticeAdoptionBinding {practice, claimedApplicability, mode, owners, upstreamProjects} =
      PracticeAdoptionBinding
        { practice,
          references = [practiceReference2],
          claimedApplicability,
          mode,
          owners,
          upstreamProjects
        }

completeReferenceRevision :: Text
completeReferenceRevision = practiceSha2

completeEvidenceReader :: EvidenceReader
completeEvidenceReader = fixtureReader

completeDependencyPinResolver :: DependencyPinResolver
completeDependencyPinResolver = compatiblePinResolver

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

validatedAddedTriggerFor :: PracticeAdoptionBinding -> ValidatedPracticeReviewTrigger
validatedAddedTriggerFor binding =
  case validateTrigger
    PracticeReviewTrigger
      { schemaVersion = practiceReviewSchemaVersion,
        triggerKind = TargetChange,
        idempotencyKey = "trigger-added-practice-evidence",
        target = targetProject,
        targetRange = RevisionRange {changeKind = Added, before = Nothing, head = headCommit},
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

bindingWithoutUpstream :: PracticeAdoptionBinding
bindingWithoutUpstream = bindingWith [practiceReference1] []

bindingWithReferences :: [RegisteredPracticeReference] -> PracticeAdoptionBinding
bindingWithReferences references = bindingWith references [RegisteredUpstreamProject {project = upstreamProject, dependency = "libfoo"}]

bindingWith :: [RegisteredPracticeReference] -> [RegisteredUpstreamProject] -> PracticeAdoptionBinding
bindingWith references upstreamProjects =
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
      upstreamProjects
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
practiceSha1 = "25c08703947fd96d78b3f6908f4454ce0f84c7e6"

practiceSha2 :: Text
practiceSha2 = "bc8a68c96db6cd2d5fc981024e332be566ff30ae"

upstreamSha2 :: Text
upstreamSha2 = "62f545e3018eaa4f854c57d4161e62fce73e2753"

upstreamSha1 :: Text
upstreamSha1 = "47234c4ad7d950dfc8a1e695e0a7acaa070494f2"

targetDecisionBlob2 :: Text
targetDecisionBlob2 = "012ea4ca3a544e103bd378495b290def714e1620"

targetManifestBlob2 :: Text
targetManifestBlob2 = "47c77c0c0d5bbd3821c4e571476e284b1ef01180"

practiceBlob1 :: Text
practiceBlob1 = "8126edfc1acfdf3f3e2e84dad04fdd6129d2905e"

upstreamBlob2 :: Text
upstreamBlob2 = "7eb1470c633b87a99a8acea5250b66c1ce716705"

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
fixtureReader = makeReader fixtureResolveRef fixtureReadBlob fixtureReadDiff fixtureGrep

makeReader :: (RepositoryId -> Text -> IO (Either EvidenceReadError RepoRef)) -> (RepoRef -> RelativePath -> IO (Either EvidenceReadError PinnedContent)) -> (RepositoryId -> Revision -> Revision -> Maybe RelativePath -> IO (Either EvidenceReadError PinnedDiff)) -> (RepoRef -> EvidenceQuery -> PageRequest -> IO (Either EvidenceReadError PinnedMatchPage)) -> EvidenceReader
makeReader resolve blobReader diffReader grepPage =
  EvidenceReader
    { resolveRef = resolve,
      readBlob = blobReader,
      readDiff = diffReader,
      readTree = \reference _ _ ->
        pure
          ( Right
              PinnedTreePage
                { provenance = provenanceFor reference,
                  entries = [],
                  nextCursor = Nothing
                }
          ),
      grep = grepPage
    }

countingDiffReader :: IORef Int -> EvidenceReader
countingDiffReader calls =
  makeReader
    fixtureResolveRef
    fixtureReadBlob
    (\repository base requestedHead path -> modifyIORef' calls (+ 1) >> fixtureReadDiff repository base requestedHead path)
    fixtureGrep

staleRefReader :: EvidenceReader
staleRefReader =
  makeReader
    (\repository mutableRef -> pure (Left (RevisionNotFound repository mutableRef)))
    fixtureReadBlob
    fixtureReadDiff
    fixtureGrep

mismatchedPracticeReader :: EvidenceReader
mismatchedPracticeReader =
  makeReader fixtureResolveRef mismatchedBlob fixtureReadDiff fixtureGrep
  where
    mismatchedBlob reference path
      | reference == practiceRef1 && relativePathText path == "docs/practices/PRACTICE-1.md" =
          fixtureReadBlob practiceRef2 path
      | otherwise = fixtureReadBlob reference path

missingTargetReader :: EvidenceReader
missingTargetReader =
  makeReader fixtureResolveRef missingBlob fixtureReadDiff fixtureGrep
  where
    missingBlob reference path
      | reference == targetRef && path == decisionPath =
          pure (Left (ContentNotFound targetRepository headSha (relativePathText path)))
      | otherwise = fixtureReadBlob reference path

endlessGrepReader :: EvidenceReader
endlessGrepReader =
  makeReader fixtureResolveRef fixtureReadBlob fixtureReadDiff endlessGrep
  where
    endlessGrep reference _ request =
      let pageNumber =
            case request ^. #cursor of
              Nothing -> 1
              Just (EvidenceCursor "1") -> 2
              Just (EvidenceCursor "2") -> 3
              Just (EvidenceCursor "3") -> 4
              Just _ -> 5
       in pure
            ( Right
                PinnedMatchPage
                  { provenance = provenanceFor reference,
                    matches = [PinnedMatch {path = "docs/practices/PRACTICE-1.md", lineNumber = pageNumber, line = "# PRACTICE-1"}],
                    nextCursor = Just (EvidenceCursor (Text.pack (show pageNumber)))
                  }
            )

fixtureResolveRef :: RepositoryId -> Text -> IO (Either EvidenceReadError RepoRef)
fixtureResolveRef repository mutableRef
  | repository == upstreamProject ^. #repository && mutableRef == "v2.0.0" = pure (Right upstreamRef2)
  | otherwise = pure (Left (InvalidContentRequest ("unknown fixture ref: " <> mutableRef)))

fixtureReadBlob :: RepoRef -> RelativePath -> IO (Either EvidenceReadError PinnedContent)
fixtureReadBlob reference path =
  case (reference ^. #repository, revisionText (reference ^. #revision), relativePathText path) of
    (RepositoryId "repo_target", revision, "docs/adr/0001.md")
      | revision == headSha -> fromSnapshot "target/T2/docs/adr/0001.md" targetDecisionBlob2
    (RepositoryId "repo_target", revision, "cabal.project")
      | revision == headSha -> fromSnapshot "target/T2/cabal.project" targetManifestBlob2
    (RepositoryId "repo_practice", revision, "docs/practices/PRACTICE-1.md")
      | revision == practiceSha1 -> fromSnapshot "practice/P1/docs/practices/PRACTICE-1.md" practiceBlob1
      | revision == practiceSha2 -> fromSnapshot "practice/P2/docs/practices/PRACTICE-1.md" "246dfb7fa84bb8eeeee051efccd7b240b83f5dc0"
    (RepositoryId "repo_upstream", revision, "src/Foo.hs")
      | revision == upstreamSha2 -> fromSnapshot "upstream/U2/src/Foo.hs" upstreamBlob2
    (repository, revision, rawPath) -> pure (Left (ContentNotFound repository revision rawPath))
  where
    fromSnapshot relativeFixturePath hash = do
      bytes <- readContentPlaneSnapshot relativeFixturePath
      pure (Right (fixtureBlob reference path hash bytes))

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

sourcePath :: EvidenceSource -> Text
sourcePath source = relativePathText (source ^. #citation . #content . #path)

sourceHash :: EvidenceSource -> Text
sourceHash source =
  case source ^. #citation . #content . #contentHash of
    ContentHash value -> value

readContentPlaneSnapshot :: FilePath -> IO ByteString
readContentPlaneSnapshot relativeFixturePath = do
  readContentPlaneFixture ("snapshots" </> relativeFixturePath)

readContentPlaneFixture :: FilePath -> IO ByteString
readContentPlaneFixture relativeFixturePath = do
  root <- repositoryRoot
  ByteString8.readFile (root </> "fixtures" </> "practice-review" </> "content-plane" </> relativeFixturePath)

repositoryRoot :: IO FilePath
repositoryRoot = go [".", ".."]
  where
    go [] = assertFailure "cannot find cabal.project from the working directory"
    go (candidate : rest) = do
      exists <- doesFileExist (candidate </> "cabal.project")
      if exists then pure candidate else go rest

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
baseSha = "47fceceac91be21ad137c827ff277ac35da37ee6"

headSha :: Text
headSha = "4860c38138deb34933840bb9587138fe1df30e8e"

observedAt :: UTCTime
observedAt = UTCTime (fromGregorian 2026 8 26) (secondsToDiffTime 0)

validBlob :: PinnedContent
validBlob = blob "repo_target" headSha "docs/adr/0001.md" "oid_target" 21 "token=fixture-secret\n"

validEvidenceSource :: EvidenceSource
validEvidenceSource =
  case validatePinnedContent testLimits TargetEvidence targetProject targetRef decisionPath validBlob of
    Left problem -> error (show problem)
    Right source -> source

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

isReadFailure :: EvidenceProblem -> Bool
isReadFailure (ReadFailed _ _ _ _ _) = True
isReadFailure _ = False

isGrepPageLimit :: EvidenceProblem -> Bool
isGrepPageLimit (EvidenceLimitExceeded "grep-pages" _ _ _) = True
isGrepPageLimit _ = False

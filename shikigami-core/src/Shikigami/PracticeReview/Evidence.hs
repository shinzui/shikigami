-- | Bounded, revision-pinned evidence reads for architecture-practice review.
--
-- This module is deliberately independent of an HTTP client, Git, Kioku, and
-- workflow effects. A production adapter can implement 'EvidenceReader' once
-- the Mori C16 content plane exists; deterministic tests supply a stub.
module Shikigami.PracticeReview.Evidence
  ( EvidenceReader (..),
    EvidenceReadError (..),
    PinnedProvenance (..),
    PinnedContent (..),
    PinnedDiff (..),
    PinnedTreeEntry (..),
    PinnedTreePage (..),
    PinnedMatch (..),
    PinnedMatchPage (..),
    EvidenceQuery (..),
    EvidenceCursor (..),
    PageRequest (..),
    EvidenceLimits,
    RedactionRule,
    mkEvidenceLimits,
    defaultEvidenceLimits,
    mkRedactionRule,
    EvidenceProblem (..),
    EvidenceSource (..),
    ValidatedPinnedDiff (..),
    UpstreamSelection (..),
    DependencyPinResolver (..),
    EvidenceCompleteness (..),
    EvidenceBundle (..),
    EvidenceBundleSummary (..),
    validatePinnedContent,
    validatePinnedDiff,
    acquireEvidence,
    summarizeEvidenceBundle,
  )
where

import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Either (partitionEithers)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Encoding.Error qualified as TextEncodingError
import Shikigami.PracticeReview
  ( Applicability (..),
    ContentHash (..),
    ContentReference (..),
    EvidenceId (..),
    EvidenceItem (..),
    EvidenceRole (..),
    PracticeAdoptionBinding (..),
    PracticeReviewResolution (..),
    PracticeReviewTrigger (..),
    ProjectRef (..),
    RegisteredPracticeReference (..),
    RegisteredUpstreamProject (..),
    ResolutionOutcome (..),
    RevisionRange (..),
    ValidatedPracticeReviewResolution,
    ValidatedPracticeReviewTrigger,
    validatedResolutionValue,
    validatedTriggerValue,
  )
import Shikigami.Prelude hiding ((.=))
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

-- | The minimum content-plane operations needed by evidence acquisition.
-- Content operations take only immutable 'RepoRef' values. 'resolveRef' is the
-- one operation that accepts a branch, tag, or other mutable ref.
data EvidenceReader = EvidenceReader
  { resolveRef :: !(RepositoryId -> Text -> IO (Either EvidenceReadError RepoRef)),
    readBlob :: !(RepoRef -> RelativePath -> IO (Either EvidenceReadError PinnedContent)),
    readDiff :: !(RepositoryId -> Revision -> Revision -> Maybe RelativePath -> IO (Either EvidenceReadError PinnedDiff)),
    readTree :: !(RepoRef -> Maybe RelativePath -> PageRequest -> IO (Either EvidenceReadError PinnedTreePage)),
    grep :: !(RepoRef -> EvidenceQuery -> PageRequest -> IO (Either EvidenceReadError PinnedMatchPage))
  }

-- | A transport-level refusal reported by an 'EvidenceReader' implementation.
-- Acquisition converts this to an 'EvidenceProblem' instead of throwing.
data EvidenceReadError
  = RepositoryNotFound !RepositoryId
  | RevisionNotFound !RepositoryId !Text
  | ContentNotFound !RepositoryId !Text !Text
  | InvalidContentRequest !Text
  | ContentTooLarge !Int
  | ContentPlaneUnavailable !Text
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceReadError where toJSON = genericToJSON eventAesonOptions

instance FromJSON EvidenceReadError where parseJSON = genericParseJSON eventAesonOptions

-- | The raw provenance stamp returned by the content plane. Revision remains
-- raw text here so the validator can reject a branch, uppercase SHA, or short
-- SHA before it becomes trusted domain data.
data PinnedProvenance = PinnedProvenance
  { repository :: !RepositoryId,
    revision :: !Text,
    mirrorObservedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

-- | One raw blob response, including its server-declared byte count and Git
-- object id/content hash.
data PinnedContent = PinnedContent
  { provenance :: !PinnedProvenance,
    path :: !Text,
    contentHash :: !ContentHash,
    declaredSize :: !Int,
    bytes :: !ByteString
  }
  deriving stock (Eq, Show, Generic)

-- | One raw diff response. A diff guides navigation; material citations are
-- made from the pinned blobs subsequently read at its changed paths.
data PinnedDiff = PinnedDiff
  { provenance :: !PinnedProvenance,
    baseRevision :: !Text,
    headRevision :: !Text,
    path :: !(Maybe Text),
    changedPaths :: ![Text],
    contentHash :: !ContentHash,
    declaredSize :: !Int,
    bytes :: !ByteString
  }
  deriving stock (Eq, Show, Generic)

-- | One raw tree entry used for bounded discovery.
data PinnedTreeEntry = PinnedTreeEntry
  { path :: !Text,
    kind :: !Text,
    declaredSize :: !Int,
    contentHash :: !ContentHash
  }
  deriving stock (Eq, Show, Generic)

newtype EvidenceCursor = EvidenceCursor {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)

data PinnedTreePage = PinnedTreePage
  { provenance :: !PinnedProvenance,
    entries :: ![PinnedTreeEntry],
    nextCursor :: !(Maybe EvidenceCursor)
  }
  deriving stock (Eq, Show, Generic)

-- | One grep hit. It is discovery evidence only; acquisition reads the blob at
-- the returned path before producing a citable 'EvidenceSource'.
data PinnedMatch = PinnedMatch
  { path :: !Text,
    lineNumber :: !Int,
    line :: !Text
  }
  deriving stock (Eq, Show, Generic)

data PinnedMatchPage = PinnedMatchPage
  { provenance :: !PinnedProvenance,
    matches :: ![PinnedMatch],
    nextCursor :: !(Maybe EvidenceCursor)
  }
  deriving stock (Eq, Show, Generic)

data EvidenceQuery = EvidenceQuery
  { query :: !Text,
    path :: !(Maybe RelativePath)
  }
  deriving stock (Eq, Show, Generic)

data PageRequest = PageRequest
  { first :: !Int,
    cursor :: !(Maybe EvidenceCursor)
  }
  deriving stock (Eq, Show, Generic)

newtype ByteLimit = ByteLimit {value :: Int}
  deriving stock (Eq, Show)

newtype CountLimit = CountLimit {value :: Int}
  deriving stock (Eq, Show)

newtype RedactionRule = RedactionRule
  { needle :: Text
  }
  deriving stock (Eq, Show)

-- | All allocation and prompt-growth limits used during acquisition.
data EvidenceLimits = EvidenceLimits
  { blobBytes :: !ByteLimit,
    diffBytes :: !ByteLimit,
    pathCount :: !CountLimit,
    grepPages :: !CountLimit,
    grepMatches :: !CountLimit,
    excerptCharacters :: !CountLimit,
    redactions :: ![RedactionRule]
  }
  deriving stock (Eq, Show)

-- | Construct a literal redaction rule. Empty needles are refused because
-- replacing an empty string would grow rather than redact content.
mkRedactionRule :: Text -> Either Text RedactionRule
mkRedactionRule raw
  | Text.null raw = Left "redaction needle must not be empty"
  | otherwise = Right (RedactionRule raw)

-- | Construct positive acquisition limits in this order: blob bytes, diff
-- bytes, changed paths, grep pages, grep matches, and excerpt characters.
mkEvidenceLimits :: Int -> Int -> Int -> Int -> Int -> Int -> [RedactionRule] -> Either Text EvidenceLimits
mkEvidenceLimits maxBlob maxDiff maxPaths maxPages maxMatches maxExcerpt redactionRules = do
  blobBytes <- ByteLimit <$> positive "blob byte limit" maxBlob
  diffBytes <- ByteLimit <$> positive "diff byte limit" maxDiff
  pathCount <- CountLimit <$> positive "path-count limit" maxPaths
  grepPages <- CountLimit <$> positive "grep-page limit" maxPages
  grepMatches <- CountLimit <$> positive "grep-match limit" maxMatches
  excerptCharacters <- CountLimit <$> positive "excerpt-character limit" maxExcerpt
  pure
    EvidenceLimits
      { blobBytes,
        diffBytes,
        pathCount,
        grepPages,
        grepMatches,
        excerptCharacters,
        redactions = redactionRules
      }
  where
    positive label value
      | value > 0 = Right value
      | otherwise = Left (label <> " must be positive")

defaultEvidenceLimits :: EvidenceLimits
defaultEvidenceLimits =
  EvidenceLimits
    { blobBytes = ByteLimit (256 * 1024),
      diffBytes = ByteLimit (1024 * 1024),
      pathCount = CountLimit 200,
      grepPages = CountLimit 10,
      grepMatches = CountLimit 200,
      excerptCharacters = CountLimit 8000,
      redactions = []
    }

-- | A typed reason why content could not become trusted evidence.
data EvidenceProblem
  = ReadFailed !RepositoryId !(Maybe Text) !(Maybe Text) !EvidenceReadError !Bool
  | InvalidPinnedRevision !Text !Text !Bool
  | ProvenanceMismatch !RepositoryId !Text !RepositoryId !Text !Bool
  | PathMismatch !Text !Text !Bool
  | InvalidReturnedPath !Text !Text !Bool
  | MissingContentHash !Text !Bool
  | InvalidDeclaredSize !Text !Int !Bool
  | ContentSizeMismatch !Text !Int !Int !Bool
  | EvidenceLimitExceeded !Text !Int !Int !Bool
  | InvalidGrepMatch !Text !Int
  | MixedReferenceRevisions !RepositoryId ![Text]
  | ResolvedRepositoryMismatch !RepositoryId !RepositoryId
  | IncompatibleUpstreamVersion !Text !Text
  | MissingRequiredEvidence !Text !Text
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceProblem where toJSON = genericToJSON eventAesonOptions

instance FromJSON EvidenceProblem where parseJSON = genericParseJSON eventAesonOptions

-- | A verdict-ready citation plus the bounded, redacted text shown to a
-- specialist. Logs should render only the citation and problems, never
-- 'excerpt'.
data EvidenceSource = EvidenceSource
  { citation :: !EvidenceItem,
    mirrorObservedAt :: !UTCTime,
    excerpt :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceSource where toJSON = genericToJSON defaultOptions

instance FromJSON EvidenceSource where parseJSON = genericParseJSON defaultOptions

data ValidatedPinnedDiff = ValidatedPinnedDiff
  { repository :: !RepositoryId,
    baseRevision :: !Revision,
    headRevision :: !Revision,
    path :: !(Maybe RelativePath),
    changedPaths :: ![RelativePath],
    contentHash :: !ContentHash,
    mirrorObservedAt :: !UTCTime,
    excerpt :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | The mutable upstream ref selected from a target dependency pin and the
-- pinned paths that become required after that ref is resolved once.
data UpstreamSelection = UpstreamSelection
  { mutableRef :: !Text,
    paths :: ![RelativePath]
  }
  deriving stock (Eq, Show, Generic)

-- | Pure dependency-pin interpretation supplied by the caller. The inputs are
-- validated target paths and their exact bytes; the resolver may parse the
-- repository's own manifest format without coupling this module to Cabal,
-- NPM, or another package ecosystem.
newtype DependencyPinResolver = DependencyPinResolver
  { resolvePin :: RegisteredUpstreamProject -> [(RelativePath, ByteString)] -> Either Text UpstreamSelection
  }

data EvidenceCompleteness = Complete | Incomplete
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceCompleteness where toJSON = genericToJSON eventAesonOptions

instance FromJSON EvidenceCompleteness where parseJSON = genericParseJSON eventAesonOptions

-- | All evidence available for adjudication. Successful sources remain when a
-- required sibling fails so the Flow can explain an unresolved result.
data EvidenceBundle = EvidenceBundle
  { target :: ![EvidenceSource],
    references :: ![EvidenceSource],
    upstream :: ![EvidenceSource],
    priorResolutions :: ![PracticeReviewResolution],
    problems :: ![EvidenceProblem],
    completeness :: !EvidenceCompleteness
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceBundle where
  toJSON EvidenceBundle {target, references, upstream, priorResolutions, problems, completeness} =
    Aeson.object
      [ "schemaVersion" .= evidenceBundleSchemaVersion,
        "target" .= target,
        "references" .= references,
        "upstream" .= upstream,
        "priorResolutions" .= priorResolutions,
        "problems" .= problems,
        "completeness" .= completeness
      ]

instance FromJSON EvidenceBundle where
  parseJSON = Aeson.withObject "EvidenceBundle" \objectValue -> do
    schemaVersion <- objectValue .: "schemaVersion"
    if schemaVersion /= evidenceBundleSchemaVersion
      then fail ("unsupported evidence-bundle schema version: " <> show (schemaVersion :: Int))
      else do
        target <- objectValue .: "target"
        references <- objectValue .: "references"
        upstream <- objectValue .: "upstream"
        priorResolutions <- objectValue .: "priorResolutions"
        problems <- objectValue .: "problems"
        completeness <- objectValue .: "completeness"
        let expectedCompleteness = if null problems then Complete else Incomplete
        if completeness /= expectedCompleteness
          then fail "evidence-bundle completeness does not match its problem set"
          else pure EvidenceBundle {target, references, upstream, priorResolutions, problems, completeness}

evidenceBundleSchemaVersion :: Int
evidenceBundleSchemaVersion = 1

-- | Log-safe bundle metadata. It deliberately has no excerpt or raw response
-- field, so operational logging cannot accidentally serialize source bytes.
data EvidenceBundleSummary = EvidenceBundleSummary
  { targetIds :: ![EvidenceId],
    referenceIds :: ![EvidenceId],
    upstreamIds :: ![EvidenceId],
    problems :: ![EvidenceProblem],
    completeness :: !EvidenceCompleteness
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceBundleSummary where toJSON = genericToJSON defaultOptions

instance FromJSON EvidenceBundleSummary where parseJSON = genericParseJSON defaultOptions

-- | Validate a blob against the exact repository, revision, and path that was
-- requested, then produce a bounded and redacted citable source.
validatePinnedContent :: EvidenceLimits -> EvidenceRole -> ProjectRef -> RepoRef -> RelativePath -> PinnedContent -> Either EvidenceProblem EvidenceSource
validatePinnedContent limits role project requested requestedPath response = do
  validateProvenance True requested (response ^. #provenance)
  returnedPath <- validatePath True (response ^. #path)
  unlessEither
    (returnedPath == requestedPath)
    (PathMismatch (relativePathText requestedPath) (response ^. #path) True)
  validateHash True (response ^. #path) (response ^. #contentHash)
  validateSize True "blob-bytes" (byteLimit ((.blobBytes) limits)) responsePath (response ^. #declaredSize) (ByteString.length (response ^. #bytes))
  unlessEither
    (response ^. #declaredSize <= byteLimit ((.blobBytes) limits))
    (EvidenceLimitExceeded "blob-bytes" (byteLimit ((.blobBytes) limits)) (response ^. #declaredSize) True)
  let stamp = response ^. #provenance
      citation =
        EvidenceItem
          { evidenceId = sourceEvidenceId role requested requestedPath (response ^. #contentHash),
            role,
            content =
              ContentReference
                { project,
                  provenance = requested,
                  path = requestedPath,
                  contentHash = response ^. #contentHash
                }
          }
  pure
    EvidenceSource
      { citation,
        mirrorObservedAt = stamp ^. #mirrorObservedAt,
        excerpt = renderExcerpt limits (response ^. #bytes)
      }
  where
    responsePath = response ^. #path

-- | Validate a diff and normalize every returned changed path. Diff bytes are
-- retained only as a bounded, redacted excerpt for navigation.
validatePinnedDiff :: EvidenceLimits -> RepositoryId -> Revision -> Revision -> Maybe RelativePath -> PinnedDiff -> Either EvidenceProblem ValidatedPinnedDiff
validatePinnedDiff limits requestedRepository requestedBase requestedHead requestedPath response = do
  let requested = RepoRef {repository = requestedRepository, revision = requestedHead}
  validateProvenance True requested (response ^. #provenance)
  validateRawRevision True requestedBase (response ^. #baseRevision)
  validateRawRevision True requestedHead (response ^. #headRevision)
  returnedPath <- traverse (validatePath True) (response ^. #path)
  unlessEither
    (returnedPath == requestedPath)
    (PathMismatch (maybe "<all>" relativePathText requestedPath) (fromMaybe "<all>" (response ^. #path)) True)
  normalizedChangedPaths <- traverse (validatePath True) (response ^. #changedPaths)
  unlessEither
    (length normalizedChangedPaths <= countLimit ((.pathCount) limits))
    (EvidenceLimitExceeded "changed-paths" (countLimit ((.pathCount) limits)) (length normalizedChangedPaths) True)
  validateHash True "<diff>" (response ^. #contentHash)
  validateSize True "diff-bytes" (byteLimit ((.diffBytes) limits)) "<diff>" (response ^. #declaredSize) (ByteString.length (response ^. #bytes))
  unlessEither
    (response ^. #declaredSize <= byteLimit ((.diffBytes) limits))
    (EvidenceLimitExceeded "diff-bytes" (byteLimit ((.diffBytes) limits)) (response ^. #declaredSize) True)
  pure
    ValidatedPinnedDiff
      { repository = requestedRepository,
        baseRevision = requestedBase,
        headRevision = requestedHead,
        path = returnedPath,
        changedPaths = normalizedChangedPaths,
        contentHash = response ^. #contentHash,
        mirrorObservedAt = response ^. #provenance . #mirrorObservedAt,
        excerpt = renderExcerpt limits (response ^. #bytes)
      }

data ReadResult = ReadResult
  { source :: !EvidenceSource,
    response :: !PinnedContent
  }
  deriving stock (Eq, Show, Generic)

-- | Acquire all target, registered-reference, compatible-upstream, and
-- caller-supplied prior-resolution evidence. This function performs no
-- persistence and emits no verdict; every required failure is returned as
-- data in an incomplete bundle.
acquireEvidence :: EvidenceLimits -> EvidenceReader -> DependencyPinResolver -> ValidatedPracticeReviewTrigger -> PracticeAdoptionBinding -> [ValidatedPracticeReviewResolution] -> IO EvidenceBundle
acquireEvidence limits reader pinResolver validatedTrigger binding validatedPriorResolutions = do
  let trigger = validatedTriggerValue validatedTrigger
      targetProject = trigger ^. #target
      targetRange = trigger ^. #targetRange
      targetRef =
        RepoRef
          { repository = targetProject ^. #repository,
            revision = targetRange ^. #head
          }
  (diffPaths, diffProblems) <- acquireTargetDiff limits reader targetProject targetRange
  let (targetPaths, targetLimitProblems) =
        boundPaths limits "target-paths" ((trigger ^. #changedDecisionPaths) <> diffPaths)
  targetReads <- traverse (readRequiredSource limits reader TargetEvidence targetProject targetRef) targetPaths
  let (targetProblems, successfulTargetReads) = partitionEithers targetReads
  (referenceReads, referenceProblems) <- acquireReferenceEvidence limits reader binding
  (upstreamReads, upstreamProblems) <- acquireUpstreamEvidence limits reader pinResolver binding successfulTargetReads
  let allProblems =
        diffProblems
          <> targetLimitProblems
          <> targetProblems
          <> referenceProblems
          <> upstreamProblems
      retainedPriorResolutions = selectPriorResolutions trigger binding targetPaths validatedPriorResolutions
  pure
    EvidenceBundle
      { target = (.source) <$> successfulTargetReads,
        references = (.source) <$> dedupeReads referenceReads,
        upstream = (.source) <$> dedupeReads upstreamReads,
        priorResolutions = retainedPriorResolutions,
        problems = allProblems,
        completeness = if null allProblems then Complete else Incomplete
      }

summarizeEvidenceBundle :: EvidenceBundle -> EvidenceBundleSummary
summarizeEvidenceBundle bundle =
  EvidenceBundleSummary
    { targetIds = evidenceIds (bundle ^. #target),
      referenceIds = evidenceIds (bundle ^. #references),
      upstreamIds = evidenceIds (bundle ^. #upstream),
      problems = bundle ^. #problems,
      completeness = bundle ^. #completeness
    }
  where
    evidenceIds = fmap (^. #citation . #evidenceId)

acquireTargetDiff :: EvidenceLimits -> EvidenceReader -> ProjectRef -> RevisionRange -> IO ([RelativePath], [EvidenceProblem])
acquireTargetDiff limits reader project range =
  case range ^. #before of
    Nothing -> pure ([], [])
    Just base -> do
      let repository = project ^. #repository
          targetHead = range ^. #head
      result <- (.readDiff) reader repository base targetHead Nothing
      case result of
        Left failure ->
          pure
            ( [],
              [ReadFailed repository (Just (revisionText targetHead)) Nothing failure True]
            )
        Right response ->
          case validatePinnedDiff limits repository base targetHead Nothing response of
            Left problem -> pure ([], [problem])
            Right validated -> pure (validated ^. #changedPaths, [])

readRequiredSource :: EvidenceLimits -> EvidenceReader -> EvidenceRole -> ProjectRef -> RepoRef -> RelativePath -> IO (Either EvidenceProblem ReadResult)
readRequiredSource limits reader role project requested path = do
  result <- (.readBlob) reader requested path
  pure case result of
    Left failure ->
      Left
        ( ReadFailed
            (requested ^. #repository)
            (Just (revisionText (requested ^. #revision)))
            (Just (relativePathText path))
            failure
            True
        )
    Right response ->
      ReadResult <$> validatePinnedContent limits role project requested path response <*> pure response

acquireReferenceEvidence :: EvidenceLimits -> EvidenceReader -> PracticeAdoptionBinding -> IO ([ReadResult], [EvidenceProblem])
acquireReferenceEvidence limits reader binding = do
  let registeredReferences = binding ^. #references
      revisionsByRepository =
        Map.fromListWith
          Set.union
          [ ( registered ^. #provenance . #repository,
              Set.singleton (revisionText (registered ^. #provenance . #revision))
            )
          | registered <- registeredReferences
          ]
      mixed = Map.filter ((> 1) . Set.size) revisionsByRepository
      mixedProblems =
        [ MixedReferenceRevisions repository (Set.toList revisions)
        | (repository, revisions) <- Map.toList mixed
        ]
      eligible =
        filter
          (\registered -> Map.notMember (registered ^. #provenance . #repository) mixed)
          registeredReferences
  acquired <- traverse (acquireRegisteredReference limits reader) eligible
  pure
    ( concatMap fst acquired,
      mixedProblems <> concatMap snd acquired
    )

acquireRegisteredReference :: EvidenceLimits -> EvidenceReader -> RegisteredPracticeReference -> IO ([ReadResult], [EvidenceProblem])
acquireRegisteredReference limits reader registered = do
  let project = registered ^. #project
      reference = registered ^. #provenance
  acquired <-
    traverse
      (acquireReferenceDocument limits reader project reference)
      (registered ^. #documentIds)
  pure (concatMap fst acquired, concatMap snd acquired)

acquireReferenceDocument :: EvidenceLimits -> EvidenceReader -> ProjectRef -> RepoRef -> Text -> IO ([ReadResult], [EvidenceProblem])
acquireReferenceDocument limits reader project reference documentId =
  case mkRelativePath documentId of
    Right directPath -> do
      direct <- (.readBlob) reader reference directPath
      case direct of
        Right response ->
          case validatePinnedContent limits ReferenceEvidence project reference directPath response of
            Left problem -> pure ([], [problem])
            Right source -> pure ([ReadResult {source, response}], [])
        Left ContentNotFound {} -> discoverAndRead
        Left failure ->
          pure
            ( [],
              [ ReadFailed
                  (reference ^. #repository)
                  (Just (revisionText (reference ^. #revision)))
                  (Just (relativePathText directPath))
                  failure
                  True
              ]
            )
    Left _ -> discoverAndRead
  where
    discoverAndRead = do
      (discoveredPaths, discoveryProblems) <- discoverReferencePaths limits reader reference documentId
      let (boundedDiscoveredPaths, pathProblems) = boundPaths limits "reference-paths" discoveredPaths
      readResults <- traverse (readRequiredSource limits reader ReferenceEvidence project reference) boundedDiscoveredPaths
      let (readProblems, successes) = partitionEithers readResults
          missingProblems =
            [MissingRequiredEvidence "reference-document" documentId | null boundedDiscoveredPaths]
      pure
        ( successes,
          discoveryProblems <> pathProblems <> readProblems <> missingProblems
        )

discoverReferencePaths :: EvidenceLimits -> EvidenceReader -> RepoRef -> Text -> IO ([RelativePath], [EvidenceProblem])
discoverReferencePaths limits reader reference documentId =
  go 0 0 Nothing Set.empty [] []
  where
    maximumPages = countLimit ((.grepPages) limits)
    maximumMatches = countLimit ((.grepMatches) limits)
    evidenceQuery = EvidenceQuery {query = documentId, path = Nothing}

    go pagesRead matchesRead cursor seenCursors collected collectedProblems
      | pagesRead >= maximumPages =
          pure
            ( collected,
              collectedProblems <> [EvidenceLimitExceeded "grep-pages" maximumPages (pagesRead + 1) True]
            )
      | matchesRead >= maximumMatches =
          pure
            ( collected,
              collectedProblems <> [EvidenceLimitExceeded "grep-matches" maximumMatches (matchesRead + 1) True]
            )
      | otherwise = do
          let remaining = maximumMatches - matchesRead
              request = PageRequest {first = min 100 remaining, cursor}
          result <- (.grep) reader reference evidenceQuery request
          case result of
            Left failure ->
              pure
                ( collected,
                  collectedProblems
                    <> [ ReadFailed
                           (reference ^. #repository)
                           (Just (revisionText (reference ^. #revision)))
                           Nothing
                           failure
                           True
                       ]
                )
            Right page ->
              case validateProvenance True reference (page ^. #provenance) of
                Left problem -> pure (collected, collectedProblems <> [problem])
                Right () -> do
                  let pageMatches = page ^. #matches
                      (acceptedMatches, matchLimitProblems) =
                        if length pageMatches <= remaining
                          then (pageMatches, [])
                          else
                            ( take remaining pageMatches,
                              [EvidenceLimitExceeded "grep-matches" maximumMatches (matchesRead + length pageMatches) True]
                            )
                      validatedPaths = validateMatch <$> acceptedMatches
                      (matchProblems, paths) = partitionEithers validatedPaths
                      next = page ^. #nextCursor
                      nextProblems = collectedProblems <> matchLimitProblems <> matchProblems
                      nextCollected = collected <> paths
                      nextMatchesRead = matchesRead + length acceptedMatches
                      nextPagesRead = pagesRead + 1
                  case next of
                    Nothing -> pure (uniquePaths nextCollected, nextProblems)
                    Just nextCursor
                      | Set.member nextCursor seenCursors ->
                          pure
                            ( uniquePaths nextCollected,
                              nextProblems
                                <> [ ReadFailed
                                       (reference ^. #repository)
                                       (Just (revisionText (reference ^. #revision)))
                                       Nothing
                                       (InvalidContentRequest "content plane repeated a grep cursor")
                                       True
                                   ]
                            )
                      | nextPagesRead >= maximumPages ->
                          pure
                            ( uniquePaths nextCollected,
                              nextProblems <> [EvidenceLimitExceeded "grep-pages" maximumPages (nextPagesRead + 1) True]
                            )
                      | nextMatchesRead >= maximumMatches ->
                          pure
                            ( uniquePaths nextCollected,
                              nextProblems <> [EvidenceLimitExceeded "grep-matches" maximumMatches (nextMatchesRead + 1) True]
                            )
                      | otherwise ->
                          go nextPagesRead nextMatchesRead (Just nextCursor) (Set.insert nextCursor seenCursors) nextCollected nextProblems

    validateMatch match
      | match ^. #lineNumber < 1 = Left (InvalidGrepMatch (match ^. #path) (match ^. #lineNumber))
      | otherwise = validatePath True (match ^. #path)

acquireUpstreamEvidence :: EvidenceLimits -> EvidenceReader -> DependencyPinResolver -> PracticeAdoptionBinding -> [ReadResult] -> IO ([ReadResult], [EvidenceProblem])
acquireUpstreamEvidence limits reader pinResolver binding targetReads = do
  let pinInputs =
        [ ( result ^. #source . #citation . #content . #path,
            result ^. #response . #bytes
          )
        | result <- targetReads
        ]
  acquired <-
    traverse
      (acquireRegisteredUpstream limits reader pinResolver pinInputs)
      (binding ^. #upstreamProjects)
  pure (concatMap fst acquired, concatMap snd acquired)

acquireRegisteredUpstream :: EvidenceLimits -> EvidenceReader -> DependencyPinResolver -> [(RelativePath, ByteString)] -> RegisteredUpstreamProject -> IO ([ReadResult], [EvidenceProblem])
acquireRegisteredUpstream limits reader pinResolver pinInputs registered =
  case (.resolvePin) pinResolver registered pinInputs of
    Left reason -> pure ([], [IncompatibleUpstreamVersion dependency reason])
    Right selection
      | Text.null (Text.strip (selection ^. #mutableRef)) ->
          pure ([], [IncompatibleUpstreamVersion dependency "dependency pin resolved to an empty upstream ref"])
      | null (selection ^. #paths) ->
          pure ([], [IncompatibleUpstreamVersion dependency "dependency pin selected no required upstream paths"])
      | otherwise -> do
          resolved <- (.resolveRef) reader upstreamRepository (selection ^. #mutableRef)
          case resolved of
            Left failure ->
              pure
                ( [],
                  [ IncompatibleUpstreamVersion
                      dependency
                      ("resolve-ref failed: " <> Text.pack (show failure))
                  ]
                )
            Right reference
              | reference ^. #repository /= upstreamRepository ->
                  pure
                    ( [],
                      [ResolvedRepositoryMismatch upstreamRepository (reference ^. #repository)]
                    )
              | otherwise -> do
                  let (upstreamPaths, pathProblems) = boundPaths limits "upstream-paths" (selection ^. #paths)
                  readResults <- traverse (readRequiredSource limits reader UpstreamEvidence project reference) upstreamPaths
                  let (readProblems, successes) = partitionEithers readResults
                  pure (successes, pathProblems <> readProblems)
  where
    dependency = registered ^. #dependency
    project = registered ^. #project
    upstreamRepository = project ^. #repository

selectPriorResolutions :: PracticeReviewTrigger -> PracticeAdoptionBinding -> [RelativePath] -> [ValidatedPracticeReviewResolution] -> [PracticeReviewResolution]
selectPriorResolutions trigger binding targetPaths =
  mapMaybe select
  where
    select validated =
      let resolution = validatedResolutionValue validated
       in case resolution ^. #outcome of
            Rejected -> Just resolution
            Accepted -> guiding resolution
            Narrowed -> guiding resolution
            Superseded -> Nothing

    guiding resolution =
      case resolution ^. #resultingApplicability of
        Just applicability
          | applicabilityCovers trigger binding targetPaths applicability -> Just resolution
        _ -> Nothing

applicabilityCovers :: PracticeReviewTrigger -> PracticeAdoptionBinding -> [RelativePath] -> Applicability -> Bool
applicabilityCovers trigger binding targetPaths applicability =
  projectCovered && pathsCovered && dependenciesCovered && practiceCovered
  where
    scopedProjects = applicability ^. #projects
    scopedPaths = applicability ^. #paths
    scopedDependencies = normalizeName <$> (applicability ^. #dependencies)
    scopedPractices = applicability ^. #practices
    targetRepository = trigger ^. #target . #repository
    targetDependencies = normalizeName . (^. #dependency) <$> (binding ^. #upstreamProjects)
    targetPractice = binding ^. #practice

    projectCovered =
      null scopedProjects
        || any ((== targetRepository) . (^. #repository)) scopedProjects
    pathsCovered =
      null scopedPaths
        || any (\scope -> any (pathsOverlap scope) targetPaths) scopedPaths
    dependenciesCovered =
      null scopedDependencies
        || any (`elem` targetDependencies) scopedDependencies
    practiceCovered = null scopedPractices || targetPractice `elem` scopedPractices

pathsOverlap :: RelativePath -> RelativePath -> Bool
pathsOverlap left right = pathContains left right || pathContains right left

pathContains :: RelativePath -> RelativePath -> Bool
pathContains parent child =
  let parentText = relativePathText parent
      childText = relativePathText child
   in parentText == childText || (parentText <> "/") `Text.isPrefixOf` childText

normalizeName :: Text -> Text
normalizeName = Text.toCaseFold . Text.strip

boundPaths :: EvidenceLimits -> Text -> [RelativePath] -> ([RelativePath], [EvidenceProblem])
boundPaths limits label rawPaths =
  let paths = uniquePaths rawPaths
      maximumPaths = countLimit ((.pathCount) limits)
   in if length paths <= maximumPaths
        then (paths, [])
        else
          ( take maximumPaths paths,
            [EvidenceLimitExceeded label maximumPaths (length paths) True]
          )

uniquePaths :: [RelativePath] -> [RelativePath]
uniquePaths = uniqueOn relativePathText

dedupeReads :: [ReadResult] -> [ReadResult]
dedupeReads = uniqueOn (^. #source . #citation . #evidenceId)

uniqueOn :: (Ord key) => (value -> key) -> [value] -> [value]
uniqueOn key = reverse . snd . foldl step (Set.empty, [])
  where
    step (seen, values) value
      | Set.member (key value) seen = (seen, values)
      | otherwise = (Set.insert (key value) seen, value : values)

validateProvenance :: Bool -> RepoRef -> PinnedProvenance -> Either EvidenceProblem ()
validateProvenance required RepoRef {repository = expectedRepository, revision = expectedRevision} PinnedProvenance {repository = actualRepository, revision = actualRevision} = do
  _ <- mapLeft (const (InvalidPinnedRevision (revisionText expectedRevision) actualRevision required)) (mkRevision actualRevision)
  unlessEither
    (actualRepository == expectedRepository && actualRevision == revisionText expectedRevision)
    (ProvenanceMismatch expectedRepository (revisionText expectedRevision) actualRepository actualRevision required)

validateRawRevision :: Bool -> Revision -> Text -> Either EvidenceProblem ()
validateRawRevision required expected actual = do
  _ <- mapLeft (const (InvalidPinnedRevision (revisionText expected) actual required)) (mkRevision actual)
  unlessEither
    (actual == revisionText expected)
    (InvalidPinnedRevision (revisionText expected) actual required)

validatePath :: Bool -> Text -> Either EvidenceProblem RelativePath
validatePath required raw =
  mapLeft
    (\reason -> InvalidReturnedPath raw reason required)
    (mkRelativePath raw)

validateHash :: Bool -> Text -> ContentHash -> Either EvidenceProblem ()
validateHash required path (ContentHash raw) =
  unlessEither
    (not (Text.null (Text.strip raw)))
    (MissingContentHash path required)

validateSize :: Bool -> Text -> Int -> Text -> Int -> Int -> Either EvidenceProblem ()
validateSize required _limitName _maximum path declared actual
  | declared < 0 = Left (InvalidDeclaredSize path declared required)
  | declared /= actual = Left (ContentSizeMismatch path declared actual required)
  | otherwise = Right ()

sourceEvidenceId :: EvidenceRole -> RepoRef -> RelativePath -> ContentHash -> EvidenceId
sourceEvidenceId role RepoRef {repository = RepositoryId repository, revision} path (ContentHash contentHash) =
  EvidenceId
    ( Text.intercalate
        ":"
        [ "evidence",
          roleText role,
          repository,
          revisionText revision,
          relativePathText path,
          contentHash
        ]
    )

roleText :: EvidenceRole -> Text
roleText TargetEvidence = "target"
roleText ReferenceEvidence = "reference"
roleText UpstreamEvidence = "upstream"

renderExcerpt :: EvidenceLimits -> ByteString -> Text
renderExcerpt EvidenceLimits {excerptCharacters = CountLimit excerptLimit, redactions} =
  Text.take excerptLimit
    . applyRedactions redactions
    . TextEncoding.decodeUtf8With TextEncodingError.lenientDecode

applyRedactions :: [RedactionRule] -> Text -> Text
applyRedactions rules content =
  foldl
    (\redacted RedactionRule {needle} -> Text.replace needle "[REDACTED]" redacted)
    content
    rules

byteLimit :: ByteLimit -> Int
byteLimit (ByteLimit value) = value

countLimit :: CountLimit -> Int
countLimit (CountLimit value) = value

unlessEither :: Bool -> EvidenceProblem -> Either EvidenceProblem ()
unlessEither True _ = Right ()
unlessEither False problem = Left problem

mapLeft :: (left -> mapped) -> Either left value -> Either mapped value
mapLeft function = either (Left . function) Right

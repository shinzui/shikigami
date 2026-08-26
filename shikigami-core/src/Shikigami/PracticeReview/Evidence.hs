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
    validatePinnedContent,
    validatePinnedDiff,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Encoding.Error qualified as TextEncodingError
import Shikigami.PracticeReview
  ( ContentHash (..),
    ContentReference (..),
    EvidenceId (..),
    EvidenceItem (..),
    EvidenceRole (..),
    ProjectRef (..),
  )
import Shikigami.Prelude
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
  | MixedReferenceRevisions !RepositoryId ![Text]
  | IncompatibleUpstreamVersion !Text !Text
  | MissingRequiredEvidence !Text !Text
  deriving stock (Eq, Show, Generic)

-- | A verdict-ready citation plus the bounded, redacted text shown to a
-- specialist. Logs should render only the citation and problems, never
-- 'excerpt'.
data EvidenceSource = EvidenceSource
  { citation :: !EvidenceItem,
    mirrorObservedAt :: !UTCTime,
    excerpt :: !Text
  }
  deriving stock (Eq, Show, Generic)

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
  validateSize True "blob-bytes" (byteLimit (blobBytes limits)) responsePath (response ^. #declaredSize) (ByteString.length (response ^. #bytes))
  unlessEither
    (response ^. #declaredSize <= byteLimit (blobBytes limits))
    (EvidenceLimitExceeded "blob-bytes" (byteLimit (blobBytes limits)) (response ^. #declaredSize) True)
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
    (length normalizedChangedPaths <= countLimit (pathCount limits))
    (EvidenceLimitExceeded "changed-paths" (countLimit (pathCount limits)) (length normalizedChangedPaths) True)
  validateHash True "<diff>" (response ^. #contentHash)
  validateSize True "diff-bytes" (byteLimit (diffBytes limits)) "<diff>" (response ^. #declaredSize) (ByteString.length (response ^. #bytes))
  unlessEither
    (response ^. #declaredSize <= byteLimit (diffBytes limits))
    (EvidenceLimitExceeded "diff-bytes" (byteLimit (diffBytes limits)) (response ^. #declaredSize) True)
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

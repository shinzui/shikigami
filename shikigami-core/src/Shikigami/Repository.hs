{-# LANGUAGE DataKinds #-}

-- | Repository identities and immutable content-plane addresses shared across
-- review, evidence acquisition, and attestation.
module Shikigami.Repository
  ( RepositoryId,
    repositoryId,
    repositoryIdText,
    Revision,
    mkRevision,
    revisionText,
    RepoRef (..),
    RelativePath,
    mkRelativePath,
    relativePathText,
  )
where

import Data.Aeson (FromJSONKey, ToJSONKey, Value (String), withText)
import Data.Char (isAsciiLower, isDigit)
import Data.Text qualified as Text
import GHC.Records (HasField (..))
import Shikigami.Prelude

-- | Mori's stable repository identity. Current producers use either a
-- @repo_...@ TypeID or a canonical @mori://@ repository URI.
newtype RepositoryId = RepositoryId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

repositoryId :: Text -> RepositoryId
repositoryId = RepositoryId

repositoryIdText :: RepositoryId -> Text
repositoryIdText (RepositoryId raw) = raw

instance HasField "value" RepositoryId Text where getField = repositoryIdText

-- | A revision accepted by the current Mori content plane: one full lowercase
-- 40-character Git SHA-1 commit id.
--
-- The constructor is private so a branch, tag, abbreviation, or differently
-- cased spelling cannot enter through ordinary construction or JSON decoding.
newtype Revision = Revision {value :: Text}
  deriving stock (Eq, Ord, Show)

-- | Construct a pinned content-plane revision.
mkRevision :: Text -> Either Text Revision
mkRevision raw
  | Text.length raw /= 40 =
      Left
        ( "revision must be a full 40-character commit SHA, got "
            <> Text.pack (show (Text.length raw))
            <> " characters"
        )
  | not (Text.all isLowerHex raw) =
      Left "revision must contain only lowercase hexadecimal characters"
  | otherwise = Right (Revision raw)
  where
    isLowerHex character = isDigit character || (isAsciiLower character && character <= 'f')

-- | The canonical lowercase commit SHA.
revisionText :: Revision -> Text
revisionText Revision {value} = value

instance ToJSON Revision where
  toJSON = String . revisionText

instance FromJSON Revision where
  parseJSON = withText "Revision" (either (fail . Text.unpack) pure . mkRevision)

-- | A repository plus the immutable revision at which content was read.
data RepoRef = RepoRef
  { repository :: !RepositoryId,
    revision :: !Revision
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A normalized POSIX path relative to a repository root.
--
-- Empty segments and @.@ are removed. Absolute paths, backslashes, NUL bytes,
-- and @..@ traversal are rejected before a value can be constructed.
newtype RelativePath = RelativePath {value :: Text}
  deriving stock (Eq, Ord, Show)

-- | Construct and normalize a safe repository-relative path.
mkRelativePath :: Text -> Either Text RelativePath
mkRelativePath raw
  | Text.null raw = Left "relative path must not be empty"
  | Text.isPrefixOf "/" raw = Left "relative path must not be absolute"
  | Text.any (== '\\') raw = Left "relative path must use POSIX '/' separators"
  | Text.any (== '\0') raw = Left "relative path must not contain NUL"
  | any (== "..") segments = Left "relative path must not contain '..' traversal"
  | null normalizedSegments = Left "relative path must name repository content"
  | otherwise = Right (RelativePath (Text.intercalate "/" normalizedSegments))
  where
    segments = Text.splitOn "/" raw
    normalizedSegments = filter (\segment -> not (Text.null segment) && segment /= ".") segments

-- | The normalized repository-relative path.
relativePathText :: RelativePath -> Text
relativePathText RelativePath {value} = value

instance ToJSON RelativePath where
  toJSON = String . relativePathText

instance FromJSON RelativePath where
  parseJSON = withText "RelativePath" (either (fail . Text.unpack) pure . mkRelativePath)

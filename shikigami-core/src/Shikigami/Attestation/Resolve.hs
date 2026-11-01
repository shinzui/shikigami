-- | Fail-closed resolution of sanctioned execution profiles.
--
-- A 'ProfileStore' is a function seam rather than a database handle. Production
-- builds it with 'postgresProfileStore'; tests can supply multiple candidates to
-- exercise ambiguity even though the PostgreSQL table's primary key prevents
-- duplicate @(profile_id, version)@ rows.
module Shikigami.Attestation.Resolve
  ( ProfileResolutionError (..),
    renderProfileResolutionError,
    ResolvedProfile,
    ResolvedProfileView (..),
    resolvedProfileFor,
    parseResolvedProfile,
    resolvedProfileView,
    ProfileMetadataRefusal (..),
    ProfileStore (..),
    postgresProfileStore,
    resolveProfile,
  )
where

import Contravariant.Extras (contrazip2)
import Control.Exception (Exception, throwIO)
import Data.Aeson (Result (..), Value)
import Data.Bifunctor (first)
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shikigami.Attestation.Profile
  ( ProfileDigest,
    ProfileId (..),
    ProfileLifecycle (..),
    ProfileVersion (..),
    SanctionedExecutionProfile (..),
    SanctionedExecutionProfileRef (..),
    parseProfileDigest,
    profileContentDigest,
    profileDigestText,
  )
import Shikigami.Prelude

-- | Every policy refusal is explicit. Infrastructure failures from the store
-- are thrown instead: unlike these five permanent policy facts, a lost database
-- connection is transient and should be retried by the workflow runtime.
data ProfileResolutionError
  = UnknownProfile !ProfileId !(Maybe ProfileVersion)
  | ProfileExpired !ProfileId !ProfileVersion !UTCTime
  | ProfileWithdrawn !ProfileId !ProfileVersion !ProfileLifecycle
  | AmbiguousProfile !ProfileId ![ProfileVersion]
  | MutableProfile !ProfileId !ProfileVersion !ProfileDigest !ProfileDigest
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | An immutable, internally consistent snapshot. Construction checks only the
-- content/reference binding; lifecycle and current lookup authority are separate
-- admission checks and must not be reapplied when decoding historical facts.
newtype ResolvedProfile = ResolvedProfile ResolvedProfileView
  deriving stock (Eq, Show)

-- | A copy for inspection and the explicit JSON transfer boundary. Modifying a
-- view cannot modify or construct an admitted snapshot.
data ResolvedProfileView = ResolvedProfileView
  { profile :: !SanctionedExecutionProfile,
    ref :: !SanctionedExecutionProfileRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

resolvedProfileView :: ResolvedProfile -> ResolvedProfileView
resolvedProfileView (ResolvedProfile view) = view

resolvedProfileFor :: SanctionedExecutionProfile -> ResolvedProfile
resolvedProfileFor content =
  ResolvedProfile
    (ResolvedProfileView content (SanctionedExecutionProfileRef content.profileId content.version (profileContentDigest content)))

parseResolvedProfile :: SanctionedExecutionProfile -> SanctionedExecutionProfileRef -> Either Text ResolvedProfile
parseResolvedProfile content reference = do
  unless (content.profileId == reference.profileId && content.version == reference.version) (Left "resolved profile coordinates differ from its reference")
  unless (profileContentDigest content == reference.digest) (Left "resolved profile content differs from its commitment")
  pure (ResolvedProfile (ResolvedProfileView content reference))

instance ToJSON ResolvedProfile where
  toJSON = toJSON . resolvedProfileView
  toEncoding = toEncoding . resolvedProfileView

instance FromJSON ResolvedProfile where
  parseJSON value = do
    ResolvedProfileView {profile, ref} <- parseJSON value
    either (fail . Text.unpack) pure (parseResolvedProfile profile ref)

-- | Unreadable or incorrectly attributed metadata is neither an absent policy
-- nor a native SQL error. This read-only refusal stays outside the five existing
-- journaled policy-error alternatives; repairing the row permits the same read
-- to recover without recording a new failure-result vocabulary.
data ProfileMetadataRefusal = ProfileMetadataUnreadable !ProfileId !(Maybe ProfileVersion)
  deriving stock (Eq, Show)

instance Exception ProfileMetadataRefusal

data ProfileReadFailure
  = ProfileReadMetadata !ProfileMetadataRefusal
  | ProfileReadPolicy !ProfileResolutionError

-- | The resolution read seam. Returning a list makes the exactly-one invariant
-- visible and testable instead of burying ambiguity in a SQL-specific branch.
newtype ProfileStore = ProfileStore
  { findProfiles :: ProfileId -> Maybe ProfileVersion -> IO (Either ProfileResolutionError [ResolvedProfile])
  }

-- | Read and check complete candidates. Policy failures preserve the existing
-- result vocabulary. Metadata refusals throw their owning data type; genuine
-- query failures retain the original infrastructure exception seam.
postgresProfileStore :: Pool -> ProfileStore
postgresProfileStore pool =
  ProfileStore \profileId requestedVersion -> do
    result <-
      Pool.use
        pool
        ( Session.statement
            (profileIdText profileId, profileVersionText <$> requestedVersion)
            findProfilesStatement
        )
    rows <- either (ioError . userError . show) pure result
    case traverse decodeProfileRow rows of
      Left (ProfileReadMetadata refusal) -> throwIO refusal
      Left (ProfileReadPolicy refusal) -> pure (Left refusal)
      Right candidates -> pure (Right candidates)

-- | Resolve exactly one profile, checking existence, ambiguity, integrity, and
-- lifecycle in that order. Integrity precedes lifecycle so a tampered expired
-- profile reports the more urgent fact.
resolveProfile ::
  ProfileStore ->
  UTCTime ->
  ProfileId ->
  Maybe ProfileVersion ->
  IO (Either ProfileResolutionError ResolvedProfile)
resolveProfile ProfileStore {findProfiles} now requestedId requestedVersion = do
  found <- findProfiles requestedId requestedVersion
  case found of
    Left refusal -> pure (Left refusal)
    Right candidates -> do
      unless (all matches candidates) (throwIO (ProfileMetadataUnreadable requestedId requestedVersion))
      pure case candidates of
        [] -> Left (UnknownProfile requestedId requestedVersion)
        [candidate] -> validateCandidate now candidate
        many -> Left (AmbiguousProfile requestedId (candidateVersion <$> many))
  where
    matches candidate =
      let reference = (resolvedProfileView candidate).ref
       in reference.profileId == requestedId && maybe True (== reference.version) requestedVersion

validateCandidate :: UTCTime -> ResolvedProfile -> Either ProfileResolutionError ResolvedProfile
validateCandidate now candidate =
  let ResolvedProfileView {profile = content, ref = profileRef} = resolvedProfileView candidate
      SanctionedExecutionProfile {lifecycle, validFrom, validUntil} = content
      SanctionedExecutionProfileRef {profileId, version} = profileRef
      expiry = fromMaybe validFrom validUntil
   in case lifecycle of
        Withdrawn -> Left (ProfileWithdrawn profileId version Withdrawn)
        Expired -> Left (ProfileExpired profileId version expiry)
        Active
          | maybe False (now >=) validUntil -> Left (ProfileExpired profileId version expiry)
          | otherwise -> Right candidate

candidateVersion :: ResolvedProfile -> ProfileVersion
candidateVersion candidate = (resolvedProfileView candidate).ref.version

renderProfileResolutionError :: ProfileResolutionError -> Text
renderProfileResolutionError = \case
  UnknownProfile profileId requestedVersion ->
    "unknown sanctioned execution profile "
      <> profileIdText profileId
      <> maybe "" ((" version " <>) . profileVersionText) requestedVersion
  ProfileExpired profileId version expiry ->
    "sanctioned execution profile "
      <> profileIdText profileId
      <> " version "
      <> profileVersionText version
      <> " expired at "
      <> Text.pack (show expiry)
  ProfileWithdrawn profileId version lifecycle ->
    "sanctioned execution profile "
      <> profileIdText profileId
      <> " version "
      <> profileVersionText version
      <> " is withdrawn ("
      <> Text.pack (show lifecycle)
      <> ")"
  AmbiguousProfile profileId versions ->
    "sanctioned execution profile "
      <> profileIdText profileId
      <> " is ambiguous across versions "
      <> Text.intercalate ", " (profileVersionText <$> versions)
  MutableProfile profileId version claimed computed ->
    "sanctioned execution profile "
      <> profileIdText profileId
      <> " version "
      <> profileVersionText version
      <> " is mutable: claimed "
      <> profileDigestText claimed
      <> ", computed "
      <> profileDigestText computed

findProfilesStatement :: Statement (Text, Maybe Text) [(Text, Text, Value, Text)]
findProfilesStatement =
  preparable
    """
    SELECT profile_id, version, profile_content, profile_digest
      FROM shikigami.sanctioned_execution_profiles
     WHERE profile_id = $1
       AND ($2::text IS NULL OR version = $2)
     ORDER BY version
    """
    ( contrazip2
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nullable Encoders.text))
    )
    ( Decoders.rowList
        ( (,,,)
            <$> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.jsonb)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
        )
    )

decodeProfileRow :: (Text, Text, Value, Text) -> Either ProfileReadFailure ResolvedProfile
decodeProfileRow (storedId, storedVersion, contentValue, storedDigest) = do
  content <- case fromJSON contentValue of
    Success decoded -> Right decoded
    Error _ -> Left metadata
  digest <- first (const metadata) (parseProfileDigest storedDigest)
  unless (content.profileId == ProfileId storedId && content.version == ProfileVersion storedVersion) (Left metadata)
  let computed = profileContentDigest content
  unless (digest == computed) (Left (ProfileReadPolicy (MutableProfile (ProfileId storedId) (ProfileVersion storedVersion) digest computed)))
  pure (resolvedProfileFor content)
  where
    metadata = ProfileReadMetadata (ProfileMetadataUnreadable (ProfileId storedId) (Just (ProfileVersion storedVersion)))

profileIdText :: ProfileId -> Text
profileIdText (ProfileId value) = value

profileVersionText :: ProfileVersion -> Text
profileVersionText (ProfileVersion value) = value

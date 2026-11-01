-- | Fail-closed resolution of sanctioned execution profiles.
--
-- A 'ProfileStore' is a function seam rather than a database handle. Production
-- builds it with 'postgresProfileStore'; tests can supply multiple candidates to
-- exercise ambiguity even though the PostgreSQL table's primary key prevents
-- duplicate @(profile_id, version)@ rows.
module Shikigami.Attestation.Resolve
  ( ProfileResolutionError (..),
    renderProfileResolutionError,
    ResolvedProfile (..),
    ProfileStore (..),
    postgresProfileStore,
    resolveProfile,
  )
where

import Contravariant.Extras (contrazip2)
import Data.Aeson (Result (..), Value)
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shikigami.Attestation.Envelope (profileDigest)
import Shikigami.Attestation.Profile
  ( ProfileDigest,
    ProfileId (..),
    ProfileLifecycle (..),
    ProfileVersion (..),
    SanctionedExecutionProfile (..),
    SanctionedExecutionProfileRef (..),
    parseProfileDigest,
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

-- | Stored content paired with the digest-bearing reference that claims to
-- identify it. The value is trustworthy only after 'resolveProfile' has checked
-- its digest and lifecycle.
data ResolvedProfile = ResolvedProfile
  { profile :: !SanctionedExecutionProfile,
    ref :: !SanctionedExecutionProfileRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The resolution read seam. Returning a list makes the exactly-one invariant
-- visible and testable instead of burying ambiguity in a SQL-specific branch.
newtype ProfileStore = ProfileStore
  { findProfiles :: ProfileId -> Maybe ProfileVersion -> IO [ResolvedProfile]
  }

-- | Read candidates from the Shikigami profile table. A database or JSON decode
-- error is raised as an IO exception so Keiro retries it; it is not mislabeled as
-- one of the five permanent policy refusals.
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
    either (ioError . userError . Text.unpack) pure (traverse decodeProfileRow rows)

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
  candidates <- findProfiles requestedId requestedVersion
  pure case candidates of
    [] -> Left (UnknownProfile requestedId requestedVersion)
    [candidate] -> validateCandidate now candidate
    many -> Left (AmbiguousProfile requestedId (candidateVersion <$> many))

validateCandidate :: UTCTime -> ResolvedProfile -> Either ProfileResolutionError ResolvedProfile
validateCandidate now candidate@ResolvedProfile {profile = content, ref = profileRef} =
  let SanctionedExecutionProfile {lifecycle, validFrom, validUntil} = content
      SanctionedExecutionProfileRef {profileId, version, digest = claimedDigest} = profileRef
      computedDigest = profileDigest content
      expiry = fromMaybe validFrom validUntil
   in if claimedDigest /= computedDigest
        then Left (MutableProfile profileId version claimedDigest computedDigest)
        else case lifecycle of
          Withdrawn -> Left (ProfileWithdrawn profileId version Withdrawn)
          Expired -> Left (ProfileExpired profileId version expiry)
          Active
            | maybe False (now >=) validUntil -> Left (ProfileExpired profileId version expiry)
            | otherwise -> Right candidate

candidateVersion :: ResolvedProfile -> ProfileVersion
candidateVersion ResolvedProfile {ref = SanctionedExecutionProfileRef {version}} = version

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

decodeProfileRow :: (Text, Text, Value, Text) -> Either Text ResolvedProfile
decodeProfileRow (storedId, storedVersion, contentValue, storedDigest) = do
  content <- case fromJSON contentValue of
    Success decoded -> Right decoded
    Error err -> Left ("cannot decode sanctioned execution profile: " <> Text.pack err)
  digest <- parseProfileDigest storedDigest
  pure
    ResolvedProfile
      { profile = content,
        ref =
          SanctionedExecutionProfileRef
            { profileId = ProfileId storedId,
              version = ProfileVersion storedVersion,
              digest
            }
      }

profileIdText :: ProfileId -> Text
profileIdText (ProfileId value) = value

profileVersionText :: ProfileVersion -> Text
profileVersionText (ProfileVersion value) = value

module Shikigami.ProfileResolutionSpec (tests) where

import Contravariant.Extras (contrazip2)
import Control.Lens (view)
import Data.Aeson (Value, toJSON)
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Attestation.Envelope (profileDigest)
import Shikigami.Attestation.Profile
import Shikigami.Attestation.Resolve
import Shikigami.Behavior.Provider.Coordinate qualified as Coordinate
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "profile resolution"
    [ testCase "resolves an active profile to its digest" do
        (withPool databaseFixture) \pool -> do
          let content = sampleProfile Active Nothing (ProfileVersion "1")
              digest = profileDigest content
          insertProfile pool content digest
          resolved <- resolveProfile (postgresProfileStore pool) testNow sampleId (Just (ProfileVersion "1"))
          assertEqual "the stored profile resolves" (Right (resolvedProfile content digest)) resolved,
      testCase "unknown id is refused by id" do
        (withPool databaseFixture) \pool -> do
          resolved <- resolveProfile (postgresProfileStore pool) testNow (ProfileId "missing") Nothing
          assertEqual "unknown profile" (Left (UnknownProfile (ProfileId "missing") Nothing)) resolved,
      testCase "expired profile is refused, naming the expiry" do
        (withPool databaseFixture) \pool -> do
          let expiry = UTCTime (fromGregorian 2026 8 18) 0
              content = sampleProfile Active (Just expiry) (ProfileVersion "1")
              digest = profileDigest content
          insertProfile pool content digest
          resolved <- resolveProfile (postgresProfileStore pool) testNow sampleId Nothing
          assertEqual "expired profile" (Left (ProfileExpired sampleId (ProfileVersion "1") expiry)) resolved,
      testCase "withdrawn profile is refused, naming the lifecycle" do
        (withPool databaseFixture) \pool -> do
          let content = sampleProfile Withdrawn Nothing (ProfileVersion "1")
              digest = profileDigest content
          insertProfile pool content digest
          resolved <- resolveProfile (postgresProfileStore pool) testNow sampleId Nothing
          assertEqual "withdrawn profile" (Left (ProfileWithdrawn sampleId (ProfileVersion "1") Withdrawn)) resolved,
      testCase "tampered content is refused as mutable" do
        (withPool databaseFixture) \pool -> do
          let content = sampleProfile Active Nothing (ProfileVersion "1")
              claimed = profileDigest content
          insertProfile pool content claimed
          tamperProfile pool sampleId (ProfileVersion "1")
          resolved <- resolveProfile (postgresProfileStore pool) testNow sampleId Nothing
          case resolved of
            Left (MutableProfile profileId version claimed' computed) -> do
              assertEqual "profile id" sampleId profileId
              assertEqual "version" (ProfileVersion "1") version
              assertEqual "claimed digest" claimed claimed'
              assertBool "the recomputed digest changed" (computed /= claimed)
            other -> assertFailure ("expected MutableProfile, got " <> show other),
      testCase "ambiguous seam match is refused, listing versions" do
        let firstProfile = sampleProfile Active Nothing (ProfileVersion "1")
            secondProfile = sampleProfile Active Nothing (ProfileVersion "2")
            store =
              ProfileStore \_ _ ->
                pure
                  [ resolvedProfile firstProfile (profileDigest firstProfile),
                    resolvedProfile secondProfile (profileDigest secondProfile)
                  ]
        resolved <- resolveProfile store testNow sampleId Nothing
        assertEqual
          "both matching versions are named"
          (Left (AmbiguousProfile sampleId [ProfileVersion "1", ProfileVersion "2"]))
          resolved
    ]

withPool :: DatabaseFixture -> (Pool -> IO a) -> IO a
withPool databaseFixture use =
  (withShikigamiFreshDatabase databaseFixture) \connectionString ->
    withStore (defaultConnectionSettings connectionString) (use . pool)

testNow :: UTCTime
testNow = UTCTime (fromGregorian 2026 8 19) 0

sampleId :: ProfileId
sampleId = ProfileId "sanctioned-review"

sampleProfile :: ProfileLifecycle -> Maybe UTCTime -> ProfileVersion -> SanctionedExecutionProfile
sampleProfile lifecycle validUntil version =
  SanctionedExecutionProfile
    { profileId = sampleId,
      version,
      issuer = Issuer "shinzui/kikan",
      lifecycle,
      validFrom = UTCTime (fromGregorian 2026 8 1) 0,
      validUntil,
      allowedCalls =
        NonEmpty.singleton
          AllowedCall
            { provider = Coordinate.providerCoordinate ("anthropic"),
              api = Coordinate.providerCoordinate ("messages"),
              endpointClass = Coordinate.providerCoordinate ("https"),
              modelId = Coordinate.providerCoordinate ("claude-sonnet-4-6"),
              thinking = ThinkingHigh
            },
      prohibitions = defaultProhibitions,
      limits = unlimitedProfileLimits,
      minimumEvidenceStrength = EvidenceModelObserved,
      requiredCorrelationFields = ["request-id"],
      signerRequirements = noSignerRequirements
    }

resolvedProfile :: SanctionedExecutionProfile -> ProfileDigest -> ResolvedProfile
resolvedProfile content digest =
  let SanctionedExecutionProfile {profileId, version} = content
   in ResolvedProfile
        { profile = content,
          ref = SanctionedExecutionProfileRef {profileId, version, digest}
        }

insertProfile :: Pool -> SanctionedExecutionProfile -> ProfileDigest -> IO ()
insertProfile pool content claimedDigest = do
  let SanctionedExecutionProfile {profileId, version, issuer, lifecycle, validFrom, validUntil} = content
      params =
        InsertProfile
          { profileId = profileIdText profileId,
            version = profileVersionText version,
            issuer = issuerText issuer,
            lifecycle = lifecycleText lifecycle,
            validFrom = validFrom,
            validUntil = validUntil,
            content = toJSON content,
            digest = profileDigestText claimedDigest
          }
  result <- Pool.use pool (Session.statement params insertProfileStatement)
  either (assertFailure . show) pure result

data InsertProfile = InsertProfile
  { profileId :: !Text,
    version :: !Text,
    issuer :: !Text,
    lifecycle :: !Text,
    validFrom :: !UTCTime,
    validUntil :: !(Maybe UTCTime),
    content :: !Value,
    digest :: !Text
  }
  deriving stock (Generic)

insertProfileStatement :: Statement InsertProfile ()
insertProfileStatement =
  preparable
    """
    INSERT INTO shikigami.sanctioned_execution_profiles
      (profile_id, version, issuer, lifecycle, valid_from, valid_until, profile_content, profile_digest)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    """
    ( (view #profileId >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #version >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #issuer >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #lifecycle >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (view #validFrom >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz))
        <> (view #validUntil >$< Encoders.param (Encoders.nullable Encoders.timestamptz))
        <> (view #content >$< Encoders.param (Encoders.nonNullable Encoders.jsonb))
        <> (view #digest >$< Encoders.param (Encoders.nonNullable Encoders.text))
    )
    Decoders.noResult

tamperProfile :: Pool -> ProfileId -> ProfileVersion -> IO ()
tamperProfile pool profileId version = do
  result <-
    Pool.use
      pool
      ( Session.statement
          (profileIdText profileId, profileVersionText version)
          tamperProfileStatement
      )
  either (assertFailure . show) pure result

tamperProfileStatement :: Statement (Text, Text) ()
tamperProfileStatement =
  preparable
    """
    UPDATE shikigami.sanctioned_execution_profiles
       SET profile_content = jsonb_set(profile_content, '{requiredCorrelationFields}', '["request-id", "tampered"]'::jsonb)
     WHERE profile_id = $1 AND version = $2
    """
    ( contrazip2
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
    )
    Decoders.noResult

profileIdText :: ProfileId -> Text
profileIdText (ProfileId value) = value

profileVersionText :: ProfileVersion -> Text
profileVersionText (ProfileVersion value) = value

profileDigestText :: ProfileDigest -> Text
profileDigestText (ProfileDigest value) = value

issuerText :: Issuer -> Text
issuerText (Issuer value) = value

lifecycleText :: ProfileLifecycle -> Text
lifecycleText = \case
  Active -> "active"
  Expired -> "expired"
  Withdrawn -> "withdrawn"

module Shikigami.ProfileResolutionSpec (tests) where

import Baikai.Evidence (commitmentDigest)
import Contravariant.Extras (contrazip2)
import Control.Exception (IOException, displayException, try)
import Control.Lens (view, (&), (.~))
import Data.Aeson (Value (..), toJSON)
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
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
import Shikigami.Attestation.PolicyValue qualified as PV
import Shikigami.Attestation.Profile
import Shikigami.Attestation.Resolve
import Shikigami.Behavior.Provider.Coordinate qualified as Coordinate
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "profile resolution"
    [ testGroup
        "owning metadata corruption"
        [ testCase name (profileMetadataRefusal databaseFixture lostConstraint mutation)
        | (name, lostConstraint, mutation) <-
            [ ("content name cannot substitute for the relational profile", True, replace "profileId" (String "foreign-profile")),
              ("content version cannot substitute for the relational version", True, replace "version" (String "foreign-version")),
              ("a committed incomplete profile cannot become absence", False, remove "limits"),
              ("a committed negative ceiling cannot become an unlimited policy", False, replace "limits" (Object (KeyMap.singleton "maxCalls" (toJSON (-1 :: Int)))))
            ]
        ],
      testCase "a malformed second profile cannot disappear behind a valid candidate" do
        withPool databaseFixture \pool -> do
          let firstProfile = sampleProfile Active Nothing (ProfileVersion "1")
              secondProfile = sampleProfile Active Nothing (ProfileVersion "2")
              store = postgresProfileStore pool
              snapshots = [resolvedProfileFor firstProfile, resolvedProfileFor secondProfile]
              document = preparable "SELECT jsonb_agg(to_jsonb(p) ORDER BY p.version) FROM shikigami.sanctioned_execution_profiles p" mempty (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.jsonb))) :: Statement () Value
              update = preparable "UPDATE shikigami.sanctioned_execution_profiles SET profile_content=$1,profile_digest=$2 WHERE version='2'" (contrazip2 (Encoders.param (Encoders.nonNullable Encoders.jsonb)) (Encoders.param (Encoders.nonNullable Encoders.text))) Decoders.noResult :: Statement (Value, Text) ()
              run :: Statement params result -> params -> IO result
              run statement value = Pool.use pool (Session.statement value statement) >>= either (fail . show) pure
          insertProfile pool firstProfile (profileDigest firstProfile)
          insertProfile pool secondProfile (profileDigest secondProfile)
          store.findProfiles sampleId Nothing >>= (@?= Right snapshots)
          resolveProfile store testNow sampleId Nothing >>= (@?= Left (AmbiguousProfile sampleId [ProfileVersion "1", ProfileVersion "2"]))
          before <- run document ()
          let malformed = toJSON (secondProfile & #profileId .~ ProfileId "foreign-profile")
          protected <- Pool.use pool (Session.statement (malformed, commitmentDigest malformed) update)
          case protected of
            Left refusal -> assertBool "normal database identity guard remains enforced" ("sanctioned_execution_profiles_content_identity" `Text.isInfixOf` Text.pack (show refusal))
            Right () -> assertFailure "normal database admitted a foreign profile identity"
          run document () >>= (@?= before)
          Pool.use pool (Session.script "ALTER TABLE shikigami.sanctioned_execution_profiles DROP CONSTRAINT sanctioned_execution_profiles_content_identity") >>= either (fail . show) pure
          run update (malformed, commitmentDigest malformed)
          corrupt <- run document ()
          try @ProfileMetadataRefusal (store.findProfiles sampleId Nothing) >>= (@?= Left (ProfileMetadataUnreadable sampleId (Just (ProfileVersion "2"))))
          try @ProfileMetadataRefusal (resolveProfile store testNow sampleId Nothing) >>= (@?= Left (ProfileMetadataUnreadable sampleId (Just (ProfileVersion "2"))))
          run document () >>= (@?= corrupt)
          run update (toJSON secondProfile, profileDigestText (profileDigest secondProfile))
          store.findProfiles sampleId Nothing >>= (@?= Right snapshots)
          run document () >>= (@?= before),
      testCase "lookup coordinates are checked even for internally consistent candidates" do
        let original = sampleProfile Active Nothing (ProfileVersion "1")
            foreignName = original & #profileId .~ ProfileId "foreign-profile"
            otherVersion = original & #version .~ ProfileVersion "2"
            attempt requestedVersion candidates = try @ProfileMetadataRefusal (resolveProfile (ProfileStore (\_ _ -> pure (Right candidates))) testNow sampleId requestedVersion)
        attempt Nothing [resolvedProfileFor foreignName] >>= (@?= Left (ProfileMetadataUnreadable sampleId Nothing))
        attempt (Just (ProfileVersion "1")) [resolvedProfileFor otherVersion] >>= (@?= Left (ProfileMetadataUnreadable sampleId (Just (ProfileVersion "1"))))
        attempt Nothing [resolvedProfileFor original, resolvedProfileFor foreignName] >>= (@?= Left (ProfileMetadataUnreadable sampleId Nothing)),
      testCase "resolves an active profile to its digest" do
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
      testCase "malformed stored commitment refuses and exact repair recovers the original profile" do
        withPool databaseFixture \pool -> do
          let content = sampleProfile Active Nothing (ProfileVersion "1")
              digest = profileDigest content
              store = postgresProfileStore pool
              readProfile = resolveProfile store testNow sampleId Nothing
              document = preparable "SELECT to_jsonb(p) FROM shikigami.sanctioned_execution_profiles p" mempty (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.jsonb))) :: Statement () Value
              setDigest = preparable "UPDATE shikigami.sanctioned_execution_profiles SET profile_digest=$1" (Encoders.param (Encoders.nonNullable Encoders.text)) Decoders.noResult :: Statement Text ()
              run :: Statement params result -> params -> IO result
              run statement value = Pool.use pool (Session.statement value statement) >>= either (fail . show) pure
          insertProfile pool content digest
          readProfile >>= (@?= Right (resolvedProfile content digest))
          before <- run document ()
          run setDigest "sha256:short"
          corrupt <- run document ()
          refused <- try @ProfileMetadataRefusal readProfile
          refused @?= Left (ProfileMetadataUnreadable sampleId (Just (ProfileVersion "1")))
          run document () >>= (@?= corrupt)
          run setDigest (profileDigestText digest)
          readProfile >>= (@?= Right (resolvedProfile content digest))
          run document () >>= (@?= before)
          -- A genuine query failure remains an exception with SQL context,
          -- separate from absent profiles and the explicit decoder diagnostic.
          Pool.use pool (Session.script "ALTER TABLE shikigami.sanctioned_execution_profiles RENAME TO withheld_profile_rows") >>= either (fail . show) pure
          unavailable <- try @IOException readProfile
          case unavailable of
            Left err -> do
              let detail = Text.pack (displayException err)
              assertBool "SQL context retained" ("sanctioned_execution_profiles" `Text.isInfixOf` detail)
              assertBool "query failure is not a decoder failure" (not ("profile digest requires" `Text.isInfixOf` detail))
            Right value -> assertFailure ("SQL failure became a profile result: " <> show value),
      testCase "ambiguous seam match is refused, listing versions" do
        let firstProfile = sampleProfile Active Nothing (ProfileVersion "1")
            secondProfile = sampleProfile Active Nothing (ProfileVersion "2")
            store =
              ProfileStore \_ _ ->
                pure
                  ( Right
                      [ resolvedProfile firstProfile (profileDigest firstProfile),
                        resolvedProfile secondProfile (profileDigest secondProfile)
                      ]
                  )
        resolved <- resolveProfile store testNow sampleId Nothing
        assertEqual
          "both matching versions are named"
          (Left (AmbiguousProfile sampleId [ProfileVersion "1", ProfileVersion "2"]))
          resolved
    ]

replace :: Key -> Value -> Value -> Value
replace key replacement (Object fields) = Object (KeyMap.insert key replacement fields)
replace _ _ _ = error "complete profile was not an object"

remove :: Key -> Value -> Value
remove key (Object fields) = Object (KeyMap.delete key fields)
remove _ _ = error "complete profile was not an object"

profileMetadataRefusal :: DatabaseFixture -> Bool -> (Value -> Value) -> IO ()
profileMetadataRefusal fixture lostConstraint mutation = withPool fixture \pool -> do
  let content = sampleProfile Active Nothing (ProfileVersion "1")
      digest = profileDigest content
      snapshot = resolvedProfileFor content
      readProfile = resolveProfile (postgresProfileStore pool) testNow sampleId Nothing
      document = preparable "SELECT to_jsonb(p) FROM shikigami.sanctioned_execution_profiles p" mempty (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.jsonb))) :: Statement () Value
      update = preparable "UPDATE shikigami.sanctioned_execution_profiles SET profile_content=$1,profile_digest=$2" (contrazip2 (Encoders.param (Encoders.nonNullable Encoders.jsonb)) (Encoders.param (Encoders.nonNullable Encoders.text))) Decoders.noResult :: Statement (Value, Text) ()
      run :: Statement params result -> params -> IO result
      run statement value = Pool.use pool (Session.statement value statement) >>= either (fail . show) pure
  insertProfile pool content digest
  readProfile >>= (@?= Right snapshot)
  before <- run document ()
  let malformed = mutation (toJSON content)
  if lostConstraint
    then do
      protected <- Pool.use pool (Session.statement (malformed, commitmentDigest malformed) update)
      case protected of
        Left refusal -> assertBool "normal database identity guard remains enforced" ("sanctioned_execution_profiles_content_identity" `Text.isInfixOf` Text.pack (show refusal))
        Right () -> assertFailure "normal database admitted a foreign profile identity"
      run document () >>= (@?= before)
      -- Only this disposable example loses its guard, to simulate unreadable
      -- retained metadata independently of the normal SQL write constraint.
      Pool.use pool (Session.script "ALTER TABLE shikigami.sanctioned_execution_profiles DROP CONSTRAINT sanctioned_execution_profiles_content_identity") >>= either (fail . show) pure
    else pure ()
  run update (malformed, commitmentDigest malformed)
  corrupt <- run document ()
  refused <- try @ProfileMetadataRefusal readProfile
  refused @?= Left (ProfileMetadataUnreadable sampleId (Just (ProfileVersion "1")))
  run document () >>= (@?= corrupt)
  run update (toJSON content, profileDigestText digest)
  readProfile >>= (@?= Right snapshot)
  run document () >>= (@?= before)

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
      requiredCorrelationFields = [PV.policyCoordinate "request-id"],
      signerRequirements = noSignerRequirements
    }

resolvedProfile :: SanctionedExecutionProfile -> ProfileDigest -> ResolvedProfile
resolvedProfile content digest =
  let SanctionedExecutionProfile {profileId, version} = content
   in either (error . show) id (parseResolvedProfile content (SanctionedExecutionProfileRef {profileId, version, digest}))

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

issuerText :: Issuer -> Text
issuerText (Issuer value) = value

lifecycleText :: ProfileLifecycle -> Text
lifecycleText = \case
  Active -> "active"
  Expired -> "expired"
  Withdrawn -> "withdrawn"

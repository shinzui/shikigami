{-# LANGUAGE DataKinds #-}

-- | Contract tests for the sanctioned-execution attestation vocabulary.
--
-- These records exist to be written down, hashed, and compared across
-- repositories, so the tests here are about /shape/ rather than behavior: what
-- encodes to which bytes, what survives a round trip, and what the type system
-- refuses to build at all.
--
-- Every expected byte string below is a hand-written literal, following the
-- convention documented at the top of "Shikigami.WireCompatSpec": a fixture
-- produced by calling the current encoder would pass no matter what the encoder
-- did, and would therefore prove nothing.
module Shikigami.AttestationContractsSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Aeson (FromJSON, Result (..), ToJSON, Value (..), encode, fromJSON, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy (ByteString)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Data.Vector qualified as Vector
import Shikigami.Attestation.Agent
  ( AgentArtifactSet (..),
    AgentVersion (..),
    AgentVersionRef (..),
    BehaviorDigest (..),
    DeclarationDigest (..),
    GroundingDigest (..),
    LogicalAgentId (..),
    PolicyDigest (..),
    RuntimeDigest (..),
    SkillsDigest (..),
    ToolCatalogDigest (..),
    declarationOnlyArtifacts,
  )
import Shikigami.Attestation.CallFacts qualified as Facts
import Shikigami.Attestation.Envelope
  ( AgentRunAttestation (..),
    AttestationPayload (..),
    CallEvidenceSet (..),
    CompletenessVerdict (..),
    PayloadDigest,
    SanctionedVerdict (..),
    SchemaVersion,
    attestationPayloadDigest,
    canonicalPayloadBytes,
    currentAttestationSchemaVersion,
    parsePayloadDigest,
    parseSchemaVersion,
    payloadDigestText,
    schemaVersionText,
  )
import Shikigami.Attestation.Envelope qualified as Envelope
import Shikigami.Attestation.Evidence qualified as Evidence
import Shikigami.Attestation.PolicyValue qualified as PV
import Shikigami.Attestation.Profile
  ( AllowedCall (..),
    EvidenceStrength (..),
    Issuer (..),
    ProfileDigest,
    ProfileId (..),
    ProfileLifecycle (..),
    ProfileLimits (..),
    ProfileVersion (..),
    Prohibitions (..),
    SanctionedExecutionProfile (..),
    SanctionedExecutionProfileRef (..),
    SignerRequirements (..),
    ThinkingLevel (..),
    defaultProhibitions,
    noSignerRequirements,
    parseProfileDigest,
    profileContentDigest,
    profileDigestText,
    unlimitedProfileLimits,
  )
import Shikigami.Attestation.Resolve qualified as Snapshot
import Shikigami.Attestation.Reviewed
  ( DiffDigest (..),
    NonConformingReason (..),
    RepositoryId (..),
    ResultDigest (..),
    ReviewedArtifact (..),
    fullCommitText,
    mkFullCommit,
    pullRequestRef,
    reviewPath,
  )
import Shikigami.Attestation.Strength
  ( AttestationStrength (..),
    parseAttestationStrength,
    renderAttestationStrength,
  )
import Shikigami.Behavior.Provider.Coordinate qualified as Coordinate
import Shikigami.Log.Correlation (runCorrelationId)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "attestation contracts"
    [ testCase "complete attestation decoding retains native sessions and refuses foreign identity domains" do
        let complete raw = case toJSON samplePayload of
              Object fields -> Object (KeyMap.insert "sessionId" (String raw) fields)
              value -> value
            valid = "kioku_session_01kvxa7d2cezhs874g3n8dfgme"
        case fromJSON (complete valid) :: Result AttestationPayload of
          Success payload -> toJSON payload @?= complete valid
          Error problem -> assertBool problem False
        mapM_ (\raw -> assertBool "native session domain refused" (case fromJSON (complete raw) :: Result AttestationPayload of Error _ -> True; _ -> False)) ["", "session-1", "kioku_session_00000000008000000000000000", "shikigami_objective_01kvxa7d2cezhs874g3n8dfgme"],
      testCase "signed review labels preserve exact non-normalized bytes without granting path access" do
        encode (reviewPath "src//./module") @?= "\"src//./module\""
        encode (Envelope.merkleCommitment "sha256:merkle") @?= "\"sha256:merkle\""
        encode (pullRequestRef "4173") @?= "\"4173\"",
      testCase "provider evidence scalar roles preserve native encodings and unknown states" do
        encode (Evidence.providerAttempt 0) @?= "0"
        encode (Evidence.providerAttempt 2) @?= "2"
        encode (Facts.measuredTokens 42) @?= "42"
        encode (Facts.measuredMicroUsd (3 / 2)) @?= encode (3 / 2 :: Rational)
        encode Facts.RelationshipKnown @?= "true"
        encode Facts.RelationshipUnknown @?= "false"
        encode Facts.CostKnown @?= "false"
        encode Facts.CostUncertain @?= "true"
        fromJSON (Bool False) @?= Success Facts.RelationshipUnknown
        fromJSON (Bool True) @?= Success Facts.CostUncertain
        assertBool "negative native token count refused" (case fromJSON (Number (-1)) :: Result Facts.MeasuredTokens of Error _ -> True; _ -> False)
        assertBool "closed correlation vocabulary refuses unknown fields" (case fromJSON (String "made-up") :: Result Facts.CorrelationField of Error _ -> True; _ -> False)
        case fromJSON (String "providerrequestid") of
          Success field -> Facts.correlationFieldText field @?= "providerrequestid"
          Error problem -> assertBool problem False,
      profileTests,
      agentTests,
      reviewedTests,
      strengthTests,
      envelopeTests
    ]

-- ---------------------------------------------------------------------------
-- Milestone 1 — the sanctioned execution profile
-- ---------------------------------------------------------------------------

profileTests :: TestTree
profileTests =
  testGroup
    "sanctioned execution profile"
    [ testCase "a checked profile snapshot retains the complete historical JSON shape" do
        let snapshot = Snapshot.resolvedProfileFor fullProfile
            view = Snapshot.resolvedProfileView snapshot
            historical = object ["profile" .= fullProfile, "ref" .= view.ref]
        Snapshot.parseResolvedProfile fullProfile view.ref @?= Right snapshot
        encode snapshot @?= encode historical
        fromJSON historical @?= Success snapshot,
      testCase "snapshot construction and complete decoding refuse a substituted reference" do
        let snapshot = Snapshot.resolvedProfileFor fullProfile
            view = Snapshot.resolvedProfileView snapshot
            other = view.ref & #profileId .~ ProfileId "unrelated-profile"
            copied = view & #ref .~ other
        Snapshot.parseResolvedProfile fullProfile other @?= Left "resolved profile coordinates differ from its reference"
        -- A copied view is an explicit untrusted transfer record. It cannot be
        -- promoted back to a snapshot without checking the binding again.
        fromJSON (toJSON copied) @?= Success copied
        assertBool "copied view does not become authority" (case fromJSON (toJSON copied) :: Result Snapshot.ResolvedProfile of Error _ -> True; Success _ -> False)
        let mutate key raw = case toJSON snapshot of
              Object fields -> case KeyMap.lookup "ref" fields of
                Just (Object reference) -> Object (KeyMap.insert "ref" (Object (KeyMap.insert key (String raw) reference)) fields)
                _ -> error "snapshot lacked its complete reference"
              _ -> error "snapshot was not an object"
        mapM_
          (\(key, raw) -> assertBool "substituted complete snapshot refused" (case fromJSON (mutate key raw) :: Result Snapshot.ResolvedProfile of Error _ -> True; Success _ -> False))
          [("profileId", "unrelated-profile"), ("version", "other-version"), ("digest", "sha256:" <> Text.replicate 64 "0")],
      testCase "historical snapshot decoding does not reapply current lifecycle admission" do
        let content = fullProfile & #lifecycle .~ Withdrawn & #validUntil .~ Just fullProfile.validFrom
            snapshot = Snapshot.resolvedProfileFor content
        roundTrips "historical withdrawn profile snapshot" snapshot,
      testCase "a complete profile reference admits only canonical SHA-256 commitments" do
        roundTrips "complete profile reference" sampleProfileRef
        let computed = profileContentDigest fullProfile
        parseProfileDigest (profileDigestText computed) @?= Right computed
        encode computed @?= encode (profileDigestText computed)
        mapM_
          ( \raw -> do
              assertBool "profile parser refused" (isLeft (parseProfileDigest raw))
              case toJSON sampleProfileRef of
                Object fields -> assertBool "complete reference refused" (case fromJSON (Object (KeyMap.insert "digest" (toJSON raw) fields)) :: Result SanctionedExecutionProfileRef of Error _ -> True; Success _ -> False)
                _ -> error "profile reference was not an object"
          )
          ["", "sha256:short", "SHA256:" <> Text.replicate 64 "a", "sha256:" <> Text.replicate 64 "A", "sha256:" <> Text.replicate 63 "0", "sha256:" <> Text.replicate 65 "0"],
      testCase "complete profiles reject negative quantities at every policy axis" do
        roundTrips "valid complete profile" fullProfile
        let mutate section key value = case toJSON fullProfile of
              Object fields -> case KeyMap.lookup section fields of
                Just (Object nested) -> Object (KeyMap.insert section (Object (KeyMap.insert key value nested)) fields)
                _ -> error "complete profile lacks its section"
              _ -> error "complete profile is not an object"
        mapM_
          (\(section, key) -> assertBool (show key) (case fromJSON (mutate section key (toJSON (-1 :: Int))) :: Result SanctionedExecutionProfile of Error _ -> True; Success _ -> False))
          ([("limits", key) | key <- ["maxCalls", "maxRetries", "maxDelegatedChildRuns", "maxTokens", "maxCostMicroUsd", "maxDurationSeconds", "maxConcurrency"]] <> [("signerRequirements", "retentionDays")])
        mapM_
          (\key -> assertBool "host Int range retained" (case fromJSON (mutate "limits" key (toJSON (toInteger (maxBound :: Int) + 1))) :: Result SanctionedExecutionProfile of Error _ -> True; Success _ -> False))
          ["maxCalls", "maxRetries", "maxDelegatedChildRuns", "maxTokens", "maxDurationSeconds", "maxConcurrency"]
        case fromJSON (mutate "limits" "maxCostMicroUsd" (toJSON (10 ^ (100 :: Int) :: Integer))) :: Result SanctionedExecutionProfile of
          Success decoded -> roundTrips "unbounded integer cost" decoded
          Error err -> error err,
      testCase "zero and unlimited ceilings remain distinct, with the original numeric encoding" do
        let zero = either (error . show) id (PV.mkCeiling (0 :: Int)) :: PV.Ceiling "calls" Int
        assertBool "negative factory input refused" (isLeft (PV.mkCeiling (-1 :: Int) :: Either Text (PV.Ceiling "calls" Int)))
        encode zero @?= "0"
        fromJSON (toJSON zero) @?= Success zero
        assertBool "unlimited remains different" (toJSON (unlimitedProfileLimits & #maxCalls .~ Just zero) /= toJSON unlimitedProfileLimits),
      testCase "documentary policy coordinates preserve arbitrary original bytes" do
        mapM_
          ( \raw -> do
              let coordinate = PV.policyCoordinate raw :: PV.PolicyCoordinate "signature-algorithm"
              PV.policyCoordinateText coordinate @?= raw
              encode coordinate @?= encode raw
              roundTrips "coordinate" coordinate
          )
          ["", "ed25519", "custom/v2", "日本", " key "],
      testCase "a fully populated profile round-trips" do
        roundTrips "profile" fullProfile,
      testCase "a profile reference round-trips" do
        roundTrips "profile ref" sampleProfileRef,
      -- The point of omitNothingFields, asserted on the record that most needs
      -- it. A profile that pins no expiry, sets no ceiling, and constrains no
      -- signer must not carry a spray of explicit nulls: those nulls would be
      -- the difference between the bytes written today and the bytes written
      -- after some later plan adds another optional field.
      testCase "a profile with nothing optional set encodes without a single null" do
        assertEqual
          "minimal profile bytes"
          minimalProfileBytes
          (encode minimalProfile)
        assertBool
          "no null appears anywhere in the encoding"
          (not (hasNull (toJSON minimalProfile))),
      -- Left at its defaults, every prohibition reads False: nothing beyond the
      -- allowed tuples is permitted. This is the fail-closed direction, and it
      -- is worth a test of its own because getting it backwards would be
      -- invisible until a run was wrongly declared sanctioned.
      testCase "defaultProhibitions permits nothing" do
        let Prohibitions
              { aliasesAllowed,
                defaultedThinkingAllowed,
                providerFallbackAllowed,
                modelFallbackAllowed,
                effortClampingAllowed,
                cliTransportsAllowed
              } = defaultProhibitions
        assertBool
          "every prohibition is in force"
          ( not
              ( PV.permissionAllowed aliasesAllowed
                  || PV.permissionAllowed defaultedThinkingAllowed
                  || PV.permissionAllowed providerFallbackAllowed
                  || PV.permissionAllowed modelFallbackAllowed
                  || PV.permissionAllowed effortClampingAllowed
                  || PV.permissionAllowed cliTransportsAllowed
              )
          ),
      -- Resolution has to refuse these three differently, and the refusal
      -- reason lands in an audit record, so they must stay distinguishable
      -- across a round trip rather than collapsing into one another.
      testCase "the three lifecycle states stay distinct across a round trip" do
        assertEqual
          "lifecycle encodings"
          ["\"active\"", "\"expired\"", "\"withdrawn\""]
          (map (encode . toJSON) [Active, Expired, Withdrawn])
        mapM_ (roundTrips "lifecycle") [Active, Expired, Withdrawn]
    ]

-- | A profile that permits nothing cannot be written down. 'allowedCalls' is a
-- 'NonEmpty', so the empty case is a type error rather than a configuration
-- mistake discovered at the end of a review. Uncommenting this fails to compile
-- with @Couldn't match type [] with NonEmpty@:
--
-- > permitsNothing :: SanctionedExecutionProfile
-- > permitsNothing = minimalProfile {allowedCalls = []}
--
-- That is the whole argument for the NonEmpty, kept next to the type it
-- constrains so it is not re-litigated later.
minimalProfile :: SanctionedExecutionProfile
minimalProfile =
  SanctionedExecutionProfile
    { profileId = ProfileId "sanctioned-review",
      version = ProfileVersion "1",
      issuer = Issuer "shinzui/kikan",
      lifecycle = Active,
      validFrom = UTCTime (fromGregorian 2026 8 5) 0,
      validUntil = Nothing,
      allowedCalls = NonEmpty.fromList [sampleAllowedCall],
      prohibitions = defaultProhibitions,
      limits = unlimitedProfileLimits,
      minimumEvidenceStrength = EvidenceModelObserved,
      requiredCorrelationFields = [PV.policyCoordinate "request-id"],
      signerRequirements = noSignerRequirements
    }

-- | The same profile with every optional field populated, so the round-trip
-- test exercises the fields the minimal one omits.
fullProfile :: SanctionedExecutionProfile
fullProfile =
  ( minimalProfile
      & #validUntil .~ (Just (UTCTime (fromGregorian 2027 8 5) 0))
      & #lifecycle .~ (Withdrawn)
      & #limits
        .~ ( ProfileLimits
               { maxCalls = Just (either (error . show) id (PV.mkCeiling 20)),
                 maxRetries = Just (either (error . show) id (PV.mkCeiling 2)),
                 maxDelegatedChildRuns = Just (either (error . show) id (PV.mkCeiling 1)),
                 maxTokens = Just (either (error . show) id (PV.mkCeiling 400000)),
                 maxCostMicroUsd = Just (either (error . show) id (PV.mkCeiling 2500000)),
                 maxDurationSeconds = Just (either (error . show) id (PV.mkCeiling 900)),
                 maxConcurrency = Just (either (error . show) id (PV.mkCeiling 4))
               }
           )
      & #signerRequirements
        .~ ( SignerRequirements
               { requiredIssuer = Just (Issuer "shinzui/shikigami"),
                 allowedKeyIds = [PV.policyCoordinate "key-2026-08"],
                 requiredAlgorithm = Just (PV.policyCoordinate "ed25519"),
                 retentionDays = Just (either (error . show) id (PV.mkCeiling 3650))
               }
           )
  )

sampleAllowedCall :: AllowedCall
sampleAllowedCall =
  AllowedCall
    { provider = Coordinate.providerCoordinate ("anthropic"),
      api = Coordinate.providerCoordinate ("messages"),
      endpointClass = Coordinate.providerCoordinate ("https"),
      modelId = Coordinate.providerCoordinate ("claude-opus-5-20260401"),
      thinking = ThinkingHigh
    }

sampleProfileRef :: SanctionedExecutionProfileRef
sampleProfileRef =
  SanctionedExecutionProfileRef
    { profileId = ProfileId "sanctioned-review",
      version = ProfileVersion "1",
      digest = either (error . show) id (parseProfileDigest "sha256:0000000000000000000000000000000000000000000000000000000000000000")
    }

minimalProfileBytes :: ByteString
minimalProfileBytes =
  "{\"allowedCalls\":[{\"api\":\"messages\",\"endpointClass\":\"https\",\"modelId\":\"claude-opus-5-20260401\",\"provider\":\"anthropic\",\"thinking\":\"ThinkingHigh\"}],\"issuer\":\"shinzui/kikan\",\"lifecycle\":\"active\",\"limits\":{},\"minimumEvidenceStrength\":\"model_observed\",\"profileId\":\"sanctioned-review\",\"prohibitions\":{\"aliasesAllowed\":false,\"cliTransportsAllowed\":false,\"defaultedThinkingAllowed\":false,\"effortClampingAllowed\":false,\"modelFallbackAllowed\":false,\"providerFallbackAllowed\":false},\"requiredCorrelationFields\":[\"request-id\"],\"signerRequirements\":{\"allowedKeyIds\":[]},\"validFrom\":\"2026-08-05T00:00:00Z\",\"version\":\"1\"}"

-- ---------------------------------------------------------------------------
-- Milestone 2 -- agent version and artifact set
-- ---------------------------------------------------------------------------

agentTests :: TestTree
agentTests =
  testGroup
    "agent version and artifacts"
    [ testCase "an agent version ref round-trips" do
        roundTrips "agent version ref" sampleAgentVersionRef,
      testCase "a fully populated artifact set round-trips" do
        roundTrips "full artifact set" fullArtifactSet,
      testCase "a declaration-only artifact set round-trips" do
        roundTrips "sparse artifact set" (declarationOnlyArtifacts (DeclarationDigest "sha256:decl")),
      -- This is the test that protects the governed-evolution follow-up
      -- requested in docs/improvement-requests/governed-agent-evolution.md.
      -- When that work adds a baseline pointer, a candidate relation, and a
      -- rollout state as OPTIONAL fields, these bytes must not move: runs
      -- attested before the change were signed over exactly this encoding, and
      -- a verifier re-deriving a digest over different bytes cannot tell a
      -- schema drift from tampering.
      --
      -- If this fails, do not update the literal. Either a required field was
      -- added, or omitNothingFields was dropped from agentAesonOptions, and
      -- both are wire-format changes that need a schema-version bump and a
      -- migration story.
      testCase "a fully populated agent version ref matches its pinned bytes" do
        assertEqual
          "AgentVersionRef bytes are pinned so lineage fields can be added later"
          pinnedAgentVersionRefBytes
          (encode sampleAgentVersionRef),
      -- The same promise, shown working rather than asserted. An artifact set
      -- whose optional digests are all absent encodes to exactly the object it
      -- would have encoded to before those fields existed -- one key. That is
      -- what omitNothingFields is for, and with every field on AgentVersionRef
      -- currently required, this record is where the mechanism is observable.
      testCase "absent optional digests vanish from the encoding entirely" do
        assertEqual
          "a declaration-only artifact set is a one-key object"
          pinnedDeclarationOnlyBytes
          (encode (declarationOnlyArtifacts (DeclarationDigest "sha256:decl")))
        assertBool
          "no null appears anywhere in the encoding"
          (not (hasNull (toJSON (declarationOnlyArtifacts (DeclarationDigest "sha256:decl"))))),
      -- An absent digest means "this agent has no such part", which is a
      -- different claim from "this part was not measured". Present and absent
      -- must therefore stay distinguishable after a round trip rather than both
      -- decoding to some default.
      testCase "a present digest and an absent one stay distinct" do
        let sparse = declarationOnlyArtifacts (DeclarationDigest "sha256:decl")
            grounded = (sparse & #groundingDigest .~ (Just (GroundingDigest "sha256:ground")))
        assertBool "sparse and grounded differ" (sparse /= grounded)
        roundTrips "grounded artifact set" grounded
    ]

sampleAgentVersionRef :: AgentVersionRef
sampleAgentVersionRef =
  AgentVersionRef
    { logicalAgentId = LogicalAgentId "architecture-reviewer",
      version = AgentVersion "2026-08-05.1",
      declarationDigest = DeclarationDigest "sha256:11111111111111111111111111111111"
    }

fullArtifactSet :: AgentArtifactSet
fullArtifactSet =
  AgentArtifactSet
    { declarationDigest = DeclarationDigest "sha256:decl",
      behaviorDigest = Just (BehaviorDigest "sha256:behavior"),
      skillsDigest = Just (SkillsDigest "sha256:skills"),
      toolCatalogDigest = Just (ToolCatalogDigest "sha256:tools"),
      groundingDigest = Just (GroundingDigest "sha256:ground"),
      runtimeDigest = Just (RuntimeDigest "sha256:runtime"),
      policyDigest = Just (PolicyDigest "sha256:policy")
    }

pinnedAgentVersionRefBytes :: ByteString
pinnedAgentVersionRefBytes =
  "{\"agentVersion\":\"2026-08-05.1\",\"declarationDigest\":\"sha256:11111111111111111111111111111111\",\"logicalAgentId\":\"architecture-reviewer\"}"

pinnedDeclarationOnlyBytes :: ByteString
pinnedDeclarationOnlyBytes =
  "{\"declarationDigest\":\"sha256:decl\"}"

-- ---------------------------------------------------------------------------
-- Milestone 3 -- reviewed artifact, non-conformance, and strength
-- ---------------------------------------------------------------------------

-- | A 64-character SHA-256 commit hash.
baseHash :: Text
baseHash = Text.replicate 64 "a"

headHash :: Text
headHash = Text.replicate 40 "b"

reviewedTests :: TestTree
reviewedTests =
  testGroup
    "reviewed artifact"
    [ -- The rule both upstream documents insist on: a moving reference cannot
      -- identify a review. These cases are what makes it enforcement rather
      -- than documentation.
      testCase "a short hash is rejected" do
        assertLeft "abc123" (mkFullCommit "abc123"),
      testCase "an empty hash is rejected" do
        assertLeft "empty" (mkFullCommit ""),
      testCase "a branch name is rejected" do
        assertLeft "main" (mkFullCommit "main")
        assertLeft "release branch" (mkFullCommit "release/2026-08"),
      testCase "a pull-request number is rejected" do
        assertLeft "PR number" (mkFullCommit "4173"),
      testCase "a 41-character near-miss is rejected" do
        assertLeft "41 chars" (mkFullCommit (Text.replicate 41 "a")),
      testCase "full 40- and 64-character hashes are accepted" do
        assertRight "sha-1 length" (mkFullCommit headHash)
        assertRight "sha-256 length" (mkFullCommit baseHash),
      -- Case is meaningless in a hex digest but not to a byte-level canonical
      -- encoding: two attestations of the same commit differing only in case
      -- would digest differently, and a verifier would report a mismatch it
      -- could not tell from tampering.
      testCase "an uppercase hash normalises to lowercase" do
        case mkFullCommit (Text.toUpper baseHash) of
          Left err -> assertBool ("expected acceptance, got " <> show err) False
          Right commit -> assertEqual "normalised" baseHash (fullCommitText commit),
      -- The constructor is unexported, so the decode path is the other way a
      -- FullCommit could be forged -- and attestations arrive as JSON from
      -- elsewhere, so this is the path that actually matters in production.
      testCase "a short hash in JSON fails to decode rather than becoming a value" do
        case fromJSON @ReviewedArtifact (toJSON shortHeadArtifactJson) of
          Success _ -> assertBool "a short head commit must not decode" False
          Error _ -> pure (),
      testCase "a reviewed artifact round-trips" do
        roundTrips "reviewed artifact" sampleReviewedArtifact,
      -- A pull request is decoration. Setting one changes nothing about the
      -- commits, which is the point: it can never be what a verdict rests on.
      testCase "a pull-request identity does not substitute for the commits" do
        let withPr = (sampleReviewedArtifact & #pullRequest .~ (Just (pullRequestRef "4173")))
        assertEqual "base is unchanged" ((.baseCommit) sampleReviewedArtifact) ((.baseCommit) withPr)
        assertEqual "head is unchanged" ((.headCommit) sampleReviewedArtifact) ((.headCommit) withPr)
        roundTrips "artifact with a pull request" withPr,
      testCase "an absent pull request leaves no null behind" do
        assertBool
          "no null in the encoding"
          (not (hasNull (toJSON sampleReviewedArtifact))),
      -- A roll-up records every reason it found, so every reason has to survive
      -- storage with its specifics intact.
      testCase "every non-conforming reason round-trips with its specifics" do
        mapM_ (roundTrips "reason") everyReason,
      -- A deterministic step is accounted for honestly rather than left as a
      -- gap or filled with a fabricated call, so this marker must never be
      -- confusable with a failure.
      testCase "NotApplicable is distinguishable from every failure reason" do
        let notApplicable = NotApplicable {step = "render-summary"}
            failures = filter (/= notApplicable) everyReason
        -- It must be one of the reasons, and the only one of its kind.
        assertEqual
          "exactly one NotApplicable in the taxonomy"
          1
          (length everyReason - length failures)
        -- Distinctness has to survive encoding, since that is how a consumer
        -- sees it: a completeness annotation must not arrive wearing the same
        -- tag as a failure. Comparing the encoded discriminator is what proves
        -- it, rather than comparing the values we just partitioned by equality.
        assertBool
          "no failure reason encodes under the not_applicable tag"
          (notElem (reasonTag notApplicable) (map reasonTag failures))
        assertEqual "the tag is the snake-cased constructor" (Just "not_applicable") (reasonTag notApplicable)
        assertEqual
          "every reason has a distinct tag from at least the marker"
          (length failures)
          (length (filter (/= Just "not_applicable") (map reasonTag failures)))
    ]

sampleReviewedArtifact :: ReviewedArtifact
sampleReviewedArtifact =
  ReviewedArtifact
    { repository = RepositoryId "mori://shinzui/shikigami",
      baseCommit = either (error . Text.unpack) id (mkFullCommit baseHash),
      headCommit = either (error . Text.unpack) id (mkFullCommit headHash),
      diffDigest = DiffDigest "sha256:diff",
      pathScope = [reviewPath "shikigami-core/src"],
      pullRequest = Nothing
    }

-- | The same object with an abbreviated head commit, as it would arrive on the
-- wire from a party that did not respect the rule.
shortHeadArtifactJson :: Value
shortHeadArtifactJson =
  Object
    ( KeyMap.fromList
        [ ("repository", String "mori://shinzui/shikigami"),
          ("baseCommit", String baseHash),
          ("headCommit", String "bbbbbbb"),
          ("diffDigest", String "sha256:diff"),
          ("pathScope", Array (Vector.fromList [String "shikigami-core/src"]))
        ]
    )

-- | One value of every constructor, each carrying specifics.
everyReason :: [NonConformingReason]
everyReason =
  [ ModelNotPermitted {callId = "call-1", modelId = "claude-sonnet-5"},
    ThinkingTranslationNotPermitted
      { callId = "call-2",
        requestedThinking = "high",
        effectiveThinking = "medium"
      },
    ProhibitedDefaultThinking {callId = "call-3"},
    ProhibitedAlias
      { callId = "call-4",
        alias = "claude-latest",
        resolvedModelId = "claude-opus-5-20260401"
      },
    ProhibitedProviderFallback {callId = "call-5", fromProvider = "anthropic", toProvider = "stub"},
    ProhibitedModelFallback {callId = "call-6", fromModelId = "opus", toModelId = "haiku"},
    ProhibitedEffortClamping {callId = "call-7", requestedThinking = "max", clampedTo = "high"},
    ProhibitedTransport {callId = "call-8", transport = "cli"},
    ProhibitedEndpoint {callId = "call-9", endpointClass = "batch"},
    MissingCallEvidence {callId = "call-10"},
    MissingRetryEvidence {callId = "call-11", attempt = 2},
    MissingContinuationEvidence {callId = "call-12"},
    MissingDelegatedChildEvidence {childRunId = "run-child-1"},
    MissingCorrelationField {callId = "call-13", correlationField = "request-id"},
    ReviewedArtifactMismatch {expectedDigest = "sha256:aaa", actualDigest = "sha256:bbb"},
    ReviewResultDigestMismatch {expectedDigest = "sha256:ccc", actualDigest = "sha256:ddd"},
    EvidenceBelowRequiredStrength
      { callId = "call-14",
        requiredStrength = EvidenceFullyObserved,
        observedStrength = EvidenceRequestedOnly
      },
    LimitExceeded {limitName = "maxCalls", limitValue = "20", observedValue = "21"},
    NotApplicable {step = "render-summary"}
  ]

strengthTests :: TestTree
strengthTests =
  testGroup
    "attestation strength"
    [ -- The ordering is the semantics, so it gets a test of its own. It exists
      -- to CHECK a minimum -- ask observed >= required -- and never to promote a
      -- weaker claim to a stronger one.
      testCase "the four tiers ascend in kikan IR-6's order" do
        assertBool
          "declared < runtime-observed < runtime-attested < provider-attested"
          (Declared < RuntimeObserved && RuntimeObserved < RuntimeAttested && RuntimeAttested < ProviderAttested),
      -- Checking a minimum is the only sanctioned use, shown working.
      testCase "a declaration-only record does not satisfy a runtime-attested policy" do
        assertBool "declared is insufficient" (not (Declared >= RuntimeAttested))
        assertBool "runtime-observed is insufficient" (not (RuntimeObserved >= RuntimeAttested))
        assertBool "runtime-attested suffices" (RuntimeAttested >= RuntimeAttested)
        assertBool "provider-attested suffices" (ProviderAttested >= RuntimeAttested),
      -- These exact strings are published in kikan IR-6 and read by verifiers
      -- elsewhere, so they are the shared contract rather than a local style
      -- choice -- note the hyphens, which eventAesonOptions would not produce.
      testCase "the wire spelling is kikan's hyphenated vocabulary" do
        assertEqual
          "canonical spellings"
          ["declared", "runtime-observed", "runtime-attested", "provider-attested"]
          (map renderAttestationStrength [Declared, RuntimeObserved, RuntimeAttested, ProviderAttested])
        assertEqual
          "encoded"
          ["\"declared\"", "\"runtime-observed\"", "\"runtime-attested\"", "\"provider-attested\""]
          (map (encode . toJSON) [Declared, RuntimeObserved, RuntimeAttested, ProviderAttested]),
      testCase "every tier round-trips" do
        mapM_ (roundTrips "strength") [Declared, RuntimeObserved, RuntimeAttested, ProviderAttested],
      -- IR-6 invariant 7: an unknown strength fails closed. Defaulting an
      -- unrecognised name to Declared would be a silent demotion, just as wrong
      -- as a promotion.
      testCase "an unknown strength is rejected rather than defaulted" do
        assertLeft "unknown name" (parseAttestationStrength "mostly-observed")
        assertLeft "underscored spelling" (parseAttestationStrength "runtime_observed")
        case fromJSON @AttestationStrength (String "mostly-observed") of
          Success _ -> assertBool "an unknown strength must not decode" False
          Error _ -> pure ()
    ]

-- ---------------------------------------------------------------------------
-- Milestone 4 -- the attestation envelope and its canonical encoding
-- ---------------------------------------------------------------------------

envelopeTests :: TestTree
envelopeTests =
  testGroup
    "attestation envelope"
    [ testCase "an attestation payload round-trips" do
        roundTrips "payload" samplePayload,
      testCase "a full attestation round-trips" do
        roundTrips "attestation" sampleAttestation,
      -- IR-6 invariant 7 requires an unknown schema to fail closed, which is
      -- impossible if the version can be absent. A verifier can only refuse
      -- what it can see.
      testCase "the schema version is required, not optional" do
        withoutVersion <- case toJSON samplePayload of
          Object fields -> pure (Object (KeyMap.delete "schemaVersion" fields))
          other -> fail ("a payload must encode to an object, got " <> show other)
        case fromJSON @AttestationPayload withoutVersion of
          Success _ -> assertBool "a payload without a schema version must not decode" False
          Error _ -> pure ()
        assertEqual
          "the current version names its producer"
          "shikigami.agent-run-attestation/1"
          (schemaVersionText currentAttestationSchemaVersion),
      -- Canonical means one logical value has exactly one byte encoding.
      testCase "a complete payload refuses unsupported schema versions" do
        roundTrips "valid complete payload" samplePayload
        parseSchemaVersion (schemaVersionText currentAttestationSchemaVersion) @?= Right currentAttestationSchemaVersion
        mapM_
          ( \raw -> do
              assertBool "unknown version parser refused" (isLeft (parseSchemaVersion raw))
              case toJSON samplePayload of
                Object fields -> assertBool "unknown complete payload refused" (case fromJSON (Object (KeyMap.insert "schemaVersion" (toJSON raw) fields)) :: Result AttestationPayload of Error _ -> True; Success _ -> False)
                _ -> error "payload was not an object"
          )
          ["", "shikigami.agent-run-attestation/2", "other.agent-run-attestation/1"],
      testCase "a complete envelope refuses malformed payload commitments" do
        roundTrips "valid complete envelope" sampleAttestation
        let computed = attestationPayloadDigest samplePayload
        parsePayloadDigest (payloadDigestText computed) @?= Right computed
        encode computed @?= encode (payloadDigestText computed)
        mapM_
          ( \raw -> do
              assertBool "payload parser refused" (isLeft (parsePayloadDigest raw))
              case toJSON sampleAttestation of
                Object fields -> assertBool "complete envelope refused" (case fromJSON (Object (KeyMap.insert "payloadDigest" (toJSON raw) fields)) :: Result AgentRunAttestation of Error _ -> True; Success _ -> False)
                _ -> error "envelope was not an object"
          )
          ["", "sha256:short", "SHA256:" <> Text.replicate 64 "a", "sha256:" <> Text.replicate 64 "A", "sha256:" <> Text.replicate 63 "0", "sha256:" <> Text.replicate 65 "0"],
      testCase "canonical bytes are stable across repeated calls" do
        assertEqual
          "same payload, same bytes"
          (canonicalPayloadBytes samplePayload)
          (canonicalPayloadBytes samplePayload),
      -- The property that makes a cross-repository digest possible at all:
      -- object keys come out sorted, so two encoders agree without having to
      -- agree about field declaration order.
      testCase "canonical bytes sort object keys" do
        let bytes = canonicalPayloadBytes samplePayload
        assertBool
          "schemaVersion sorts after runId"
          (indexOf "\"runId\"" bytes < indexOf "\"schemaVersion\"" bytes)
        assertBool
          "agentArtifacts sorts first among the top-level keys"
          (indexOf "\"agentArtifacts\"" bytes < indexOf "\"agentVersion\"" bytes)
        assertBool
          "no insignificant whitespace"
          (not (ByteString.isInfixOf "\", \"" bytes)),
      -- The conformance test. kikan IR-6's "Conformance fixtures" section
      -- promises golden payloads that Baikai, Shikigami, and Kotei all consume,
      -- but IR-6 is still in the proposed state and publishes none: as of
      -- 2026-08-19, AgentRunAttestation appears nowhere in the kikan repository
      -- except in the request document itself.
      --
      -- So this fixture is OURS, and the conformance claim is one-sided. It
      -- proves this repository's encoding has not drifted; it does not prove
      -- agreement with anybody. When kikan publishes its golden payload, replace
      -- this literal with kikan's bytes -- a difference at that point is the
      -- test doing its job, and tells you exactly which field moved.
      testCase "canonical payload bytes match the pinned fixture" do
        assertEqual
          "canonical payload bytes (one-sided: kikan has published no golden payload)"
          pinnedCanonicalPayload
          (canonicalPayloadBytes samplePayload),
      -- Pinned as a literal for the same reason the canonical bytes are: a
      -- digest recomputed inside the test would agree with the implementation
      -- no matter what the implementation did. Together these two literals pin
      -- the whole relationship -- these exact bytes hash to this exact digest.
      testCase "the payload digest matches its pinned value" do
        assertEqual
          "payload digest"
          pinnedPayloadDigest
          (attestationPayloadDigest samplePayload),
      -- A signature covers a payload and cannot cover itself. The split types
      -- make hashing the signature inexpressible; this checks the consequence.
      testCase "the digest ignores the signature and key" do
        let signed = (sampleAttestation & #signature .~ (Just (Envelope.attestationSignature "sig")) & #keyId .~ (Just (PV.policyCoordinate "key-1")))
        assertEqual
          "signing does not change the payload digest"
          (attestationPayloadDigest ((.payload) sampleAttestation))
          (attestationPayloadDigest ((.payload) signed)),
      -- Changing any covered field must change the digest, or the binding is
      -- worthless.
      testCase "changing a covered field changes the digest" do
        let tampered = (samplePayload & #reviewClass .~ Envelope.reviewClass "something-else")
        assertBool
          "a different payload digests differently"
          (attestationPayloadDigest samplePayload /= attestationPayloadDigest tampered),
      testCase "every verdict shape round-trips" do
        mapM_ (roundTrips "completeness") [EvidenceComplete, EvidenceIncomplete {missing = [MissingCallEvidence {callId = "call-1"}]}]
        mapM_
          (roundTrips "sanctioned verdict")
          [ Sanctioned,
            NonConforming {reasons = [ProhibitedDefaultThinking {callId = "call-1"}]},
            Indeterminate {reasons = [MissingCallEvidence {callId = "call-2"}]}
          ]
        mapM_ (roundTrips "evidence set") [CallEvidenceMerkleRoot {merkleRoot = Envelope.merkleCommitment "sha256:merkle"}, CallEvidenceRecords {records = []}]
    ]

samplePayload :: AttestationPayload
samplePayload =
  AttestationPayload
    { schemaVersion = currentAttestationSchemaVersion,
      issuer = Issuer "shinzui/shikigami",
      issuedAt = UTCTime (fromGregorian 2026 8 5) 0,
      expiresAt = Nothing,
      runId = runCorrelationId "run-1",
      sessionId = Nothing,
      reviewClass = Envelope.reviewClass "architecture-practice",
      profile = sampleProfileRef,
      reviewed = sampleReviewedArtifact,
      agentVersion = sampleAgentVersionRef,
      agentArtifacts = declarationOnlyArtifacts (DeclarationDigest "sha256:decl"),
      callEvidence = CallEvidenceMerkleRoot {merkleRoot = Envelope.merkleCommitment "sha256:merkle"},
      reviewResultDigest = ResultDigest "sha256:result",
      completeness = EvidenceComplete,
      sanctioned = Sanctioned,
      strength = RuntimeAttested
    }

sampleAttestation :: AgentRunAttestation
sampleAttestation =
  AgentRunAttestation
    { payload = samplePayload,
      payloadDigest = attestationPayloadDigest samplePayload,
      signature = Nothing,
      keyId = Nothing
    }

pinnedCanonicalPayload :: ByteString.ByteString
pinnedCanonicalPayload =
  "{\"agentArtifacts\":{\"declarationDigest\":\"sha256:decl\"},\"agentVersion\":{\"agentVersion\":\"2026-08-05.1\",\"declarationDigest\":\"sha256:11111111111111111111111111111111\",\"logicalAgentId\":\"architecture-reviewer\"},\"callEvidence\":{\"merkleRoot\":\"sha256:merkle\",\"type\":\"call_evidence_merkle_root\"},\"completeness\":{\"type\":\"evidence_complete\"},\"issuedAt\":\"2026-08-05T00:00:00Z\",\"issuer\":\"shinzui/shikigami\",\"profile\":{\"digest\":\"sha256:0000000000000000000000000000000000000000000000000000000000000000\",\"profileId\":\"sanctioned-review\",\"version\":\"1\"},\"reviewClass\":\"architecture-practice\",\"reviewResultDigest\":\"sha256:result\",\"reviewed\":{\"baseCommit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"diffDigest\":\"sha256:diff\",\"headCommit\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"pathScope\":[\"shikigami-core/src\"],\"repository\":\"mori://shinzui/shikigami\"},\"runId\":\"run-1\",\"sanctioned\":{\"type\":\"sanctioned\"},\"schemaVersion\":\"shikigami.agent-run-attestation/1\",\"strength\":\"runtime-attested\"}"

pinnedPayloadDigest :: PayloadDigest
pinnedPayloadDigest = either (error . show) id (parsePayloadDigest "sha256:3a00e20cdb4d53408be548e6ccaaf613ef6f07e446167b1547fbfbde31dec02e")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Encode, decode, and assert the value survived intact.
roundTrips :: (Eq a, Show a, ToJSON a, FromJSON a) => String -> a -> IO ()
roundTrips label value =
  case fromJSON (toJSON value) of
    Error err -> assertBool (label <> " failed to decode: " <> err) False
    Success decoded -> assertEqual (label <> " round-trips") value decoded

-- | Byte offset of a needle, or -1.
indexOf :: ByteString.ByteString -> ByteString.ByteString -> Int
indexOf needle haystack =
  case ByteString.breakSubstring needle haystack of
    (before, rest)
      | ByteString.null rest -> -1
      | otherwise -> ByteString.length before

-- | The @type@ discriminator a reason encodes under.
reasonTag :: NonConformingReason -> Maybe Text
reasonTag reason = case toJSON reason of
  Object o -> case KeyMap.lookup "type" o of
    Just (String tag) -> Just tag
    _ -> Nothing
  _ -> Nothing

-- | Assert a validating constructor refused its input.
assertLeft :: (Show a) => String -> Either e a -> IO ()
assertLeft label = \case
  Left _ -> pure ()
  Right ok -> assertBool (label <> " should have been rejected, got " <> show ok) False

-- | Assert a validating constructor accepted its input.
assertRight :: (Show e) => String -> Either e a -> IO ()
assertRight label = \case
  Right _ -> pure ()
  Left err -> assertBool (label <> " should have been accepted, got " <> show err) False

-- | Does a 'Null' appear anywhere in this value, at any depth?
hasNull :: Value -> Bool
hasNull = \case
  Null -> True
  Object o -> any hasNull (KeyMap.elems o)
  Array xs -> any hasNull (Vector.toList xs)
  _ -> False

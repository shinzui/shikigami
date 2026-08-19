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

import Data.Aeson (FromJSON, Result (..), ToJSON, Value (..), encode, fromJSON, toJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy (ByteString)
import Data.List.NonEmpty qualified as NonEmpty
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
import Shikigami.Attestation.Profile
  ( AllowedCall (..),
    EvidenceStrength (..),
    Issuer (..),
    ProfileDigest (..),
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
    unlimitedProfileLimits,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "attestation contracts"
    [ profileTests,
      agentTests
    ]

-- ---------------------------------------------------------------------------
-- Milestone 1 — the sanctioned execution profile
-- ---------------------------------------------------------------------------

profileTests :: TestTree
profileTests =
  testGroup
    "sanctioned execution profile"
    [ testCase "a fully populated profile round-trips" do
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
              ( aliasesAllowed
                  || defaultedThinkingAllowed
                  || providerFallbackAllowed
                  || modelFallbackAllowed
                  || effortClampingAllowed
                  || cliTransportsAllowed
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
      requiredCorrelationFields = ["request-id"],
      signerRequirements = noSignerRequirements
    }

-- | The same profile with every optional field populated, so the round-trip
-- test exercises the fields the minimal one omits.
fullProfile :: SanctionedExecutionProfile
fullProfile =
  minimalProfile
    { validUntil = Just (UTCTime (fromGregorian 2027 8 5) 0),
      lifecycle = Withdrawn,
      limits =
        ProfileLimits
          { maxCalls = Just 20,
            maxRetries = Just 2,
            maxDelegatedChildRuns = Just 1,
            maxTokens = Just 400000,
            maxCostMicroUsd = Just 2500000,
            maxDurationSeconds = Just 900,
            maxConcurrency = Just 4
          },
      signerRequirements =
        SignerRequirements
          { requiredIssuer = Just (Issuer "shinzui/shikigami"),
            allowedKeyIds = ["key-2026-08"],
            requiredAlgorithm = Just "ed25519",
            retentionDays = Just 3650
          }
    }

sampleAllowedCall :: AllowedCall
sampleAllowedCall =
  AllowedCall
    { provider = "anthropic",
      api = "messages",
      endpointClass = "https",
      modelId = "claude-opus-5-20260401",
      thinking = ThinkingHigh
    }

sampleProfileRef :: SanctionedExecutionProfileRef
sampleProfileRef =
  SanctionedExecutionProfileRef
    { profileId = ProfileId "sanctioned-review",
      version = ProfileVersion "1",
      digest = ProfileDigest "sha256:0000000000000000000000000000000000000000000000000000000000000000"
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
            grounded = sparse {groundingDigest = Just (GroundingDigest "sha256:ground")}
        assertBool "sparse and grounded differ" (sparse /= grounded)
        roundTrips "grounded artifact set" grounded
    ]

sampleAgentVersionRef :: AgentVersionRef
sampleAgentVersionRef =
  AgentVersionRef
    { logicalAgentId = LogicalAgentId "architecture-reviewer",
      agentVersion = AgentVersion "2026-08-05.1",
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
-- Helpers
-- ---------------------------------------------------------------------------

-- | Encode, decode, and assert the value survived intact.
roundTrips :: (Eq a, Show a, ToJSON a, FromJSON a) => String -> a -> IO ()
roundTrips label value =
  case fromJSON (toJSON value) of
    Error err -> assertBool (label <> " failed to decode: " <> err) False
    Success decoded -> assertEqual (label <> " round-trips") value decoded

-- | Does a 'Null' appear anywhere in this value, at any depth?
hasNull :: Value -> Bool
hasNull = \case
  Null -> True
  Object o -> any hasNull (KeyMap.elems o)
  Array xs -> any hasNull (Vector.toList xs)
  _ -> False

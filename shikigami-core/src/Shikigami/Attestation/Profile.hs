{-# LANGUAGE DataKinds #-}

-- | The sanctioned execution profile: the immutable, versioned policy that says
-- how a run is allowed to execute.
--
-- A profile is resolved /before/ a behavior executes, and the run stays pinned
-- to the resolved digest for its whole life, so what a run was permitted to do
-- cannot be edited after the fact. Resolving and pinning belong to
-- @docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md@; this module
-- only says what a profile /is/.
--
-- Two vocabularies here are imported rather than declared, and the reason is the
-- same in both cases: the comparison that matters happens against values that
-- arrive from @baikai@, and a second local scale would have to be translated at
-- exactly that point.
--
-- * 'ThinkingLevel' is baikai's provider-neutral reasoning-effort scale. A
--   profile permits thinking levels; the evidence that comes back from a call
--   reports the level that was requested as this same type.
--
-- * 'EvidenceStrength' is baikai's /per-call/ observation-completeness scale
--   (@requested_only@ through @fully_observed@) — how much the provider
--   corroborated about one call. It is __not__ the four-tier trust vocabulary
--   kikan IR-6 defines (@declared@, @runtime-observed@, @runtime-attested@,
--   @provider-attested@); that is a different scale that answers a different
--   question, and it lives in @Shikigami.Attestation.Strength@ as
--   @AttestationStrength@. Do not conflate them.
module Shikigami.Attestation.Profile
  ( -- * Identity
    ProfileId (..),
    ProfileVersion (..),
    ProfileDigest,
    parseProfileDigest,
    profileDigestText,
    profileContentDigest,
    Issuer (..),

    -- * Lifecycle
    ProfileLifecycle (..),

    -- * What a run may do
    AllowedCall (..),
    Prohibitions (..),
    defaultProhibitions,
    ProfileLimits (..),
    unlimitedProfileLimits,
    SignerRequirements (..),
    noSignerRequirements,

    -- * The profile, and the reference that points at it
    SanctionedExecutionProfile (..),
    SanctionedExecutionProfileRef (..),

    -- * Encoding
    profileAesonOptions,

    -- * Re-exported policy vocabulary
    ThinkingLevel (..),
    EvidenceStrength (..),
  )
where

import Baikai.Evidence (EvidenceStrength (..), commitmentDigest)
import Baikai.ThinkingLevel (ThinkingLevel (..))
import Data.Aeson (withText)
import Data.Text qualified as Text
import Dhall (FromDhall (..))
import Dhall qualified
import Shikigami.Attestation.PolicyValue
import Shikigami.Behavior.Provider.Coordinate
import Shikigami.Prelude

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- | The stable name of a policy, constant across its versions.
newtype ProfileId = ProfileId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | An immutable revision of a policy. A profile is never edited in place; a
-- change produces a new version with a new digest.
newtype ProfileVersion = ProfileVersion {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

instance FromDhall ProfileId where autoWith _ = ProfileId <$> Dhall.strictText

instance FromDhall ProfileVersion where autoWith _ = ProfileVersion <$> Dhall.strictText

-- | The digest of a profile's canonical content.
--
-- 'Shikigami.Attestation.Envelope.profileDigest' computes it with the same
-- canonical SHA-256 seam as attestation payloads. Resolution and pinning added
-- that computation in
-- @docs/plans/50-fail-closed-profile-resolution-and-run-pinning.md@; signing
-- still belongs to plan 52.
newtype ProfileDigest = ProfileDigest Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parseProfileDigest :: Text -> Either Text ProfileDigest
parseProfileDigest raw
  | Text.length raw == 71 && "sha256:" `Text.isPrefixOf` raw && Text.all hex (Text.drop 7 raw) = Right (ProfileDigest raw)
  | otherwise = Left "profile digest requires sha256 and 64 lowercase hexadecimal digits"
  where
    hex character = (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')

profileDigestText :: ProfileDigest -> Text
profileDigestText (ProfileDigest raw) = raw

instance FromJSON ProfileDigest where
  parseJSON = withText "profile digest" (either (fail . Text.unpack) pure . parseProfileDigest)

-- | The original canonical content commitment. This owns construction so the
-- opaque representation does not depend on the envelope importing its constructor.
profileContentDigest :: SanctionedExecutionProfile -> ProfileDigest
profileContentDigest = ProfileDigest . commitmentDigest . toJSON

-- | Who issued a profile. A verifier checks this against its trusted issuers;
-- kikan IR-6 invariant 7 requires an unknown issuer to fail closed.
newtype Issuer = Issuer {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- | Where a profile is in its life.
--
-- These three are distinguished rather than collapsed into a boolean because
-- resolution has to refuse them differently: a 'Withdrawn' profile was revoked
-- and its refusal reason is not the same audit fact as one that merely
-- 'Expired', and neither is the same as a profile nobody has heard of. The
-- refusal reason ends up in an audit record, so the distinction has to survive.
data ProfileLifecycle = Active | Expired | Withdrawn
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON ProfileLifecycle where toJSON = genericToJSON eventAesonOptions

instance FromJSON ProfileLifecycle where parseJSON = genericParseJSON eventAesonOptions

-- ---------------------------------------------------------------------------
-- What a run may do
-- ---------------------------------------------------------------------------

-- | One permitted way to make a model call.
--
-- The whole tuple is permitted at once, deliberately. Permitting a set of models
-- and a set of thinking levels independently would silently permit every
-- combination of the two, including combinations nobody sanctioned — a policy
-- that allows model @X@ at @minimal@ and model @Y@ at @max@ must not thereby
-- allow @X@ at @max@. kikan IR-6 states the same rule: policy applies to allowed
-- tuples, not to independent allow-lists.
data AllowedCall = AllowedCall
  { -- | The service that runs the model, e.g. @anthropic@.
    provider :: !(ProviderCoordinate "provider-name"),
    -- | The API family reached, e.g. @messages@.
    api :: !(ProviderCoordinate "provider-api"),
    -- | How the provider is reached — an HTTP endpoint class or a command-line
    -- transport. Recorded separately from 'api' because a profile may permit an
    -- API over HTTP while prohibiting the same API over a CLI transport.
    endpointClass :: !(ProviderCoordinate "endpoint-class"),
    -- | An exact model identifier. Never an alias: an alias can be repointed
    -- after the profile was resolved, which is one of UC-8's reject cases.
    modelId :: !(ProviderCoordinate "provider-model-id"),
    -- | The canonical reasoning effort this tuple permits.
    thinking :: !ThinkingLevel
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON AllowedCall where toJSON = genericToJSON profileAesonOptions

instance FromJSON AllowedCall where parseJSON = genericParseJSON profileAesonOptions

-- | The things a run may not do, stated explicitly.
--
-- Every field is a question a verifier asks, and every one defaults to
-- __disallowed__ in 'defaultProhibitions'. That direction is the point: the
-- request this module serves is specific that an omitted SDK default is not
-- evidence of compliance, so a hand-written profile that forgets a field must
-- fail closed rather than open. Read 'Permitted' (encoded as @true@) as "this profile went out of its
-- way to permit this".
data Prohibitions = Prohibitions
  { -- | May a call name a model by a mutable alias instead of an exact id?
    aliasesAllowed :: !(Permission "aliasesAllowed"),
    -- | May a call leave the thinking level unset and take the SDK default?
    defaultedThinkingAllowed :: !(Permission "defaultedThinkingAllowed"),
    -- | May the runtime complete a call against a different provider?
    providerFallbackAllowed :: !(Permission "providerFallbackAllowed"),
    -- | May the runtime complete a call against a different model?
    modelFallbackAllowed :: !(Permission "modelFallbackAllowed"),
    -- | May a provider clamp the requested effort down to one it supports?
    effortClampingAllowed :: !(Permission "effortClampingAllowed"),
    -- | May a call be made over a command-line transport rather than an API?
    cliTransportsAllowed :: !(Permission "cliTransportsAllowed")
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Prohibitions where toJSON = genericToJSON profileAesonOptions

instance FromJSON Prohibitions where parseJSON = genericParseJSON profileAesonOptions

-- | Every prohibition in force: nothing beyond the allowed tuples is permitted.
--
-- Build a profile from this and relax individual fields, rather than assembling
-- a 'Prohibitions' field by field — that way a field added later is prohibited
-- in existing code until someone decides otherwise.
defaultProhibitions :: Prohibitions
defaultProhibitions =
  Prohibitions
    { aliasesAllowed = Prohibited,
      defaultedThinkingAllowed = Prohibited,
      providerFallbackAllowed = Prohibited,
      modelFallbackAllowed = Prohibited,
      effortClampingAllowed = Prohibited,
      cliTransportsAllowed = Prohibited
    }

-- | Ceilings on what a run may consume.
--
-- Every field is a 'Maybe', and __absent means no ceiling__ — a deliberate
-- "unlimited", never a zero. A zero is a real limit that forbids everything; if
-- you mean that, use a zero ceiling.
data ProfileLimits = ProfileLimits
  { maxCalls :: !(Maybe (Ceiling "calls" Int)),
    maxRetries :: !(Maybe (Ceiling "retries" Int)),
    maxDelegatedChildRuns :: !(Maybe (Ceiling "delegated-child-runs" Int)),
    maxTokens :: !(Maybe (Ceiling "tokens" Int)),
    -- | A cost ceiling in millionths of a US dollar.
    --
    -- Integer micro-dollars rather than a fractional type on purpose: this
    -- record is covered by a digest that a different repository — possibly in a
    -- different language — has to reproduce byte for byte, and a decimal
    -- fraction is the classic way for two such encoders to disagree.
    maxCostMicroUsd :: !(Maybe (Ceiling "cost-micro-usd" Integer)),
    maxDurationSeconds :: !(Maybe (Ceiling "duration-seconds" Int)),
    maxConcurrency :: !(Maybe (Ceiling "concurrency" Int))
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ProfileLimits where toJSON = genericToJSON profileAesonOptions

instance FromJSON ProfileLimits where parseJSON = genericParseJSON profileAesonOptions

-- | No ceiling on anything. Note the contrast with 'defaultProhibitions': limits
-- default to permissive because an unset ceiling is a normal thing to mean,
-- while an unset prohibition is not.
unlimitedProfileLimits :: ProfileLimits
unlimitedProfileLimits =
  ProfileLimits
    { maxCalls = Nothing,
      maxRetries = Nothing,
      maxDelegatedChildRuns = Nothing,
      maxTokens = Nothing,
      maxCostMicroUsd = Nothing,
      maxDurationSeconds = Nothing,
      maxConcurrency = Nothing
    }

-- | What the eventual attestation's signature and retention must satisfy.
data SignerRequirements = SignerRequirements
  { -- | The issuer the attestation must be signed by, when the profile pins one.
    requiredIssuer :: !(Maybe Issuer),
    -- | Key identifiers the signature may use. Empty means the profile does not
    -- constrain the key beyond 'requiredIssuer'.
    allowedKeyIds :: ![PolicyCoordinate "signing-key-id"],
    -- | The signature algorithm the attestation must use, when pinned.
    requiredAlgorithm :: !(Maybe (PolicyCoordinate "signature-algorithm")),
    -- | How long the attestation must remain retrievable, in days.
    retentionDays :: !(Maybe (Ceiling "retention-days" Int))
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SignerRequirements where toJSON = genericToJSON profileAesonOptions

instance FromJSON SignerRequirements where parseJSON = genericParseJSON profileAesonOptions

-- | A profile that constrains neither signer nor retention.
noSignerRequirements :: SignerRequirements
noSignerRequirements =
  SignerRequirements
    { requiredIssuer = Nothing,
      allowedKeyIds = [],
      requiredAlgorithm = Nothing,
      retentionDays = Nothing
    }

-- ---------------------------------------------------------------------------
-- The profile
-- ---------------------------------------------------------------------------

-- | An immutable, versioned policy: everything a run is permitted to do, and
-- everything it is not.
--
-- Note what is /absent/: the profile carries no digest of itself. A digest is
-- taken over content, so it cannot be part of the content it covers. The digest
-- lives on 'SanctionedExecutionProfileRef' instead.
data SanctionedExecutionProfile = SanctionedExecutionProfile
  { profileId :: !ProfileId,
    version :: !ProfileVersion,
    issuer :: !Issuer,
    lifecycle :: !ProfileLifecycle,
    validFrom :: !UTCTime,
    -- | Absent means the profile does not expire on its own. It can still be
    -- 'Withdrawn'.
    validUntil :: !(Maybe UTCTime),
    -- | At least one permitted tuple, always.
    --
    -- 'NonEmpty' rather than a list is load-bearing. A profile permitting
    -- nothing would make every run non-conforming, which is a configuration
    -- mistake that should be impossible to write down rather than something
    -- discovered at the end of a review.
    allowedCalls :: !(NonEmpty AllowedCall),
    prohibitions :: !Prohibitions,
    limits :: !ProfileLimits,
    -- | The floor a single call's evidence must reach. This is baikai's per-call
    -- scale — see the module header on why it is not kikan's four trust tiers.
    minimumEvidenceStrength :: !EvidenceStrength,
    -- | Provider correlation fields that must be present on every call's
    -- evidence, e.g. @request-id@. A call missing one of these is
    -- non-conforming even if everything else about it was permitted.
    requiredCorrelationFields :: ![PolicyCoordinate "correlation-field"],
    signerRequirements :: !SignerRequirements
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SanctionedExecutionProfile where toJSON = genericToJSON profileAesonOptions

instance FromJSON SanctionedExecutionProfile where parseJSON = genericParseJSON profileAesonOptions

-- | A pointer to an exact profile revision, by digest.
--
-- This is what a run pins and what an attestation carries: the name kikan IR-6
-- uses, and the smallest thing that unambiguously identifies which policy a run
-- was held to. A verifier that holds the profile itself can re-derive the digest
-- and check it matches.
data SanctionedExecutionProfileRef = SanctionedExecutionProfileRef
  { profileId :: !ProfileId,
    version :: !ProfileVersion,
    digest :: !ProfileDigest
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SanctionedExecutionProfileRef where toJSON = genericToJSON profileAesonOptions

instance FromJSON SanctionedExecutionProfileRef where parseJSON = genericParseJSON profileAesonOptions

-- ---------------------------------------------------------------------------
-- Encoding
-- ---------------------------------------------------------------------------

-- | The one Aeson options value every record in this module uses.
--
-- @omitNothingFields@ is on so that a record which resolved nothing optional
-- encodes to the same bytes it would have before that optional field existed.
-- That is what lets a later plan add a field without rewriting history, and it
-- is why there is a single options function here rather than one per instance:
-- one place to change, and no way for two records to drift apart.
profileAesonOptions :: Options
profileAesonOptions = defaultOptions {omitNothingFields = True}

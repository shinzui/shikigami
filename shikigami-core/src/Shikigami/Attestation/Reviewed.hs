-- | What code was reviewed, and the specific ways a run can fail to conform.
--
-- The load-bearing idea here is that a reviewed artifact must be identified by
-- something that cannot move. Both upstream documents are emphatic about it:
-- kikan IR-6 says "branch names or pull-request numbers alone are insufficient",
-- and UC-8 lists "the pull request head changed" as a reject case. A gate that
-- accepted a branch name would attest to whatever that branch points at when
-- someone later asks, which is not the thing anybody reviewed.
--
-- That rule is enforced by the type rather than by convention: 'FullCommit' has
-- no exported data constructor, so the only ways to obtain one are
-- 'mkFullCommit' and the 'FromJSON' instance, and both run the same validation.
module Shikigami.Attestation.Reviewed
  ( -- * Repository vocabulary
    RepositoryId (..),
    Revision,
    mkRevision,
    revisionText,
    DiffDigest (..),
    ResultDigest (..),

    -- * Commits that cannot move
    FullCommit,
    mkFullCommit,
    fullCommitText,

    -- * The reviewed artifact
    ReviewedArtifact (..),

    -- * Non-conformance
    NonConformingReason (..),

    -- * Encoding
    reviewedAesonOptions,

    -- * Re-exported evidence vocabulary
    EvidenceStrength (..),
  )
where

import Baikai.Evidence (EvidenceStrength (..))
import Data.Aeson (Value (String), withText)
import Data.Char (isHexDigit)
import Data.Text qualified as Text
import Shikigami.Prelude
import Shikigami.Repository (RepositoryId (..), Revision, mkRevision, revisionText)

-- ---------------------------------------------------------------------------
-- Repository vocabulary
-- ---------------------------------------------------------------------------

-- 'RepositoryId' and the strict Mori content-plane 'Revision' now live in
-- "Shikigami.Repository". They remain re-exported here so code written against
-- the temporary plan-49 home keeps compiling while review and evidence code use
-- the neutral shared module directly.

-- | Digest of the reviewed diff, or of the reviewed tree.
newtype DiffDigest = DiffDigest {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Digest of the review result the agent produced.
--
-- Bound into the attestation so that a verdict cannot be edited after signing;
-- a mismatch is 'ReviewResultDigestMismatch'.
newtype ResultDigest = ResultDigest {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- ---------------------------------------------------------------------------
-- Commits that cannot move
-- ---------------------------------------------------------------------------

-- | A full-length commit hash: the only thing this module accepts as an
-- identifier of reviewed code.
--
-- The data constructor is not exported. Build one with 'mkFullCommit', read one
-- with 'fullCommitText'. That is not ceremony — it is the enforcement point for
-- the rule that a moving reference cannot identify a review, and it has to hold
-- on the decode path too, because attestations arrive as JSON from elsewhere.
-- The 'FromJSON' instance therefore runs the same validation rather than
-- wrapping the text unchecked; a short hash in a payload is a decode failure,
-- not a value.
newtype FullCommit = FullCommit {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)

-- | The hash, lowercase.
fullCommitText :: FullCommit -> Text
fullCommitText FullCommit {value} = value

-- | Accept a full-length hexadecimal commit hash; reject everything else.
--
-- Accepts 40 characters (SHA-1) and 64 (SHA-256), since git is mid-migration
-- between them. Anything shorter is an abbreviation — abbreviations are
-- ambiguous by construction and get more ambiguous as a repository grows.
-- Anything non-hexadecimal is a branch, a tag, or a mistake.
--
-- The hash is lowercased on the way in. Case is not meaningful in a hex digest,
-- but it /is/ meaningful to a byte-level canonical encoding: two attestations of
-- the very same commit whose hashes differed only in case would produce
-- different payload digests, which a verifier would report as a mismatch it
-- could not distinguish from tampering. Normalising here means that cannot
-- happen.
mkFullCommit :: Text -> Either Text FullCommit
mkFullCommit raw
  | not (Text.all isHexDigit raw) =
      Left ("commit hash is not hexadecimal: " <> raw)
  | Text.length raw `notElem` [40, 64] =
      Left
        ( "commit hash must be a full 40- or 64-character hash, got "
            <> Text.pack (show (Text.length raw))
            <> " characters: "
            <> raw
        )
  | otherwise = Right (FullCommit (Text.toLower raw))

instance ToJSON FullCommit where
  toJSON FullCommit {value} = String value

instance FromJSON FullCommit where
  parseJSON = withText "FullCommit" (either (fail . Text.unpack) pure . mkFullCommit)

-- ---------------------------------------------------------------------------
-- The reviewed artifact
-- ---------------------------------------------------------------------------

-- | Exactly which code a review covered.
data ReviewedArtifact = ReviewedArtifact
  { repository :: !RepositoryId,
    -- | The commit the change is measured from.
    baseCommit :: !FullCommit,
    -- | The commit that was reviewed.
    headCommit :: !FullCommit,
    diffDigest :: !DiffDigest,
    -- | The paths the review covered. Empty means the whole tree.
    pathScope :: ![Text],
    -- | __Decoration, never load-bearing.__ A pull-request number is useful for
    -- a human following a link back to a discussion, and worthless for
    -- verification: it can be force-pushed, retargeted, or reopened against
    -- different code. Nothing about a verdict may depend on this field. It is
    -- 'Maybe' because a review need not have a pull request at all, and because
    -- its absence must not change the bytes of the surrounding record.
    pullRequest :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ReviewedArtifact where toJSON = genericToJSON reviewedAesonOptions

instance FromJSON ReviewedArtifact where parseJSON = genericParseJSON reviewedAesonOptions

-- ---------------------------------------------------------------------------
-- Non-conformance
-- ---------------------------------------------------------------------------

-- | One specific way a run failed to conform to its profile.
--
-- The taxonomy is deliberately generous rather than clever. A roll-up that
-- records every reason it found is worth far more than one that reduces partial
-- evidence to a boolean: the request this serves is explicit that the roll-up
-- "records every non-conforming reason rather than reducing partial evidence to
-- a Boolean", and an operator reading an audit record needs to know /which/
-- call, /which/ model, and /what/ was expected.
--
-- Each constructor therefore carries its specifics. Where a reason concerns one
-- model call it carries that call's id, so a verdict on a multi-call run points
-- at the call that broke it rather than at the run as a whole.
data NonConformingReason
  = -- | A call used a model no allowed tuple permits.
    ModelNotPermitted {callId :: !Text, modelId :: !Text}
  | -- | The provider's translation of the requested thinking level is not one
    -- any allowed tuple permits.
    ThinkingTranslationNotPermitted
      { callId :: !Text,
        requestedThinking :: !Text,
        effectiveThinking :: !Text
      }
  | -- | Thinking was left unset and the SDK default applied, which the profile
    -- prohibits. An omitted default is not evidence of compliance.
    ProhibitedDefaultThinking {callId :: !Text}
  | -- | A mutable alias named the model, or an alias resolved differently than
    -- it did when the profile was resolved.
    ProhibitedAlias {callId :: !Text, alias :: !Text, resolvedModelId :: !Text}
  | ProhibitedProviderFallback {callId :: !Text, fromProvider :: !Text, toProvider :: !Text}
  | ProhibitedModelFallback {callId :: !Text, fromModelId :: !Text, toModelId :: !Text}
  | ProhibitedEffortClamping {callId :: !Text, requestedThinking :: !Text, clampedTo :: !Text}
  | ProhibitedTransport {callId :: !Text, transport :: !Text}
  | ProhibitedEndpoint {callId :: !Text, endpointClass :: !Text}
  | -- | A call the run is known to have made has no evidence record.
    MissingCallEvidence {callId :: !Text}
  | -- | A retry attempt is missing from the evidence set.
    MissingRetryEvidence {callId :: !Text, attempt :: !Int}
  | -- | A continuation of a multi-turn call is missing.
    MissingContinuationEvidence {callId :: !Text}
  | -- | A delegated child run is terminal but contributed no evidence.
    MissingDelegatedChildEvidence {childRunId :: !Text}
  | -- | A correlation field the profile requires is absent from a call's
    -- evidence, so the call cannot be located in the provider's own records.
    MissingCorrelationField {callId :: !Text, correlationField :: !Text}
  | -- | The reviewed code no longer matches the digests the run was bound to.
    ReviewedArtifactMismatch {expectedDigest :: !Text, actualDigest :: !Text}
  | -- | The stored review result does not match the result digest in the
    -- evidence set.
    ReviewResultDigestMismatch {expectedDigest :: !Text, actualDigest :: !Text}
  | -- | A call's evidence is weaker than the profile's floor. Note both values
    -- are on baikai's per-call scale, not
    -- 'Shikigami.Attestation.Strength.AttestationStrength'.
    EvidenceBelowRequiredStrength
      { callId :: !Text,
        requiredStrength :: !EvidenceStrength,
        observedStrength :: !EvidenceStrength
      }
  | -- | A ceiling in the profile's limits was exceeded.
    LimitExceeded {limitName :: !Text, limitValue :: !Text, observedValue :: !Text}
  | -- | A step made no model call, and that is correct rather than missing.
    --
    -- This marker exists so a deterministic step can be accounted for honestly.
    -- The alternative — leaving a gap in the evidence set — is indistinguishable
    -- from a call whose evidence was lost, and the alternative to /that/ is
    -- fabricating a model call that never happened. Both are worse. A run
    -- carrying this reason is not thereby non-conforming; it is a completeness
    -- annotation, and consumers must treat it as distinct from every failure
    -- above.
    NotApplicable {step :: !Text}
  deriving stock (Eq, Show, Generic)

instance ToJSON NonConformingReason where toJSON = genericToJSON eventAesonOptions

instance FromJSON NonConformingReason where parseJSON = genericParseJSON eventAesonOptions

-- ---------------------------------------------------------------------------
-- Encoding
-- ---------------------------------------------------------------------------

-- | The Aeson options the records in this module use. Sums here use
-- 'eventAesonOptions' instead, matching the rest of the repository.
reviewedAesonOptions :: Options
reviewedAesonOptions = defaultOptions {omitNothingFields = True}

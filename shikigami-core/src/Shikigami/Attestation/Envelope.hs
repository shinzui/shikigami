-- | The signed document, and exactly what gets hashed.
--
-- The separation between 'AttestationPayload' and 'AgentRunAttestation' is the
-- point of this module and is not cosmetic. A signature covers a payload; it
-- cannot cover itself. Keeping both in one flat record makes it easy to hash the
-- signature field along with everything else, and very hard to notice — the
-- resulting digests look perfectly normal and simply never verify anywhere else.
-- Splitting the types means the mistake cannot be expressed:
-- 'canonicalPayloadBytes' takes a payload, and a payload has no signature field.
module Shikigami.Attestation.Envelope
  ( -- * Schema identity
    SchemaVersion,
    parseSchemaVersion,
    schemaVersionText,
    currentAttestationSchemaVersion,

    -- * Digest
    PayloadDigest,
    parsePayloadDigest,
    payloadDigestText,

    -- * Verdicts
    CallEvidenceSet (..),
    CompletenessVerdict (..),
    SanctionedVerdict (..),

    -- * The documents
    AttestationPayload (..),
    AgentRunAttestation (..),

    -- * Canonical encoding
    canonicalPayloadBytes,
    attestationPayloadDigest,
    profileDigest,

    -- * Encoding
    envelopeAesonOptions,
  )
where

import Baikai.Evidence (canonicalEncode, commitmentDigest)
import Data.Aeson (Value, withText)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Shikigami.Attestation.Agent (AgentArtifactSet, AgentVersionRef)
import Shikigami.Attestation.Profile (Issuer, ProfileDigest, SanctionedExecutionProfile, SanctionedExecutionProfileRef, profileContentDigest)
import Shikigami.Attestation.Reviewed (NonConformingReason, ResultDigest, ReviewedArtifact)
import Shikigami.Attestation.Strength (AttestationStrength)
import Shikigami.Prelude

-- ---------------------------------------------------------------------------
-- Schema identity
-- ---------------------------------------------------------------------------

-- | Which version of the attestation contract a document speaks.
data SchemaVersion = AttestationV1
  deriving stock (Eq, Ord, Show)

parseSchemaVersion :: Text -> Either Text SchemaVersion
parseSchemaVersion "shikigami.agent-run-attestation/1" = Right AttestationV1
parseSchemaVersion _ = Left "unsupported attestation schema version"

schemaVersionText :: SchemaVersion -> Text
schemaVersionText AttestationV1 = "shikigami.agent-run-attestation/1"

instance ToJSON SchemaVersion where
  toJSON = toJSON . schemaVersionText
  toEncoding = toEncoding . schemaVersionText

instance FromJSON SchemaVersion where
  parseJSON = withText "attestation schema version" (either (fail . Text.unpack) pure . parseSchemaVersion)

-- | The schema version this build produces.
--
-- The field on 'AttestationPayload' is __required__, not optional, and that is a
-- deliberate constraint rather than an oversight. kikan IR-6 invariant 7 says an
-- unknown schema must fail closed; a verifier can only refuse what it can see,
-- and an absent version is indistinguishable from version one to anybody
-- reading a stored document later.
--
-- The string names the producer as well as the number so that a document found
-- out of context still says what it is.
currentAttestationSchemaVersion :: SchemaVersion
currentAttestationSchemaVersion = AttestationV1

-- ---------------------------------------------------------------------------
-- Digest
-- ---------------------------------------------------------------------------

-- | A digest over a payload's canonical bytes, self-describing as
-- @sha256:\<hex\>@.
newtype PayloadDigest = PayloadDigest Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

parsePayloadDigest :: Text -> Either Text PayloadDigest
parsePayloadDigest raw
  | Text.length raw == 71 && "sha256:" `Text.isPrefixOf` raw && Text.all hex (Text.drop 7 raw) = Right (PayloadDigest raw)
  | otherwise = Left "attestation payload digest requires sha256 and 64 lowercase hexadecimal digits"
  where
    hex character = (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')

payloadDigestText :: PayloadDigest -> Text
payloadDigestText (PayloadDigest raw) = raw

instance FromJSON PayloadDigest where
  parseJSON = withText "attestation payload digest" (either (fail . Text.unpack) pure . parsePayloadDigest)

-- ---------------------------------------------------------------------------
-- Verdicts
-- ---------------------------------------------------------------------------

-- | The complete call evidence, or a commitment to it.
--
-- kikan IR-6 allows either the ordered complete set or a Merkle root over it,
-- because a run with many calls should not be forced to inline all of them into
-- a signed document.
--
-- The records are held as already-encoded JSON rather than as baikai's
-- 'Baikai.Evidence.ModelCallEvidence'. That is a consequence of what baikai
-- publishes: @ModelCallEvidence@ derives 'ToJSON' but __not__ 'FromJSON', so a
-- payload typed in terms of it could be written and never read back, and an
-- attestation that cannot be decoded is useless to the verifier it exists for.
-- Holding the encoded records also preserves them exactly as the producer
-- emitted them, which is what the payload digest covers anyway. Collecting and
-- ordering them belongs to
-- @docs\/plans\/51-run-evidence-aggregate-and-compliance-roll-up.md@.
data CallEvidenceSet
  = -- | Every terminal call, in order, complete.
    CallEvidenceRecords {records :: ![Value]}
  | -- | A Merkle root over the ordered set, held elsewhere.
    CallEvidenceMerkleRoot {merkleRoot :: !Text}
  deriving stock (Eq, Show, Generic)

instance ToJSON CallEvidenceSet where toJSON = genericToJSON eventAesonOptions

instance FromJSON CallEvidenceSet where parseJSON = genericParseJSON eventAesonOptions

-- | Whether every call the run made is accounted for.
--
-- Separate from 'SanctionedVerdict' because the two failures are different
-- facts: a run whose every recorded call was permitted but whose retry evidence
-- is missing is not a compliant run, and it is also not a run that broke policy.
-- Collapsing them would let missing evidence read as approval.
data CompletenessVerdict
  = EvidenceComplete
  | EvidenceIncomplete {missing :: ![NonConformingReason]}
  deriving stock (Eq, Show, Generic)

instance ToJSON CompletenessVerdict where toJSON = genericToJSON eventAesonOptions

instance FromJSON CompletenessVerdict where parseJSON = genericParseJSON eventAesonOptions

-- | Whether the run stayed inside its profile.
--
-- 'Indeterminate' is a required third state rather than a shade of failure.
-- kikan IR-6 is explicit that unknown effective values produce an indeterminate
-- verdict and not a sanctioned one, and UC-8 lists evidence below the required
-- strength as indeterminate. A verifier rejects both 'NonConforming' and
-- 'Indeterminate', but an operator needs to tell "this run broke the rules" from
-- "we cannot tell what this run did", because only the second is fixed by
-- collecting better evidence.
--
-- Both carry every reason found, never a count or a boolean: the request this
-- serves says the roll-up "records every non-conforming reason rather than
-- reducing partial evidence to a Boolean".
data SanctionedVerdict
  = Sanctioned
  | NonConforming {reasons :: ![NonConformingReason]}
  | Indeterminate {reasons :: ![NonConformingReason]}
  deriving stock (Eq, Show, Generic)

instance ToJSON SanctionedVerdict where toJSON = genericToJSON eventAesonOptions

instance FromJSON SanctionedVerdict where parseJSON = genericParseJSON eventAesonOptions

-- ---------------------------------------------------------------------------
-- The documents
-- ---------------------------------------------------------------------------

-- | Everything the signature covers.
--
-- One document binding the policy, the code, the agent, the evidence, and the
-- result, so that a verifier checking one signature has checked all of them
-- together. kikan IR-6 invariant 4 requires exactly that: result, code,
-- behavior, evidence roll-up, and policy under one signature or one verifiable
-- chain. Anything reachable only through a separate unsigned lookup could be
-- swapped after the fact.
data AttestationPayload = AttestationPayload
  { schemaVersion :: !SchemaVersion,
    issuer :: !Issuer,
    issuedAt :: !UTCTime,
    -- | Absent means the attestation does not expire on its own.
    expiresAt :: !(Maybe UTCTime),
    runId :: !Text,
    sessionId :: !(Maybe Text),
    -- | What kind of review this was, e.g. @architecture-practice@. A gate uses
    -- it to check the attestation answers the question it asked.
    reviewClass :: !Text,
    profile :: !SanctionedExecutionProfileRef,
    reviewed :: !ReviewedArtifact,
    agentVersion :: !AgentVersionRef,
    agentArtifacts :: !AgentArtifactSet,
    callEvidence :: !CallEvidenceSet,
    reviewResultDigest :: !ResultDigest,
    completeness :: !CompletenessVerdict,
    sanctioned :: !SanctionedVerdict,
    -- | What this document's claim rests on. kikan IR-6's four trust tiers, not
    -- baikai's per-call observation scale — see
    -- "Shikigami.Attestation.Strength".
    strength :: !AttestationStrength
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON AttestationPayload where toJSON = genericToJSON envelopeAesonOptions

instance FromJSON AttestationPayload where parseJSON = genericParseJSON envelopeAesonOptions

-- | The payload, its digest, and the signature over it.
--
-- 'signature' and 'keyId' are 'Maybe' because nothing signs yet.
-- @docs\/plans\/52-signed-attestation-read-api-and-uc-8-conformance.md@ owns
-- signing, and owns making a /served/ attestation always carry both — an
-- unsigned document is a work-in-progress record, never something a gate may
-- accept.
data AgentRunAttestation = AgentRunAttestation
  { payload :: !AttestationPayload,
    payloadDigest :: !PayloadDigest,
    signature :: !(Maybe Text),
    keyId :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON AgentRunAttestation where toJSON = genericToJSON envelopeAesonOptions

instance FromJSON AgentRunAttestation where parseJSON = genericParseJSON envelopeAesonOptions

-- ---------------------------------------------------------------------------
-- Canonical encoding
-- ---------------------------------------------------------------------------

-- | The exact bytes a payload's digest is taken over.
--
-- __This function's output is a wire format.__ Changing it changes every digest
-- this repository has ever produced, which means every stored attestation stops
-- verifying at once. It needs a 'SchemaVersion' bump and a migration story, not
-- an edit.
--
-- /Canonical/ means one logical value has exactly one byte encoding, so two
-- parties hashing the same payload get the same digest. That is why this is a
-- named function rather than 'Data.Aeson.encode': aeson makes no promise about
-- object key order across versions, and this digest has to match one computed by
-- a different repository, possibly in a different language.
--
-- The encoder itself is @baikai@'s 'canonicalEncode', deliberately borrowed
-- rather than rewritten. It sorts keys, emits no insignificant whitespace,
-- normalises numbers so @1@, @1.0@, and @1e0@ agree, and hand-writes its string
-- escaper precisely so that an aeson upgrade cannot silently change a recorded
-- digest. A fresh implementation would plausibly miss two of those and discover
-- it as a cross-repository mismatch, which is the one failure this whole design
-- exists to prevent.
--
-- What stays this repository's own is /which fields the payload contains and in
-- what shape/ — that is the part kikan IR-6 ratifies, and the reason this is a
-- named function of ours at all. The encoder is borrowed; the payload definition
-- is not.
canonicalPayloadBytes :: AttestationPayload -> ByteString
canonicalPayloadBytes = canonicalEncode . toJSON

-- | The digest of a payload's canonical bytes, as @sha256:\<hex\>@.
--
-- This is @sha256@ over exactly what 'canonicalPayloadBytes' returns — the two
-- cannot drift, because this is implemented as baikai's 'commitmentDigest' over
-- the same 'toJSON' value, and that function is itself defined as a hash of
-- 'canonicalEncode'.
--
-- The plan that introduced this module intended to defer the computation, on the
-- grounds that hashing would need a new dependency. It does not: baikai 0.5 is
-- already a direct dependency and exports this. A stub returning a placeholder
-- would have been worse than either alternative, since a caller downstream could
-- store it as though it were a real digest.
--
-- __Signing is still not done here.__
-- @docs\/plans\/52-signed-attestation-read-api-and-uc-8-conformance.md@ owns the
-- signature over this digest and the key that produces it.
attestationPayloadDigest :: AttestationPayload -> PayloadDigest
attestationPayloadDigest = PayloadDigest . commitmentDigest . toJSON

-- | SHA-256 over the sanctioned profile's canonical JSON content.
--
-- A profile reference is deliberately not part of this input: its digest points
-- at the content and therefore cannot be one of the fields being hashed. This
-- uses the same canonical encoder as 'attestationPayloadDigest', so profile and
-- attestation commitments cannot drift onto subtly different JSON rules.
profileDigest :: SanctionedExecutionProfile -> ProfileDigest
profileDigest = profileContentDigest

-- ---------------------------------------------------------------------------
-- Encoding
-- ---------------------------------------------------------------------------

-- | The Aeson options the records in this module use. Sums use
-- 'eventAesonOptions'.
envelopeAesonOptions :: Options
envelopeAesonOptions = defaultOptions {omitNothingFields = True}

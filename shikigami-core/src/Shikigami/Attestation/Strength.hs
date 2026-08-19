-- | How much a claim actually proves — the four trust tiers kikan IR-6 defines.
--
-- __This is not the same scale as @baikai@'s 'Baikai.Evidence.EvidenceStrength',__
-- despite both being ascending strength orderings, and the two must never be
-- translated into one another. They answer different questions:
--
-- * baikai's grades /how completely the provider corroborated one call/:
--   @requested_only@, @correlated@, @model_observed@, @fully_observed@. Every
--   value it can produce is a runtime observation of some completeness.
--
-- * this one grades /who vouches for the claim/: configuration, the runtime's
--   own records, a runtime signature over a complete roll-up, or the provider
--   itself.
--
-- The whole of baikai's scale sits inside this one's 'RuntimeObserved' tier.
-- baikai cannot emit 'RuntimeAttested' — it does not sign Shikigami run
-- attestations — and it cannot emit 'Declared', since it only speaks about calls
-- that happened. Collapsing the two would make kikan IR-6 acceptance criterion 6
-- unstatable: "a declaration-only record cannot satisfy a runtime-attested
-- policy" needs both tiers to exist in one type.
module Shikigami.Attestation.Strength
  ( AttestationStrength (..),
    renderAttestationStrength,
    parseAttestationStrength,
  )
where

import Data.Aeson (Value (String), withText)
import Shikigami.Prelude

-- | The tier of trust behind a claim, ascending.
--
-- __The 'Ord' instance exists to check a minimum, and for nothing else.__ Ask
-- @observed >= required@ and refuse when it does not hold. Never use it the
-- other way — a verifier must not treat a weaker claim as satisfying a stronger
-- requirement, and must not "round up" a claim because everything else about a
-- run looked fine. kikan IR-6 states the rule directly: verifiers must not
-- silently promote one level to another. An unknown or unreadable strength is an
-- indeterminate verdict, never a passing one.
--
-- __Do not reorder the constructors.__ The ordering is the semantics.
data AttestationStrength
  = -- | Configuration names a model or thinking level; execution was not
    -- observed. The weakest thing anyone can say.
    Declared
  | -- | Trusted runtime code records the request it sent and the response
    -- metadata it received. This is the tier every @baikai@ evidence record
    -- lands in, whatever its own finer-grained strength says.
    RuntimeObserved
  | -- | A trusted runtime signs a digest-bound, complete roll-up of its runtime
    -- observations. This is what this initiative's first delivery targets.
    RuntimeAttested
  | -- | The provider, or a separately trusted execution boundary, signs the
    -- execution facts. No provider supplies this today; the tier exists so that
    -- when one does, the vocabulary does not have to change underneath records
    -- already written.
    ProviderAttested
  deriving stock (Eq, Ord, Show, Generic)

-- | The canonical wire spelling, hyphenated.
--
-- Hyphens rather than the underscores 'Shikigami.Prelude.eventAesonOptions'
-- would produce: these exact strings are published in kikan IR-6's
-- evidence-strength table and are read by verifiers in other repositories, so
-- the spelling is the shared contract's, not this repository's house style.
renderAttestationStrength :: AttestationStrength -> Text
renderAttestationStrength = \case
  Declared -> "declared"
  RuntimeObserved -> "runtime-observed"
  RuntimeAttested -> "runtime-attested"
  ProviderAttested -> "provider-attested"

-- | Read a strength back from its canonical spelling.
--
-- Anything else is rejected rather than defaulted. kikan IR-6 invariant 7
-- requires an unknown strength to fail closed, and defaulting an unrecognised
-- name to 'Declared' would be a silent demotion just as wrong as a promotion.
parseAttestationStrength :: Text -> Either Text AttestationStrength
parseAttestationStrength = \case
  "declared" -> Right Declared
  "runtime-observed" -> Right RuntimeObserved
  "runtime-attested" -> Right RuntimeAttested
  "provider-attested" -> Right ProviderAttested
  other -> Left ("unknown attestation strength: " <> other)

instance ToJSON AttestationStrength where
  toJSON = String . renderAttestationStrength

instance FromJSON AttestationStrength where
  parseJSON =
    withText "AttestationStrength" (either (fail . show) pure . parseAttestationStrength)

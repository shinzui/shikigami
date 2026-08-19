-- | Which agent ran, at which exact version, made of which exact parts.
--
-- Two records with different owners. 'AgentVersionRef' is this repository's own
-- notion of agent identity — the thing a run pins so that "the reviewer agent"
-- means one immutable revision rather than whatever is deployed now.
-- 'AgentArtifactSet' is the portable digest bundle kikan IR-6 names, which
-- travels in an attestation and is checked by a verifier that has never seen
-- this repository.
module Shikigami.Attestation.Agent
  ( -- * Identity
    LogicalAgentId (..),
    AgentVersion (..),

    -- * Digests
    DeclarationDigest (..),
    BehaviorDigest (..),
    SkillsDigest (..),
    ToolCatalogDigest (..),
    GroundingDigest (..),
    RuntimeDigest (..),
    PolicyDigest (..),

    -- * The records
    AgentVersionRef (..),
    AgentArtifactSet (..),
    declarationOnlyArtifacts,

    -- * Encoding
    agentAesonOptions,
  )
where

import Shikigami.Prelude

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- | The stable name of an agent, constant across its versions.
--
-- For a manifest under @agents/@ this is its declared @name@ — see
-- @Shikigami.Agent.Decl@.
newtype LogicalAgentId = LogicalAgentId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | An immutable version of one agent. Never reused, never edited in place.
newtype AgentVersion = AgentVersion {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- ---------------------------------------------------------------------------
-- Digests
-- ---------------------------------------------------------------------------

-- Each part of an agent gets its own digest type rather than sharing one alias.
-- A declaration digest is not interchangeable with a tool-catalog digest, and
-- having the compiler catch a swapped pair is worth more than the brevity of a
-- single 'Digest' newtype -- these values are all opaque hex strings, so a swap
-- is invisible to review and produces a verifier failure far from its cause.

-- | Digest of the agent's declaration (the Dhall manifest under @agents/@).
newtype DeclarationDigest = DeclarationDigest {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Digest of the executable behavior, or of a serialized Shikumi program.
newtype BehaviorDigest = BehaviorDigest {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Digest of the skills or instructions supplied to the behavior.
newtype SkillsDigest = SkillsDigest {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Digest of the catalog of tools the agent was permitted to call.
newtype ToolCatalogDigest = ToolCatalogDigest {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Digest of the grounding bundle the run was given.
newtype GroundingDigest = GroundingDigest {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Digest of the runtime that executed the agent.
newtype RuntimeDigest = RuntimeDigest {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Digest of the policy in force, distinct from the sanctioned execution
-- profile's own digest.
newtype PolicyDigest = PolicyDigest {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- ---------------------------------------------------------------------------
-- The records
-- ---------------------------------------------------------------------------

-- | Which agent, at which immutable version.
--
-- __Why this record is shaped to be extended, and why a test pins its bytes.__
-- This repository will grow /governed agent evolution/ — keeping a baseline and
-- a candidate version of one agent active at the same time, relating them, and
-- rolling one out. That work is requested in
-- @docs\/improvement-requests\/governed-agent-evolution.md@ and has no plan yet.
-- When it arrives it must /extend/ this record rather than replace it, because
-- by then runs will have been attested against values already written down, and
-- a verifier re-deriving a digest over changed bytes gets a mismatch it cannot
-- distinguish from tampering.
--
-- So every field that work will need — a baseline pointer, a candidate relation,
-- a rollout state — has to be addable as an optional field without changing the
-- bytes of anything encoded today. That is what @omitNothingFields@ in
-- 'agentAesonOptions' buys, and
-- @Shikigami.AttestationContractsSpec@ is what makes it checkable rather than a
-- promise: it pins these bytes as a literal. Adding an optional field keeps that
-- test green; adding a required one, or dropping @omitNothingFields@, fails it
-- immediately with a byte diff.
data AgentVersionRef = AgentVersionRef
  { logicalAgentId :: !LogicalAgentId,
    agentVersion :: !AgentVersion,
    declarationDigest :: !DeclarationDigest
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON AgentVersionRef where toJSON = genericToJSON agentAesonOptions

instance FromJSON AgentVersionRef where parseJSON = genericParseJSON agentAesonOptions

-- | The portable bundle of digests that binds a run to exactly the parts the
-- agent was made of.
--
-- Only the declaration is required. The rest are genuinely optional facts about
-- an agent rather than placeholders: an agent with no grounding bundle has no
-- grounding digest, and an agent whose behavior is a declared prompt rather than
-- a compiled program has no behavior digest. An absent digest says "this agent
-- has no such part", which is a different claim from "this part was not
-- measured" — a distinction a verifier needs, and the reason these are omitted
-- from the encoding entirely rather than written as nulls.
data AgentArtifactSet = AgentArtifactSet
  { declarationDigest :: !DeclarationDigest,
    behaviorDigest :: !(Maybe BehaviorDigest),
    skillsDigest :: !(Maybe SkillsDigest),
    toolCatalogDigest :: !(Maybe ToolCatalogDigest),
    groundingDigest :: !(Maybe GroundingDigest),
    runtimeDigest :: !(Maybe RuntimeDigest),
    policyDigest :: !(Maybe PolicyDigest)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON AgentArtifactSet where toJSON = genericToJSON agentAesonOptions

instance FromJSON AgentArtifactSet where parseJSON = genericParseJSON agentAesonOptions

-- | An artifact set for an agent that is nothing but its declaration. Build from
-- this and fill in the parts an agent actually has, so a part nobody set stays
-- absent rather than becoming an accidental digest of something empty.
declarationOnlyArtifacts :: DeclarationDigest -> AgentArtifactSet
declarationOnlyArtifacts declarationDigest =
  AgentArtifactSet
    { declarationDigest,
      behaviorDigest = Nothing,
      skillsDigest = Nothing,
      toolCatalogDigest = Nothing,
      groundingDigest = Nothing,
      runtimeDigest = Nothing,
      policyDigest = Nothing
    }

-- ---------------------------------------------------------------------------
-- Encoding
-- ---------------------------------------------------------------------------

-- | The one Aeson options value both records in this module use.
--
-- @omitNothingFields@ is the whole mechanism behind this module's
-- extend-don't-replace promise; see the note on 'AgentVersionRef'. Changing it
-- is a wire-format change affecting every attestation ever written, not an
-- edit.
agentAesonOptions :: Options
agentAesonOptions = defaultOptions {omitNothingFields = True}

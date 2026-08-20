{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Shikigami.Agent.Decl
  ( AgentDecl (..),
    IdentityDecl (..),
    MemoryScopeDecl (..),
    RecordPolicy (..),
    MemoryPolicy (..),
    RecallLimit,
    mkRecallLimit,
    recallLimitNatural,
    recallLimitInt,
    defaultMemoryPolicy,
    Behavior (..),
    Trigger (..),
    StreamMatch (..),
    Sink (..),
    SignalType (..),
    Priority (..),
    RecipientFrom (..),
    ProfileRequirement (..),
  )
where

import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Text qualified as Text
import Dhall (Decoder (..), FromDhall (..))
import Dhall qualified
import Numeric.Natural (Natural)
import Shikigami.Prelude

data IdentityDecl = IdentityDecl {principal :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data MemoryScopeDecl = AgentScope | Shared
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data RecordPolicy = Always | OnSuccess | Never
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

-- | A declaration-level recall bound. Dhall naturals are unbounded, so this
-- value is validated before any conversion to the runtime's 'Int' query bound.
newtype RecallLimit = RecallLimit Natural
  deriving stock (Eq, Ord)

instance Show RecallLimit where
  show = show . recallLimitNatural

mkRecallLimit :: Natural -> Either Text RecallLimit
mkRecallLimit value
  | value < 1 = Left (boundMessage value)
  | value > 1000 = Left (boundMessage value)
  | otherwise = Right (RecallLimit value)
  where
    boundMessage invalid =
      "recallLimit must be between 1 and 1000 inclusive; got "
        <> Text.pack (show invalid)

recallLimitNatural :: RecallLimit -> Natural
recallLimitNatural (RecallLimit value) = value

-- | Total because 'mkRecallLimit' admits only values from 1 through 1000.
recallLimitInt :: RecallLimit -> Int
recallLimitInt = fromIntegral . recallLimitNatural

instance FromDhall RecallLimit where
  autoWith _ =
    let Decoder {extract = extractNatural, expected = expectedNatural} = Dhall.natural
     in Decoder
          { extract = \expression ->
              case Dhall.toMonadic (extractNatural expression) of
                Left err -> Dhall.fromMonadic (Left err)
                Right value -> either Dhall.extractError pure (mkRecallLimit value),
            expected = expectedNatural
          }

instance ToJSON RecallLimit where
  toJSON = toJSON . recallLimitNatural

instance FromJSON RecallLimit where
  parseJSON value = do
    natural <- parseJSON value
    either (fail . Text.unpack) pure (mkRecallLimit natural)

data MemoryPolicy = MemoryPolicy
  { scope :: !MemoryScopeDecl,
    recallLimit :: !RecallLimit,
    recordPolicy :: !RecordPolicy
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

defaultMemoryPolicy :: MemoryPolicy
defaultMemoryPolicy =
  MemoryPolicy
    { scope = AgentScope,
      recallLimit = RecallLimit 10,
      recordPolicy = OnSuccess
    }

data SignalType
  = Notification
  | Alert
  | Reminder
  | TaskCandidate
  | DigestItem
  | AgentRequest
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Priority = Low | Normal | High | Urgent
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data RecipientFrom = SubjectOwner | AreaOwner | Actor
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data StreamMatch = StreamMatch
  { verb :: !(Maybe Text),
    source :: !(Maybe Text),
    subjectType :: !(Maybe Text),
    verbs :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Trigger
  = Schedule {cron :: !Text}
  | Stream {match :: !StreamMatch}
  | Event {eventType :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Behavior
  = Deterministic {rule :: !Text, params :: !(Map Text Text)}
  | ShikumiProgram
      { task :: !Text,
        preferEnrichment :: !Bool,
        grounding :: !(Maybe Text),
        enabledBy :: !(Maybe Text)
      }
  | Skill {path :: !Text}
  | Flow {name :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data Sink
  = KawaDigest {subjectType :: !Text, verb :: !Text}
  | KizashiSignal
      { source :: !Text,
        signalType :: !SignalType,
        priority :: !Priority,
        importance :: !Natural,
        recipientFrom :: !RecipientFrom,
        defaultRecipient :: !(Maybe Text),
        intentTemplate :: !Text,
        extraContextTags :: ![Text]
      }
  | ReiAction {intentionId :: !Text, note :: !Text}
  | DanwaConversation {topic :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

-- | Which sanctioned execution profile an agent run must resolve before it may
-- open a memory session. An absent version means "the one active version" and
-- therefore still fails if the store returns zero or multiple candidates.
data ProfileRequirement = ProfileRequirement
  { profileId :: !Text,
    version :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

data AgentDecl = AgentDecl
  { name :: !Text,
    description :: !Text,
    trigger :: !Trigger,
    behavior :: !Behavior,
    sinks :: ![Sink],
    sanctionedProfile :: !(Maybe ProfileRequirement),
    identity :: !(Maybe IdentityDecl),
    memory :: !MemoryPolicy,
    enabled :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall)

-- | Keep declarations carrying only defaulted optional policy byte-compatible
-- with values journaled before those fields existed. Non-default declarations
-- still carry their complete policy in the workflow journal.
instance ToJSON AgentDecl where
  toJSON AgentDecl {name, description, trigger, behavior, sinks, sanctionedProfile, identity, memory, enabled} =
    Aeson.object
      ( [ "name" Aeson..= name,
          "description" Aeson..= description,
          "trigger" Aeson..= trigger,
          "behavior" Aeson..= behavior,
          "sinks" Aeson..= sinks
        ]
          <> maybe [] (\profile -> ["sanctionedProfile" Aeson..= profile]) sanctionedProfile
          <> maybe [] (\declaredIdentity -> ["identity" Aeson..= declaredIdentity]) identity
          <> ["memory" Aeson..= memory | memory /= defaultMemoryPolicy]
          <> ["enabled" Aeson..= False | not enabled]
      )

-- | Missing fields decode to the pre-schema-evolution behavior. This is needed
-- for replaying old @lookup-agent@ workflow step values as well as for ordinary
-- JSON compatibility.
instance FromJSON AgentDecl where
  parseJSON = Aeson.withObject "AgentDecl" \value -> do
    name <- value Aeson..: "name"
    description <- value Aeson..: "description"
    trigger <- value Aeson..: "trigger"
    behavior <- value Aeson..: "behavior"
    sinks <- value Aeson..: "sinks"
    sanctionedProfile <- value Aeson..:? "sanctionedProfile"
    identity <- value Aeson..:? "identity"
    memory <- value Aeson..:? "memory" Aeson..!= defaultMemoryPolicy
    enabled <- value Aeson..:? "enabled" Aeson..!= True
    pure AgentDecl {name, description, trigger, behavior, sinks, sanctionedProfile, identity, memory, enabled}

{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Shikigami.Api.Agent
  ( AgentDecl (..),
    Behavior (..),
    Trigger (..),
    StreamMatch (..),
    Sink (..),
    SignalType (..),
    Priority (..),
    RecipientFrom (..),
  )
where

import Data.Map.Strict (Map)
import Dhall (FromDhall)
import Numeric.Natural (Natural)
import Shikigami.Prelude

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

data AgentDecl = AgentDecl
  { name :: !Text,
    description :: !Text,
    trigger :: !Trigger,
    behavior :: !Behavior,
    sinks :: ![Sink]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToJSON, FromJSON)

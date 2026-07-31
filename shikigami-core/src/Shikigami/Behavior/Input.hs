-- | What a behavior is given to work with: the event that triggered this run,
-- and what the agent already learned from earlier ones.
--
-- These are two different things and each arm renders them differently — the
-- skill arm writes them into the model context, the program arm passes them as
-- named arguments — so they are kept apart rather than merged into one payload
-- 'Value'. Merging is what the conversation path does today
-- ("Shikigami.Agent.Conversation" smuggles turn history into the payload), and
-- it makes the payload's shape depend on which trigger produced it.
--
-- This lives in its own module rather than in "Shikigami.Behavior.Run" because
-- "Shikigami.Behavior.Skill" also needs it, and @Run@ imports @Skill@. @Run@
-- re-exports it, so callers see it where the plan says it lives.
module Shikigami.Behavior.Input
  ( BehaviorInput (..),
    triggerOnly,
    memoryContentText,
  )
where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Text (Text)
import GHC.Generics (Generic)
import Kioku.Api.Types (MemoryRecord (..))

-- | The behavior's input: the trigger payload, plus the memories the @recall@
-- step returned for this run.
--
-- 'recalled' is deliberately the /journaled/ recall result rather than
-- something the behavior fetches for itself: on a crash-replay the workflow
-- hands back the recorded list, so a resumed run sees exactly the memories the
-- original attempt saw.
data BehaviorInput = BehaviorInput
  { payload :: !Value,
    recalled :: ![MemoryRecord]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | An input for a caller that has a trigger payload and no memory to offer.
--
-- Three callers are in that position and all of them are honest about it: the
-- @run-behavior@ command opens no database, and the conversation path carries
-- its context as turns inside the payload instead. Naming the case keeps an
-- empty 'recalled' from looking like an oversight at the call site.
triggerOnly :: Value -> BehaviorInput
triggerOnly payload = BehaviorInput {payload, recalled = []}

-- | The prose of a recalled memory — what an agent actually remembered, with
-- the bookkeeping stripped off.
memoryContentText :: MemoryRecord -> Text
memoryContentText MemoryRecord {content} = content

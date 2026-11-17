{-# LANGUAGE DataKinds #-}

-- | Where the conversation loop's messages come from and where its replies
-- go (plan 135, M5).
--
-- The conversation workflow ("Shikigami.Agent.Conversation") is the kernel's:
-- a durable, multi-turn session between one agent and the people who address
-- it, with an idle timeout and a reply per turn. It names no service. A pack
-- contributes a 'ConversationChannel' that says which integration event
-- addresses an agent, how that event's payload becomes an 'InboundMessage', and
-- which output carries the agent's reply. The Kikan binding's Danwa channel is
-- the first; another chat service is another channel, not another workflow.
--
-- An agent takes part in a channel's conversations by declaring
-- @Trigger.Event { eventType }@ with the channel's event type. That one
-- declaration is how the event consumer routes a delivery to the conversation
-- workflow and how the worker finds the decoder and the reply.
module Shikigami.Agent.Conversation.Channel
  ( -- * Messages
    InboundMessage (..),

    -- * Channels
    ConversationChannel (..),
    ConversationChannels,
    mkConversationChannels,
    noConversationChannels,
    conversationChannelList,
    channelForEventType,
    channelForAgent,
    agentEventType,
  )
where

import Data.Aeson (Value, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.List (find, nub)
import Data.Text qualified as Text
import Shikigami.Agent.Decl (AgentDecl (..), Trigger (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Output (OutputDecl)
import Shikigami.Prelude hiding ((.=))

-- | One message addressed to an agent, in the kernel's terms. The workflow
-- journals it, so its JSON keys are stable: a channel's payload decoder may
-- read whatever its service sends, but it produces exactly these fields.
data InboundMessage = InboundMessage
  { -- | The conversation the message belongs to, in the channel's ids. The
    -- workflow keeps one durable instance per conversation.
    conversationId :: !(DeclarationCoordinate "conversation"),
    -- | The message, unique within the channel. A redelivered message is the
    -- same turn.
    messageId :: !(DeclarationCoordinate "conversation-message"),
    parentMessageId :: !(Maybe (DeclarationCoordinate "conversation-message")),
    author :: !(DeclarationCoordinate "conversation-participant"),
    content :: !Text,
    -- | The agent's own participant id in the channel, which the agent's
    -- behavior sees beside the message.
    agentParticipantId :: !(DeclarationCoordinate "conversation-participant"),
    occurredAt :: !UTCTime
  }
  deriving stock (Eq, Show)

instance ToJSON InboundMessage where
  toJSON message =
    Aeson.object
      [ "conversationId" .= message.conversationId,
        "messageId" .= message.messageId,
        "parentMessageId" .= message.parentMessageId,
        "author" .= message.author,
        "content" .= message.content,
        "agentParticipantId" .= message.agentParticipantId,
        "occurredAt" .= message.occurredAt
      ]

instance FromJSON InboundMessage where
  parseJSON =
    withObject "InboundMessage" \o ->
      InboundMessage
        <$> o .: "conversationId"
        <*> o .: "messageId"
        <*> o .:? "parentMessageId"
        <*> o .: "author"
        <*> o .: "content"
        <*> o .: "agentParticipantId"
        <*> o .: "occurredAt"

-- | What a pack supplies for one conversation service.
data ConversationChannel = ConversationChannel
  { -- | A short name for logs and refusals, such as @danwa@.
    name :: !Text,
    -- | The integration event type that addresses an agent in this channel.
    eventType :: !Text,
    -- | Read one delivery's payload. A 'Left' is a permanent refusal of that
    -- delivery, with a bounded reason.
    decodeMessage :: !(Value -> Either Text InboundMessage),
    -- | The output that posts the agent's reply under the message it answers.
    -- It is checked against the composition's outputs and grants like any
    -- declared output.
    replyOutput :: !(InboundMessage -> OutputDecl)
  }

-- | Sealed: every name and every event type is unique.
newtype ConversationChannels = ConversationChannels [ConversationChannel]

mkConversationChannels :: [ConversationChannel] -> Either Text ConversationChannels
mkConversationChannels channels
  | length (nub names) /= length names = Left ("two conversation channels share a name: " <> Text.intercalate ", " names)
  | length (nub events) /= length events = Left ("two conversation channels claim one event type: " <> Text.intercalate ", " events)
  | otherwise = Right (ConversationChannels channels)
  where
    names = (.name) <$> channels
    events = (.eventType) <$> channels

noConversationChannels :: ConversationChannels
noConversationChannels = ConversationChannels []

conversationChannelList :: ConversationChannels -> [ConversationChannel]
conversationChannelList (ConversationChannels channels) = channels

channelForEventType :: ConversationChannels -> Text -> Maybe ConversationChannel
channelForEventType (ConversationChannels channels) wanted = find ((== wanted) . (.eventType)) channels

-- | The channel an agent converses in: the one whose event type its
-- @Trigger.Event@ declares. 'Nothing' for any other agent.
channelForAgent :: ConversationChannels -> AgentDecl -> Maybe ConversationChannel
channelForAgent channels decl = agentEventType decl >>= channelForEventType channels

-- | The event type an agent's @Trigger.Event@ declares.
agentEventType :: AgentDecl -> Maybe Text
agentEventType AgentDecl {trigger} = case trigger of
  Event {eventType} -> Just (declarationCoordinateText eventType)
  _ -> Nothing

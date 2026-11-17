{-# LANGUAGE DataKinds #-}

-- | The Danwa conversation channel (plan 135, M5): Danwa's public
-- addressed-message events start and continue the kernel's conversation loop,
-- and each reply is a @danwa.conversation@ output under the message it answers.
--
-- An agent converses through Danwa by declaring
-- @Trigger.Event { eventType = "danwa.message-addressed-to-agent" }@; the
-- distribution's @kikan-shikigami-consume-events@ reads the topic Danwa
-- publishes them on (@danwa.message-addressed.v1@).
module Kikan.Shikigami.Binding.Conversation
  ( AddressedMessage (..),
    addressedMessageEventType,
    danwaChannel,
    inboundMessage,
  )
where

import Data.Aeson (withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Kikan.Shikigami.Binding.Outputs (DanwaConversationOutput (..), DanwaTarget (..), danwaConversationOutput)
import Shikigami.Agent.Conversation.Channel (ConversationChannel (..), InboundMessage (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Prelude hiding ((.=))

-- | Danwa's public message-addressed payload.
--
-- This mirrors the public `danwa.message-addressed-to-agent` contract. It
-- deliberately does not expose or depend on Danwa's private event store, read
-- models, outbox table, or database schema.
data AddressedMessage = AddressedMessage
  { conversationId :: !(DeclarationCoordinate "danwa-conversation"),
    messageId :: !(DeclarationCoordinate "danwa-message"),
    parentMessageId :: !(Maybe (DeclarationCoordinate "danwa-message")),
    author :: !(DeclarationCoordinate "danwa-participant"),
    content :: !Text,
    agentParticipantId :: !(DeclarationCoordinate "danwa-participant"),
    embellishmentId :: !(DeclarationCoordinate "danwa-embellishment"),
    mentionedBy :: !(DeclarationCoordinate "danwa-participant"),
    occurredAt :: !UTCTime
  }
  deriving stock (Eq, Show)

instance ToJSON AddressedMessage where
  toJSON msg =
    Aeson.object
      [ "conversationId" .= (.conversationId) msg,
        "messageId" .= (.messageId) msg,
        "parentMessageId" .= (.parentMessageId) msg,
        "author" .= (.author) msg,
        "content" .= (.content) msg,
        "agentParticipantId" .= (.agentParticipantId) msg,
        "embellishmentId" .= (.embellishmentId) msg,
        "mentionedBy" .= (.mentionedBy) msg,
        "occurredAt" .= (.occurredAt) msg
      ]

instance FromJSON AddressedMessage where
  parseJSON =
    withObject "AddressedMessage" \o ->
      AddressedMessage
        <$> o .: "conversationId"
        <*> o .: "messageId"
        <*> o .: "parentMessageId"
        <*> o .: "author"
        <*> o .: "content"
        <*> o .: "agentParticipantId"
        <*> o .: "embellishmentId"
        <*> o .: "mentionedBy"
        <*> o .: "occurredAt"

addressedMessageEventType :: Text
addressedMessageEventType = "danwa.message-addressed-to-agent"

-- | The channel the binding registers.
danwaChannel :: ConversationChannel
danwaChannel =
  ConversationChannel
    { name = "danwa",
      eventType = addressedMessageEventType,
      decodeMessage = \payload -> case Aeson.fromJSON payload of
        Aeson.Success addressed -> Right (inboundMessage addressed)
        Aeson.Error problem -> Left ("not a Danwa addressed message: " <> Text.take 256 (Text.pack problem)),
      replyOutput = \message ->
        danwaConversationOutput
          DanwaConversationOutput
            { topic = "danwa-conversation",
              thread =
                Just
                  DanwaTarget
                    { conversationId = declarationCoordinate (declarationCoordinateText message.conversationId),
                      parentMessageId = Just (declarationCoordinate (declarationCoordinateText message.messageId))
                    }
            }
    }

-- | The kernel's view of an addressed message. Danwa's embellishment and
-- mention ids stay on Danwa's side: the conversation loop needs neither.
inboundMessage :: AddressedMessage -> InboundMessage
inboundMessage addressed =
  InboundMessage
    { conversationId = retag addressed.conversationId,
      messageId = retag addressed.messageId,
      parentMessageId = retag <$> addressed.parentMessageId,
      author = retag addressed.author,
      content = addressed.content,
      agentParticipantId = retag addressed.agentParticipantId,
      occurredAt = addressed.occurredAt
    }
  where
    retag :: DeclarationCoordinate a -> DeclarationCoordinate b
    retag = declarationCoordinate . declarationCoordinateText

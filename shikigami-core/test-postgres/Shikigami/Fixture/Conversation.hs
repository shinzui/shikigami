{-# LANGUAGE DataKinds #-}

-- | A conversation channel for the kernel's workflow tests (plan 135, M5).
--
-- The kernel's tests exercise its conversation loop, not any chat service:
-- this channel reads a payload that already has the kernel's message shape
-- and replies with a raw output of a kind the fixture outputs register. The
-- Danwa channel is qualified by the binding's suite.
module Shikigami.Fixture.Conversation
  ( fixtureEventType,
    fixtureChannel,
    fixtureChannels,
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Agent.Conversation.Channel (ConversationChannel (..), ConversationChannels, InboundMessage (..), mkConversationChannels)
import Shikigami.Fixture.RawOutput (rawOutput)

-- | The event type a fixture conversation agent declares.
fixtureEventType :: Text
fixtureEventType = "fixture.message-addressed"

fixtureChannel :: ConversationChannel
fixtureChannel =
  ConversationChannel
    { name = "fixture-chat",
      eventType = fixtureEventType,
      decodeMessage = \payload -> case Aeson.fromJSON payload of
        Aeson.Success message -> Right message
        Aeson.Error problem -> Left (Text.pack problem),
      replyOutput = \message ->
        rawOutput
          "danwa.conversation"
          [ "topic" .= ("fixture-conversation" :: Text),
            "thread" .= object ["conversationId" .= message.conversationId, "parentMessageId" .= Just message.messageId]
          ]
    }

fixtureChannels :: ConversationChannels
fixtureChannels = either (error . Text.unpack) id (mkConversationChannels [fixtureChannel])

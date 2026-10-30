-- | Public Danwa integration-event payloads consumed by Shikigami.
module Shikigami.Integration.Danwa
  ( AddressedMessage (..),
    addressedMessageEventType,
  )
where

import Data.Aeson (withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Shikigami.Prelude hiding ((.=))

-- | Danwa's public message-addressed payload.
--
-- This mirrors the public `danwa.message-addressed-to-agent` contract. It
-- deliberately does not expose or depend on Danwa's private event store, read
-- models, outbox table, or database schema.
data AddressedMessage = AddressedMessage
  { conversationId :: !Text,
    messageId :: !Text,
    parentMessageId :: !(Maybe Text),
    author :: !Text,
    content :: !Text,
    agentParticipantId :: !Text,
    embellishmentId :: !Text,
    mentionedBy :: !Text,
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

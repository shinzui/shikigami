{-# LANGUAGE DataKinds #-}

-- | The Danwa conversation channel (plan 135, M5): Danwa's public
-- addressed-message payload becomes the kernel's message, and the reply is a
-- @danwa.conversation@ output under the message it answers.
module Kikan.Shikigami.Binding.ConversationSpec (tests) where

import Data.Aeson (Value, eitherDecode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Kikan.Shikigami.Binding (kikanBinding)
import Kikan.Shikigami.Binding.Conversation (AddressedMessage (..), addressedMessageEventType, danwaChannel)
import Kikan.Shikigami.Binding.Output (kikanOutputRegistrations)
import Shikigami.Agent.Conversation.Channel (ConversationChannel (..), InboundMessage (..), channelForEventType)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Authority (outputKindText)
import Shikigami.Flow.Builtin (builtinPack)
import Shikigami.Flow.Pack (FlowPack (..), composeFlowRegistry, registeredConversationChannels)
import Shikigami.Output (OutputDecl (..))
import Shikigami.Output.Registration (OutputRegistration (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Danwa conversation channel"
    [ testCase "decodes the public addressed-message payload" do
        case eitherDecode @AddressedMessage (Aeson.encode payload) of
          Left err -> assertFailure ("decode failed: " <> err)
          Right msg ->
            msg
              @?= AddressedMessage
                { conversationId = declarationCoordinate "conv_public_1",
                  messageId = declarationCoordinate "msg_public_1",
                  parentMessageId = Nothing,
                  author = declarationCoordinate "part_human_test",
                  content = "please help",
                  agentParticipantId = declarationCoordinate "part_agent_test",
                  embellishmentId = declarationCoordinate "emb_public_1",
                  mentionedBy = declarationCoordinate "part_human_test",
                  occurredAt = UTCTime (fromGregorian 2026 6 27) 0
                },
      testCase "the channel serves Danwa's public event type and the binding registers it" do
        addressedMessageEventType @?= "danwa.message-addressed-to-agent"
        danwaChannel.eventType @?= addressedMessageEventType
        fmap (.name) kikanBinding.conversationChannels @?= ["danwa"]
        case composeFlowRegistry [builtinPack, kikanBinding] of
          Left _ -> assertFailure "the binding refused to compose"
          Right registry -> fmap (.name) (channelForEventType (registeredConversationChannels registry) addressedMessageEventType) @?= Just "danwa",
      testCase "an addressed message becomes the kernel's message, without Danwa's own ids" do
        case danwaChannel.decodeMessage payload of
          Left problem -> assertFailure ("refused: " <> show problem)
          Right message -> do
            message
              @?= InboundMessage
                { conversationId = declarationCoordinate "conv_public_1",
                  messageId = declarationCoordinate "msg_public_1",
                  parentMessageId = Nothing,
                  author = declarationCoordinate "part_human_test",
                  content = "please help",
                  agentParticipantId = declarationCoordinate "part_agent_test",
                  occurredAt = UTCTime (fromGregorian 2026 6 27) 0
                }
            -- The kernel message journals exactly its own keys.
            Aeson.toJSON message
              @?= object
                [ "conversationId" .= ("conv_public_1" :: Text),
                  "messageId" .= ("msg_public_1" :: Text),
                  "parentMessageId" .= Aeson.Null,
                  "author" .= ("part_human_test" :: Text),
                  "content" .= ("please help" :: Text),
                  "agentParticipantId" .= ("part_agent_test" :: Text),
                  "occurredAt" .= ("2026-06-27T00:00:00Z" :: Text)
                ],
      testCase "a payload that is not an addressed message is refused with a reason" do
        case danwaChannel.decodeMessage (object ["content" .= ("hi" :: Text)]) of
          Left problem -> assertBool "names Danwa" (problem /= "")
          Right message -> assertFailure ("accepted " <> show message),
      testCase "the reply is a valid danwa.conversation output under the message it answers" do
        message <- either (assertFailure . show) pure (danwaChannel.decodeMessage payload)
        let reply = danwaChannel.replyOutput message
        outputKindText reply.kind @?= "danwa.conversation"
        reply.config
          @?= object
            [ "topic" .= ("danwa-conversation" :: Text),
              "thread" .= object ["conversationId" .= ("conv_public_1" :: Text), "parentMessageId" .= ("msg_public_1" :: Text)]
            ]
        case [registration | registration <- kikanOutputRegistrations, registration.kind == reply.kind] of
          [registration] -> registration.validate reply.config @?= Right ()
          other -> assertFailure ("expected one danwa.conversation registration, found " <> show (length other))
    ]

payload :: Value
payload =
  object
    [ "conversationId" .= ("conv_public_1" :: Text),
      "messageId" .= ("msg_public_1" :: Text),
      "parentMessageId" .= Aeson.Null,
      "author" .= ("part_human_test" :: Text),
      "content" .= ("please help" :: Text),
      "agentParticipantId" .= ("part_agent_test" :: Text),
      "embellishmentId" .= ("emb_public_1" :: Text),
      "mentionedBy" .= ("part_human_test" :: Text),
      "occurredAt" .= ("2026-06-27T00:00:00Z" :: Text)
    ]

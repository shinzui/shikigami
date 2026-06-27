-- | Real @DanwaConversation@ sink handler. It posts the rendered behavior output into
-- an existing danwa conversation when a target is present, or starts a fresh thread for
-- ordinary one-shot runs.
module Shikigami.Sink.Danwa
  ( runDanwa,
    postReply,
  )
where

import Danwa.Client qualified as Danwa
import Danwa.Conversation.Api qualified as Conv
import Danwa.Message.Api qualified as Msg
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Text (encodeToLazyText)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as TL
import Shikigami.Api.Agent (Sink (..))
import Shikigami.Prelude
import Shikigami.Sink.Config (DanwaConfig (..))
import Shikigami.Sink.Permission (AgentIdentity (..))
import Shikigami.Sink.Types (DanwaTarget (..))

runDanwa :: DanwaConfig -> AgentIdentity -> Maybe DanwaTarget -> Sink -> Value -> IO (Either Text Text)
runDanwa cfg identity target sink output =
  case sink of
    DanwaConversation {} ->
      case target of
        Just t -> postReply cfg t (renderDanwaContent output)
        Nothing -> postToFreshConversation cfg identity sink (renderDanwaContent output)
    _ -> pure (Left "runDanwa: not a DanwaConversation sink")

postReply :: DanwaConfig -> DanwaTarget -> Text -> IO (Either Text Text)
postReply cfg (DanwaTarget {dtConversationId = cid, dtParentMessageId = parent}) content = do
  result <-
    Danwa.runDanwa (Text.unpack (danwaBaseUrl cfg)) $
      case parent of
        Nothing ->
          Danwa.postMessage
            cid
            Msg.PostMessageRequest
              { Msg.author = danwaAgentParticipant cfg,
                Msg.content = content
              }
        Just parentMessageId ->
          Danwa.replyToMessage
            cid
            parentMessageId
            Msg.PostMessageRequest
              { Msg.author = danwaAgentParticipant cfg,
                Msg.content = content
              }
  pure $ case result of
    Left err -> Left (Text.pack (show err))
    Right response ->
      let Msg.MessageResponse {Msg.messageId = mid} = response
       in Right mid

postToFreshConversation :: DanwaConfig -> AgentIdentity -> Sink -> Text -> IO (Either Text Text)
postToFreshConversation cfg (AgentIdentity _agentName) sink content =
  case sink of
    DanwaConversation {} -> do
      result <-
        Danwa.runDanwa (Text.unpack (danwaBaseUrl cfg)) do
          conversation <-
            Danwa.startConversation
              Conv.StartConversationRequest
                { Conv.startedBy = danwaAgentParticipant cfg,
                  Conv.kind = "thread",
                  Conv.parentConversationId = Nothing
                }
          let Conv.ConversationResponse {Conv.conversationId = cid} = conversation
          _ <-
            Danwa.joinConversation
              cid
              Conv.JoinConversationRequest
                { Conv.participantId = danwaAgentParticipant cfg,
                  Conv.participantType = "agent"
                }
          response <-
            Danwa.postMessage
              cid
              Msg.PostMessageRequest
                { Msg.author = danwaAgentParticipant cfg,
                  Msg.content = content
                }
          let Msg.MessageResponse {Msg.messageId = mid} = response
          pure mid
      pure $ case result of
        Left err -> Left (Text.pack (show err))
        Right mid -> Right mid
    _ -> pure (Left "postToFreshConversation: not a DanwaConversation sink")

renderDanwaContent :: Value -> Text
renderDanwaContent v = case v of
  Object o -> case KeyMap.lookup "reply" o <|> KeyMap.lookup "summary" o of
    Just (String s) -> s
    _ -> compact v
  String s -> s
  _ -> compact v
  where
    compact = TL.toStrict . encodeToLazyText

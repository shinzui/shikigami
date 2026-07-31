module Shikigami.Server.Command.DanwaSpike
  ( runDanwaSpike,
  )
where

import Danwa.Client qualified as Danwa
import Danwa.Conversation.Api qualified as Conv
import Danwa.Message.Api qualified as Msg
import Data.Text qualified as Text
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @danwa-spike --danwa-url URL --human part_... --agent part_...@
-- proves the outbound danwa client path before the real sink is wired.
runDanwaSpike :: String -> String -> String -> IO ()
runDanwaSpike danwaUrl humanArg agentArg = do
  let human = Text.pack humanArg
      agent = Text.pack agentArg
      action = do
        conversation <-
          Danwa.startConversation
            Conv.StartConversationRequest
              { Conv.startedBy = human,
                Conv.kind = "thread",
                Conv.parentConversationId = Nothing
              }
        let Conv.ConversationResponse {Conv.conversationId = cid} = conversation
        _ <-
          Danwa.joinConversation
            cid
            Conv.JoinConversationRequest
              { Conv.participantId = human,
                Conv.participantType = "human"
              }
        _ <-
          Danwa.joinConversation
            cid
            Conv.JoinConversationRequest
              { Conv.participantId = agent,
                Conv.participantType = "agent"
              }
        humanMessage <-
          Danwa.postMessage
            cid
            Msg.PostMessageRequest
              { Msg.author = human,
                Msg.content = "Hello from shikigami danwa-spike."
              }
        let Msg.MessageResponse {Msg.messageId = humanMessageId} = humanMessage
        agentReply <-
          Danwa.replyToMessage
            cid
            humanMessageId
            Msg.PostMessageRequest
              { Msg.author = agent,
                Msg.content = "Hello from the shikigami agent spike."
              }
        let Msg.MessageResponse {Msg.messageId = agentMessageId} = agentReply
        pure (cid, humanMessageId, agentMessageId)
  result <- Danwa.runDanwa danwaUrl action
  case result of
    Left err -> do
      hPutStrLn stderr ("danwa-spike: " <> show err)
      exitFailure
    Right (cid, humanMessageId, agentMessageId) -> do
      putStrLn ("started conversation " <> Text.unpack cid)
      putStrLn ("posted human message " <> Text.unpack humanMessageId)
      putStrLn ("posted agent reply   " <> Text.unpack agentMessageId)

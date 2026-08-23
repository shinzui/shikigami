-- | Real @DanwaConversation@ sink handler. It posts the rendered behavior output into
-- an existing danwa conversation when a target is present, or starts a fresh thread for
-- ordinary one-shot runs.
module Shikigami.Sink.Danwa
  ( DanwaError (..),
    runDanwa,
    runDanwaWithHeaders,
    postReply,
    renderDanwaError,
  )
where

import Control.Exception (IOException, try)
import Danwa.Client qualified as Danwa
import Danwa.Conversation.Api qualified as Conv
import Danwa.Message.Api qualified as Msg
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Text (encodeToLazyText)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as TL
import Network.HTTP.Types.Header (Header)
import Servant.Client (ClientEnv)
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Prelude
import Shikigami.Sink.Config (DanwaConfig (..))
import Shikigami.Sink.Http (HttpFailure, renderHttpFailure, runDanwaClientWithHeaders)
import Shikigami.Sink.Permission (AgentIdentity (..))
import Shikigami.Sink.Types (DanwaTarget (..), DeliveryGuard (..))

data DanwaError
  = DanwaHttpError !HttpFailure
  | DanwaReceiptFailure !Text
  | DanwaUsageError !Text
  deriving stock (Eq, Show)

renderDanwaError :: DanwaError -> Text
renderDanwaError = \case
  DanwaHttpError failure -> renderHttpFailure failure
  DanwaReceiptFailure detail -> detail
  DanwaUsageError detail -> detail

-- | Post the behavior output into danwa.
--
-- The declared @topic@ is honored only when this opens a /fresh/ thread, and
-- then as the first line of the opening message rather than as a conversation
-- attribute — danwa's domain has no topic to set. A reply into an existing
-- thread ignores it by design: the thread already has its context, and
-- re-announcing the topic on every message would be noise.
--
-- In-band was chosen over rejecting the field at validate time because the field
-- has real declarative value — a human opening the thread sees what it is about
-- — and because rejecting it would invalidate manifests that are otherwise
-- correct. What was not an option was continuing to accept it and do nothing.
runDanwa :: ClientEnv -> DanwaConfig -> AgentIdentity -> Maybe DeliveryGuard -> Maybe DanwaTarget -> Sink -> Value -> IO (Either DanwaError Text)
runDanwa clientEnv = runDanwaWithHeaders clientEnv []

-- | 'runDanwa' with dispatch-scoped propagation headers.
runDanwaWithHeaders :: ClientEnv -> [Header] -> DanwaConfig -> AgentIdentity -> Maybe DeliveryGuard -> Maybe DanwaTarget -> Sink -> Value -> IO (Either DanwaError Text)
runDanwaWithHeaders clientEnv headers cfg identity receipts target sink output =
  case sink of
    DanwaConversation {topic} ->
      case target of
        Just t -> postReplyWithHeaders clientEnv headers cfg t (renderDanwaContent output)
        Nothing -> postToFreshConversation clientEnv headers cfg identity receipts sink (withTopicLine topic (renderDanwaContent output))
    _ -> pure (Left (DanwaUsageError "runDanwa: not a DanwaConversation sink"))

-- | Prefix the opening message with the declared topic, if there is one.
--
-- An empty topic contributes nothing rather than an empty bracket, so a
-- declaration that omits it reads exactly as it did before.
withTopicLine :: Text -> Text -> Text
withTopicLine topic content
  | Text.null (Text.strip topic) = content
  | otherwise = "[" <> Text.strip topic <> "]\n" <> content

postReply :: ClientEnv -> DanwaConfig -> DanwaTarget -> Text -> IO (Either DanwaError Text)
postReply clientEnv = postReplyWithHeaders clientEnv []

postReplyWithHeaders :: ClientEnv -> [Header] -> DanwaConfig -> DanwaTarget -> Text -> IO (Either DanwaError Text)
postReplyWithHeaders clientEnv headers cfg (DanwaTarget {conversationId = cid, parentMessageId = parent}) content = do
  result <-
    runDanwaClientWithHeaders headers clientEnv $
      case parent of
        Nothing ->
          Danwa.postMessage
            cid
            Msg.PostMessageRequest
              { Msg.author = agentParticipant cfg,
                Msg.content = content
              }
        Just parentMessageId ->
          Danwa.replyToMessage
            cid
            parentMessageId
            Msg.PostMessageRequest
              { Msg.author = agentParticipant cfg,
                Msg.content = content
              }
  pure $ case result of
    Left failure -> Left (DanwaHttpError failure)
    Right response ->
      let Msg.MessageResponse {Msg.messageId = mid} = response
       in Right mid

postToFreshConversation :: ClientEnv -> [Header] -> DanwaConfig -> AgentIdentity -> Maybe DeliveryGuard -> Sink -> Text -> IO (Either DanwaError Text)
postToFreshConversation clientEnv headers cfg (AgentIdentity _agentName) receipts sink content =
  case sink of
    DanwaConversation {} -> do
      guardedConversation >>= \case
        Left err -> pure (Left err)
        Right cid -> postReplyWithHeaders clientEnv headers cfg DanwaTarget {conversationId = cid, parentMessageId = Nothing} content
    _ -> pure (Left (DanwaUsageError "postToFreshConversation: not a DanwaConversation sink"))
  where
    guardedConversation = case receipts of
      Nothing -> startJoinAndRemember Nothing
      Just deliveryGuard -> do
        lookedUp <- tryIO (lookupReceipt deliveryGuard "conv")
        case lookedUp of
          Left _ -> pure (Left (DanwaReceiptFailure "danwa conversation receipt lookup failed"))
          Right (Just cid) -> pure (Right cid)
          Right Nothing -> startJoinAndRemember (Just deliveryGuard)

    startJoinAndRemember deliveryGuard = do
      started <-
        runDanwaClientWithHeaders headers clientEnv $
          Danwa.startConversation
            Conv.StartConversationRequest
              { Conv.startedBy = agentParticipant cfg,
                Conv.kind = "thread",
                Conv.parentConversationId = Nothing
              }
      case started of
        Left failure -> pure (Left (DanwaHttpError failure))
        Right Conv.ConversationResponse {Conv.conversationId = cid} -> do
          joined <-
            runDanwaClientWithHeaders headers clientEnv $
              Danwa.joinConversation
                cid
                Conv.JoinConversationRequest
                  { Conv.participantId = agentParticipant cfg,
                    Conv.participantType = "agent"
                  }
          case joined of
            Left failure -> pure (Left (DanwaHttpError failure))
            Right _ -> rememberConversation deliveryGuard cid

    rememberConversation Nothing cid = pure (Right cid)
    rememberConversation (Just deliveryGuard) cid =
      tryIO (recordReceipt deliveryGuard "conv" cid) <&> \case
        Left _ -> Left (DanwaReceiptFailure "danwa conversation receipt write failed")
        Right () -> Right cid

tryIO :: IO a -> IO (Either IOException a)
tryIO = try

renderDanwaContent :: Value -> Text
renderDanwaContent v = case v of
  Object o -> case KeyMap.lookup "reply" o <|> KeyMap.lookup "summary" o of
    Just (String s) -> s
    _ -> compact v
  String s -> s
  _ -> compact v
  where
    compact = TL.toStrict . encodeToLazyText

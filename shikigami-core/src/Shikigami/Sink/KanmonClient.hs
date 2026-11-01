{-# LANGUAGE DataKinds #-}

-- | The guarded channel-egress client. Shikigami authenticates only to Kanmon;
-- provider credentials and destination authorization remain downstream.
module Shikigami.Sink.KanmonClient
  ( KanmonError (..),
    resolveConversationKey,
    buildEgressRequest,
    postEgress,
    postEgressWithHeaders,
    renderKanmonError,
  )
where

import Data.Aeson (Value (..), eitherDecode, encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Types.Header (Header)
import Shikigami.Activity qualified as Activity
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Prelude
import Shikigami.Sink.Config (KanmonConfig (..))
import Shikigami.Sink.Http (HttpEnv, HttpFailure, postJSONWithHeaders, renderHttpFailure)
import Shikigami.Sink.Types (SinkContext (..), mkSourceEventId)
import Shikigami.Sink.Validate (validateKanmonRouteSegment)
import Shikigami.Sink.Wire (EgressActionRequest (..), EgressActionResponse)

data KanmonError
  = KanmonHttpError !HttpFailure
  | KanmonDecodeError !Text
  | KanmonUsageError !Text
  deriving stock (Eq, Show)

-- | Resolve the destination once, before durable enqueue. Non-empty static
-- declarations win, then output metadata, then the triggering subject id.
resolveConversationKey :: Sink -> Maybe Activity.ActivityEnvelope -> Value -> Maybe Text
resolveConversationKey sink activity output =
  firstNonEmpty
    [ declaredKey sink,
      objectText "conversation_key" output,
      activitySubjectId activity
    ]

-- | Build the exact Kanmon request from durable, already-resolved metadata.
buildEgressRequest :: SinkContext -> Value -> Either Text EgressActionRequest
buildEgressRequest ctx@SinkContext {conversationKey = resolvedConversationKey, triggeringActivityId = resolvedTriggeringActivityId} output =
  case nonEmpty resolvedConversationKey of
    Nothing -> Left "ChannelEgress requires a resolved conversation key"
    Just resolvedKey ->
      Right
        EgressActionRequest
          { conversationKey = resolvedKey,
            content = contentFrom output,
            idempotencyKey = Just (mkSourceEventId ctx),
            triggeringActivityId = nonEmpty resolvedTriggeringActivityId
          }

postEgress :: HttpEnv -> KanmonConfig -> DeclarationCoordinate "channel" -> DeclarationCoordinate "channel-action" -> EgressActionRequest -> IO (Either KanmonError EgressActionResponse)
postEgress env = postEgressWithHeaders env []

postEgressWithHeaders :: HttpEnv -> [Header] -> KanmonConfig -> DeclarationCoordinate "channel" -> DeclarationCoordinate "channel-action" -> EgressActionRequest -> IO (Either KanmonError EgressActionResponse)
postEgressWithHeaders env headers KanmonConfig {baseUrl} channel action request =
  case validateRoute (declarationCoordinateText channel) (declarationCoordinateText action) of
    Left problem -> pure (Left (KanmonUsageError problem))
    Right () -> do
      let url = Text.dropWhileEnd (== '/') baseUrl <> "/channels/" <> declarationCoordinateText channel <> "/actions/" <> declarationCoordinateText action
      postJSONWithHeaders env headers url request <&> \case
        Left failure -> Left (KanmonHttpError failure)
        Right body ->
          case eitherDecode body of
            Left _ -> Left (KanmonDecodeError "invalid EgressActionResponse")
            Right response -> Right response

-- | Render only stable categories and validated usage facts. Response bodies,
-- request content, conversation keys, and credentials never enter this text.
renderKanmonError :: KanmonError -> Text
renderKanmonError = \case
  KanmonHttpError failure -> renderHttpFailure failure
  KanmonDecodeError _ -> "decode EgressActionResponse"
  KanmonUsageError problem -> "invalid Kanmon request: " <> problem

validateRoute :: Text -> Text -> Either Text ()
validateRoute channel action = do
  _ <- validateField "channel" channel
  _ <- validateField "action" action
  pure ()
  where
    validateField field value =
      case validateKanmonRouteSegment value of
        Left reason -> Left (field <> " " <> reason)
        Right valid -> Right valid

declaredKey :: Sink -> Maybe Text
declaredKey = \case
  ChannelEgress {conversationKey} -> nonEmpty (declarationCoordinateText <$> conversationKey)
  _ -> Nothing

objectText :: Text -> Value -> Maybe Text
objectText key = \case
  Object fields ->
    case KeyMap.lookup (Key.fromText key) fields of
      Just (String value) -> nonEmpty (Just value)
      _ -> Nothing
  _ -> Nothing

activitySubjectId :: Maybe Activity.ActivityEnvelope -> Maybe Text
activitySubjectId = \case
  Just Activity.ActivityEnvelope {Activity.subject = Activity.Subject {Activity.subjectId}} -> nonEmpty (Just (Activity.activityCoordinateText subjectId))
  Nothing -> Nothing

firstNonEmpty :: [Maybe Text] -> Maybe Text
firstNonEmpty = listToMaybe . mapMaybe nonEmpty

nonEmpty :: Maybe Text -> Maybe Text
nonEmpty value = value >>= \candidate -> candidate <$ guard (not (Text.null (Text.strip candidate)))

contentFrom :: Value -> Text
contentFrom output =
  fromMaybe
    (TextEncoding.decodeUtf8 (LazyByteString.toStrict (encode output)))
    (firstNonEmpty (fmap (`objectText` output) ["reply", "content", "summary"]))

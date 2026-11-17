{-# LANGUAGE DataKinds #-}

-- | The configurations of the five Kikan output kinds (plan 135, M3).
--
-- A declaration names a Kikan output as an 'OutputDecl': a kind and a JSON
-- configuration. This module is the typed form of each configuration and the
-- one place that converts between the two, so an adapter, a flow and a
-- declaration helper all agree on the shape. A configuration is also where an
-- output is /directed/: a signal names an exact @recipient@, and a Danwa post
-- names the @thread@ it replies in. The kernel never reads either; the
-- adapter does.
module Shikigami.Sink.Outputs
  ( -- * Kinds
    kawaDigestKind,
    kizashiSignalKind,
    reiActionKind,
    danwaConversationKind,
    channelEgressKind,
    kikanOutputKinds,

    -- * Configurations
    KawaDigestOutput (..),
    KizashiSignalOutput (..),
    ReiActionOutput (..),
    DanwaConversationOutput (..),
    DanwaTarget (..),
    ChannelEgressOutput (..),
    kawaDigestOutput,
    kizashiSignalOutput,
    reiActionOutput,
    danwaConversationOutput,
    channelEgressOutput,
    decodeOutputConfig,

    -- * Directing an output
    toRecipient,
    inThread,

    -- * Validation
    outputConfigErrors,
    validateKanmonRouteSegment,

    -- * From the legacy sink union
    sinkOutput,
    declarationOutputs,
  )
where

import Data.Aeson (Value (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Text qualified as Text
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl (AgentDecl (..), Priority, RecipientFrom (..), SignalType, Sink (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Authority (OutputKind, mkOutputKind, outputKindText)
import Shikigami.Output (OutputDecl (..))
import Shikigami.Prelude hiding ((.=))

kawaDigestKind, kizashiSignalKind, reiActionKind, danwaConversationKind, channelEgressKind :: OutputKind
kawaDigestKind = known "kawa.digest"
kizashiSignalKind = known "kizashi.signal"
reiActionKind = known "rei.action"
danwaConversationKind = known "danwa.conversation"
channelEgressKind = known "channel.egress"

kikanOutputKinds :: [OutputKind]
kikanOutputKinds = [kawaDigestKind, kizashiSignalKind, reiActionKind, danwaConversationKind, channelEgressKind]

known :: Text -> OutputKind
known = either (error . Text.unpack) id . mkOutputKind

-- | One C1 activity envelope in Kawa per run.
data KawaDigestOutput = KawaDigestOutput
  { subjectType :: !(ActivityCoordinate "subject-kind"),
    verb :: !(ActivityCoordinate "verb")
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | One C4 signal in Kizashi.
data KizashiSignalOutput = KizashiSignalOutput
  { source :: !(ActivityCoordinate "source"),
    signalType :: !SignalType,
    priority :: !Priority,
    importance :: !SignalImportance,
    -- | How to find the recipient from the trigger activity.
    recipientFrom :: !RecipientFrom,
    defaultRecipient :: !(Maybe (DeclarationCoordinate "recipient")),
    intentTemplate :: !Text,
    extraContextTags :: ![Text],
    -- | An exact recipient chosen by the producer, which wins over the
    -- strategy. Flows set it from trusted configuration, never from a payload.
    recipient :: !(Maybe (DeclarationCoordinate "recipient"))
  }
  deriving stock (Eq, Show, Generic)

-- | One action against a Rei intention, over the legacy ingestion protocol.
data ReiActionOutput = ReiActionOutput
  { intentionId :: !(DeclarationCoordinate "intention"),
    note :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A concrete Danwa thread target. A parent message id means "reply under
-- that message"; absent parent means "post a top-level message in the
-- conversation".
data DanwaTarget = DanwaTarget
  { conversationId :: !(DeclarationCoordinate "danwa-conversation"),
    parentMessageId :: !(Maybe (DeclarationCoordinate "danwa-message"))
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A Danwa post: into @thread@ when it is set, otherwise into a fresh
-- thread whose opening line is the topic.
data DanwaConversationOutput = DanwaConversationOutput
  { topic :: !Text,
    thread :: !(Maybe DanwaTarget)
  }
  deriving stock (Eq, Show, Generic)

-- | One guarded channel action through Kanmon.
data ChannelEgressOutput = ChannelEgressOutput
  { channel :: !(DeclarationCoordinate "channel"),
    action :: !(DeclarationCoordinate "channel-action"),
    conversationKey :: !(Maybe (DeclarationCoordinate "conversation"))
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON KizashiSignalOutput where
  toJSON KizashiSignalOutput {source, signalType, priority, importance, recipientFrom, defaultRecipient, intentTemplate, extraContextTags, recipient} =
    object
      ( [ "source" .= source,
          "signalType" .= signalType,
          "priority" .= priority,
          "importance" .= importance,
          "recipientFrom" .= recipientFrom,
          "defaultRecipient" .= defaultRecipient,
          "intentTemplate" .= intentTemplate,
          "extraContextTags" .= extraContextTags
        ]
          <> ["recipient" .= value | Just value <- [recipient]]
      )

instance FromJSON KizashiSignalOutput where
  parseJSON = withObject "kizashi.signal" \fields ->
    KizashiSignalOutput
      <$> fields .: "source"
      <*> fields .: "signalType"
      <*> fields .: "priority"
      <*> fields .: "importance"
      <*> fields .: "recipientFrom"
      <*> fields .:? "defaultRecipient"
      <*> fields .: "intentTemplate"
      <*> (fromMaybe [] <$> fields .:? "extraContextTags")
      <*> fields .:? "recipient"

instance ToJSON DanwaConversationOutput where
  toJSON DanwaConversationOutput {topic, thread} = object (["topic" .= topic] <> ["thread" .= value | Just value <- [thread]])

instance FromJSON DanwaConversationOutput where
  parseJSON = withObject "danwa.conversation" \fields -> DanwaConversationOutput <$> (fromMaybe "" <$> fields .:? "topic") <*> fields .:? "thread"

instance ToJSON ChannelEgressOutput where
  toJSON ChannelEgressOutput {channel, action, conversationKey} =
    object (["channel" .= channel, "action" .= action] <> ["conversationKey" .= value | Just value <- [conversationKey]])

instance FromJSON ChannelEgressOutput where
  parseJSON = withObject "channel.egress" \fields -> ChannelEgressOutput <$> fields .: "channel" <*> fields .: "action" <*> fields .:? "conversationKey"

kawaDigestOutput :: KawaDigestOutput -> OutputDecl
kawaDigestOutput = OutputDecl kawaDigestKind . Aeson.toJSON

kizashiSignalOutput :: KizashiSignalOutput -> OutputDecl
kizashiSignalOutput = OutputDecl kizashiSignalKind . Aeson.toJSON

reiActionOutput :: ReiActionOutput -> OutputDecl
reiActionOutput = OutputDecl reiActionKind . Aeson.toJSON

danwaConversationOutput :: DanwaConversationOutput -> OutputDecl
danwaConversationOutput = OutputDecl danwaConversationKind . Aeson.toJSON

channelEgressOutput :: ChannelEgressOutput -> OutputDecl
channelEgressOutput = OutputDecl channelEgressKind . Aeson.toJSON

-- | Read an output's configuration as its typed form.
decodeOutputConfig :: (FromJSON a) => OutputKind -> Value -> Either Text a
decodeOutputConfig kind config = case parseEither Aeson.parseJSON config of
  Left problem -> Left ("output " <> outputKindText kind <> ": " <> Text.pack problem)
  Right value -> Right value

-- | Send a signal to exactly this recipient. Any other output is returned
-- unchanged.
toRecipient :: DeclarationCoordinate "recipient" -> OutputDecl -> OutputDecl
toRecipient recipient = setField kizashiSignalKind "recipient" (Aeson.toJSON recipient)

-- | Post a Danwa output into this thread. Any other output is returned
-- unchanged.
inThread :: DanwaTarget -> OutputDecl -> OutputDecl
inThread target = setField danwaConversationKind "thread" (Aeson.toJSON target)

setField :: OutputKind -> Aeson.Key -> Value -> OutputDecl -> OutputDecl
setField kind key value decl@OutputDecl {kind = declared, config}
  | declared /= kind = decl
  | Object fields <- config = OutputDecl {kind = declared, config = Object (KeyMap.insert key value fields)}
  | otherwise = decl

-- | What no runtime can fix in a configuration: it does not decode, a
-- signal routes by an ownership directory that does not exist and names
-- nobody to fall back to, or a channel route segment is malformed. A kind
-- this module does not know has no errors here; its adapter validates it.
outputConfigErrors :: OutputDecl -> [Text]
outputConfigErrors OutputDecl {kind, config}
  | kind == kawaDigestKind = decoded \KawaDigestOutput {subjectType, verb} ->
      [ field <> " must be a non-empty string of at most 128 characters"
      | (field, value) <- [("subjectType", activityCoordinateText subjectType), ("verb", activityCoordinateText verb)],
        Text.null (Text.strip value) || Text.length value > 128
      ]
  | kind == kizashiSignalKind = decoded \KizashiSignalOutput {recipientFrom, defaultRecipient, recipient} ->
      [ "recipientFrom=" <> Text.pack (show recipientFrom) <> " requires defaultRecipient (no ownership directory exists to resolve it)"
      | needsDirectory recipientFrom,
        isNothing defaultRecipient,
        isNothing recipient
      ]
  | kind == reiActionKind = decoded (const [] :: ReiActionOutput -> [Text])
  | kind == danwaConversationKind = decoded (const [] :: DanwaConversationOutput -> [Text])
  | kind == channelEgressKind = decoded \ChannelEgressOutput {channel, action, conversationKey} ->
      routeErrors "channel" (declarationCoordinateText channel)
        <> routeErrors "action" (declarationCoordinateText action)
        <> ["conversationKey must be non-empty when declared" | maybe False (Text.null . Text.strip . declarationCoordinateText) conversationKey]
  | otherwise = []
  where
    decoded :: (FromJSON a) => (a -> [Text]) -> [Text]
    decoded check = either pure check (decodeOutputConfig kind config)

-- | Which strategies name a person this platform has no way to look up.
needsDirectory :: RecipientFrom -> Bool
needsDirectory = \case
  SubjectOwner -> True
  AreaOwner -> True
  Actor -> False

-- | Validate one path component in Kanmon's channel-action route. The client
-- repeats this check at publication so corrupted durable data cannot inject a
-- slash, query, or traversal-like path after declaration validation has passed.
validateKanmonRouteSegment :: Text -> Either Text Text
validateKanmonRouteSegment segment
  | Text.null segment = Left "must be non-empty"
  | Text.all isAllowed segment = Right segment
  | otherwise = Left "must contain only ASCII letters, digits, '.', '_', or '-'"
  where
    isAllowed char =
      ('a' <= char && char <= 'z')
        || ('A' <= char && char <= 'Z')
        || ('0' <= char && char <= '9')
        || char `elem` ("._-" :: String)

routeErrors :: Text -> Text -> [Text]
routeErrors field value =
  case validateKanmonRouteSegment value of
    Left reason -> [field <> " " <> reason]
    Right _ -> []

-- | The output a legacy sink declares.
sinkOutput :: Sink -> OutputDecl
sinkOutput = \case
  KawaDigest {subjectType, verb} -> kawaDigestOutput KawaDigestOutput {subjectType, verb}
  KizashiSignal {source, signalType, priority, importance, recipientFrom, defaultRecipient, intentTemplate, extraContextTags} ->
    kizashiSignalOutput KizashiSignalOutput {source, signalType, priority, importance, recipientFrom, defaultRecipient, intentTemplate, extraContextTags, recipient = Nothing}
  ReiAction {intentionId, note} -> reiActionOutput ReiActionOutput {intentionId, note}
  DanwaConversation {topic} -> danwaConversationOutput DanwaConversationOutput {topic, thread = Nothing}
  ChannelEgress {channel, action, conversationKey} -> channelEgressOutput ChannelEgressOutput {channel, action, conversationKey}

-- | Every output a declaration lists: its legacy sinks, then its outputs.
declarationOutputs :: AgentDecl -> [OutputDecl]
declarationOutputs AgentDecl {sinks, outputs} = (sinkOutput <$> sinks) <> outputs

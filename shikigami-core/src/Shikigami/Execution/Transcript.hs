-- | Application replay records. No decoder for Baikai Response, Context,
-- Options or ModelCallEvidence is implied by these codecs.
module Shikigami.Execution.Transcript where

import Baikai.Api (Api)
import Baikai.Content qualified as Content
import Baikai.Context qualified as Context
import Baikai.Error qualified as Error
import Baikai.Message qualified as Message
import Baikai.Model qualified as Model
import Baikai.Response qualified as Response
import Baikai.StopReason (StopReason (..))
import Baikai.Usage (zeroUsage)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Kioku.Id (SessionId)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Attestation.Envelope (profileDigest)
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile (..))
import Shikigami.Capability.Overlay (ResolvedCapabilitySet)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Prelude hiding (Options)

newtype ExecutionId = ExecutionId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

executionIdFor :: Text -> ExecutionId
executionIdFor assignment = ExecutionId ("execution:" <> versionedDigest "shikigami.execution/1" (toJSON assignment))

operationIdFor :: ExecutionId -> Integer -> OperationId
operationIdFor execution cursor = OperationId ("operation:" <> versionedDigest "shikigami.execution-operation/1" (toJSON (execution, cursor)))

data PayloadRef = PayloadRef
  { payloadId :: !Text,
    digest :: !Text,
    bytes :: !Integer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ProviderReplay = ProviderReplay
  { api :: !Api,
    model :: !Text,
    items :: ![Aeson.Value]
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ProviderReplay where show _ = "ProviderReplay <protected>"

data ToolInvocation = ToolInvocation
  { callId :: !Text,
    name :: !Text,
    arguments :: !Aeson.Value
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ToolInvocation where show invocation = "ToolInvocation " <> show invocation.name <> " <protected>"

data ReplayBlock
  = TextBlock !Text
  | ThinkingBlock !Text !(Maybe Text) !Bool !(Maybe ProviderReplay)
  | ToolBlock !ToolInvocation
  | ImageBlock !Content.ImageContent
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ReplayBlock where show _ = "ReplayBlock <protected>"

data ReplayAssistant = ReplayAssistant
  { format :: !Int,
    blocks :: ![ReplayBlock],
    stopReason :: !StopReason,
    responseId :: !(Maybe Text),
    timestamp :: !(Maybe UTCTime),
    usage :: !Aeson.Value,
    failure :: !(Maybe (Bool, Text))
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance Show ReplayAssistant where show assistant = "ReplayAssistant " <> show assistant.format <> " <protected>"

instance FromJSON ReplayAssistant where
  parseJSON value = do
    assistant <- Aeson.genericParseJSON Aeson.defaultOptions value
    unless (assistant.format == 1) (fail "unsupported assistant replay version")
    unless (length assistant.blocks <= 256 && all assistantBlock assistant.blocks) (fail "unsupported assistant replay blocks")
    pure assistant
    where
      assistantBlock ImageBlock {} = False
      assistantBlock _ = True

data ReplayMessage
  = UserTurn ![ReplayBlock] !(Maybe UTCTime)
  | AssistantTurn !ReplayAssistant
  | ToolTurn !Text !Text ![ReplayBlock] !Bool !(Maybe UTCTime)
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ReplayMessage where show _ = "ReplayMessage <protected>"

data ReplayContext = ReplayContext
  { format :: !Int,
    systemPrompt :: !(Maybe Text),
    messages :: ![ReplayMessage]
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance Show ReplayContext where show context = "ReplayContext " <> show context.format <> " <protected>"

instance FromJSON ReplayContext where
  parseJSON value = do
    context <- Aeson.genericParseJSON Aeson.defaultOptions value
    unless (context.format == 1 && length context.messages <= 10000) (fail "unsupported context replay version or size")
    either (const (fail "unsupported context replay content")) (const (pure context)) (restoreContext context)

data SkillInstructions = SkillInstructions
  { name :: !Text,
    description :: !Text,
    body :: !Text
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show SkillInstructions where show _ = "SkillInstructions <protected>"

data ExecutionSnapshot = ExecutionSnapshot
  { format :: !Int,
    executionId :: !ExecutionId,
    runId :: !Text,
    agent :: !AgentName,
    identity :: !AgentIdentity,
    sessionId :: !SessionId,
    selection :: !ExecutionSelection,
    sanctionedProfile :: !(Maybe ResolvedProfile),
    instructions :: !SkillInstructions,
    initialContext :: !ReplayContext,
    capabilities :: !ResolvedCapabilitySet,
    offeredTools :: !Aeson.Value,
    policy :: !HarnessPolicy
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance Show ExecutionSnapshot where show snapshot = "ExecutionSnapshot " <> show snapshot.executionId <> " <protected>"

instance FromJSON ExecutionSnapshot where
  parseJSON value = do
    snapshot <- Aeson.genericParseJSON Aeson.defaultOptions value
    unless (snapshot.format == 1 && snapshot.executionId == executionIdFor snapshot.selection.assignmentId && snapshot.selection.profile == ((.ref) <$> snapshot.sanctionedProfile)) (fail "unsupported execution snapshot version or identity")
    unless (maybe True (\resolved -> resolved.ref.profileId == resolved.profile.profileId && resolved.ref.version == resolved.profile.version && resolved.ref.digest == profileDigest resolved.profile) snapshot.sanctionedProfile) (fail "execution profile content differs from its immutable reference")
    pure snapshot

validateSnapshot :: ExecutionSnapshot -> Either ExecutionError ()
validateSnapshot snapshot = case Aeson.fromJSON (toJSON snapshot) of
  Aeson.Success decoded | decoded == snapshot -> Right ()
  _ -> Left UnsupportedReplay

data ExecutionPhase = Active | Parked | Unresolved | Succeeded | Failed | Cancelled
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data NextWork = NeedModel | NeedTool !PayloadRef !Int | NeedValidation !PayloadRef | WorkFinished
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ExecutionState = ExecutionState
  { format :: !Int,
    executionId :: !ExecutionId,
    revision :: !Integer,
    phase :: !ExecutionPhase,
    cursor :: !Integer,
    next :: !NextWork,
    snapshot :: !PayloadRef,
    activeOperation :: !(Maybe OperationId),
    result :: !(Maybe PayloadRef),
    repairs :: !Int,
    modelTurns :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON ExecutionState where
  parseJSON value = do
    state <- Aeson.genericParseJSON Aeson.defaultOptions value
    unless (state.format == 1 && state.revision >= 0 && state.cursor >= 0 && state.cursor <= 10000) (fail "unsupported execution state version or cursor")
    pure state

data OperationKind = ModelTurn | ToolOperation | ModelSummary
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data OperationSpec = OperationSpec
  { operationId :: !OperationId,
    kind :: !OperationKind,
    recovery :: !RecoveryClass,
    name :: !Text,
    policyDigest :: !Text,
    scopeDigest :: !Text,
    responsePosition :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Operation = Operation
  { format :: !Int,
    executionId :: !ExecutionId,
    position :: !Integer,
    specification :: !OperationSpec,
    fingerprint :: !Text,
    input :: !PayloadRef,
    outcome :: !(Maybe PayloadRef),
    continuation :: !(Maybe NextWork),
    uncertain :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON Operation where
  parseJSON value = do
    operation <- Aeson.genericParseJSON Aeson.defaultOptions value
    unless (operation.format == 1 && operation.position >= 0 && operation.specification.operationId == operationIdFor operation.executionId operation.position) (fail "unsupported operation version or identity")
    pure operation

data OperationOutcome
  = ModelReturned !ReplayAssistant !(Maybe Aeson.Value)
  | ToolReturned ![ReplayBlock] !Bool
  | OperationDenied !Text
  | OperationUnresolved !Text
  | TerminalResult !Aeson.Value
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show OperationOutcome where show _ = "OperationOutcome <protected>"

data ExecutionError
  = ExecutionMissing
  | ExecutionIdentityConflict
  | ExecutionRevisionConflict
  | ExecutionNotActive
  | OperationMissing
  | OperationConflict
  | UnresolvedOperation
  | UnsupportedReplay
  | CorruptReplay
  | ReplayReadRefused
  | PayloadTooLarge
  | ResourceAdmissionRefused !Text
  | ProjectionUnavailable
  | ExecutionCommandRefused
  | ExecutionOutputInvalid
  | ExecutionStorageUnavailable
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

captureAssistant :: Response.Response -> ReplayAssistant
captureAssistant response =
  ReplayAssistant
    { format = 1,
      blocks = map assistantBlock (Vector.toList response.message.content),
      stopReason = response.message.stopReason,
      responseId = response.responseId,
      timestamp = response.message.timestamp,
      usage = toJSON response.message.usage,
      failure = (\err -> (Error.isRetryable err, Text.take 512 (Error.message err))) <$> Response.responseError response
    }
  where
    assistantBlock = \case
      Content.AssistantText text -> TextBlock text.text
      Content.AssistantToolCall call -> ToolBlock (ToolInvocation call.id_ call.name call.arguments)
      Content.AssistantThinking thinking -> ThinkingBlock thinking.thinking thinking.signature thinking.redacted (replay <$> thinking.replayState)
    replay value = ProviderReplay value.replayApi value.replayModel (Vector.toList value.replayItems)

restoreAssistant :: ReplayAssistant -> Either ExecutionError Message.AssistantPayload
restoreAssistant assistant = do
  unless (assistant.format == 1) (Left UnsupportedReplay)
  blocks <- traverse restore assistant.blocks
  pure
    Message.AssistantPayload
      { Message.content = Vector.fromList blocks,
        -- Provider request history does not consume measured usage. Preserve its
        -- original JSON above; policy/accounting use the durable normalized facts.
        Message.usage = zeroUsage,
        Message.stopReason = assistant.stopReason,
        Message.errorMessage = snd <$> assistant.failure,
        Message.timestamp = assistant.timestamp
      }
  where
    restore = \case
      TextBlock text -> Right (Content.AssistantText (Content.TextContent text))
      ThinkingBlock text signature redacted replay -> Right (Content.AssistantThinking (Content.ThinkingContent text signature redacted ((\value -> Content.ThinkingReplay value.api value.model (Vector.fromList value.items)) <$> replay)))
      ToolBlock call -> Right (Content.AssistantToolCall (Content.ToolCall call.callId call.name call.arguments))
      ImageBlock {} -> Left UnsupportedReplay

restoreContext :: ReplayContext -> Either ExecutionError Context.Context
restoreContext context = do
  unless (context.format == 1) (Left UnsupportedReplay)
  messages <- traverse restore context.messages
  pure (Context.emptyContext & #systemPrompt .~ context.systemPrompt & #messages .~ Vector.fromList messages)
  where
    restore = \case
      AssistantTurn assistant -> Message.AssistantMessage <$> restoreAssistant assistant
      UserTurn blocks timestamp -> do
        content <- traverse user blocks
        pure (Message.UserMessage (Message.UserPayload (Vector.fromList content) timestamp))
      ToolTurn callId name blocks failed timestamp -> do
        content <- traverse tool blocks
        pure (Message.ToolResultMessage (Message.ToolResultPayload callId name (Vector.fromList content) failed timestamp))
    user (TextBlock text) = Right (Content.UserText (Content.TextContent text))
    user (ImageBlock image) = Right (Content.UserImage image)
    user _ = Left UnsupportedReplay
    tool (TextBlock text) = Right (Content.ToolResultText (Content.TextContent text))
    tool (ImageBlock image) = Right (Content.ToolResultImage image)
    tool _ = Left UnsupportedReplay

toolInvocations :: ReplayAssistant -> [ToolInvocation]
toolInvocations assistant = [call | ToolBlock call <- assistant.blocks]

assistantText :: ReplayAssistant -> Text
assistantText assistant = Text.concat [text | TextBlock text <- assistant.blocks]

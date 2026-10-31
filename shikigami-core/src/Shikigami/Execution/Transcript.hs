{-# LANGUAGE DataKinds #-}

-- | Application replay records. No decoder for Baikai Response, Context,
-- Options or ModelCallEvidence is implied by these codecs.
module Shikigami.Execution.Transcript where

import Baikai.Api (Api)
import Baikai.Content qualified as Content
import Baikai.Context qualified as Context
import Baikai.Error qualified as Error
import Baikai.Message qualified as Message
import Baikai.Response qualified as Response
import Baikai.StopReason (StopReason (..))
import Baikai.Tool qualified as BaikaiTool
import Baikai.Usage (zeroUsage)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID
import Data.Vector qualified as Vector
import Keiki.Shape (CanonicalTypeName (..))
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.Id (SessionId)
import Shikigami.Agent.Approval (ReviewRequestId)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Attestation.Envelope (profileDigest)
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile (..))
import Shikigami.Capability.Overlay (ResolvedCapabilitySet)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.AssignmentKey (AssignmentKey)
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Progress
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.ToolPosition
import Shikigami.Prelude hiding (Options)
import Shikigami.StateRevision
import Shikigami.Workspace.Instructions (WorkspaceAdmission (..), instructionPrompt)
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikumi.Tool.Output qualified as Tool

newtype ExecutionId = ExecutionId {value :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

executionIdFor :: AssignmentKey -> ExecutionId
executionIdFor assignment = ExecutionId ("execution:" <> versionedDigest "shikigami.execution/1" (toJSON assignment))

-- Technical journal identity is independent of resource keys, whose digest
-- prefixes contain separators reserved by Keiro's stream naming protocol.
executionWorkflowId :: ExecutionId -> WorkflowId
executionWorkflowId execution = WorkflowId (UUID.toText (UUID.generateNamed UUID.namespaceURL (nameBytes ("shikigami.execution:" <> execution.value))))

operationIdFor :: ExecutionId -> StateRevision "execution-operation" -> OperationId
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
  | RequestTurn ![ReplayBlock] !(Maybe UTCTime)
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
    unless (validContextHeader context) (fail "unsupported context replay version or request anchor")
    either (const (fail "unsupported context replay content")) (const (pure context)) (restoreContext context)

-- Version 1 keeps its original first-user anchor. Version 2 marks the current
-- request explicitly, so earlier conversation turns can remain chronological
-- and compactable without losing that request on later model/tool turns.
contextRequest :: [ReplayMessage] -> Maybe ReplayMessage
contextRequest messages = listToMaybe [message | message@RequestTurn {} <- messages] <|> listToMaybe [message | message@UserTurn {} <- messages]

validContextHeader :: ReplayContext -> Bool
validContextHeader context =
  length context.messages <= 10000 && case context.format of
    1 -> requests == 0
    2 -> requests == 1
    _ -> False
  where
    requests = length [() | RequestTurn {} <- context.messages]

data SkillInstructions = SkillInstructions
  { name :: !Text,
    description :: !Text,
    body :: !Text
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show SkillInstructions where show _ = "SkillInstructions <protected>"

data ToolBinding = ToolBinding
  { name :: !Text,
    revision :: !Text,
    schemaDigest :: !Text,
    recovery :: !RecoveryClass,
    invoiceCost :: !ToolInvoiceCost
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ToolBinding where
  toJSON binding = case Aeson.genericToJSON Aeson.defaultOptions binding of
    Aeson.Object fields | binding.invoiceCost == UnreportedInvoiceCost -> Aeson.Object (KeyMap.delete "invoiceCost" fields)
    value -> value

instance FromJSON ToolBinding where
  parseJSON = Aeson.withObject "ToolBinding" \fields -> Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object (if KeyMap.member "invoiceCost" fields then fields else KeyMap.insert "invoiceCost" (toJSON UnreportedInvoiceCost) fields))

data ToolOperationInput = ToolOperationInput
  { response :: !PayloadRef,
    position :: !ToolPosition,
    invocation :: !ToolInvocation,
    binding :: !ToolBinding
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ToolOperationInput where show _ = "ToolOperationInput <protected>"

-- The accepted assistant owns the list bound; the position owns its scalar bound.
toolContinuation :: ToolOperationInput -> ReplayAssistant -> NextWork
toolContinuation input assistant = case nextToolPosition input.position of
  Just position | toolPositionNumber position < length (toolInvocations assistant) -> NeedTool input.response position
  _ -> NeedModel

toolScopeDigest :: ToolBinding -> Text
toolScopeDigest = versionedDigest "shikigami.execution-tool-scope/1" . toJSON

data PermissionResolution = PermissionApproved | PermissionDenied | PermissionExpired
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data PermissionBinding = PermissionBinding
  { reviewRequestId :: !ReviewRequestId,
    fingerprint :: !Text,
    scopeDigest :: !Text,
    policyDigest :: !Text,
    expiresAt :: !UTCTime,
    resolution :: !(Maybe PermissionResolution)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

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
    policy :: !HarnessPolicy,
    toolBindings :: ![ToolBinding],
    workspace :: !(Maybe WorkspaceAdmission)
  }
  deriving stock (Eq, Generic)

instance ToJSON ExecutionSnapshot where
  toJSON snapshot = case Aeson.genericToJSON Aeson.defaultOptions snapshot of
    Aeson.Object fields -> Aeson.Object ((if isNothing snapshot.workspace then KeyMap.delete "workspace" else id) ((if null snapshot.toolBindings then KeyMap.delete "toolBindings" else id) fields))
    value -> value

instance Show ExecutionSnapshot where show snapshot = "ExecutionSnapshot " <> show snapshot.executionId <> " <protected>"

instance FromJSON ExecutionSnapshot where
  parseJSON = Aeson.withObject "ExecutionSnapshot" \fields -> do
    let defaults = (if KeyMap.member "workspace" fields then id else KeyMap.insert "workspace" Aeson.Null) (if KeyMap.member "toolBindings" fields then fields else KeyMap.insert "toolBindings" (toJSON ([] :: [ToolBinding])) fields)
    snapshot <- Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object defaults)
    unless (snapshot.format == 1 && snapshot.executionId == executionIdFor snapshot.selection.assignmentId && snapshot.selection.profile == ((.ref) <$> snapshot.sanctionedProfile)) (fail "unsupported execution snapshot version or identity")
    unless (maybe True (\resolved -> resolved.ref.profileId == resolved.profile.profileId && resolved.ref.version == resolved.profile.version && resolved.ref.digest == profileDigest resolved.profile) snapshot.sanctionedProfile) (fail "execution profile content differs from its immutable reference")
    case snapshot.selection.effectiveOptions of
      Aeson.Object options -> unless (all (\key -> case KeyMap.lookup key options of Nothing -> True; Just Aeson.Null -> True; Just (Aeson.Object fields) -> KeyMap.null fields; _ -> False) ["headers", "metadata", "apiKey"]) (fail "execution snapshot contains unsupported private model options")
      _ -> fail "execution snapshot options are unsupported"
    unless (length snapshot.toolBindings <= 128 && length (nub (map (\(binding :: ToolBinding) -> binding.name) snapshot.toolBindings)) == length snapshot.toolBindings && all validBinding snapshot.toolBindings) (fail "invalid immutable tool bindings")
    unless (null snapshot.toolBindings) $ case Aeson.fromJSON snapshot.offeredTools of
      Aeson.Success tools -> unless (sort (map (\(tool :: BaikaiTool.Tool) -> tool.name) tools) == sort (map (\(binding :: ToolBinding) -> binding.name) snapshot.toolBindings) && all (\(tool :: BaikaiTool.Tool) -> any (\(binding :: ToolBinding) -> binding.name == tool.name && binding.schemaDigest == versionedDigest "shikigami.tool-schema/1" tool.parameters) snapshot.toolBindings) tools) (fail "execution tool bindings differ from the frozen menu")
      Aeson.Error _ -> fail "execution tool menu is unsupported"
    forM_ snapshot.workspace \admission -> do
      unless (admission.runId == snapshot.runId && admission.assignmentId == snapshot.selection.assignmentId && Just admission.rootId == snapshot.selection.rootId && admission.owner == snapshot.identity) (fail "workspace differs from its accepted execution")
      unless (admission.workspace.provider == "shikigami.workspace/1" && not (Text.null admission.workspace.resource) && Text.length admission.workspace.resource <= 128 && Text.length admission.bindingDigest == 71 && "sha256:" `Text.isPrefixOf` admission.bindingDigest) (fail "unsupported workspace binding")
      unless (maybe False (instructionPrompt admission.instructions `Text.isSuffixOf`) snapshot.initialContext.systemPrompt) (fail "workspace instructions are absent from fixed context")
    pure snapshot
    where
      validBinding binding = all (\value -> not (Text.null value) && Text.length value <= 256) [binding.name, binding.revision, binding.schemaDigest]

validateSnapshot :: ExecutionSnapshot -> Either ExecutionError ()
validateSnapshot snapshot = case Aeson.fromJSON (toJSON snapshot) of
  Aeson.Success decoded | decoded == snapshot -> Right ()
  _ -> Left UnsupportedReplay

-- A command's terminal choice is distinct from resource-root cancellation.
data Termination = StopAsFailure | StopAsCancelled
  deriving stock (Eq, Show)

data ExecutionPhase = Active | Parked | Unresolved | Succeeded | Failed | Cancelled
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data NextWork = NeedModel | NeedTool !PayloadRef !ToolPosition | NeedValidation !PayloadRef | WorkFinished
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ExecutionState = ExecutionState
  { format :: !Int,
    executionId :: !ExecutionId,
    revision :: !(StateRevision "execution"),
    phase :: !ExecutionPhase,
    cursor :: !(StateRevision "execution-operation"),
    next :: !NextWork,
    snapshot :: !PayloadRef,
    activeOperation :: !(Maybe OperationId),
    result :: !(Maybe PayloadRef),
    repairs :: !RepairCount,
    modelTurns :: !ModelTurnCount,
    wake :: !(Maybe PayloadRef),
    failure :: !(Maybe ExecutionError),
    pendingReceipts :: !PendingReceiptCount
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ExecutionState where
  toJSON state = case Aeson.genericToJSON Aeson.defaultOptions state of
    Aeson.Object raw -> let fields = if state.pendingReceipts == noPendingReceipts then KeyMap.delete "pendingReceipts" raw else raw in Aeson.Object (if isNothing state.failure then KeyMap.delete "failure" (if isNothing state.wake then KeyMap.delete "wake" fields else fields) else if isNothing state.wake then KeyMap.delete "wake" fields else fields)
    value -> value

instance FromJSON ExecutionState where
  parseJSON = Aeson.withObject "ExecutionState" \fields -> do
    state <- Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object (foldr (\key current -> if KeyMap.member key current then current else KeyMap.insert key Aeson.Null current) (if KeyMap.member "pendingReceipts" fields then fields else KeyMap.insert "pendingReceipts" (toJSON (0 :: Int)) fields) ["wake", "failure"]))
    unless (state.format == 1 && revisionNumber state.cursor <= 10000) (fail "unsupported execution state version or cursor")
    pure state

data OperationKind = ModelTurn | ToolOperation | ModelSummary | ModelRepair
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data OperationSpec = OperationSpec
  { operationId :: !OperationId,
    kind :: !OperationKind,
    recovery :: !RecoveryClass,
    name :: !Text,
    policyDigest :: !Text,
    scopeDigest :: !Text,
    responsePosition :: !(Maybe ToolPosition)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Operation = Operation
  { format :: !Int,
    executionId :: !ExecutionId,
    position :: !(StateRevision "execution-operation"),
    specification :: !OperationSpec,
    fingerprint :: !Text,
    input :: !PayloadRef,
    outcome :: !(Maybe PayloadRef),
    continuation :: !(Maybe NextWork),
    uncertain :: !Bool,
    permission :: !(Maybe PermissionBinding)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Operation where
  toJSON operation = case Aeson.genericToJSON Aeson.defaultOptions operation of
    Aeson.Object fields | isNothing operation.permission -> Aeson.Object (KeyMap.delete "permission" fields)
    value -> value

instance FromJSON Operation where
  parseJSON = Aeson.withObject "Operation" \fields -> do
    operation <- Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object (if KeyMap.member "permission" fields then fields else KeyMap.insert "permission" Aeson.Null fields))
    unless (operation.format == 1 && operation.specification.operationId == operationIdFor operation.executionId operation.position) (fail "unsupported operation version or identity")
    pure operation

data ReplayToolResult = ReplayToolResult
  { format :: !Int,
    blocks :: ![ReplayBlock],
    failed :: !Bool,
    structuredContent :: !(Maybe Aeson.Value),
    extensionBlocks :: ![Aeson.Value]
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance Show ReplayToolResult where show _ = "ReplayToolResult <protected>"

instance FromJSON ReplayToolResult where
  parseJSON value = do
    result <- Aeson.genericParseJSON Aeson.defaultOptions value
    unless (result.format == 1 && length result.blocks <= 256 && length result.extensionBlocks <= 128 && all valid result.blocks) (fail "unsupported tool observation")
    pure result
    where
      valid (TextBlock _) = True; valid ImageBlock {} = True; valid _ = False

captureToolOutput :: Tool.ToolOutput -> ReplayToolResult
captureToolOutput output = ReplayToolResult 1 (map capture (Vector.toList output.result.content)) output.result.isError output.structuredContent output.extensionBlocks
  where
    capture (Content.ToolResultText text) = TextBlock text.text
    capture (Content.ToolResultImage image) = ImageBlock image

observationBlocks :: ReplayToolResult -> [ReplayBlock]
observationBlocks result = result.blocks <> maybe [] (\value -> [TextBlock ("Structured JSON: " <> render value)]) result.structuredContent <> map (TextBlock . ("Extension JSON: " <>) . render) result.extensionBlocks
  where
    render = Text.decodeUtf8 . Lazy.toStrict . Aeson.encode

data OperationOutcome
  = ModelReturned !ReplayAssistant !(Maybe Aeson.Value)
  | ToolReturned ![ReplayBlock] !Bool
  | RichToolReturned !ReplayToolResult
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
  | AttemptMissing
  | AttemptConflict
  | AttemptClaimLost
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
  | ExecutionPolicyRefused !Text
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
  unless (validContextHeader context) (Left UnsupportedReplay)
  messages <- traverse restore context.messages
  pure (Context.emptyContext & #systemPrompt .~ context.systemPrompt & #messages .~ Vector.fromList messages)
  where
    restore = \case
      RequestTurn blocks timestamp -> do
        content <- traverse user blocks
        pure (Message.UserMessage (Message.UserPayload (Vector.fromList content) timestamp))
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

instance CanonicalTypeName ExecutionId where
  canonicalTypeName _ = "shikigami.ExecutionId.v1"

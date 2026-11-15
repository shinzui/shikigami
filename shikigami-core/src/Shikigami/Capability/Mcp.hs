-- | MCP server bindings (ADR-65; EP-3 M2 of MasterPlan 22).
--
-- The operator's tools file holds each server's transport and the tools it
-- approves, each with its approved description, input schema and operation
-- class. A declaration names only a server and a subset of its approved
-- tools; it is offered as the overlay @mcp.<server>@. The binding's revision
-- digests the whole binding, so a changed schema is a new revision, and an
-- acquisition whose discovered tools differ from the approved ones refuses.
module Shikigami.Capability.Mcp
  ( McpServerId,
    mkMcpServerId,
    mcpServerIdText,
    McpToolName,
    mkMcpToolName,
    mcpToolNameText,
    McpToolRequest (..),
    McpArgument (..),
    ApprovedMcpTool (..),
    McpBinding (..),
    mcpCapabilityId,
    mcpBindingRevisionInput,
    approvedSchema,
    DiscoveredMcpTool (..),
    McpBindingMismatch (..),
    renderMcpBindingMismatch,
    verifyDiscoveredTools,
    DiscoveryStatus (..),
    discoveryStatus,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Char (isAlphaNum, isAsciiLower, isDigit)
import Data.List (find, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Dhall (FromDhall (..))
import Dhall qualified
import GHC.Generics (Generic)
import Shikigami.Capability.Overlay (CapabilityId, CapabilityOperationClass, mkCapabilityId)

-- | @[a-z][a-z0-9-]{0,31}@, the suffix of @mcp.<server>@.
newtype McpServerId = McpServerId Text
  deriving stock (Eq, Ord, Show)

mkMcpServerId :: Text -> Either Text McpServerId
mkMcpServerId value = case Text.uncons value of
  Just (first', rest) | isAsciiLower first', Text.length value <= 32, Text.all (\c -> isAsciiLower c || isDigit c || c == '-') rest -> Right (McpServerId value)
  _ -> Left ("MCP server id \"" <> value <> "\" must match [a-z][a-z0-9-]{0,31}")

mcpServerIdText :: McpServerId -> Text
mcpServerIdText (McpServerId value) = value

-- | The server's own tool name: @[A-Za-z0-9_.-]{1,64}@.
newtype McpToolName = McpToolName Text
  deriving stock (Eq, Ord, Show)

mkMcpToolName :: Text -> Either Text McpToolName
mkMcpToolName value
  | not (Text.null value) && Text.length value <= 64 && Text.all (\c -> (isAlphaNum c && c < '\x80') || c `elem` ['_', '.', '-']) value = Right (McpToolName value)
  | otherwise = Left ("MCP tool name \"" <> value <> "\" must match [A-Za-z0-9_.-]{1,64}")

mcpToolNameText :: McpToolName -> Text
mcpToolNameText (McpToolName value) = value

-- | What a declaration asks for: approved tools of one cataloged server.
data McpToolRequest = McpToolRequest
  { server :: !McpServerId,
    tools :: !(NonEmpty McpToolName)
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | A server argument: literal, or the run's workspace path, substituted only
-- at acquisition so the revision does not depend on any one run.
data McpArgument
  = LiteralArgument !Text
  | WorkspaceRootArgument
  deriving stock (Eq, Ord, Show, Generic)

data ApprovedMcpTool = ApprovedMcpTool
  { remoteName :: !McpToolName,
    description :: !Text,
    -- | The approved input schema, as JSON text.
    inputSchema :: !Text,
    operationClass :: !CapabilityOperationClass
  }
  deriving stock (Eq, Show, Generic)

data McpBinding = McpBinding
  { server :: !McpServerId,
    -- | The absolute path of the server executable (stdio transport).
    command :: !Text,
    arguments :: ![McpArgument],
    -- | Environment variable names passed through by name; values are never stored.
    environment :: ![Text],
    tools :: ![ApprovedMcpTool]
  }
  deriving stock (Eq, Show, Generic)

mcpCapabilityId :: McpServerId -> CapabilityId
mcpCapabilityId server = either (error . show) id (mkCapabilityId ("mcp." <> mcpServerIdText server))

-- | What the binding's revision digests: the binding with each schema
-- canonicalized and the tools sorted by name (ADR-65).
mcpBindingRevisionInput :: McpBinding -> Value
mcpBindingRevisionInput McpBinding {server, command, arguments, environment, tools} =
  object
    [ "server" .= mcpServerIdText server,
      "command" .= command,
      "arguments" .= (renderArgument <$> arguments),
      "environment" .= environment,
      "tools" .= [object ["remoteName" .= mcpToolNameText tool.remoteName, "description" .= tool.description, "inputSchema" .= approvedSchema tool, "operationClass" .= tool.operationClass] | tool <- sortOn (.remoteName) tools]
    ]
  where
    renderArgument = \case
      LiteralArgument value -> object ["literal" .= value]
      WorkspaceRootArgument -> object ["workspaceRoot" .= True]

-- | The approved schema as JSON, or the empty object when the text is not JSON.
approvedSchema :: ApprovedMcpTool -> Value
approvedSchema tool = maybe (object []) id (Aeson.decodeStrict (Text.Encoding.encodeUtf8 tool.inputSchema))

data DiscoveredMcpTool = DiscoveredMcpTool
  { name :: !Text,
    inputSchema :: !Value
  }
  deriving stock (Eq, Show)

data McpBindingMismatch
  = ApprovedToolMissing !McpToolName
  | ApprovedSchemaChanged !McpToolName
  | RequestedToolNotApproved !McpToolName
  deriving stock (Eq, Show)

renderMcpBindingMismatch :: McpBindingMismatch -> Text
renderMcpBindingMismatch = \case
  ApprovedToolMissing tool -> "approved tool " <> mcpToolNameText tool <> " is not offered by the server"
  ApprovedSchemaChanged tool -> "approved tool " <> mcpToolNameText tool <> " schema changed"
  RequestedToolNotApproved tool -> "tool " <> mcpToolNameText tool <> " is not approved in the binding"

-- | Every requested tool is approved, offered, and offered with exactly the
-- approved schema. Unapproved tools the server offers are ignored.
verifyDiscoveredTools :: McpBinding -> NonEmpty McpToolName -> [DiscoveredMcpTool] -> Either McpBindingMismatch ()
verifyDiscoveredTools binding requested discovered = mapM_ check requested
  where
    check tool = case find (\approved -> approved.remoteName == tool) binding.tools of
      Nothing -> Left (RequestedToolNotApproved tool)
      Just approved -> case find (\offered -> offered.name == mcpToolNameText tool) discovered of
        Nothing -> Left (ApprovedToolMissing tool)
        Just offered
          | offered.inputSchema == approvedSchema approved -> Right ()
          | otherwise -> Left (ApprovedSchemaChanged tool)

data DiscoveryStatus = Approved | ApprovedSchemaDiffers | NotApproved
  deriving stock (Eq, Show)

discoveryStatus :: McpBinding -> DiscoveredMcpTool -> DiscoveryStatus
discoveryStatus binding offered = case find (\approved -> mcpToolNameText approved.remoteName == offered.name) binding.tools of
  Nothing -> NotApproved
  Just approved
    | approvedSchema approved == offered.inputSchema -> Approved
    | otherwise -> ApprovedSchemaDiffers

checked :: (b -> Either Text a) -> Dhall.Decoder b -> Dhall.Decoder a
checked parse Dhall.Decoder {extract = readBase, expected} =
  Dhall.Decoder
    { extract = \expression -> case Dhall.toMonadic (readBase expression) of
        Left problem -> Dhall.fromMonadic (Left problem)
        Right value -> either Dhall.extractError pure (parse value),
      expected
    }

instance FromDhall McpServerId where autoWith _ = checked mkMcpServerId Dhall.strictText

instance FromDhall McpToolName where autoWith _ = checked mkMcpToolName Dhall.strictText

instance FromDhall McpArgument

instance FromDhall ApprovedMcpTool

instance FromDhall McpBinding

data McpToolRequestDhall = McpToolRequestDhall {server :: !McpServerId, tools :: ![McpToolName]}
  deriving stock (Generic)

instance FromDhall McpToolRequestDhall

instance FromDhall McpToolRequest where
  autoWith options = checked fromDhallForm (autoWith options)
    where
      fromDhallForm McpToolRequestDhall {server, tools} = case tools of
        first' : rest -> Right McpToolRequest {server, tools = first' :| rest}
        [] -> Left ("the MCP request for " <> mcpServerIdText server <> " names no tool")

instance ToJSON McpServerId where toJSON = toJSON . mcpServerIdText

instance FromJSON McpServerId where parseJSON = Aeson.withText "McpServerId" (either (fail . Text.unpack) pure . mkMcpServerId)

instance ToJSON McpToolName where toJSON = toJSON . mcpToolNameText

instance FromJSON McpToolName where parseJSON = Aeson.withText "McpToolName" (either (fail . Text.unpack) pure . mkMcpToolName)

instance ToJSON McpToolRequest

instance FromJSON McpToolRequest

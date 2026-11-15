-- | Declared tools inside a coding agent (EP-3 M3 of MasterPlan 22).
--
-- A coding agent runs its own commands, so its declared tools reach it as
-- configuration: Claude Code gets a PreToolUse hook that asks
-- 'decideGatedCall' about every shell and MCP call, and the MCP servers of its
-- requests as an MCP configuration. Shell access is exactly the declared CLI
-- tools: one plain command per call, whose first word is a declared
-- executable and whose arguments match a declared pattern. Everything here is
-- pure; the hook executable and the files are the host's.
module Shikigami.Capability.Declared.Gate
  ( GatedTools (..),
    GatedCall (..),
    GateRefusal (..),
    renderGateRefusal,
    ShellSyntax (..),
    parseSimpleCommand,
    decideGatedCall,
    claudeHookSettings,
    claudeMcpConfig,
    codexMcpArguments,
  )
where

import Data.Aeson (FromJSON, ToJSON, Value, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Char (isSpace)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Shikigami.Capability.Declared
import Shikigami.Capability.Mcp

-- | What a gate decides with: the run's declared tools, written by the
-- runner into the attempt directory.
data GatedTools = GatedTools
  { cli :: ![CliToolDecl],
    mcp :: ![McpToolRequest]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data GatedCall
  = -- | A shell command line the agent asked to run.
    ShellCall !Text
  | -- | A tool by the vendor's name, such as @mcp__git__git_status@.
    NamedToolCall !Text
  deriving stock (Eq, Show)

data ShellSyntax = CompoundCommand | Redirection | Substitution | Expansion | UnterminatedQuote | EmptyCommand
  deriving stock (Eq, Show)

data GateRefusal
  = UnsupportedShellSyntax !ShellSyntax
  | UndeclaredExecutable !Text
  | ArgumentsOutsidePatterns !Text
  | UndeclaredTool !Text
  deriving stock (Eq, Show)

renderGateRefusal :: GateRefusal -> Text
renderGateRefusal = \case
  UnsupportedShellSyntax syntax -> "unsupported shell syntax (" <> Text.pack (show syntax) <> "): issue one declared command per call, with no pipes, redirection, substitution or variables"
  UndeclaredExecutable executable -> "undeclared executable " <> executable
  ArgumentsOutsidePatterns tool -> "arguments outside declared patterns for " <> tool
  UndeclaredTool tool -> "tool " <> tool <> " is not declared for this run"

-- | Plain words, single-quoted words, and double-quoted words without @$@,
-- backticks or backslashes; nothing that a shell would combine or expand.
parseSimpleCommand :: Text -> Either ShellSyntax [Text]
parseSimpleCommand input = go (Text.unpack (Text.strip input)) [] Nothing
  where
    go [] acc current = case current of
      Nothing -> if null acc then Left EmptyCommand else Right (reverse acc)
      Just word -> Right (reverse (Text.pack (reverse word) : acc))
    go (c : rest) acc current
      | c `elem` [';', '&', '|'] = Left CompoundCommand
      | c `elem` ['<', '>'] = Left Redirection
      | c `elem` ['(', ')', '`'] = Left Substitution
      | c `elem` ['$', '\\', '*', '?', '~', '{', '}', '#', '!'] = Left Expansion
      | c == '\n' = Left CompoundCommand
      | isSpace c = go rest (maybe acc (\word -> Text.pack (reverse word) : acc) current) Nothing
      | c == '\'' = case break (== '\'') rest of
          (quoted, _ : after) -> go after acc (Just (reverse quoted <> maybe "" id current))
          _ -> Left UnterminatedQuote
      | c == '"' = case break (== '"') rest of
          (quoted, _ : after)
            | any (`elem` ['$', '`', '\\']) quoted -> Left Expansion
            | otherwise -> go after acc (Just (reverse quoted <> maybe "" id current))
          _ -> Left UnterminatedQuote
      | otherwise = go rest acc (Just (c : maybe "" id current))

-- | Admit a call only when it is exactly a declared tool.
decideGatedCall :: GatedTools -> GatedCall -> Either GateRefusal Text
decideGatedCall GatedTools {cli, mcp} = \case
  ShellCall line -> case parseSimpleCommand line of
    Left syntax -> Left (UnsupportedShellSyntax syntax)
    Right [] -> Left (UnsupportedShellSyntax EmptyCommand)
    Right (executable : arguments) -> case find (\tool -> executableRefText tool.executable == executable) cli of
      Nothing -> Left (UndeclaredExecutable executable)
      Just tool -> case decideCliArguments tool arguments of
        Left _ -> Left (ArgumentsOutsidePatterns (toolNameText tool.name))
        Right () -> Right (cliCapabilityName tool.name)
  NamedToolCall name -> case Text.splitOn "__" name of
    ["mcp", server, tool]
      | any (\request -> mcpServerIdText request.server == server && tool `elem` (mcpToolNameText <$> foldr (:) [] request.tools)) mcp -> Right ("mcp." <> server)
    _ -> Left (UndeclaredTool name)

-- | Claude Code @--settings@: every shell and MCP call goes through the gate.
claudeHookSettings :: Text -> Value
claudeHookSettings gateCommand =
  object
    [ "hooks"
        .= object
          [ "PreToolUse"
              .= [ object
                     [ "matcher" .= ("Bash|mcp__.*" :: Text),
                       "hooks" .= [object ["type" .= ("command" :: Text), "command" .= gateCommand]]
                     ]
                 ]
          ]
    ]

-- | Claude Code @--mcp-config@ for the requested servers, started in the
-- worktree. Environment values are copied from the run's environment by name.
claudeMcpConfig :: FilePath -> [(Text, Text)] -> [McpBinding] -> Value
claudeMcpConfig root environment bindings =
  object
    [ "mcpServers"
        .= object
          [ Key.fromText (mcpServerIdText binding.server)
              .= object
                [ "command" .= binding.command,
                  "args" .= (argumentText <$> binding.arguments),
                  "env" .= object [Key.fromText name .= value | (name, value) <- environment, name `elem` binding.environment]
                ]
          | binding <- bindings
          ]
    ]
  where
    argumentText = \case
      LiteralArgument value -> value
      WorkspaceRootArgument -> Text.pack root

-- | Codex @-c@ overrides that bind each requested server with only the
-- requested approved tools enabled.
codexMcpArguments :: FilePath -> [(McpBinding, McpToolRequest)] -> [Text]
codexMcpArguments root servers =
  concat
    [ [ "-c",
        prefix <> ".command=" <> tomlString binding.command,
        "-c",
        prefix <> ".args=[" <> Text.intercalate "," (tomlString . argumentText <$> binding.arguments) <> "]",
        "-c",
        prefix <> ".enabled_tools=[" <> Text.intercalate "," (tomlString . mcpToolNameText <$> foldr (:) [] request.tools) <> "]"
      ]
    | (binding, request) <- servers,
      let prefix = "mcp_servers." <> mcpServerIdText binding.server
    ]
  where
    argumentText = \case
      LiteralArgument value -> value
      WorkspaceRootArgument -> Text.pack root
    tomlString value = "\"" <> Text.replace "\"" "\\\"" (Text.replace "\\" "\\\\" value) <> "\""

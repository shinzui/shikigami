-- | A minimal MCP client over stdio and the provider of @mcp.<server>@
-- (ADR-65; EP-3 M2 of MasterPlan 22).
--
-- The client speaks newline-delimited JSON-RPC 2.0 to the bound server's
-- standard input and output: @initialize@, @notifications/initialized@,
-- @tools/list@ (following @nextCursor@ for a bounded number of pages) and
-- @tools/call@. Every request waits at most the call timeout. It supports no
-- HTTP, SSE or OAuth; it sits behind 'McpSession' so that Baikai's client can
-- replace it. The provider opens a session at acquisition, refuses when the
-- discovered tools differ from the approved ones, offers only the requested
-- approved tools with the approved descriptions and schemas, and closes the
-- server at release.
module Shikigami.Capability.Mcp.Local
  ( McpSession (..),
    openMcpSession,
    mcpDescriptor,
    mcpBindingRevision,
    mcpToolProvider,
  )
where

import Control.Exception (IOException, SomeException, try)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (getCurrentTime)
import Effectful.Dispatch.Static (unsafeEff_)
import Shikigami.Agent.DeclarationValue (declarationCoordinateText)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Capability.Mcp
import Shikigami.Capability.Overlay (CapabilityDescriptor (..), CapabilityRevision, CapabilityToolDescriptor (..), mkCapabilityRevision)
import Shikigami.Capability.Provider (CapabilityAcquireError (..), CapabilityLease (..), CapabilityProvider (..), CapabilityRun (..), CapabilityScope (..))
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Coordinate (executionCoordinate)
import Shikigami.Record (ActionRecord (..), RecordEvent (..), TierLabel, mkRecordEntry, mkRecordKind)
import Shikumi.Tool (ToolError (..), mkDynTool)
import Shikumi.Tool.Output (textToolOutput)
import System.Environment (getEnvironment)
import System.IO (BufferMode (LineBuffering), Handle, hClose, hFlush, hSetBuffering)
import System.Process
import System.Timeout (timeout)

data McpSession = McpSession
  { discovered :: ![DiscoveredMcpTool],
    call :: !(Text -> Value -> IO (Either Text Value)),
    close :: !(IO ())
  }

-- | The call timeout and the number of @tools/list@ pages.
callTimeoutSeconds :: Int
callTimeoutSeconds = 60

discoveryPages :: Int
discoveryPages = 10

-- | Start the bound server for one workspace and discover its tools.
openMcpSession :: FilePath -> McpBinding -> IO (Either Text McpSession)
openMcpSession root binding = do
  ambient <- getEnvironment
  let arguments = [case argument of LiteralArgument value -> Text.unpack value; WorkspaceRootArgument -> root | argument <- binding.arguments]
      wanted = ["PATH", "HOME", "USER", "LANG"] <> (Text.unpack <$> binding.environment)
      environment = mapMaybe (\name -> (name,) <$> lookup name ambient) wanted
  spawned <-
    try @IOException
      ( createProcess
          (proc (Text.unpack binding.command) arguments)
            { cwd = Just root,
              env = Just environment,
              std_in = CreatePipe,
              std_out = CreatePipe,
              std_err = NoStream,
              create_group = True,
              close_fds = True
            }
      )
  case spawned of
    Left problem -> pure (Left ("the MCP server " <> mcpServerIdText binding.server <> " did not start: " <> Text.pack (show problem)))
    Right (Just input, Just output, _, handle) -> do
      hSetBuffering input LineBuffering
      counter <- newIORef (1 :: Int)
      let request method params = do
            requestId <- atomicModifyIORef' counter (\n -> (n + 1, n))
            sent <- try @IOException (send input (object ["jsonrpc" .= ("2.0" :: Text), "id" .= requestId, "method" .= method, "params" .= params]))
            case sent of
              Left problem -> pure (Left (Text.pack (show problem)))
              Right () -> maybe (Left (method <> " timed out")) id <$> timeout (callTimeoutSeconds * 1000000) (awaitResponse output requestId)
          stop = do
            _ <- try @SomeException (hClose input)
            exited <- timeout 2000000 (waitForProcess handle)
            case exited of
              Just _ -> pure ()
              Nothing -> getPid handle >>= mapM_ (\_ -> terminateProcess handle) >> pure ()
      initialized <- request "initialize" (object ["protocolVersion" .= ("2025-06-18" :: Text), "capabilities" .= object [], "clientInfo" .= object ["name" .= ("shikigami" :: Text), "version" .= ("1" :: Text)]])
      case initialized of
        Left problem -> stop >> pure (Left ("the MCP server " <> mcpServerIdText binding.server <> " did not initialize: " <> problem))
        Right _ -> do
          _ <- try @IOException (send input (object ["jsonrpc" .= ("2.0" :: Text), "method" .= ("notifications/initialized" :: Text)]))
          listed <- listTools request Nothing discoveryPages []
          case listed of
            Left problem -> stop >> pure (Left problem)
            Right tools ->
              pure
                ( Right
                    McpSession
                      { discovered = tools,
                        call = \name arguments' -> request "tools/call" (object ["name" .= name, "arguments" .= arguments']),
                        close = stop
                      }
                )
    Right _ -> pure (Left "the MCP server's pipes were not created")
  where
    listTools request cursor pages acc
      | pages <= 0 = pure (Right acc)
      | otherwise = do
          page <- request "tools/list" (maybe (object []) (\c -> object ["cursor" .= c]) cursor)
          case page of
            Left problem -> pure (Left problem)
            Right (Object result) -> do
              let tools = case KeyMap.lookup "tools" result of
                    Just (Array values) -> mapMaybe discoveredTool (foldr (:) [] values)
                    _ -> []
              case KeyMap.lookup "nextCursor" result of
                Just (String next) -> listTools request (Just next) (pages - 1) (acc <> tools)
                _ -> pure (Right (acc <> tools))
            Right _ -> pure (Left "tools/list returned no result object")
    discoveredTool = \case
      Object tool | Just (String name) <- KeyMap.lookup "name" tool -> Just DiscoveredMcpTool {name, inputSchema = maybe (object []) id (KeyMap.lookup "inputSchema" tool)}
      _ -> Nothing

send :: Handle -> Value -> IO ()
send handle message = do
  ByteString.hPut handle (LazyByteString.toStrict (Aeson.encode message) <> "\n")
  hFlush handle

-- | Read lines until the response to this id; notifications are skipped.
awaitResponse :: Handle -> Int -> IO (Either Text Value)
awaitResponse output requestId = do
  line <- try @IOException (Char8.hGetLine output)
  case line of
    Left problem -> pure (Left ("the MCP server closed its output: " <> Text.pack (show problem)))
    Right bytes -> case Aeson.decodeStrict bytes of
      Just (Object message)
        | KeyMap.lookup "id" message == Just (Aeson.toJSON requestId) -> pure case (KeyMap.lookup "result" message, KeyMap.lookup "error" message) of
            (Just result, _) -> Right result
            (_, Just failure) -> Left (Text.Encoding.decodeUtf8Lenient (LazyByteString.toStrict (Aeson.encode failure)))
            _ -> Left "the MCP response had neither a result nor an error"
      _ -> awaitResponse output requestId

-- | @mcp.<server>@ at the binding's revision; the logical tools are the
-- approved remote names.
mcpDescriptor :: McpBinding -> NonEmpty McpToolName -> CapabilityDescriptor
mcpDescriptor binding requested =
  CapabilityDescriptor
    { capability = mcpCapabilityId binding.server,
      revision = mcpBindingRevision binding,
      tools = [CapabilityToolDescriptor {name = executionCoordinate (mcpToolNameText approved.remoteName), operationClass = approved.operationClass} | approved <- binding.tools, approved.remoteName `elem` requested]
    }

-- | @mcp-v1-@ and the digest of the whole binding (ADR-65).
mcpBindingRevision :: McpBinding -> CapabilityRevision
mcpBindingRevision binding = either (error . show) id (mkCapabilityRevision ("mcp-v1-" <> Text.replace ":" "-" (versionedDigest "shikigami.mcp-binding/1" (mcpBindingRevisionInput binding))))

-- | Acquire: start the server, verify the requested tools against the
-- approved ones, and offer those tools; release: stop the server.
mcpToolProvider :: ActionRecord -> TierLabel -> AgentName -> FilePath -> McpBinding -> NonEmpty McpToolName -> CapabilityProvider
mcpToolProvider record tier agent root binding requested =
  CapabilityProvider
    { descriptor,
      acquire = \scope -> do
        opened <- openMcpSession root binding
        case opened of
          Left problem -> refuse scope problem
          Right session -> case verifyDiscoveredTools binding requested session.discovered of
            Left mismatch -> session.close >> refuse scope (renderMcpBindingMismatch mismatch)
            Right () ->
              pure
                ( Right
                    CapabilityLease
                      { descriptor,
                        tools = [toolFor scope session approved | approved <- binding.tools, approved.remoteName `elem` requested],
                        release = session.close >> pure (Right ())
                      }
                )
    }
  where
    descriptor = mcpDescriptor binding requested
    refuse scope problem = do
      appendCalled scope "-" [] (object ["decision" .= ("refused" :: Text), "reason" .= problem])
      pure (Left (CapabilityAcquireError problem))
    toolFor scope session approved =
      mkDynTool (mcpToolNameText approved.remoteName) approved.description (approvedSchema approved) \input -> unsafeEff_ do
        let name = mcpToolNameText approved.remoteName
        result <- session.call name input
        case result of
          Left problem -> do
            appendCalled scope name [] (object ["decision" .= ("admitted" :: Text), "outcome" .= ("failed" :: Text), "reason" .= problem])
            pure (Left (ToolRunFailed name problem))
          Right (Object payload) -> do
            let failed = KeyMap.lookup "isError" payload == Just (Bool True)
                text = case KeyMap.lookup "content" payload of
                  Just (Array blocks) -> Text.intercalate "\n" [rendered | Object block <- foldr (:) [] blocks, Just rendered <- [blockText block]]
                  _ -> ""
            appendCalled scope name [] (object ["decision" .= ("admitted" :: Text), "isError" .= failed])
            pure (if failed then Left (ToolRunFailed name text) else Right (textToolOutput text))
          Right other -> pure (Right (textToolOutput (Text.Encoding.decodeUtf8Lenient (LazyByteString.toStrict (Aeson.encode other)))))
    blockText block = case (KeyMap.lookup "type" block, KeyMap.lookup "text" block) of
      (Just (String "text"), Just (String value)) -> Just value
      (Just (String kind), _) -> Just ("[" <> kind <> " content]")
      _ -> Nothing
    appendCalled CapabilityScope {runId, principal} name arguments detail = do
      at <- getCurrentTime
      let payload = case detail of
            Object fields -> Object (KeyMap.union fields (KeyMap.fromList [("tool", Aeson.toJSON ("mcp." <> mcpServerIdText binding.server)), ("remote", Aeson.toJSON name), ("host", Aeson.toJSON ("skill" :: Text)), ("arguments", Aeson.toJSON (arguments :: [Text]))]))
            other -> other
          run = case runId of
            WorkflowRun workflowId -> Just workflowId
            OneOffRun _ -> Nothing
      case mkRecordKind "tool.called" of
        Right kind | Right entry <- mkRecordEntry kind payload -> () <$ record.append RecordEvent {at, run, principal = declarationCoordinateText principal, tier, agent = Just agent, entry}
        _ -> pure ()

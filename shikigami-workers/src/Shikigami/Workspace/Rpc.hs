{-# LANGUAGE ForeignFunctionInterface #-}

-- | Bounded, credential-checked Unix transport. The manager owns the listener
-- through daemon restart; repository services never receive this descriptor.
module Shikigami.Workspace.Rpc
  ( RpcError (..),
    RpcRequest (..),
    RpcReply (..),
    ProcessView (..),
    RpcPolicy (..),
    getSystemdListener,
    serveRpc,
    callRpc,
    dispatchSupervisorRpc,
    processViewResult,
  )
where

import Control.Concurrent.Async (replicateConcurrently_)
import Control.Exception (IOException, bracket, catch, mask_)
import Control.Monad (forever)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Foreign.C
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBytes
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Execution.Identity (AttemptId (..), OperationId (..))
import Shikigami.Prelude
import Shikigami.WorkerSession.Transfer
import Shikigami.WorkerSession.Types (WorkerSessionId)
import Shikigami.Workspace.Process
import Shikigami.Workspace.Supervisor
import Shikigami.Workspace.Transfer (workspaceTransferProvider)
import Shikumi.Tool (ToolError)
import Shikumi.Tool.Output (ToolOutput)
import System.FilePath (isAbsolute, normalise)
import System.Timeout (timeout)

data RpcError = RpcRefused | RpcUnavailable | RpcMalformed | RpcPeerDenied | RpcTimeout | RpcUnsupported
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data RpcRequest = RpcLaunch !SupervisorRequest | RpcObserve !OperationId | RpcFence !TransferIntent | RpcAdmitWrite !WorkspaceRef !WorkerSessionId !AgentIdentity !Integer !OperationId
  deriving stock (Eq)

instance Show RpcRequest where show _ = "RpcRequest <protected>"

data ProcessView = ProcessView
  { operationId :: !OperationId,
    attemptId :: !AttemptId,
    generation :: !Integer,
    bindingDigest :: !Text,
    phase :: !ProcessPhase,
    receipt :: !(Maybe ProcessReceipt)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ProcessView where show _ = "ProcessView <protected>"

-- An error carries no no-launch/completion proof.
data RpcReply = RpcFailure !SupervisorError | RpcView !ProcessView | RpcFenceResult !FenceOutcome | RpcWriteResult !Bool
  deriving stock (Eq)

instance Show RpcReply where show _ = "RpcReply <protected>"

data RpcPolicy = RpcPolicy {users :: ![Integer], workers :: !Int, timeoutSeconds :: !Int}
  deriving stock (Eq, Show)

instance ToJSON RpcRequest where
  toJSON request = case request of
    RpcLaunch value -> Aeson.object ["format" Aeson..= (1 :: Int), "action" Aeson..= ("launch" :: Text), "request" Aeson..= value]
    RpcObserve value -> Aeson.object ["format" Aeson..= (1 :: Int), "action" Aeson..= ("observe" :: Text), "operationId" Aeson..= value]
    RpcFence value -> Aeson.object ["format" Aeson..= (2 :: Int), "action" Aeson..= ("fence" :: Text), "intent" Aeson..= value]
    RpcAdmitWrite workspace session owner epoch operation -> Aeson.object ["format" Aeson..= (2 :: Int), "action" Aeson..= ("admitWrite" :: Text), "workspace" Aeson..= workspace, "sessionId" Aeson..= session, "owner" Aeson..= owner, "epoch" Aeson..= epoch, "operationId" Aeson..= operation]

instance FromJSON RpcRequest where
  parseJSON = Aeson.withObject "workspace request" \fields -> do
    format <- fields Aeson..: "format"
    action <- fields Aeson..: "action"
    case (format :: Int, action :: Text) of
      (1, "launch") | keys fields ["format", "action", "request"] -> RpcLaunch <$> fields Aeson..: "request"
      (1, "observe") | keys fields ["format", "action", "operationId"] -> do
        operation <- fields Aeson..: "operationId"
        let OperationId value = operation
        unless (bounded value) (fail "invalid operation")
        pure (RpcObserve operation)
      (2, "fence") | keys fields ["format", "action", "intent"] -> RpcFence <$> fields Aeson..: "intent"
      (2, "admitWrite") | keys fields ["format", "action", "workspace", "sessionId", "owner", "epoch", "operationId"] -> RpcAdmitWrite <$> fields Aeson..: "workspace" <*> fields Aeson..: "sessionId" <*> fields Aeson..: "owner" <*> fields Aeson..: "epoch" <*> fields Aeson..: "operationId"
      _ -> fail "unsupported request"

instance ToJSON RpcReply where
  toJSON reply = case reply of
    RpcFailure err -> Aeson.object ["format" Aeson..= (1 :: Int), "error" Aeson..= err]
    RpcView value -> Aeson.object ["format" Aeson..= (1 :: Int), "view" Aeson..= value]
    RpcFenceResult value -> Aeson.object ["format" Aeson..= (2 :: Int), "fence" Aeson..= value]
    RpcWriteResult value -> Aeson.object ["format" Aeson..= (2 :: Int), "admitted" Aeson..= value]

instance FromJSON RpcReply where
  parseJSON = Aeson.withObject "workspace reply" \fields -> do
    format <- fields Aeson..: "format"
    case (format :: Int) of
      1 | keys fields ["format", "error"] -> RpcFailure <$> fields Aeson..: "error"
      1 | keys fields ["format", "view"] -> RpcView <$> fields Aeson..: "view"
      2 | keys fields ["format", "fence"] -> RpcFenceResult <$> fields Aeson..: "fence"
      2 | keys fields ["format", "admitted"] -> RpcWriteResult <$> fields Aeson..: "admitted"
      _ -> fail "unsupported reply"

keys :: Aeson.Object -> [Key] -> Bool
keys fields expected = length fields == length expected && all (`KeyMap.member` fields) expected

foreign import ccall unsafe "shikigami_workspace_systemd_socket" adoptSocket :: CString -> IO CInt

-- Call once before application threads which may mutate environment. Close the
-- returned socket without shutdown(2): the manager retains the same listener.
getSystemdListener :: FilePath -> IO (Either RpcError Socket.Socket)
getSystemdListener path
  | not (validPath path) = pure (Left RpcRefused)
  | otherwise = protect $ mask_ $ Bytes.useAsCString (Encoding.encodeUtf8 (Text.pack path)) \name -> do
      fd <- adoptSocket name
      if fd == -78
        then pure (Left RpcUnsupported)
        else
          if fd < 0
            then pure (Left RpcRefused)
            else Right <$> Socket.mkSocket fd

serveRpc :: RpcPolicy -> Socket.Socket -> (RpcRequest -> IO RpcReply) -> IO (Either RpcError ())
serveRpc policy listener dispatch
  | null policy.users || length policy.users > 32 || any (\uid -> uid < 0 || uid > 4294967295) policy.users || policy.workers < 1 || policy.workers > 16 || policy.timeoutSeconds < 1 || policy.timeoutSeconds > 120 = pure (Left RpcRefused)
  | otherwise = protect do
      address <- Socket.getSocketName listener
      kind <- Socket.getSocketType listener
      case address of
        Socket.SockAddrUnix path | validPath path && kind == Socket.Stream -> do
          replicateConcurrently_ policy.workers $
            forever $
              bracket (fst <$> Socket.accept listener) Socket.close \connection -> do
                -- Authenticate before reading frames or invoking a handler.
                (_, user, _) <- Socket.getPeerCredential connection
                case user of
                  Just uid | toInteger uid `elem` policy.users -> do
                    _ <- timeout (policy.timeoutSeconds * 1000000) $ protect do
                      received <- receiveFrame 4096 connection
                      case received >>= either (const (Left RpcMalformed)) Right . Aeson.eitherDecodeStrict @RpcRequest of
                        Left _ -> pure (Left RpcMalformed)
                        Right request -> do
                          reply <- dispatch request
                          sendFrame 8192 connection (Lazy.toStrict (Aeson.encode reply))
                    pure ()
                  _ -> pure ()
          pure (Right ())
        _ -> pure (Left RpcRefused)

callRpc :: FilePath -> Integer -> Int -> RpcRequest -> IO (Either RpcError RpcReply)
callRpc path serverUser seconds request
  | not (validPath path) || serverUser < 0 || serverUser > 4294967295 || seconds < 1 || seconds > 120 = pure (Left RpcRefused)
  | otherwise = do
      result <- timeout (seconds * 1000000) $
        protect $
          bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close \connection -> do
            Socket.withFdSocket connection Socket.setCloseOnExecIfNeeded
            Socket.connect connection (Socket.SockAddrUnix path)
            (_, user, _) <- Socket.getPeerCredential connection
            if maybe False ((== serverUser) . toInteger) user
              then do
                sent <- sendFrame 4096 connection (Lazy.toStrict (Aeson.encode request))
                case sent of
                  Left err -> pure (Left err)
                  Right () -> do
                    received <- receiveFrame 8192 connection
                    pure do
                      body <- received
                      reply <- either (const (Left RpcMalformed)) Right (Aeson.eitherDecodeStrict body)
                      case (request, reply) of
                        (_, RpcFailure _) -> Right reply
                        (RpcLaunch _, RpcView value) | value.operationId == requestOperation request && validView value -> Right reply
                        (RpcObserve _, RpcView value) | value.operationId == requestOperation request && validView value -> Right reply
                        (RpcFence intent, RpcFenceResult (FencedAndSettled proof)) | matchesFence intent proof -> Right reply
                        (RpcFence _, RpcFenceResult outcome) | outcome `elem` [FenceUnresolved, FenceConflict, FenceUnavailable] -> Right reply
                        (RpcAdmitWrite {}, RpcWriteResult _) -> Right reply
                        _ -> Left RpcMalformed
              else pure (Left RpcPeerDenied)
      pure (fromMaybe (Left RpcTimeout) result)

dispatchSupervisorRpc :: SupervisorRuntime -> RpcRequest -> IO RpcReply
dispatchSupervisorRpc runtime (RpcFence intent) = RpcFenceResult <$> (workspaceTransferProvider runtime).reconcile intent
dispatchSupervisorRpc runtime (RpcAdmitWrite workspace session owner epoch operation) = do
  result <- (workspaceTransferProvider runtime).admitWrite workspace session owner epoch operation
  pure (RpcWriteResult (either (const False) (const True) result))
dispatchSupervisorRpc runtime request = do
  result <- case request of
    RpcLaunch actual -> superviseProcess runtime actual
    RpcObserve operation -> reconcileProcess runtime operation
  pure case result of
    Left err -> RpcFailure err
    Right record -> RpcView (ProcessView record.operationId record.attemptId record.generation record.bindingDigest record.phase record.receipt)

requestOperation :: RpcRequest -> OperationId
requestOperation (RpcLaunch request) = request.operationId
requestOperation (RpcObserve operation) = operation
requestOperation (RpcFence intent) = intent.operationId
requestOperation (RpcAdmitWrite _ _ _ _ operation) = operation

processViewResult :: ProcessView -> Maybe (Either ToolError ToolOutput)
processViewResult value
  | validView value && value.phase `elem` [ProcessSettled, ProcessRefused] = Just (renderProcessResult value.receipt)
  | otherwise = Nothing

validView :: ProcessView -> Bool
validView value =
  bounded operation && bounded attempt && value.generation > 0 && value.generation < 9223372036854775808 && digestText value.bindingDigest && case value.receipt of
    Nothing -> value.phase /= ProcessSettled
    Just receipt -> value.phase == ProcessSettled && receipt.operationId == value.operationId && receipt.attemptId == value.attemptId && receipt.generation == value.generation && receipt.bindingDigest == value.bindingDigest && digestText receipt.fingerprint && receipt.unit == processUnit value.operationId receipt.fingerprint && hostIdentity receipt.bootId && hostIdentity receipt.invocationId && receipt.descendantsEmpty && receipt.outputComplete && maybe (receipt.termination /= ProcessExited) (\code -> code >= 0 && code <= 255) receipt.exitCode && all validOutput [receipt.stdout, receipt.stderr] && receipt.stdout.bytes + receipt.stderr.bytes <= 1048576
  where
    OperationId operation = value.operationId
    AttemptId attempt = value.attemptId
    validOutput output = bounded output.artifact && output.artifact `notElem` [".", ".."] && Text.all (\c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c `elem` ("._-" :: String)) output.artifact && digestText output.digest && output.bytes >= 0

validPath :: FilePath -> Bool
validPath path = isAbsolute path && path /= "/" && normalise path == path && not ('\0' `elem` path) && not (".." `elem` Text.splitOn "/" (Text.pack path)) && Bytes.length (Encoding.encodeUtf8 (Text.pack path)) <= 100

receiveFrame :: Int -> Socket.Socket -> IO (Either RpcError Bytes.ByteString)
receiveFrame limit connection = do
  header <- receiveExact connection 4
  case header of
    Nothing -> pure (Left RpcMalformed)
    Just prefix -> do
      let size = Bytes.foldl' (\total byte -> total * 256 + fromIntegral byte) (0 :: Integer) prefix
      if size < 1 || size > toInteger limit
        then pure (Left RpcMalformed)
        else maybe (Left RpcMalformed) Right <$> receiveExact connection (fromInteger size)

receiveExact :: Socket.Socket -> Int -> IO (Maybe Bytes.ByteString)
receiveExact connection size = go size []
  where
    go 0 chunks = pure (Just (Bytes.concat (reverse chunks)))
    go remaining chunks = do
      chunk <- SocketBytes.recv connection remaining
      if Bytes.null chunk then pure Nothing else go (remaining - Bytes.length chunk) (chunk : chunks)

sendFrame :: Int -> Socket.Socket -> Bytes.ByteString -> IO (Either RpcError ())
sendFrame limit connection body
  | Bytes.null body || Bytes.length body > limit = pure (Left RpcMalformed)
  | otherwise = do
      let size = Bytes.length body
          prefix = Bytes.pack [fromIntegral (size `div` divisor `mod` 256) | divisor <- [16777216, 65536, 256, 1]]
      SocketBytes.sendAll connection (prefix <> body)
      pure (Right ())

protect :: IO (Either RpcError a) -> IO (Either RpcError a)
protect work = catch work (\(_ :: IOException) -> pure (Left RpcUnavailable))

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ViewPatterns #-}

-- | Manager-owned supervisor listener and dispatch. Clients and service share
-- the core wire codecs and bounded, kernel-peer-checked transport.
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
import Control.Exception (bracket, mask_)
import Control.Monad (forever)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Foreign.C
import Network.Socket qualified as Socket
import Shikigami.Prelude
import Shikigami.WorkerSession.Transfer (WorkspaceProvider (..))
import Shikigami.Workspace.Process
import Shikigami.Workspace.Protocol
import Shikigami.Workspace.RpcClient
import Shikigami.Workspace.Supervisor
import Shikigami.Workspace.Transfer (workspaceTransferProvider)
import Shikigami.Workspace.Value
import Shikumi.Tool (ToolError)
import Shikumi.Tool.Output (ToolOutput)
import System.Timeout (timeout)

data RpcPolicy = RpcPolicy {users :: ![RpcPeerUserId], workers :: !RpcConcurrency, timeoutSeconds :: !RpcRequestSeconds}
  deriving stock (Eq, Show)

foreign import ccall unsafe "shikigami_workspace_systemd_socket" adoptSocket :: CString -> IO CInt

-- Call once before application threads which may mutate environment. Close the
-- returned socket without shutdown(2): the manager retains the same listener.
getSystemdListener :: WorkspaceLocator "rpc-socket" -> IO (Either RpcError Socket.Socket)
getSystemdListener (workspaceLocatorPath -> path)
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
  | null (map rpcPeerUserIdNumber policy.users) || length (map rpcPeerUserIdNumber policy.users) > 32 || any (\uid -> uid < 0 || uid > 4294967295) (map rpcPeerUserIdNumber policy.users) || (rpcConcurrencyNumber policy.workers) < 1 || (rpcConcurrencyNumber policy.workers) > 16 || (rpcRequestSecondsNumber policy.timeoutSeconds) < 1 || (rpcRequestSecondsNumber policy.timeoutSeconds) > 120 = pure (Left RpcRefused)
  | otherwise = protect do
      address <- Socket.getSocketName listener
      kind <- Socket.getSocketType listener
      case address of
        Socket.SockAddrUnix path | validPath path && kind == Socket.Stream -> do
          replicateConcurrently_ (rpcConcurrencyNumber policy.workers) $
            forever $
              bracket (fst <$> Socket.accept listener) Socket.close \connection -> do
                -- Authenticate before reading frames or invoking a handler.
                (_, user, _) <- Socket.getPeerCredential connection
                case user of
                  Just uid | toInteger uid `elem` (map rpcPeerUserIdNumber policy.users) -> do
                    _ <- timeout ((rpcRequestSecondsNumber policy.timeoutSeconds) * 1000000) $ protect do
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

processViewResult :: ProcessView -> Maybe (Either ToolError ToolOutput)
processViewResult value
  | validView value && value.phase `elem` [ProcessSettled, ProcessRefused] = Just (renderProcessResult value.receipt)
  | otherwise = Nothing

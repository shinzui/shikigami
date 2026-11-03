{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ViewPatterns #-}

-- | Bounded peer-checked supervisor client and shared frame transport. It owns
-- no listener, systemd service, process launch or repository filesystem access.
module Shikigami.Workspace.RpcClient where

import Control.Exception (IOException, bracket, catch)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBytes
import Shikigami.Prelude
import Shikigami.WorkerSession.Transfer
import Shikigami.Workspace.Protocol
import Shikigami.Workspace.Value
import System.FilePath (isAbsolute, normalise)
import System.Timeout (timeout)

-- Trusted endpoint and kernel server identity; no tool argument grants authority.
data ProcessClient = ProcessClient
  { socketPath :: !(WorkspaceLocator "rpc-socket"),
    serverUser :: !RpcPeerUserId,
    requestSeconds :: !RpcRequestSeconds,
    waitSeconds :: !RpcWaitSeconds
  }

callRpc :: WorkspaceLocator "rpc-socket" -> RpcPeerUserId -> RpcRequestSeconds -> RpcRequest -> IO (Either RpcError RpcReply)
callRpc (workspaceLocatorPath -> path) (rpcPeerUserIdNumber -> serverUser) (rpcRequestSecondsNumber -> seconds) request
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

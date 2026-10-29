module Shikigami.WorkspaceRpcSpec (tests, withListener) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently, withAsync)
import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V4 (nextRandom)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBytes
import Shikigami.Execution.Identity (AttemptId (..), OperationId (..))
import Shikigami.Workspace.Process
import Shikigami.Workspace.Rpc
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "workspace Unix RPC"
    [ testCase "authenticates real Unix peers and returns only retained process metadata" $ withListener \path listener uid -> do
        calls <- newIORef (0 :: Int)
        withAsync (serveRpc (RpcPolicy [uid] 2 2) listener (counted calls)) \_ -> do
          callRpc path uid 3 request >>= (@?= Right reply)
          readIORef calls >>= (@?= 1)
          let body = Lazy.toStrict (Aeson.encode reply)
          mapM_ (\field -> assertBool "no command, path or raw output in reply" (not (field `Bytes.isInfixOf` body))) ["executable", "arguments", "environment", "storageRoot", "stdout.pipe"],
      testCase "rejects client credentials before invoking the accepted-operation handler" $ withListener \path listener uid -> do
        calls <- newIORef (0 :: Int)
        withAsync (serveRpc (RpcPolicy [otherUid uid] 1 2) listener (counted calls)) \_ -> do
          result <- callRpc path uid 3 request
          assertBool "denied peer has no reply proof" (isLeft result)
          readIORef calls >>= (@?= 0),
      testCase "client verifies the server UID before disclosing operation coordinates" $ withListener \path listener uid -> do
        calls <- newIORef (0 :: Int)
        withAsync (serveRpc (RpcPolicy [uid] 1 2) listener (counted calls)) \_ -> do
          callRpc path (otherUid uid) 3 request >>= (@?= Left RpcPeerDenied)
          -- A subsequent valid request proves the denied connection was drained.
          callRpc path uid 3 request >>= (@?= Right reply)
          readIORef calls >>= (@?= 1),
      testCase "oversized, truncated, unknown-field and unsupported-version frames cause no handler call" $ withListener \path listener uid -> do
        calls <- newIORef (0 :: Int)
        withAsync (serveRpc (RpcPolicy [uid] 1 2) listener (counted calls)) \_ -> do
          mapM_
            (rawRefused path)
            [ Bytes.pack [0, 0, 16, 1],
              Bytes.pack [0, 0, 0, 100] <> "{",
              frame "{\"format\":1,\"action\":\"observe\",\"operationId\":\"operation\",\"path\":\"/host\"}",
              frame "{\"format\":2,\"action\":\"observe\",\"operationId\":\"operation\"}",
              frame "{\"format\":1,\"action\":\"launch\",\"request\":{\"executionId\":\"e\",\"operationId\":\"o\",\"attemptId\":\"a\",\"owner\":\"c\",\"generation\":1,\"command\":\"/bin/sh\"}}"
            ]
          callRpc path uid 3 request >>= (@?= Right reply)
          readIORef calls >>= (@?= 1),
      testCase "bounded workers recover from slow partial frames" $ withListener \path listener uid -> do
        calls <- newIORef (0 :: Int)
        withAsync (serveRpc (RpcPolicy [uid] 1 1) listener (counted calls)) \_ ->
          withConnection path \slow -> do
            SocketBytes.sendAll slow (Bytes.pack [0, 0])
            callRpc path uid 4 request >>= (@?= Right reply)
            readIORef calls >>= (@?= 1),
      testCase "cancelling the server leaves the manager-owned listener reusable" $ withListener \path listener uid -> do
        calls <- newIORef (0 :: Int)
        let serve = serveRpc (RpcPolicy [uid] 2 2) listener (counted calls)
        withAsync serve \_ -> callRpc path uid 3 request >>= (@?= Right reply)
        withAsync serve \_ -> callRpc path uid 3 request >>= (@?= Right reply)
        readIORef calls >>= (@?= 2),
      testCase "handler concurrency remains bounded and timeout frees every slot" $ withListener \path listener uid -> do
        counts <- newIORef (0 :: Int, 0 :: Int)
        let handler _ = do
              atomicModifyIORef' counts (\(total, active) -> ((total + 1, active + 1), ()))
              (_, active) <- readIORef counts
              assertBool "fixed worker bound" (active <= 2)
              -- Reset on cancellation too; each timed-out request relinquishes its slot.
              bracket (pure ()) (const (atomicModifyIORef' counts (\(total, n) -> ((total, n - 1), ())))) (const (threadDelay 5000000))
              pure reply
        withAsync (serveRpc (RpcPolicy [uid] 2 1) listener handler) \_ -> do
          results <- mapConcurrently (const (callRpc path uid 4 request)) [1 .. 4 :: Int]
          assertBool "timed-out handlers provide no completion proof" (all isLeft results)
          readIORef counts >>= (@?= (4, 0)),
      testCase "client refuses unrelated operation and invalid settled evidence" $ withListener \path listener uid -> do
        let wrong = RpcView (ProcessView (OperationId "other") (AttemptId "actual") 1 digest ProcessReserved Nothing)
            incomplete = RpcView (ProcessView operation (AttemptId "actual") 1 digest ProcessSettled Nothing)
        mapM_ (\value -> withAsync (serveRpc (RpcPolicy [uid] 1 2) listener (const (pure value))) \_ -> callRpc path uid 3 request >>= (@?= Left RpcMalformed)) [wrong, incomplete],
      testCase "TCP listeners cannot enter peer-credential transport" $
        bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close \listener -> do
          Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
          Socket.listen listener 1
          serveRpc (RpcPolicy [0] 1 1) listener (const (pure reply)) >>= (@?= Left RpcRefused),
      testCase "invalid endpoints and unbounded policy refuse before dispatch" $ withListener \path listener uid -> do
        callRpc "relative" uid 1 request >>= (@?= Left RpcRefused)
        callRpc path uid 0 request >>= (@?= Left RpcRefused)
        serveRpc (RpcPolicy [] 1 1) listener (const (pure reply)) >>= (@?= Left RpcRefused)
        serveRpc (RpcPolicy [uid] 17 1) listener (const (pure reply)) >>= (@?= Left RpcRefused)
    ]

withListener :: (FilePath -> Socket.Socket -> Integer -> IO a) -> IO a
withListener use = do
  temporary <- getTemporaryDirectory
  identifier <- Text.take 12 . UUID.toText <$> nextRandom
  let directory = temporary </> ("s96-" <> Text.unpack identifier)
      path = directory </> "rpc"
  bracket (createDirectory directory >> setFileMode directory 0o700) (const (removeDirectoryRecursive directory)) \_ ->
    bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close \listener -> do
      Socket.withFdSocket listener Socket.setCloseOnExecIfNeeded
      Socket.bind listener (Socket.SockAddrUnix path)
      setFileMode path 0o600
      Socket.listen listener 16
      uid <- toInteger <$> getEffectiveUserID
      use path listener uid

withConnection :: FilePath -> (Socket.Socket -> IO a) -> IO a
withConnection path use = bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close \connection -> do
  Socket.connect connection (Socket.SockAddrUnix path)
  use connection

rawRefused :: FilePath -> Bytes.ByteString -> IO ()
rawRefused path body = withConnection path \connection -> do
  SocketBytes.sendAll connection body
  Socket.shutdown connection Socket.ShutdownSend
  result <- timeout 3000000 (SocketBytes.recv connection 1)
  result @?= Just Bytes.empty

frame :: Bytes.ByteString -> Bytes.ByteString
frame body = Bytes.pack [fromIntegral (Bytes.length body `div` divisor `mod` 256) | divisor <- [16777216, 65536, 256, 1]] <> body

counted :: IORef Int -> RpcRequest -> IO RpcReply
counted calls actual = do
  actual @?= request
  atomicModifyIORef' calls (\count -> (count + 1, ()))
  pure reply

operation :: OperationId
operation = OperationId "operation"

request :: RpcRequest
request = RpcObserve operation

reply :: RpcReply
reply = RpcView (ProcessView operation (AttemptId "actual") 1 digest ProcessReserved Nothing)

digest :: Text.Text
digest = "sha256:" <> Text.replicate 64 "a"

otherUid :: Integer -> Integer
otherUid uid = (uid + 1) `mod` 4294967296

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

module Shikigami.Workers.InspectionSpec (tests) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar
import Control.Exception (bracket, try)
import Control.Monad (forever, unless, void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.IORef
import Data.Text (Text)
import Effectful (liftIO, runEff)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types
import Network.WebSockets qualified as WebSocket
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Mock (listAdapter)
import Shibuya.App qualified as Shibuya
import Shibuya.Core.Ack (AckDecision (AckOk))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (mkIngested)
import Shibuya.Core.Types (MessageId (..), mkEnvelope)
import Shibuya.Telemetry.Effect (runTracingNoop)
import Shikigami.App (noopTracer)
import Shikigami.Inspection.Store (withObservedStore)
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Runtime (registerRuntimeCatalog)
import Shikigami.Workers.ConsumerApp (consumerAppConfig, withConsumerApp)
import Shikigami.Workers.Inspection (consumerInspection, withConsumerInspection)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

reader :: Text
reader = "worker-inspection-reader-012345678901234567890123456789"

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "worker inspection"
    [ testCase "the authenticated worker host inspects its actual master and drains that one owner" (scenario fixture False),
      testCase "parent cancellation joins the active worker socket and admitted delivery" (scenario fixture True)
    ]

scenario :: DatabaseFixture -> Bool -> IO ()
scenario fixture cancelled =
  withShikigamiFreshDatabase fixture \connection -> do
    ready <- newEmptyMVar
    entered <- newEmptyMVar
    released <- newEmptyMVar
    releaseOwner <- newEmptyMVar
    starts <- newIORef (0 :: Int)
    stopped <- newIORef (0 :: Int)
    acknowledged <- newIORef (0 :: Int)
    workFinished <- newEmptyMVar
    tracer <- noopTracer
    selected <- case Aeson.fromJSON (object ["port" .= (0 :: Int), "readToken" .= reader, "allowedOrigins" .= ["https://ops.example" :: Text]]) of
      Aeson.Error problem -> fail problem
      Aeson.Success config -> pure config
    let logger = Log.Logger Log.Info \line -> case Aeson.decodeStrict line of
          Just (Object fields) | KeyMap.lookup "event" fields == Just (String "inspection.listening") ->
            case KeyMap.lookup "port" fields of
              Just value -> case Aeson.fromJSON value of Aeson.Success port -> putMVar ready (port :: Int); _ -> pure ()
              _ -> pure ()
          _ -> pure ()
        settings = defaultConnectionSettings connection
    withObservedStore tracer settings \store collector -> do
      registerRuntimeCatalog store
      let inspection = consumerInspection 330 (Just selected) logger settings store collector
      Async.withAsync
        ( runEff $ runTracingNoop do
            let delivery = mkIngested (mkEnvelope (MessageId "one-owner") ()) (AckHandle (\_ -> liftIO (modifyIORef' acknowledged (+ 1) >> putMVar workFinished ())))
                adapter = (listAdapter [delivery]) {shutdown = liftIO (modifyIORef' stopped (+ 1) >> void (tryPutMVar released ()))}
                handler _ = do
                  liftIO (modifyIORef' starts (+ 1) >> putMVar entered ())
                  liftIO (takeMVar released)
                  pure AckOk
                processorId = Shibuya.ProcessorId "the-actual-worker"
            withConsumerApp consumerAppConfig [(processorId, Shibuya.mkProcessor adapter handler)] \app ->
              withConsumerInspection inspection (Shibuya.getAppMaster app) $ liftIO do
                takeMVar releaseOwner
        )
        \owner -> do
          await "native handler started" (takeMVar entered)
          port <- await "worker inspection listener ready" (takeMVar ready)
          bracket (Http.newManager Http.defaultManagerSettings) Http.closeManager \manager -> do
            initial <- Http.parseRequest ("http://127.0.0.1:" <> show port <> "/shibuya/metrics")
            denied <- Http.httpLbs initial manager
            assertEqual "worker metrics are authenticated" status401 (Http.responseStatus denied)
            observed <- Http.httpLbs initial {Http.requestHeaders = [(hAuthorization, "Bearer worker-inspection-reader-012345678901234567890123456789")]} manager
            assertEqual "worker metrics use native HTTP" status200 (Http.responseStatus observed)
            value <- either fail pure (Aeson.eitherDecode (Http.responseBody observed))
            case value of
              Object fields -> case KeyMap.lookup "the-actual-worker" fields of
                Just (Object metrics) -> do
                  assertEqual "optional latency detail stays unavailable" Nothing (KeyMap.lookup "latency" metrics)
                  assertEqual "optional oldest in-flight detail stays unavailable" Nothing (KeyMap.lookup "oldestInFlight" metrics)
                  assertEqual "optional partition progress stays unavailable" Nothing (KeyMap.lookup "progress" metrics)
                _ -> assertFailure "the actual admitted processor is absent"
              _ -> assertFailure "native metrics are not an object"
          WebSocket.runClientWith "127.0.0.1" port "/shibuya/ws" WebSocket.defaultConnectionOptions [(hAuthorization, "Bearer worker-inspection-reader-012345678901234567890123456789"), (hOrigin, "https://ops.example")] \client -> do
            first <- receive client
            assertEqual "native initial snapshot" (Just (String "snapshot")) (field "type" first)
            WebSocket.sendTextData client (Aeson.encode (object ["type" .= ("subscribe_all" :: Text)]))
            snapshot <- receive client
            assertEqual "native replacement snapshot" (Just (String "snapshot")) (field "type" snapshot)
            assertBool "socket and owner share the same master" (case field "metrics" snapshot of Just (Object rows) -> KeyMap.member "the-actual-worker" rows; _ -> False)
            unless cancelled $ bracket (Http.newManager Http.defaultManagerSettings) Http.closeManager \manager -> do
              loaded <- newEmptyMVar
              reads <- newIORef (0 :: Int)
              initial <- Http.parseRequest ("http://127.0.0.1:" <> show port <> "/keiro/wf/inspect/list?limit=1")
              let poll = do
                    response <- Http.httpLbs initial {Http.requestHeaders = [(hAuthorization, "Bearer worker-inspection-reader-012345678901234567890123456789")]} manager
                    assertEqual "real database inspection under load" status200 (Http.responseStatus response)
                    modifyIORef' reads (+ 1)
                    void (tryPutMVar loaded ())
              Async.withAsync (forever poll) \load -> do
                await "inspection load started" (takeMVar loaded)
                putMVar released ()
                await "admitted worker progresses during inspection load" (takeMVar workFinished)
                Async.poll load >>= assertBool "load remains independently active" . maybe True (const False)
                readIORef reads >>= assertBool "at least one bounded database read completed" . (> 0)
            if cancelled then Async.cancel owner else putMVar releaseOwner ()
            outcome <- await "consumer and inspection joined" (Async.waitCatch owner)
            if cancelled
              then assertBool "parent cancellation propagates" (isLeft outcome)
              else case outcome of Right (Right ()) -> pure (); _ -> assertFailure (show outcome)
            let drain = (try (WebSocket.receiveData client :: IO Lazy.ByteString) :: IO (Either WebSocket.ConnectionException Lazy.ByteString)) >>= either (const (pure ())) (const drain)
            await "active worker socket closed after retained terminal/goodbye frames" drain
    readIORef starts >>= assertEqual "inspection creates no second consumer" 1
    readIORef stopped >>= assertEqual "adapter cleanup joins once" 1
    readIORef acknowledged >>= assertEqual "admitted delivery settles once after inspection closes" 1

receive :: WebSocket.Connection -> IO Value
receive client = await "worker metrics frame" (WebSocket.receiveData client :: IO Lazy.ByteString) >>= either fail pure . Aeson.eitherDecode

field :: Aeson.Key -> Value -> Maybe Value
field key (Object fields) = KeyMap.lookup key fields
field _ _ = Nothing

await :: String -> IO a -> IO a
await label action = timeout 7000000 action >>= maybe (assertFailure (label <> " timed out") >> fail "timeout") pure

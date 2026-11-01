module Shikigami.InspectionSocketSpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar
import Control.Concurrent.STM (atomically, check)
import Control.Exception (bracket, finally, try)
import Control.Monad (forM_, void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Effectful (liftIO)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Keiro.Ops.Http.Feed qualified as Feed
import Keiro.Ops.Http.Protocol qualified as Protocol
import Keiro.Ops.Http.Views (Item (..), View (..))
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), appendJournalEntry)
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Effect (runStoreIO)
import Kiroku.Store.Observability (KirokuEvent (..), SubscriptionGroupContext (..))
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (GlobalPosition (..))
import Network.HTTP.Types
import Network.Socket qualified as Socket
import Network.WebSockets qualified as WebSocket
import Shikigami.Inspection.Runtime (InspectionRuntime (..))
import Shikigami.Inspection.Settings (InspectionSettings (..))
import Shikigami.InspectionHttpSpec (Result (..), field, inspectionLimit, profile, readCredential, request, withFixture)
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Trigger.Enqueue (ensureRunQueue)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "administrative inspection sockets"
    [ testCase "authenticated clients share one canonical view, preserve refusals and reconnect from a fresh snapshot" $
        withFixture fixture ((profile False) {maxViews = inspectionLimit 1, maxQueuedFrames = inspectionLimit 2}) \runtime _ store _ manager -> do
          assertEqual "idle mount has no driver or wake cursor" (Feed.FeedStats 0 0 False) =<< Feed.feedStats runtime.feeds
          now <- getCurrentTime
          void (runStoreIO store (appendJournalEntry (WorkflowName "inspection") (WorkflowId "one") (StepRecorded "start" Null now)) >>= either (fail . show) pure)
          socket runtime "/keiro/ws?client=one" \one -> do
            assertEqual "open idle socket does not poll" (Feed.FeedStats 0 1 False) =<< Feed.feedStats runtime.feeds
            socket runtime "/keiro/ws" \two -> do
              forM_ [one, two] \connection -> send connection (subscribe "workflows") >> receive connection >>= assertType "snapshot"
              assertEqual "canonical view is shared" (Feed.FeedStats 1 2 True) =<< Feed.feedStats runtime.feeds
              forM_ [1 .. 5 :: Int] \_ -> send one (object ["type" .= ("ping" :: Text)]) >> receive one >>= assertType "pong"
              send one (object ["type" .= ("subscribe" :: Text), "feed" .= ("workflows" :: Text), "workflow_name" .= ("other" :: Text)])
              refused <- receive one
              assertEqual "old subscription survives capacity refusal" (Just (String "too_many_views")) (field "code" refused)
              void (runStoreIO store (appendJournalEntry (WorkflowName "inspection") (WorkflowId "one") (WorkflowCompleted now)) >>= either (fail . show) pure)
              update <- receive one
              assertType "update" update
              assertEqual "both clients see the same observation" update =<< receive two
              polled <- request manager runtime.port methodGet "/keiro/wf/inspect/list?limit=100" [(hAuthorization, readCredential)] ""
              assertEqual "native poll and live feed carry the same lifecycle" (field "items" polled.value) (field "changed" update)
              forM_ [one, two] \connection -> send connection (object ["type" .= ("unsubscribe" :: Text), "feed" .= ("workflows" :: Text)]) >> receive connection >>= assertType "unsubscribed"
              assertEqual "last unsubscribe joins the wake owner" (Feed.FeedStats 0 2 False) =<< Feed.feedStats runtime.feeds
          await "all disconnected clients release admission" (waitStats runtime (Feed.FeedStats 0 0 False))
          socket runtime "/keiro/ws" \connection -> do
            send connection (subscribe "workflows")
            fresh <- receive connection
            assertType "snapshot" fresh
            assertBool "reconnect observes completed truth" (field "items" fresh /= Just (Aeson.toJSON ([] :: [Value]))),
      testCase "all three native first-page feeds are mounted and unknown additive input is a typed refusal" $
        withFixture fixture (profile False) \runtime _ _ _ manager ->
          socket runtime "/keiro/ws" \connection -> do
            forM_ [("workflows", "/keiro/wf/inspect/list"), ("timers", "/keiro/timer/pending/list"), ("projection_groups", "/keiro/projection/status")] \(feed, path) -> do
              send connection (subscribe feed)
              snapshot <- receive connection
              assertType "snapshot" snapshot
              assertEqual "native feed name" (Just (String feed)) (field "feed" snapshot)
              polled <- request manager runtime.port methodGet path [(hAuthorization, readCredential)] ""
              assertEqual "first page uses the native HTTP representation" (field "items" polled.value) (field "items" snapshot)
            send connection (subscribe "unknown")
            unknown <- receive connection
            assertEqual "unknown feed code" (Just (String "unknown_feed")) (field "code" unknown)
            send connection (object ["type" .= ("subscribe" :: Text), "feed" .= ("timers" :: Text), "unknown_filter" .= True])
            invalid <- receive connection
            assertEqual "unknown filter code" (Just (String "invalid_subscription")) (field "code" invalid),
      testCase "upgrade authentication, Origin, connection capacity and joined handle close are real listener behavior" $
        withFixture fixture ((profile False) {maxConnections = inspectionLimit 1}) \runtime _ _ _ manager -> do
          let upgrade = [(hConnection, "Upgrade"), (hUpgrade, "websocket"), ("Sec-WebSocket-Version", "13"), ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")]
          denied <- request manager runtime.port methodGet "/keiro/ws" upgrade ""
          assertEqual "upgrade is authenticated before allocation" status401 denied.status
          forbidden <- request manager runtime.port methodGet "/keiro/ws" (upgrade <> [(hAuthorization, readCredential), (hOrigin, "https://foreign.example")]) ""
          assertEqual "upgrade preserves native Origin policy" status403 forbidden.status
          socket runtime "/keiro/ws" \connection -> do
            full <- request manager runtime.port methodGet "/keiro/ws" (upgrade <> [(hAuthorization, readCredential)]) ""
            assertEqual "socket admission is bounded" status503 full.status
            Feed.closeFeedHandle runtime.feeds
            receive connection >>= assertType "goodbye"
          assertEqual "close joins every socket and driver" (Feed.FeedStats 0 0 False) =<< Feed.feedStats runtime.feeds,
      testCase "active refresh checks schema again and refuses drift without fabricating an empty snapshot" $
        withFixture fixture ((profile False) {refreshMillis = inspectionLimit 50}) \runtime _ store _ _ ->
          socket runtime "/keiro/ws" \connection -> do
            send connection (subscribe "timers")
            receive connection >>= assertType "snapshot"
            Pool.use store.pool (Session.script "CREATE TABLE keiro.shikigami_feed_drift (id bigint)") >>= either (fail . show) pure
            refusal <- receive connection
            assertEqual "refresh reports a read failure" (Just (String "read_failed")) (field "code" refusal),
      testCase "Kiroku metrics retain their snapshot subscription protocol on the bounded authenticated transport" $
        withFixture fixture ((profile False) {refreshMillis = inspectionLimit 100}) \runtime _ _ _ _ ->
          socket runtime "/kiroku/ws/metrics" \connection -> do
            receive connection >>= assertType "snapshot"
            send connection (object ["type" .= ("unsubscribe_metrics" :: Text)])
            send connection (object ["type" .= ("ping" :: Text)])
            receiveType "pong" connection
            silent <- timeout 250000 (WebSocket.receiveData connection :: IO Lazy.ByteString)
            assertEqual "unsubscribe stops periodic delivery" Nothing silent
            send connection (object ["type" .= ("subscribe_metrics" :: Text)])
            receive connection >>= assertType "snapshot",
      testCase "PGMQ's real queue feed is poll-authoritative and reconnects with its native metrics snapshot" $
        withFixture fixture (profile False) \runtime _ store _ _ -> do
          ensureRunQueue store.pool >>= either (fail . show) pure
          forM_ [1 .. 2 :: Int] \_ -> socket runtime "/pgmq/ws" \connection -> do
            send connection (object ["type" .= ("subscribe" :: Text), "queue" .= ("shikigami_run_jobs" :: Text)])
            snapshot <- receive connection
            assertType "snapshot" snapshot
            assertEqual "poll-only profile never claims LISTEN acknowledgement" (Just (Bool False)) (field "push" snapshot),
      testCase "HTTP reads and native feed initialization share admission while serving writes keep their own pool" $
        withFixture fixture ((profile False) {maxConcurrentReads = inspectionLimit 1}) \runtime _ store _ manager -> do
          entered <- newEmptyMVar
          cleaned <- newEmptyMVar
          gate <- newEmptyMVar
          let blocked = View "inspection-shared-admission" Protocol.Workflows (liftIO ((putMVar entered () >> takeMVar gate) `finally` putMVar cleaned ()))
          Async.withAsync (Feed.acquireDriver runtime.feeds blocked) \initializing -> do
            await "feed read admitted" (takeMVar entered)
            busy <- request manager runtime.port methodGet "/keiro/aggregate/types" [(hAuthorization, readCredential)] ""
            assertEqual "HTTP does not bypass feed admission" status503 busy.status
            now <- getCurrentTime
            written <- runStoreIO store (appendJournalEntry (WorkflowName "inspection-progress") (WorkflowId "one") (StepRecorded "write" Null now))
            assertBool "serving write progresses while inspection is occupied" (case written of Right _ -> True; _ -> False)
            Async.cancel initializing
            await "cancelled initialization joined its reader" (takeMVar cleaned)
          assertEqual "cancelled initialization releases view and wake owner" (Feed.FeedStats 0 0 False) =<< Feed.feedStats runtime.feeds
          healthy <- request manager runtime.port methodGet "/keiro/aggregate/types" [(hAuthorization, readCredential)] ""
          assertEqual "native admission is available after cancellation" status200 healthy.status,
      testCase "host shutdown joins clients from every mounted protocol before its fixture releases stores" do
        clients <- newIORef []
        retained <- newIORef Nothing
        ( do
            withFixture fixture (profile False) \runtime _ store _ _ -> do
              writeIORef retained (Just runtime)
              ensureRunQueue store.pool >>= either (fail . show) pure
              forM_ [("/keiro/ws", Just (subscribe "workflows")), ("/kiroku/ws/metrics", Nothing), ("/pgmq/ws", Just (object ["type" .= ("subscribe" :: Text), "queue" .= ("shikigami_run_jobs" :: Text)]))] \(path, initial) -> do
                ready <- newEmptyMVar
                client <-
                  Async.async
                    ( socket runtime path \connection -> do
                        maybe (pure ()) (send connection) initial
                        receive connection >>= assertType "snapshot"
                        putMVar ready ()
                        drain connection
                    )
                modifyIORef' clients (client :)
                await "native protocol is active before host return" (takeMVar ready)
              assertEqual "Keiro socket is active at the host boundary" 1 . (.activeConnections) =<< Feed.feedStats runtime.feeds
              assertEqual "Kiroku socket is active at the host boundary" 1 =<< atomically runtime.metricsConnections
            readIORef clients >>= mapM_ (\client -> void (await "native client was joined by host shutdown" (Async.waitCatch client)))
            readIORef retained >>= \case
              Nothing -> assertFailure "missing host observation"
              Just runtime -> do
                assertEqual "closed host retains no driver, client or wake owner" (Feed.FeedStats 0 0 False) =<< Feed.feedStats runtime.feeds
                assertEqual "closed metrics host retains no client" 0 =<< atomically runtime.metricsConnections
          )
          `finally` (readIORef clients >>= mapM_ Async.cancel),
      testCase "a real non-reading TCP metrics client expires and returns native admission" $
        withFixture fixture ((profile False) {deliveryDeadlineSeconds = inspectionLimit 1, maxFrameBytes = inspectionLimit 1048576, maxQueuedBytes = inspectionLimit 2097152}) \runtime _ store _ manager -> do
          -- Exercise the native collector with a large but permitted snapshot.
          forM_ [1 .. 128 :: Int] \index ->
            maybe (assertFailure "collector callback missing") ($ KirokuEventSubscriptionStarted (SubscriptionName (Text.pack (show index) <> Text.replicate 4096 "s")) (GlobalPosition 0) NonGroup) store.eventHandler
          ready <- newEmptyMVar
          release <- newEmptyMVar
          Async.withAsync
            ( smallReceiveSocket
                runtime
                "/kiroku/ws/metrics"
                ( \connection -> do
                    putMVar ready ()
                    forM_ [1 .. 64 :: Int] (\_ -> send connection (object ["type" .= ("subscribe_metrics" :: Text)]))
                    takeMVar release
                )
            )
            \client ->
              ( do
                  await "slow client handshake" (takeMVar ready)
                  active <- atomically runtime.metricsConnections
                  assertEqual "native metrics socket is admitted" 1 active
                  await "slow delivery releases its native connection slot" (atomically (runtime.metricsConnections >>= check . (== 0)))
                  healthy <- request manager runtime.port methodGet "/kiroku/metrics" [(hAuthorization, readCredential)] ""
                  assertEqual "the listener remains useful after slow socket cancellation" status200 healthy.status
                  putMVar release ()
                  void (await "client joined" (Async.waitCatch client))
              )
                `finally` void (tryPutMVar release ()),
      testCase "native metrics frames cannot escape the outgoing byte cap" $
        withFixture fixture ((profile False) {maxFrameBytes = inspectionLimit 512, maxQueuedBytes = inspectionLimit 1024}) \runtime _ _ _ manager -> do
          result <- try @WebSocket.ConnectionException (socket runtime "/kiroku/ws/metrics" receive)
          assertBool "oversized native snapshot closes before any payload frame" (case result of Left _ -> True; _ -> False)
          await "oversized connection returned admission" (atomically (runtime.metricsConnections >>= check . (== 0)))
          healthy <- request manager runtime.port methodGet "/kiroku/metrics" [(hAuthorization, readCredential)] ""
          assertEqual "HTTP retains its independent response budget" status200 healthy.status,
      testCase "native metrics reject oversized incoming socket messages and join their sampler" $
        withFixture fixture ((profile False) {maxRequestBytes = inspectionLimit 128}) \runtime _ _ _ _ -> do
          result <-
            try @WebSocket.ConnectionException
              ( socket runtime "/kiroku/ws/metrics" \connection -> do
                  receive connection >>= assertType "snapshot"
                  send connection (object ["type" .= ("ping" :: Text), "oversized" .= Text.replicate 1024 "x"])
                  await "oversized input closes the socket" (drain connection)
              )
          assertBool "input cap terminates the actual connection" (case result of Left _ -> True; _ -> False)
          await "oversized input returned admission" (atomically (runtime.metricsConnections >>= check . (== 0))),
      testCase "a slow native subscriber receives overflow before surviving deltas and resynchronizes from a snapshot" $
        withFixture fixture ((profile False) {refreshMillis = inspectionLimit 10, maxQueuedFrames = inspectionLimit 2, maxQueuedBytes = inspectionLimit 1024, maxFrameBytes = inspectionLimit 512}) \runtime _ _ _ _ -> do
          source <- newIORef (0 :: Int)
          let item value = Item "one" (String "one") (object ["value" .= value])
              view = View "inspection-controlled" Protocol.Workflows (liftIO do stamp <- getCurrentTime; value <- readIORef source; pure (stamp, [item value], Nothing))
          driver <- Feed.acquireDriver runtime.feeds view >>= either (fail . show) pure
          ( do
              slow <- Feed.subscribe driver
              void (await "initial driver snapshot" (atomically (Feed.nextFrame slow)))
              forM_ [1 .. 5] \value -> do
                writeIORef source value
                await "bounded driver refresh" (atomically do snapshot <- Feed.driverSnapshot driver; case snapshot of Protocol.Snapshot {sequence} -> check (sequence == fromIntegral value); _ -> check False)
              overflow <- await "overflow notice" (atomically (Feed.nextFrame slow))
              case overflow of
                Protocol.ErrorFrame Protocol.QueueOverflow _ _ -> pure ()
                _ -> assertFailure "overflow was hidden from the slow subscriber"
              latest <- Feed.subscribe driver
              frame <- await "replacement snapshot" (atomically (Feed.nextFrame latest))
              case frame of
                Protocol.Snapshot {sequence, items} -> do
                  assertEqual "snapshot resumes at the authoritative sequence" 5 sequence
                  assertEqual "snapshot replaces lost deltas" [object ["value" .= (5 :: Int)]] items
                _ -> assertFailure "recovery did not begin from a complete snapshot"
              Feed.unsubscribe driver latest
              Feed.unsubscribe driver slow
            )
            `finally` Feed.releaseDriver runtime.feeds view,
      testCase "a retiring view keeps its slot until cancellation cleanup has joined" $
        withFixture fixture ((profile False) {refreshMillis = inspectionLimit 10, maxViews = inspectionLimit 1}) \runtime _ _ _ _ -> do
          blocked <- newIORef False
          entered <- newEmptyMVar
          cleanupEntered <- newEmptyMVar
          cleanupGate <- newEmptyMVar
          never <- newEmptyMVar
          let view =
                View
                  "inspection-retiring"
                  Protocol.Workflows
                  ( liftIO do
                      active <- readIORef blocked
                      if active then (putMVar entered () >> takeMVar never) `finally` (putMVar cleanupEntered () >> takeMVar cleanupGate) else pure ()
                      stamp <- getCurrentTime
                      pure (stamp, [], Nothing)
                  )
          driver <- Feed.acquireDriver runtime.feeds view >>= either (fail . show) pure
          _ <- Feed.subscribe driver
          writeIORef blocked True
          await "refresh entered" (takeMVar entered)
          Async.withAsync (Feed.releaseDriver runtime.feeds view) \release ->
            ( do
                await "retirement cleanup entered" (takeMVar cleanupEntered)
                refused <- Feed.acquireDriver runtime.feeds view
                assertBool "retiring slot cannot be replaced" (case refused of Left Feed.FeedRetiring -> True; _ -> False)
                assertEqual "retiring view remains charged" (Feed.FeedStats 1 0 True) =<< Feed.feedStats runtime.feeds
                writeIORef blocked False
                putMVar cleanupGate ()
                await "retirement joined" (Async.wait release)
            )
              `finally` void (tryPutMVar cleanupGate ())
          assertEqual "last cleanup releases the slot and cursor" (Feed.FeedStats 0 0 False) =<< Feed.feedStats runtime.feeds
    ]

socket :: InspectionRuntime -> String -> (WebSocket.Connection -> IO a) -> IO a
socket runtime path = WebSocket.runClientWith "127.0.0.1" runtime.port path WebSocket.defaultConnectionOptions [(hAuthorization, readCredential), (hOrigin, "https://ops.example")]

subscribe :: Text -> Value
subscribe feed = object ["type" .= ("subscribe" :: Text), "feed" .= feed]

send :: WebSocket.Connection -> Value -> IO ()
send connection = WebSocket.sendTextData connection . Aeson.encode

receive :: WebSocket.Connection -> IO Value
receive connection = do
  bytes <- await "WebSocket frame" (WebSocket.receiveData connection :: IO Lazy.ByteString)
  either (\problem -> assertFailure problem >> fail "invalid frame") pure (Aeson.eitherDecode bytes)

receiveType :: Text -> WebSocket.Connection -> IO ()
receiveType expected connection = do
  frame <- receive connection
  if field "type" frame == Just (String expected) then pure () else receiveType expected connection

assertType :: Text -> Value -> IO ()
assertType expected frame = assertEqual "native frame type" (Just (String expected)) (field "type" frame)

await :: String -> IO a -> IO a
await label action = timeout 7000000 action >>= maybe (assertFailure (label <> " timed out") >> fail "timeout") pure

waitStats :: InspectionRuntime -> Feed.FeedStats -> IO ()
waitStats runtime expected = do
  observed <- Feed.feedStats runtime.feeds
  if observed == expected then pure () else threadDelay 1000 >> waitStats runtime expected

-- A real peer with a tiny receive window makes native output hit backpressure;
-- the callback deliberately never reads a WebSocket payload.
smallReceiveSocket :: InspectionRuntime -> String -> (WebSocket.Connection -> IO a) -> IO a
smallReceiveSocket runtime path action = do
  addresses <- Socket.getAddrInfo Nothing (Just "127.0.0.1") (Just (show runtime.port))
  case addresses of
    [] -> fail "loopback address unavailable"
    address : _ -> bracket (Socket.socket (Socket.addrFamily address) Socket.Stream Socket.defaultProtocol) Socket.close \peer -> do
      Socket.setSocketOption peer Socket.RecvBuffer 1024
      Socket.connect peer (Socket.addrAddress address)
      WebSocket.runClientWithSocket peer "127.0.0.1" path WebSocket.defaultConnectionOptions [(hAuthorization, readCredential), (hOrigin, "https://ops.example")] action

drain :: WebSocket.Connection -> IO ()
drain connection = (WebSocket.receiveData connection :: IO Lazy.ByteString) >> drain connection

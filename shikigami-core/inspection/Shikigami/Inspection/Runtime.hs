-- | A separately authenticated operational listener over inspection-owned capacity.
module Shikigami.Inspection.Runtime
  ( InspectionRuntime (..),
    withInspectionRuntime,
    inspectionHttpConfig,
    inspectionFeedConfig,
    inspectionConnectionSettings,
    authorizeInspection,
  )
where

import Control.Concurrent.Async (race, wait, withAsync)
import Control.Concurrent.MVar
import Control.Concurrent.STM (STM, readTVar)
import Control.Exception (Exception, SomeAsyncException, SomeException, bracket, evaluate, fromException, throwIO, try)
import Control.Monad (unless)
import Data.Aeson ((.=))
import Data.ByteArray (constEq)
import Data.ByteString qualified as Bytes
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Keiro.Ops.Http qualified as Ops
import Keiro.Ops.Http.Budget qualified as Budget
import Kiroku.Metrics qualified as Metrics
import Kiroku.Store.Connection (ConnectionSettings, ConnectionSettingsM (..), KirokuStore (..))
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.WebSockets (isWebSocketsReq)
import Network.Wai.Handler.WebSockets qualified as WaiSocket
import Network.WebSockets qualified as WebSocket
import Network.WebSockets.Connection qualified as WebSocketConnection
import Network.WebSockets.Stream qualified as WebSocketStream
import Pgmq.Inspect.Config qualified as Pgmq
import Pgmq.Inspect.Env qualified as Pgmq
import Pgmq.Inspect.Server qualified as Pgmq
import PostgresqlConnectionString qualified as ConnectionString
import Shikigami.Inspection.Catalog (inspectionHooks)
import Shikigami.Inspection.Settings (InspectionSettings (..), MutationAccess (..), inspectionHostText, inspectionLimitInt, inspectionOriginText, inspectionPortInt, revealInspectionCredential)
import Shikigami.Log qualified as Log

-- Exposed observations are useful for qualification; callers do not own cleanup.
data InspectionRuntime = InspectionRuntime
  { port :: !Int,
    feeds :: !Ops.FeedHandle,
    metricsConnections :: !(STM Int)
  }

inspectionHttpConfig :: InspectionSettings -> Ops.OpsHttpConfig
inspectionHttpConfig settings =
  Ops.defaultOpsHttpConfig
    { Ops.mutations = if settings.mutationsEnabled == InspectionMutable then Ops.MutationsEnabled else Ops.MutationsDisabled,
      Ops.allowedOrigins = (map inspectionOriginText settings.allowedOrigins),
      Ops.inspectionLimits = Ops.InspectionLimits (inspectionLimitInt settings.maxConcurrentReads) (inspectionLimitInt settings.readDeadlineSeconds) (inspectionLimitInt settings.mutationDeadlineSeconds) (inspectionLimitInt settings.deliveryDeadlineSeconds) (inspectionLimitInt settings.statementTimeoutMillis) (inspectionLimitInt settings.maxResponseBytes) (inspectionLimitInt settings.maxRequestBytes)
    }

inspectionFeedConfig :: InspectionSettings -> Ops.FeedConfig
inspectionFeedConfig settings =
  Ops.defaultFeedConfig
    { Ops.fallbackInterval = fromIntegral (inspectionLimitInt settings.refreshMillis) / 1000,
      Ops.minRefreshInterval = fromIntegral (inspectionLimitInt settings.refreshMillis) / 1000,
      Ops.maxViews = (inspectionLimitInt settings.maxViews),
      Ops.maxConnections = (inspectionLimitInt settings.maxConnections),
      Ops.maxFrameBytes = (inspectionLimitInt settings.maxFrameBytes),
      Ops.maxQueuedBytes = (inspectionLimitInt settings.maxQueuedBytes),
      Ops.queueCapacity = (inspectionLimitInt settings.maxQueuedFrames),
      Ops.readTimeout = fromIntegral (min (inspectionLimitInt settings.readDeadlineSeconds) (inspectionLimitInt settings.deliveryDeadlineSeconds)),
      Ops.maxItems = 100
    }

-- Parse through the driver's structured connection-string library. Preserve
-- existing options, then impose finite connection and lock budgets. Hasql's
-- public inspection pool retains its finite 10-second acquisition timeout;
-- the whole read also has the shorter application deadline.
inspectionConnectionSettings :: ConnectionSettings -> Either Text ConnectionSettings
inspectionConnectionSettings settings = do
  parsed <- either (const (Left "invalid inspection database connection string")) Right (ConnectionString.parse settings.connString)
  let options = maybe "" (<> " ") (Map.lookup "options" (ConnectionString.toParams parsed))
      bounded = parsed <> ConnectionString.param "connect_timeout" "2" <> ConnectionString.param "options" (options <> "-c lock_timeout=250ms")
  pure settings {connString = ConnectionString.toUrl bounded, observationHandler = Nothing}

-- The writer owns the store and collector; inspection substitutes only a pool.
-- Stop/join accepted sockets, then feed drivers and PGMQ refreshes, then the pool.
withInspectionRuntime :: Maybe InspectionSettings -> Log.Logger -> ConnectionSettings -> KirokuStore -> Metrics.KirokuMetrics -> [Ops.MountedSurface] -> (Maybe InspectionRuntime -> IO a) -> IO a
withInspectionRuntime Nothing _ _ _ _ _ action = action Nothing
withInspectionRuntime (Just settings) logger connection store metrics extras action = do
  bounded <- either (fail . Text.unpack) pure (inspectionConnectionSettings connection)
  origins <- either (const (fail "invalid inspection Origin policy")) pure (traverse Metrics.allowedOrigin (map inspectionOriginText settings.allowedOrigins))
  let http = inspectionHttpConfig settings
      feeds = inspectionFeedConfig settings
      server = Ops.defaultOpsHttpServerConfig {Ops.bindHost = (inspectionHostText settings.host), Ops.port = (inspectionPortInt settings.port), Ops.requestTimeoutSeconds = (inspectionLimitInt settings.deliveryDeadlineSeconds) + (inspectionLimitInt settings.readDeadlineSeconds) + 1}
      metricsConfig = Metrics.defaultConfig {Metrics.cors = Metrics.corsAllowOrigins origins, Metrics.wsMaxConnections = (inspectionLimitInt settings.maxConnections), Metrics.wsEventQueueCap = fromIntegral (inspectionLimitInt settings.maxQueuedFrames), Metrics.wsPushIntervalUs = (inspectionLimitInt settings.refreshMillis) * 1000}
      pgmqConfig = Pgmq.defaultInspectConfig {Pgmq.corsPolicy = maybe Pgmq.CorsDisabled (Pgmq.CorsAllowOrigins . fmap Text.encodeUtf8) (NonEmpty.nonEmpty (map inspectionOriginText settings.allowedOrigins)), Pgmq.wsMaxConnections = (inspectionLimitInt settings.maxConnections), Pgmq.wsMaxSubscriptions = (inspectionLimitInt settings.maxViews), Pgmq.wsQueueCapacity = fromIntegral (inspectionLimitInt settings.maxQueuedFrames), Pgmq.wsMaxQueues = (inspectionLimitInt settings.maxViews), Pgmq.wsMaxFrameBytes = (inspectionLimitInt settings.maxFrameBytes), Pgmq.maxConcurrentReads = (inspectionLimitInt settings.maxConcurrentReads), Pgmq.pollIntervalUs = (inspectionLimitInt settings.refreshMillis) * 1000, Pgmq.metricsMinRefreshUs = (inspectionLimitInt settings.refreshMillis) * 1000}
  Ops.withOpsInspectionPool http.inspectionLimits bounded \pool -> do
    let inspectionStore = store {pool}
    metricsState <- Metrics.newWebSocketState (inspectionLimitInt settings.maxConnections)
    -- Select actual providers explicitly. Protected history is outside browser
    -- display authority; no owner JSON or native event-tail protocol is rewritten.
    let providers =
          Metrics.defaultServerProviders
            { Metrics.subscriptionStatus = Just (Metrics.storeSubscriptionStatus inspectionStore),
              Metrics.checkpointInventory = Just (Metrics.storeCheckpointInventory inspectionStore),
              Metrics.webSocketChannels = Metrics.WebSocketChannels True False,
              Metrics.webSocketServer = \pending ->
                if Bytes.takeWhile (/= 63) (WebSocket.requestPath (WebSocket.pendingRequest pending)) == "/ws/metrics"
                  then Metrics.websocketApp metricsConfig metrics inspectionStore metricsState pending
                  else WebSocket.rejectRequest pending "event history is outside inspection display authority"
            }
    checkpointGate <- newMVar ()
    let serializedProviders =
          providers
            { Metrics.checkpointInventory = Just (withMVar checkpointGate (const (Metrics.storeCheckpointInventory inspectionStore)))
            }
        postgres = do
          Metrics.DependencyStatus name healthy latency detail <- Metrics.postgresPing inspectionStore
          pure (Metrics.DependencyStatus name healthy latency (fmap (const "database inspection unavailable") detail))
    companionBudget <- Budget.newInspectionBudget http.inspectionLimits
    Pgmq.withInspectRuntime pgmqConfig (Pgmq.poolEnv pool Nothing) \pgmq ->
      Ops.withFeedHandle http feeds inspectionStore \handle -> do
        keiro <- Ops.opsApplicationWithFeeds http handle inspectionHooks inspectionStore
        let companions = [Ops.MountedSurface Ops.kirokuPrefix (boundedMetricsSocket settings serializedProviders.webSocketServer (Metrics.combinedAppWithProviders metricsConfig metrics [postgres] serializedProviders)), Ops.MountedSurface Ops.pgmqPrefix pgmq.runtimeApplication] <> extras
            boundedCompanions = map (\surface -> surface {Ops.application = boundedCompanion settings companionBudget surface.application}) companions
        router <- either (fail . Text.unpack . Ops.renderComposeError) pure (Ops.composeSurfaces (Ops.ComposeConfig (map inspectionOriginText settings.allowedOrigins)) (Ops.MountedSurface Ops.keiroPrefix keiro : boundedCompanions))
        let application = authorizeInspection settings logger router
        Ops.withOpsHttpServer server application \listener -> do
          Log.logInfo logger "inspection.listening" ["host" .= (inspectionHostText settings.host), "port" .= listener.serverPort, "scope" .= ("this-process" :: Text)]
          result <- race (wait listener.serverThread >> fail "inspection listener stopped unexpectedly") (action (Just (InspectionRuntime listener.serverPort handle (readTVar metricsState.connectionCount))))
          either pure pure result

-- Origin checks stay with each native surface. Authentication is independent.
-- Preflight performs no operation and needs no credential; the actual request does.
authorizeInspection :: InspectionSettings -> Log.Logger -> Middleware
authorizeInspection settings logger application request respond
  | requestMethod request == methodOptions = application request respond
  | otherwise = case [value | (name, value) <- requestHeaders request, name == hAuthorization] of
      [value]
        | credential settings.readToken value || maybe False (`credential` value) settings.writeToken ->
            if requestMethod request `elem` [methodGet, methodHead]
              then if metadataRead (pathInfo request) then application request respond else respond (failure status403 "display_authority_required")
              else
                if requiresErasureAuthority (pathInfo request)
                  then respond (failure status403 "erasure_authority_required")
                  else
                    if settings.mutationsEnabled == InspectionMutable && maybe False (`credential` value) settings.writeToken
                      then do
                        invocation <- UUID.toText <$> UUID.nextRandom
                        Log.logInfo logger "operator.inspection.invoked" ["invocation" .= invocation, "method" .= Text.decodeUtf8 (requestMethod request), "path" .= Text.decodeUtf8With (\_ _ -> Just '?') (Bytes.take 512 (rawPathInfo request))]
                        application request \response -> do
                          Log.logInfo logger "operator.inspection.finished" ["invocation" .= invocation, "status" .= statusCode (responseStatus response)]
                          respond response
                      else respond (failure status403 "mutation_authority_required")
      _ -> respond (mapResponseHeaders ((hWWWAuthenticate, "Bearer") :) (failure status401 "administrative_credential_required"))
  where
    credential expected actual = constEq (Text.encodeUtf8 ("Bearer " <> revealInspectionCredential expected)) actual

-- A generic administrative credential cannot supply the application erasure
-- decision required before permanent history deletion. No such HTTP hook exists.
requiresErasureAuthority :: [Text] -> Bool
requiresErasureAuthority ("keiro" : "stream" : "hard-delete" : _) = True
requiresErasureAuthority _ = False

-- Caller authority only: owning surfaces still parse flags, cursors and IDs.
metadataRead :: [Text] -> Bool
metadataRead = \case
  [] -> True
  ["keiro", "health"] -> True
  ["keiro", "ws"] -> True
  ["keiro", "aggregate", verb] -> verb `elem` ["types", "list", "show", "snapshot"]
  "keiro" : "wf" : "inspect" : verb : _ -> verb `elem` ["list", "header"]
  ["keiro", "timer", "pending", "list"] -> True
  "keiro" : "projection" : verb : _ -> verb `elem` ["status", "position"]
  "keiro" : "shard" : verb : _ -> verb `elem` ["list", "status"]
  ["keiro", kind, "backlog"] -> kind `elem` ["inbox", "outbox"]
  "keiro" : "rebuild" : "versioned" : "status" : _ -> True
  "keiro" : "rebuild" : verb : _ -> verb `elem` ["list", "preview", "status", "retired", "external-read"]
  ["kiroku", "capabilities"] -> True
  "kiroku" : "ws" : rest -> rest == ["metrics"]
  "kiroku" : kind : _ -> kind `elem` ["metrics", "health", "subscriptions", "subscription-checkpoints"]
  ["pgmq", "queues"] -> True
  ["pgmq", "queues", _] -> True
  ["pgmq", "queues", _, kind] -> kind `elem` ["metrics", "bindings"]
  "pgmq" : kind : _ -> kind `elem` ["health", "ws"]
  "shibuya" : kind : _ -> kind `elem` ["metrics", "health", "ws"]
  _ -> False

failure :: Status -> Text -> Response
failure status code = Ops.errorResponse (Ops.OpsHttpError status code "administrative inspection request refused" Nothing)

-- Kiroku's native server app owns its snapshot protocol, Origin checks and
-- collector lifetime. The public WAI raw-I/O seam supplies finite frame/input
-- and delivery budgets through the released stream/handshake adapter API. No
-- accepted connection, frame protocol or library-private state is rewritten.
boundedMetricsSocket :: InspectionSettings -> WebSocket.ServerApp -> Middleware
boundedMetricsSocket settings serverApp fallback request respond
  | isWebSocketsReq request = respond (responseRaw run (failure status400 "websocket_upgrade_required"))
  | otherwise = fallback request respond
  where
    options =
      WebSocket.defaultConnectionOptions
        { WebSocket.connectionFramePayloadSizeLimit = WebSocket.SizeLimit (fromIntegral (inspectionLimitInt settings.maxRequestBytes)),
          WebSocket.connectionMessageDataSizeLimit = WebSocket.SizeLimit (fromIntegral (inspectionLimitInt settings.maxRequestBytes))
        }
    run source sink =
      bracket
        ( WebSocketStream.makeStream
            (do chunk <- source; pure (if Bytes.null chunk then Nothing else Just chunk))
            ( \case
                Nothing -> pure ()
                Just chunk -> do
                  bytes <- evaluate (Lazy.length (Lazy.take (fromIntegral (inspectionLimitInt settings.maxFrameBytes) + 1) chunk))
                  unless (bytes <= fromIntegral (inspectionLimitInt settings.maxFrameBytes)) (throwIO ResultTooLarge)
                  Budget.withInspectionDelivery (inspectionLimitInt settings.deliveryDeadlineSeconds) (mapM_ sink (Lazy.toChunks chunk))
            )
        )
        WebSocketStream.close
        ( \stream ->
            serverApp
              WebSocketConnection.PendingConnection
                { WebSocketConnection.pendingOptions = options,
                  WebSocketConnection.pendingRequest = WaiSocket.getRequestHead request,
                  WebSocketConnection.pendingOnAccept = const (pure ()),
                  WebSocketConnection.pendingStream = stream
                }
        )

-- Companion packages keep their own wire protocol. Bound public HTTP reads,
-- encoding and delivery around their applications; their socket runtimes own WS.
boundedCompanion :: InspectionSettings -> Budget.InspectionBudget -> Middleware
boundedCompanion settings budget application request respond
  | Bytes.length (rawPathInfo request) + Bytes.length (rawQueryString request) > (inspectionLimitInt settings.maxRequestBytes) = respond (failure status413 "inspection_request_too_large")
  | isWebSocketsReq request && pathInfo request `elem` [["ws"], ["ws", "metrics"], ["ws", "events"]] = application request respond
  | otherwise = do
      admitted <- Budget.withInspectionAdmission budget do
        ready <- newEmptyMVar
        delivered <- newEmptyMVar
        withAsync (application request (\response -> capture response >>= putMVar ready >> takeMVar delivered)) \worker -> do
          computed <- Budget.withInspectionDeadline (inspectionLimitInt settings.readDeadlineSeconds) (trySynchronous (race (takeMVar ready) (wait worker >> fail "inspection application returned without response")))
          case computed of
            Left _ -> respond (failure status504 "inspection_timeout")
            Right (Left problem) -> respond $ case fromException problem of
              Just ResultTooLarge -> failure status413 "inspection_result_too_large"
              Nothing -> failure status503 "inspection_failed"
            Right (Right (Right _)) -> respond (failure status503 "inspection_failed")
            Right (Right (Left response)) -> Budget.withInspectionDelivery (inspectionLimitInt settings.deliveryDeadlineSeconds) do
              result <- respond response
              putMVar delivered result
              wait worker
      case admitted of
        Left _ -> respond (failure status503 "inspection_busy")
        Right result -> pure result
  where
    capture response = do
      let (status, headers, stream) = responseToStream response
      chunks <- newIORef (0 :: Int, [])
      stream \body ->
        body
          ( \builder -> do
              (size, previous) <- readIORef chunks
              let output = Lazy.take (fromIntegral ((inspectionLimitInt settings.maxResponseBytes) - size + 1)) (Builder.toLazyByteString builder)
              count <- evaluate (fromIntegral (Lazy.length output))
              unless (size + count <= (inspectionLimitInt settings.maxResponseBytes)) (throwIO ResultTooLarge)
              writeIORef chunks (size + count, output : previous)
          )
          (pure ())
      (_, parts) <- readIORef chunks
      pure (responseLBS status headers (mconcat (reverse parts)))

data CompanionFailure = ResultTooLarge deriving stock (Show)

instance Exception CompanionFailure

trySynchronous :: IO a -> IO (Either SomeException a)
trySynchronous action =
  try action >>= \case
    Left problem | Just (_ :: SomeAsyncException) <- fromException problem -> throwIO problem
    result -> pure result

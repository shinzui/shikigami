module Shikigami.InspectionHttpSpec (tests, withFixture, profile, inspectionLimit, readCredential, request, Result (..), field) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar
import Control.Exception (bracket, finally)
import Control.Lens ((&), (.~))
import Control.Monad (forM_, void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as Vector
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Keiro.Command (RunCommandOptions (..), defaultRunCommandOptions, runCommand)
import Keiro.Ops.Http (MountedSurface (..), shibuyaPrefix)
import Keiro.PGMQ qualified
import Keiro.Stream qualified as Stream
import Keiro.Telemetry (newKeiroMetrics)
import Kiroku.Metrics qualified as Metrics
import Kiroku.Otel.Subscription (spanCatchup)
import Kiroku.Otel.TraceContext (extractTraceContext)
import Kiroku.Store.Connection (ConnectionSettings, ConnectionSettingsM (..), KirokuStore (..), defaultConnectionSettings)
import Kiroku.Store.Observability (KirokuEvent (..), SubscriptionGroupContext (..))
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Subscription.Fsm (DeadLetterReason (..))
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (GlobalPosition (..), RecordedEvent (..), StreamName (..), StreamVersion (..))
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types
import Network.Wai qualified as Wai
import OpenTelemetry.Exporter.InMemory (assertMetricNamed, assertSpanNamed, inMemoryListExporter, inMemoryMetricExporter)
import OpenTelemetry.Exporter.Metric (MetricExport (..), NumberValue (..), SumDataPoint (..))
import OpenTelemetry.Metric qualified as Metric
import OpenTelemetry.Resource (emptyMaterializedResources)
import OpenTelemetry.Trace qualified as Trace
import OpenTelemetry.Trace.Core qualified as TraceCore
import Pgmq qualified
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Execution.Transcript (ExecutionId (..))
import Shikigami.ExecutionLifecycle.Generated.Domain qualified as Execution
import Shikigami.ExecutionLifecycle.Generated.EventStream (executionLifecycleCategory, executionLifecycleEventStream)
import Shikigami.Inspection.Runtime (InspectionRuntime (..), withInspectionRuntime)
import Shikigami.Inspection.Settings (InspectionLimit, InspectionSettings (..), parseInspectionLimit)
import Shikigami.Inspection.Store (withObservedStore)
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Runtime (registerRuntimeCatalog, runtimeConnectionSettings)
import Shikigami.Trigger.Enqueue (ensureRunQueue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

readCredential, writeCredential :: ByteString
readCredential = "Bearer inspection-reader-012345678901234567890123456789"
writeCredential = "Bearer inspection-writer-012345678901234567890123456789"

profile :: Bool -> InspectionSettings
profile mutations = case Aeson.fromJSON (object ["port" .= (0 :: Int), "readToken" .= Text.decodeUtf8 (dropBearer readCredential), "writeToken" .= Text.decodeUtf8 (dropBearer writeCredential), "mutationsEnabled" .= mutations, "allowedOrigins" .= ["https://ops.example" :: Text]]) of
  Aeson.Success settings -> settings
  Aeson.Error problem -> error problem
  where
    dropBearer = Text.encodeUtf8 . Text.drop 7 . Text.decodeUtf8

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "administrative HTTP inspection"
    [ testCase "configuration refuses unknown fields, weak/equal credentials and invalid budgets" do
        let valid = object ["readToken" .= Text.decodeUtf8 (Text.encodeUtf8 (Text.replicate 32 "r"))]
            supplied key value = case valid of Object fields -> Object (KeyMap.insert key value fields); _ -> valid
        forM_ [supplied "maxConcurrentReads" (Aeson.toJSON (0 :: Int)), supplied "deliveryDeadlineSeconds" (Aeson.toJSON (0 :: Int)), supplied "maxQueuedFrames" (Aeson.toJSON (1 :: Int)), supplied "maxQueuedBytes" (Aeson.toJSON (1 :: Int)), supplied "allowedOrigins" (Aeson.toJSON ["*" :: Text]), supplied "readToken" (String "short"), supplied "writeToken" (String (Text.replicate 32 "r")), supplied "mutationsEnabled" (Bool True), supplied "misspelled" (Bool True)] \value ->
          assertBool "invalid profile must fail before resource acquisition" (isLeft (Aeson.parseEither Aeson.parseJSON value :: Either String InspectionSettings)),
      testCase "authenticated real listener shares CLI lifecycle facts and refuses protected history" $
        withFixture fixture (profile False) \runtime _ store _ manager -> do
          tracer <- noopTracer
          let env = AppEnv (defaultConnectionSettings "postgresql://127.0.0.1:1/not-used") tracer Nothing (Just store)
              identifier = "http-inspection"
          appended <- runAppIO env (runCommand defaultRunCommandOptions executionLifecycleEventStream (Stream.entityStream executionLifecycleCategory identifier) (Execution.AdmitExecution (Execution.AdmitExecutionData (ExecutionId identifier) "HTTP_PRIVATE_DIGEST")))
          assertBool "native aggregate fixture" (case appended of Right (Right _) -> True; _ -> False)
          forM_ ["/", "/keiro/aggregate/types", "/kiroku/capabilities", "/pgmq/queues"] \path -> do
            denied <- request manager runtime.port methodGet path [] ""
            assertEqual "unauthenticated request" status401 denied.status
            duplicate <- request manager runtime.port methodGet path [(hAuthorization, readCredential), (hAuthorization, readCredential)] ""
            assertEqual "duplicate credential header" status401 duplicate.status
            allowed <- request manager runtime.port methodGet path [(hAuthorization, readCredential)] ""
            assertEqual "authorized metadata request" status200 allowed.status
          viewed <- request manager runtime.port methodGet "/keiro/aggregate/show?name=ExecutionLifecycle&id=http-inspection" [(hAuthorization, readCredential)] ""
          assertEqual "HTTP lifecycle is the CLI allowlist" (Just (object ["executionId" .= identifier, "revision" .= (0 :: Int), "pendingReceipts" .= (0 :: Int)])) (field "state" viewed.value)
          assertBool "no private digest in display" (not ("HTTP_PRIVATE_DIGEST" `Text.isInfixOf` Text.decodeUtf8 (Lazy.toStrict viewed.body)))
          capabilities <- request manager runtime.port methodGet "/kiroku/capabilities" [(hAuthorization, readCredential)] ""
          assertEqual "raw browse is not advertised" (Just (Bool False)) (field "routes" capabilities.value >>= field "browse")
          assertEqual "event tail is not advertised" (Just (Bool False)) (field "routes" capabilities.value >>= field "websocket_events")
          forM_ ["/kiroku/events", "/kiroku/ws/events", "/pgmq/queues/shikigami_run_jobs/messages", "/keiro/wf/inspect/journal/private/run"] \path -> do
            denied <- request manager runtime.port methodGet path [(hAuthorization, readCredential)] ""
            assertEqual "protected payload is outside display authority" status403 denied.status,
      testCase "native mutations require distinct authority, Origin policy, preview and exact JSON confirmation" $
        withFixture fixture (profile True) \runtime logs _ _ manager -> do
          let path = "/keiro/inbox/gc?older_than=30d"
              authorized = [(hAuthorization, writeCredential)]
          readOnly <- request manager runtime.port methodPost path [(hAuthorization, readCredential)] ""
          assertEqual "read credential cannot mutate" status403 readOnly.status
          foreignOrigin <- request manager runtime.port methodPost path (authorized <> [(hOrigin, "https://foreign.example")]) ""
          assertEqual "actual bodyless POST checks Origin" status403 foreignOrigin.status
          duplicate <- request manager runtime.port methodPost path (authorized <> [(hOrigin, "https://ops.example"), (hOrigin, "https://ops.example")]) ""
          assertEqual "duplicate Origin refused" status403 duplicate.status
          preview <- request manager runtime.port methodPost path authorized ""
          assertEqual "native preview succeeds without execution" status200 preview.status
          assertEqual "native preview envelope" (Just (String "preview")) (field "outcome" preview.value)
          wrongMedia <- request manager runtime.port methodPost path (authorized <> [(hContentType, "text/plain")]) "{\"confirm\":\"execute\"}"
          assertEqual "non-JSON confirmation refused" status415 wrongMedia.status
          invalid <- request manager runtime.port methodPost path (authorized <> [(hContentType, "application/json")]) "{\"confirm\":true}"
          assertEqual "confirmation uses the native exact protocol" status400 invalid.status
          executed <- request manager runtime.port methodPost path (authorized <> [(hContentType, "application/json"), (hOrigin, "https://ops.example")]) "{\"confirm\":\"execute\"}"
          assertEqual "native confirmed operation" status200 executed.status
          assertEqual "native execution envelope" (Just (String "executed")) (field "outcome" executed.value)
          erasure <- request manager runtime.port methodPost "/keiro/stream/hard-delete/protected-history" (authorized <> [(hContentType, "application/json")]) "{\"confirm\":\"execute\"}"
          assertEqual "generic mutation authority cannot supply a governed erasure decision" status403 erasure.status
          assertEqual "separate erasure authority is explicit" (Just (String "erasure_authority_required")) (field "error" erasure.value >>= field "code")
          lines <- readIORef logs
          assertBool "mutation attempts have structured audit evidence" (any (Text.isInfixOf "operator.inspection.invoked" . Text.decodeUtf8) lines && any (Text.isInfixOf "operator.inspection.finished" . Text.decodeUtf8) lines)
          assertBool "credentials never enter audit" (all (not . Text.isInfixOf "inspection-writer-" . Text.decodeUtf8) lines),
      testCase "mutation policy stays disabled even for a valid write credential" $
        withFixture fixture (profile False) \runtime _ _ _ manager -> do
          denied <- request manager runtime.port methodPost "/keiro/inbox/gc" [(hAuthorization, writeCredential), (hContentType, "application/json")] "{\"confirm\":\"execute\"}"
          assertEqual "explicit enablement required" status403 denied.status,
      testCase "native administrative repair retains live-only projection policy" $
        withFixture fixture (profile True) \runtime _ _ _ manager -> do
          preview <- request manager runtime.port methodGet "/keiro/rebuild/preview/run_evidence_store" [(hAuthorization, readCredential)] ""
          assertEqual "native catalog preview is mounted" status200 preview.status
          refused <- request manager runtime.port methodPost "/keiro/rebuild/reproject-stream/run_evidence_store/run_evidence_writer/runEvidence-shikigami_run_evidence_01h455vb4pex5vsknk084sn02q" [(hAuthorization, writeCredential), (hContentType, "application/json")] "{\"confirm\":\"execute\"}"
          assertEqual "administrative confirmation cannot invent a live-only replay adapter" status422 refused.status
          assertEqual "native typed failure envelope" (Just (String "command_failed")) (field "error" refused.value >>= field "code"),
      testCase "PGMQ DLQ read requires mutation authority and confirmation before leasing a real entry" $
        withFixture fixture (profile True) \runtime _ store _ manager -> do
          ensureRunQueue store.pool >>= either (fail . show) pure
          identifier <- Pool.use store.pool (Pgmq.sendMessage (Pgmq.SendMessage RunJobs.runJob.jobQueue.dlqName (Pgmq.MessageBody (object ["original_message_id" .= (1 :: Int), "original_message" .= Null, "dead_letter_reason" .= ("inspection fixture" :: Text)])) Nothing)) >>= either (fail . show) pure
          let lookupEntry = Pool.use store.pool (Pgmq.lookupMessage (Pgmq.LookupMessage "shikigami_run_jobs_dlq" identifier)) >>= either (fail . show) (maybe (fail "missing task-owned DLQ row") pure)
              path = "/keiro/pgmq/dlq/read?queue=shikigami_run_jobs&limit=1"
          before <- lookupEntry
          assertEqual "fresh entry has never been leased" 0 before.readCount
          denied <- request manager runtime.port methodPost path [(hAuthorization, readCredential)] ""
          assertEqual "a viewer cannot lease an entry" status403 denied.status
          preview <- request manager runtime.port methodPost path [(hAuthorization, writeCredential)] ""
          assertEqual "the operator first receives a preview" status200 preview.status
          untouched <- lookupEntry
          assertEqual "preview did not reserve or increment the row" before.readCount untouched.readCount
          assertEqual "preview left visibility unchanged" before.visibilityTime untouched.visibilityTime
          leased <- request manager runtime.port methodPost path [(hAuthorization, writeCredential), (hContentType, "application/json")] "{\"confirm\":\"execute\"}"
          assertEqual "confirmed native lease" status200 leased.status
          after <- lookupEntry
          assertEqual "native read reserves once" 1 after.readCount
          assertBool "native visibility moved forward" (after.visibilityTime > before.visibilityTime),
      testCase "native live schema check refuses drift on the next request" $
        withFixture fixture (profile False) \runtime _ store _ manager -> do
          altered <- Pool.use store.pool (Session.script "CREATE TABLE keiro.shikigami_inspection_drift (id bigint)")
          assertBool "task-owned schema fault injected" (case altered of Right () -> True; _ -> False)
          refused <- request manager runtime.port methodGet "/keiro/aggregate/types" [(hAuthorization, readCredential)] ""
          assertEqual "fresh request rechecks live schema" status409 refused.status
          assertEqual "structured drift code" (Just (String "schema_drift")) (field "error" refused.value >>= field "code"),
      testCase "companion admission, read deadlines and encoded bytes are bounded over the actual listener" do
        entered <- newEmptyMVar
        stopped <- newEmptyMVar
        release <- newEmptyMVar
        let controlled request respond = case Wai.pathInfo request of
              ["health"] -> (putMVar entered () >> takeMVar release >> respond (Wai.responseLBS status200 [(hContentType, "application/json")] "{}")) `finally` putMVar stopped ()
              ["metrics"] -> respond (Wai.responseLBS status200 [(hContentType, "application/json")] (Aeson.encode (Text.replicate 2048 "x")))
              _ -> respond (Wai.responseLBS status200 [(hContentType, "application/json")] "{}")
            selected = (profile False) {maxConcurrentReads = inspectionLimit 1, readDeadlineSeconds = inspectionLimit 1, statementTimeoutMillis = inspectionLimit 500, maxResponseBytes = inspectionLimit 1024, maxFrameBytes = inspectionLimit 256, maxQueuedBytes = inspectionLimit 512}
        withFixtureSurfaces [MountedSurface shibuyaPrefix controlled] fixture selected \runtime _ _ _ manager -> do
          Async.withAsync (request manager runtime.port methodGet "/shibuya/health" [(hAuthorization, readCredential)] "") \pending -> do
            takeMVar entered
            busy <- request manager runtime.port methodGet "/shibuya/health/live" [(hAuthorization, readCredential)] ""
            assertEqual "no waiting queue grows behind a slow read" status503 busy.status
            expired <- Async.wait pending
            assertEqual "bounded read times out" status504 expired.status
            takeMVar stopped
          healthy <- request manager runtime.port methodGet "/shibuya/health/live" [(hAuthorization, readCredential)] ""
          assertEqual "cancelled read returned admission" status200 healthy.status
          huge <- request manager runtime.port methodGet "/shibuya/metrics" [(hAuthorization, readCredential)] ""
          assertEqual "encoding is bounded before headers or delivery" status413 huge.status
          assertEqual "stable byte budget error" (Just (String "inspection_result_too_large")) (field "error" huge.value >>= field "code"),
      testCase "collector, lifecycle tracing, Keiro bridge and passthrough compose before store acquisition" $
        withShikigamiFreshDatabase fixture \connection -> do
          seen <- newIORef (0 :: Int)
          (exporter, exported) <- inMemoryMetricExporter
          (processor, spans) <- inMemoryListExporter
          bracket (Trace.createTracerProvider [processor] Trace.emptyTracerProviderOptions) (\provider -> void (Trace.shutdownTracerProvider provider Nothing)) \traceProvider ->
            bracket (Metric.createMeterProvider emptyMaterializedResources Metric.defaultSdkMeterProviderOptions {Metric.metricExporter = Just exporter}) (\(provider, _) -> void (Metric.shutdownMeterProvider provider Nothing)) \(provider, _) -> do
              let tracer = Trace.makeTracer traceProvider "shikigami-inspection-test" Trace.tracerOptions
              meter <- Metric.getMeter provider "shikigami-inspection-test"
              engineMetrics <- newKeiroMetrics meter
              let base = runtimeConnectionSettings Log.silentLogger (Just engineMetrics) connection
                  settings :: ConnectionSettings
                  settings = (base & #eventHandler .~ (Just (\event -> maybe (pure ()) ($ event) base.eventHandler >> modifyIORef' seen (+ 1))))
              withObservedStore tracer settings \store metrics -> do
                let emit event = maybe (assertFailure "observed event callback missing") ($ event) store.eventHandler
                emit (KirokuEventSubscriptionStarted (SubscriptionName "inspection-fixture") (GlobalPosition 0) NonGroup)
                emit (KirokuEventSubscriptionCaughtUp (SubscriptionName "inspection-fixture") (GlobalPosition 0) NonGroup)
                emit (KirokuEventSubscriptionDeadLettered (SubscriptionName "inspection-fixture") (GlobalPosition 1) (DeadLetterMaxAttempts 5) NonGroup)
                snapshot <- Metrics.snapshotMetrics metrics
                assertEqual "collector sees lifecycle start" 1 snapshot.counters.subscriptionsStarted
                assertEqual "collector sees lifecycle progress" 1 snapshot.counters.subscriptionsCaughtUp
                assertEqual "collector sees terminal dead letter" 1 snapshot.counters.subscriptionsDeadLettered
                readIORef seen >>= assertBool "existing passthrough remains installed" . (>= 3)
                void (assertSpanNamed spans spanCatchup)
                flushed <- Metric.forceFlushMeterProvider provider Nothing
                assertEqual "metric exporter flush" Metric.FlushSuccess flushed
                counter <- assertMetricNamed exported "keiro.subscription.deadlettered"
                case counter of
                  MetricExportSum {mesSumPoints} -> assertEqual "the bridge records the same terminal event once" [IntNumber 1] (map (.sumDataPointValue) (Vector.toList mesSumPoints))
                  _ -> assertFailure "wrong Keiro counter export kind"
                let env = AppEnv settings tracer (Just engineMetrics) (Just store)
                    options :: RunCommandOptions
                    options = defaultRunCommandOptions {metadata = Just (object ["retained" .= True])}
                Trace.inSpan tracer "inspection-metadata" Trace.defaultSpanArguments do
                  recorded <- runAppIO env (runCommand options executionLifecycleEventStream (Stream.entityStream executionLifecycleCategory "inspection-trace") (Execution.AdmitExecution (Execution.AdmitExecutionData (ExecutionId "inspection-trace") "private-trace-digest")))
                  assertBool "native traced command succeeds" (case recorded of Right (Right _) -> True; _ -> False)
                events <- runAppIO env (readStreamForward (StreamName "executionLifecycle-inspection-trace") (StreamVersion 0) 10) >>= either (fail . show) pure
                case Vector.toList events of
                  [event] -> do
                    assertEqual "active W3C context reaches the native append" (Just True) (TraceCore.isValid <$> extractTraceContext event)
                    assertEqual "enrichment preserves existing metadata" (Just (Bool True)) (event.metadata >>= field "retained")
                  _ -> assertFailure "native command did not record one event"
    ]

withFixture :: DatabaseFixture -> InspectionSettings -> (InspectionRuntime -> IORef [ByteString] -> KirokuStore -> Metrics.KirokuMetrics -> Http.Manager -> IO a) -> IO a
withFixture = withFixtureSurfaces []

withFixtureSurfaces :: [MountedSurface] -> DatabaseFixture -> InspectionSettings -> (InspectionRuntime -> IORef [ByteString] -> KirokuStore -> Metrics.KirokuMetrics -> Http.Manager -> IO a) -> IO a
withFixtureSurfaces surfaces fixture settings action = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  messages <- newIORef []
  let logger = Log.Logger Log.Info (\message -> atomicModifyIORef' messages (\previous -> (message : previous, ())))
      connections = defaultConnectionSettings connection
  withObservedStore tracer connections \store metrics -> do
    registerRuntimeCatalog store
    withInspectionRuntime (Just settings) logger connections store metrics surfaces \case
      Nothing -> assertFailure "enabled listener was not allocated" >> fail "listener missing"
      Just runtime -> bracket (Http.newManager Http.defaultManagerSettings) Http.closeManager (action runtime messages store metrics)

data Result = Result {status :: !Status, body :: !Lazy.ByteString, value :: !Value}

request :: Http.Manager -> Int -> Method -> String -> RequestHeaders -> Lazy.ByteString -> IO Result
request manager port method path headers body = do
  initial <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
  response <- Http.httpLbs initial {Http.method = method, Http.requestHeaders = headers, Http.requestBody = Http.RequestBodyLBS body, Http.responseTimeout = Http.responseTimeoutMicro 10000000} manager
  value <- either (\problem -> assertFailure ("invalid native JSON: " <> problem) >> fail "invalid JSON") pure (Aeson.eitherDecode (Http.responseBody response))
  pure (Result (Http.responseStatus response) (Http.responseBody response) value)

field :: Aeson.Key -> Value -> Maybe Value
field key (Object fields) = KeyMap.lookup key fields
field _ _ = Nothing

inspectionLimit :: Int -> InspectionLimit scope
inspectionLimit = either (error . show) id . parseInspectionLimit

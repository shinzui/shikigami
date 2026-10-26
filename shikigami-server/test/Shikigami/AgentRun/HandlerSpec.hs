module Shikigami.AgentRun.HandlerSpec (tests, withRunServer, right) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Keiro.Workflow (WorkflowId (..), runWorkflow)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (runStoreIO)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import OpenTelemetry.Trace qualified as Trace
import Pgmq qualified
import Relay.Pagination (Connection (..), Direction (..), PageRequest (..), cursorToText)
import Relay.Pagination.Conformance (checkConformance, conformancePassed, defaultConformanceConfig, renderConformanceReport)
import Servant.Health (ProbeVerdict (Healthy))
import Shikigami.Agent.Catalog (AgentCatalog (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.AgentRun.Api
import Shikigami.AgentRun.Status (deriveRunStatus)
import Shikigami.Api.Problem (ProblemDetails (..))
import Shikigami.App.Config (defaultAppConfig)
import Shikigami.Directory qualified as Directory
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport
import Shikigami.Prelude
import Shikigami.Server.App (shikigamiApplication)
import Shikigami.Server.Boot (newServerEnvWith)
import Shikigami.Trigger.Enqueue (ensureRunQueue, runQueueName)
import Test.Tasty
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "agent-run HTTP"
    [ testCase "HTTP completion without a successful complete step is failed" $
        withRunServerStore fixture Directory.disabledDirectoryHandle \store request -> do
          response <- request "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" Aeson..= ("terminal" :: Text), "payload" Aeson..= Aeson.object []])
          accepted <- decodeBody response
          _ <- right =<< runStoreIO store (runWorkflow agentRunWorkflowName (WorkflowId accepted.runId) (pure ()))
          result <- request "GET" ("/agents/heartbeat/runs/" <> Text.unpack accepted.runId) Aeson.Null
          statusCode (Http.responseStatus result) @?= 200
          view <- right (Aeson.eitherDecode (Http.responseBody result) :: Either String AgentRunStatus)
          view.status @?= "failed"
          fmap (.kind) view.failure @?= Just "behavior_failed",
      testCase "accepted status, cross-agent guard and run history paginate without gaps" $
        withRunServer fixture Directory.disabledDirectoryHandle \_ request -> do
          let payload key = Aeson.object ["idempotencyKey" Aeson..= key, "payload" Aeson..= Aeson.object []]
          accepted <- forM ([1 .. 7] :: [Int]) \index -> do
            response <- request "POST" "/agents/heartbeat/runs" (payload ("history-" <> Text.pack (show index)))
            decodeBody response
          let latest = last accepted
          response <- request "GET" ("/agents/heartbeat/runs/" <> Text.unpack latest.runId) Aeson.Null
          statusCode (Http.responseStatus response) @?= 200
          view <- right (Aeson.eitherDecode (Http.responseBody response) :: Either String AgentRunStatus)
          view.status @?= "accepted"
          view.acceptedAt @?= Just latest.acceptedAt
          view.failure @?= Nothing
          request "GET" ("/agents/disabled-heartbeat/runs/" <> Text.unpack latest.runId) Aeson.Null >>= assertProblem 404 "run_not_found"
          request "GET" "/agents/heartbeat/runs/no-such-run" Aeson.Null >>= assertProblem 404 "run_not_found"
          request "GET" "/agents/absent/runs" Aeson.Null >>= assertProblem 404 "agent_not_found"
          request "GET" "/agents/absent/runs/any-run" Aeson.Null >>= assertProblem 404 "agent_not_found"
          request "GET" "/agents/heartbeat/runs?first=0" Aeson.Null >>= assertProblem 400 "invalid_url"
          request "GET" "/agents/heartbeat/runs?after=e30" Aeson.Null >>= assertProblem 400 "invalid_url"
          let fetch page = do
                let size = show page.pageSize
                    suffix = maybe "" (("&" <>) . ((if page.direction == Forward then "after=" else "before=") <>) . Text.unpack . cursorToText) page.cursor
                    query = (if page.direction == Forward then "?first=" else "?last=") <> size <> suffix
                response <- request "GET" ("/agents/heartbeat/runs" <> query) Aeson.Null
                connection <- right (Aeson.eitherDecode (Http.responseBody response) :: Either String (Connection RunRequestView))
                pure (fmap (.runId) connection)
          report <- checkConformance (defaultConformanceConfig 3) id fetch (fmap (.runId) (reverse accepted))
          assertBool (Text.unpack (renderConformanceReport report)) (conformancePassed report),
      testCase "accept and replay return one resource and one message; conflict is typed" $
        withRunServer fixture Directory.disabledDirectoryHandle \pool post -> do
          let body = Aeson.object ["idempotencyKey" Aeson..= ("http-1" :: Text), "payload" Aeson..= Aeson.object []]
          first <- post "POST" "/agents/heartbeat/runs" body
          statusCode (Http.responseStatus first) @?= 202
          accepted <- decodeBody first
          accepted.runId @?= "34390b28-e1aa-59b4-8df1-6ae2c9abd01e"
          lookup "Location" (Http.responseHeaders first) @?= Just "/agents/heartbeat/runs/34390b28-e1aa-59b4-8df1-6ae2c9abd01e"
          repeated <- post "POST" "/agents/heartbeat/runs" body
          statusCode (Http.responseStatus repeated) @?= 200
          Http.responseBody repeated @?= Http.responseBody first
          conflict <- post "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" Aeson..= ("http-1" :: Text), "payload" Aeson..= Aeson.object ["changed" Aeson..= True]])
          assertProblem 409 "idempotency_key_conflict" conflict
          metrics <- right =<< Pool.use pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 1,
      testCase "unknown, disabled, malformed and oversized requests use problem details" $
        withRunServer fixture Directory.disabledDirectoryHandle \_ post -> do
          let valid = Aeson.object ["idempotencyKey" Aeson..= ("invalids" :: Text), "payload" Aeson..= Aeson.object []]
          post "POST" "/agents/absent/runs" valid >>= assertProblem 404 "agent_not_found"
          post "POST" "/agents/disabled-heartbeat/runs" valid >>= assertProblem 409 "agent_not_runnable"
          forM_ [Aeson.object [], Aeson.object ["idempotencyKey" Aeson..= ("key" :: Text), "payload" Aeson..= ([] :: [Text])], Aeson.object ["idempotencyKey" Aeson..= Text.replicate 201 "k", "payload" Aeson..= Aeson.object []]] \invalid ->
            post "POST" "/agents/heartbeat/runs" invalid >>= assertProblem 400 "invalid_body"
          post "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" Aeson..= ("large" :: Text), "payload" Aeson..= Aeson.object ["value" Aeson..= Text.replicate 70000 "x"]]) >>= assertProblem 413 "payload_too_large",
      testCase "a store failure is a 503 and rolls back acceptance" $
        withRunServer fixture Directory.disabledDirectoryHandle \pool post -> do
          _ <- right =<< Pool.use pool (Session.script "DROP TABLE shikigami.agent_run_requests")
          post "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" Aeson..= ("store-down" :: Text), "payload" Aeson..= Aeson.object []]) >>= assertProblem 503 "unavailable",
      testCase "paused identities cannot request runs" do
        directory <- Directory.newDirectoryHandle (Directory.staticDirectorySource [Directory.PrincipalRecord "agent_heartbeat" "heartbeat" Directory.Paused])
        _ <- Directory.refreshDirectory directory
        withRunServer fixture directory \_ post ->
          post "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" Aeson..= ("paused" :: Text), "payload" Aeson..= Aeson.object []]) >>= assertProblem 409 "agent_not_runnable",
      testCase "unavailable directory refuses with a retryable service problem" do
        directory <- Directory.newDirectoryHandle (pure (Left "offline"))
        withRunServer fixture directory \_ post ->
          post "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" Aeson..= ("offline" :: Text), "payload" Aeson..= Aeson.object []]) >>= assertProblem 503 "unavailable"
    ]

decodeBody :: Http.Response LBS.ByteString -> IO AgentRunAccepted
decodeBody = right . Aeson.eitherDecode . Http.responseBody

assertProblem :: Int -> Text -> Http.Response LBS.ByteString -> IO ()
assertProblem status code response = do
  statusCode (Http.responseStatus response) @?= status
  lookup "Content-Type" (Http.responseHeaders response) @?= Just "application/problem+json"
  problem <- right (Aeson.eitherDecode (Http.responseBody response) :: Either String ProblemDetails)
  problem.code @?= code

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

withRunServer :: DatabaseFixture -> Directory.DirectoryHandle -> (Pool.Pool -> (String -> String -> Aeson.Value -> IO (Http.Response LBS.ByteString)) -> IO a) -> IO a
withRunServer fixture directory body = withRunServerStore fixture directory (\store -> body store.pool)

withRunServerStore :: DatabaseFixture -> Directory.DirectoryHandle -> (KirokuStore -> (String -> String -> Aeson.Value -> IO (Http.Response LBS.ByteString)) -> IO a) -> IO a
withRunServerStore fixture directory body =
  withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
    _ <- right =<< ensureRunQueue store.pool
    declaration <- loadAgent "../agents/heartbeat.dhall" >>= right
    let catalog = AgentCatalog (Map.fromList [("heartbeat", declaration), ("disabled-heartbeat", declaration & #name .~ "disabled-heartbeat" & #enabled .~ False)]) 0
    provider <- Trace.createTracerProvider [] Trace.emptyTracerProviderOptions
    let tracer = Trace.makeTracer provider "run-test" Trace.tracerOptions
        env = newServerEnvWith tracer defaultAppConfig store.pool Log.silentLogger catalog directory (pure Healthy) (pure Healthy) & #readRunStatus .~ deriveRunStatus store
    testWithApplication (pure (shikigamiApplication env)) \port -> do
      manager <- Http.newManager Http.defaultManagerSettings
      body store \method path value -> do
        request <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
        Http.httpLbs request {Http.method = Text.encodeUtf8 (Text.pack method), Http.requestHeaders = [("Content-Type", "application/json")], Http.requestBody = Http.RequestBodyLBS (Aeson.encode value)} manager

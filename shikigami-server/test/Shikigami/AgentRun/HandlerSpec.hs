module Shikigami.AgentRun.HandlerSpec (tests, withRunServer, right) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Keiro.PGMQ qualified as Job
import Keiro.Workflow (StepName (..), WorkflowId (..), runWorkflow, step)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (runStoreIO)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import OpenTelemetry.Trace qualified as Trace
import Pgmq qualified
import Relay.Pagination (Connection (..), Direction (..), PageRequest (..), cursorToText)
import Relay.Pagination.Conformance (checkConformance, conformancePassed, defaultConformanceConfig, renderConformanceReport)
import Relay.Pagination.Servant (RelayPageError (..))
import Servant.Health (ProbeVerdict (Healthy))
import Shikigami.Agent.Catalog (AgentCatalog (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.AgentRun.Api
import Shikigami.AgentRun.Ledger qualified as Ledger
import Shikigami.AgentRun.Status (deriveRunStatus)
import Shikigami.Api.Problem (ProblemDetails (..))
import Shikigami.App.Config (defaultAppConfig)
import Shikigami.Directory qualified as Directory
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport
import Shikigami.Prelude hiding ((.=))
import Shikigami.RunJobs qualified as RunJobs
import Shikigami.Server.App (shikigamiApplication)
import Shikigami.Server.Boot (newServerEnvWith)
import Shikigami.Trigger.Enqueue (ensureRunQueue, runQueueName)
import Test.Tasty
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "agent-run HTTP"
    [ testCase "HTTP reconciles automatic pre-workflow exhaustion and retains failure after purge" $
        withRunServerStore fixture Directory.disabledDirectoryHandle \store request -> do
          response <- request "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" .= ("exhaustion" :: Text), "payload" .= Aeson.object []])
          accepted <- decodeBody response
          forM_ ([1 .. 5] :: [Int]) \_ -> void (right =<< Pool.use store.pool (Pgmq.readMessage (Pgmq.ReadMessage runQueueName 0 (Just 1) Nothing)))
          let runtime = Job.JobRuntime store.pool Nothing
          _ <- right =<< Job.runJobEff runtime (Job.runJobOnce 1 RunJobs.runJob (\_ -> liftIO (assertFailure "exhausted job reached handler")))
          result <- request "GET" ("/agents/heartbeat/runs/" <> Text.unpack accepted.runId) Aeson.Null
          statusCode (Http.responseStatus result) @?= 200
          view <- right (Aeson.eitherDecode (Http.responseBody result) :: Either String AgentRunStatus)
          view.status @?= "failed"
          fmap (.kind) view.failure @?= Just "dead_lettered"
          fmap (.reason) view.failure @?= Just "max_retries_exceeded"
          _ <- right =<< Job.runJobEff runtime (Job.purgeDlq RunJobs.runJob)
          repeated <- request "GET" ("/agents/heartbeat/runs/" <> Text.unpack accepted.runId) Aeson.Null
          Http.responseBody repeated @?= Http.responseBody result
          Ledger.lookupRunRequest store.pool (fixtureAgentName "heartbeat") accepted.runId >>= \case
            Right (Just row) -> row.disposition @?= Ledger.RunDeadLettered
            _ -> assertFailure "terminal receipt was not persisted",
      testCase "corrupt stored run history is a non-retryable typed internal failure" $
        withRunServerStore fixture Directory.disabledDirectoryHandle \store request -> do
          response <- request "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" .= ("corrupt-history" :: Text), "payload" .= Aeson.object []])
          accepted <- decodeBody response
          _ <- right =<< runStoreIO store (runWorkflow agentRunWorkflowName (WorkflowId accepted.runId) (step (StepName "open-session") (pure (Aeson.object ["private" .= ("MUST_NOT_LEAK" :: Text)]))))
          result <- request "GET" ("/agents/heartbeat/runs/" <> Text.unpack accepted.runId) Aeson.Null
          assertProblem 500 "internal_error" result
          details <- right (Aeson.eitherDecode (Http.responseBody result) :: Either String ProblemDetails)
          details.retryable @?= False
          assertBool "stored payload is not an HTTP diagnostic" (not ("MUST_NOT_LEAK" `Text.isInfixOf` Text.decodeUtf8 (LBS.toStrict (Http.responseBody result)))),
      testCase "HTTP completion without a successful complete step is failed" $
        withRunServerStore fixture Directory.disabledDirectoryHandle \store request -> do
          response <- request "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" .= ("terminal" :: Text), "payload" .= Aeson.object []])
          accepted <- decodeBody response
          _ <- right =<< runStoreIO store (runWorkflow agentRunWorkflowName (WorkflowId accepted.runId) (pure ()))
          result <- request "GET" ("/agents/heartbeat/runs/" <> Text.unpack accepted.runId) Aeson.Null
          statusCode (Http.responseStatus result) @?= 200
          view <- right (Aeson.eitherDecode (Http.responseBody result) :: Either String AgentRunStatus)
          view.status @?= "failed"
          fmap (.kind) view.failure @?= Just "behavior_failed",
      testCase "accepted status, cross-agent guard and run history paginate without gaps" $
        withRunServer fixture Directory.disabledDirectoryHandle \_ request -> do
          let payload key = Aeson.object ["idempotencyKey" .= key, "payload" .= Aeson.object []]
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
          request "GET" "/agents/heartbeat/runs?first=0" Aeson.Null >>= assertPageError "invalid_page_size"
          request "GET" "/agents/heartbeat/runs?after=e30" Aeson.Null >>= assertPageError "invalid_cursor"
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
          let body = Aeson.object ["idempotencyKey" .= ("http-1" :: Text), "payload" .= Aeson.object []]
          first <- post "POST" "/agents/heartbeat/runs" body
          statusCode (Http.responseStatus first) @?= 202
          accepted <- decodeBody first
          accepted.runId @?= "114ab443-f469-59bb-a640-56502b5ae5bf"
          lookup "Location" (Http.responseHeaders first) @?= Just "/agents/heartbeat/runs/114ab443-f469-59bb-a640-56502b5ae5bf"
          repeated <- post "POST" "/agents/heartbeat/runs" body
          statusCode (Http.responseStatus repeated) @?= 200
          Http.responseBody repeated @?= Http.responseBody first
          conflict <- post "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" .= ("http-1" :: Text), "payload" .= Aeson.object ["changed" .= True]])
          assertProblem 409 "idempotency_key_conflict" conflict
          metrics <- right =<< Pool.use pool (Pgmq.queueMetrics runQueueName)
          metrics.queueLength @?= 1,
      testCase "unknown, disabled, malformed and oversized requests use problem details" $
        withRunServer fixture Directory.disabledDirectoryHandle \_ post -> do
          let valid = Aeson.object ["idempotencyKey" .= ("invalids" :: Text), "payload" .= Aeson.object []]
          post "POST" "/agents/absent/runs" valid >>= assertProblem 404 "agent_not_found"
          post "POST" "/agents/disabled-heartbeat/runs" valid >>= assertProblem 409 "agent_not_runnable"
          forM_ [Aeson.object [], Aeson.object ["idempotencyKey" .= ("key" :: Text), "payload" .= ([] :: [Text])], Aeson.object ["idempotencyKey" .= Text.replicate 201 "k", "payload" .= Aeson.object []]] \invalid ->
            post "POST" "/agents/heartbeat/runs" invalid >>= assertProblem 400 "invalid_body"
          post "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" .= ("large" :: Text), "payload" .= Aeson.object ["value" .= Text.replicate 70000 "x"]]) >>= assertProblem 413 "payload_too_large",
      testCase "a store failure is a 503 and rolls back acceptance" $
        withRunServer fixture Directory.disabledDirectoryHandle \pool post -> do
          _ <- right =<< Pool.use pool (Session.script "DROP TABLE shikigami.agent_run_requests")
          post "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" .= ("store-down" :: Text), "payload" .= Aeson.object []]) >>= assertProblem 503 "unavailable",
      testCase "paused identities cannot request runs" do
        directory <- Directory.newDirectoryHandle (Directory.staticDirectorySource [Directory.PrincipalRecord "agent_heartbeat" "heartbeat" Directory.Paused])
        _ <- Directory.refreshDirectory directory
        withRunServer fixture directory \_ post ->
          post "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" .= ("paused" :: Text), "payload" .= Aeson.object []]) >>= assertProblem 409 "agent_not_runnable",
      testCase "unavailable directory refuses with a retryable service problem" do
        directory <- Directory.newDirectoryHandle (pure (Left "offline"))
        withRunServer fixture directory \_ post ->
          post "POST" "/agents/heartbeat/runs" (Aeson.object ["idempotencyKey" .= ("offline" :: Text), "payload" .= Aeson.object []]) >>= assertProblem 503 "unavailable"
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
    let catalog = AgentCatalog (Map.fromList [(fixtureAgentName "heartbeat", declaration), (fixtureAgentName "disabled-heartbeat", declaration & #name .~ fixtureAgentName "disabled-heartbeat" & #enabled .~ False)]) 0
    provider <- Trace.createTracerProvider [] Trace.emptyTracerProviderOptions
    let tracer = Trace.makeTracer provider "run-test" Trace.tracerOptions
        env = newServerEnvWith tracer defaultAppConfig store.pool Log.silentLogger catalog directory (pure Healthy) (pure Healthy) & #readRunStatus .~ deriveRunStatus store
    testWithApplication (pure (shikigamiApplication env)) \port -> do
      manager <- Http.newManager Http.defaultManagerSettings
      body store \method path value -> do
        request <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
        Http.httpLbs request {Http.method = Text.encodeUtf8 (Text.pack method), Http.requestHeaders = [("Content-Type", "application/json")], Http.requestBody = Http.RequestBodyLBS (Aeson.encode value)} manager

assertPageError :: Text -> Http.Response LBS.ByteString -> IO ()
assertPageError expected response = do
  statusCode (Http.responseStatus response) @?= 400
  error <- right (Aeson.eitherDecode (Http.responseBody response) :: Either String RelayPageError)
  error.code @?= expected
  error.retryable @?= False

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

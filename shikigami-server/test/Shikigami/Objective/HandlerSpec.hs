{-# LANGUAGE DataKinds #-}

module Shikigami.Objective.HandlerSpec (tests) where

import Control.Concurrent.Async (replicateConcurrently)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kioku.Id (genSessionId, idText)
import Kioku.Session qualified as Memory
import Kioku.Session.Domain (StartSessionData (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import OpenTelemetry.Trace qualified as Trace
import Pgmq qualified
import Servant.Health (ProbeVerdict (Healthy))
import Settei (answer, defaultResolveOptions, resolve)
import Settei.Optparse (cliOverride, cliSources)
import Shikigami.Agent.Catalog (AgentCatalog (..))
import Shikigami.Agent.Conversation.SessionIndex qualified as ConversationIndex
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (ResolvedAgentIdentity (CompatibilityAgent), compatibilityIdentity, identityText)
import Shikigami.Agent.RunJob (RunJob (..))
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Log qualified as Log
import Shikigami.Memory.Access (agentActor, shikigamiMemorySpace, shikigamiWriteContext)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Migrations.TestSupport
import Shikigami.Objective.Api
import Shikigami.Objective.Command qualified as Command
import Shikigami.Objective.Inspection (ObjectiveView (..))
import Shikigami.Objective.Types qualified as O
import Shikigami.Prelude hiding ((.=))
import Shikigami.RunJobs (decodeRunJob)
import Shikigami.Runtime (registerRuntimeCatalog)
import Shikigami.Server.App (shikigamiApplication)
import Shikigami.Server.Boot (newServerEnvWith)
import Shikigami.Server.Seam (ServerEnv (..))
import Shikigami.Trigger.Enqueue (ensureRunQueue, runQueueName)
import Test.Tasty
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "objective HTTP"
    [ testCase "distinct callers, current revocation, protected metadata and ordered attributed history" $ withFixture fixture \_ call -> do
        created <- call "a" "POST" "/objectives" createBody
        expect 201 created
        receipt <- decode created :: IO ReceiptView
        let path = "/objectives/" <> Text.unpack receipt.objectiveId
        replay <- call "a" "POST" "/objectives" createBody
        expect 200 replay
        Http.responseBody replay @?= Http.responseBody created
        call "b" "GET" path Aeson.Null >>= expect 404
        call "b" "GET" (path <> "/history") Aeson.Null >>= expect 404
        page <- decode =<< call "b" "GET" "/objectives" Aeson.Null :: IO ObjectivePage
        page.items @?= []
        call "b" "POST" (path <> "/commands") (command "denied" 0 (Command.ReviseInstructions (checked O.parseInstructions "new"))) >>= expect 403
        changed <- call "a" "POST" (path <> "/commands") (command "edit" 0 (Command.ReviseInstructions (checked O.parseInstructions "PRIVATE-INSTRUCTIONS")))
        expect 200 changed
        repeated <- call "a" "POST" (path <> "/commands") (command "edit" 0 (Command.ReviseInstructions (checked O.parseInstructions "PRIVATE-INSTRUCTIONS")))
        Http.responseBody repeated @?= Http.responseBody changed
        call "a" "POST" (path <> "/commands") (command "stale" 0 (Command.SetNextAction [])) >>= expect 409
        view <- call "a" "GET" path Aeson.Null
        expect 200 view
        assertBool "metadata hides instructions" (not ("PRIVATE" `Text.isInfixOf` Text.decodeUtf8 (Lazy.toStrict (Http.responseBody view))))
        first <- decode =<< call "a" "GET" (path <> "/history?limit=1") Aeson.Null :: IO HistoryPage
        map (.receipt.revision) first.items @?= [0]
        first.next @?= Just 0
        map (.actor) first.items @?= [PrincipalView "caller" "a"]
        second <- decode =<< call "a" "GET" (path <> "/history?after=0&limit=1") Aeson.Null :: IO HistoryPage
        map (.receipt.revision) second.items @?= [1]
        second.next @?= Nothing
        call "a" "POST" (path <> "/commands") (command "grant-b" 1 (Command.GrantMember (O.VerifiedCaller (checked O.parseCallerId "b")) [O.Reader])) >>= expect 200
        call "b" "GET" path Aeson.Null >>= expect 200
        call "a" "POST" (path <> "/commands") (command "revoke-b" 2 (Command.RevokeMember (O.VerifiedCaller (checked O.parseCallerId "b")))) >>= expect 200
        call "b" "GET" path Aeson.Null >>= expect 404
        call "b" "GET" (path <> "/history") Aeson.Null >>= expect 404,
      testCase "concurrent creation has one fresh response and one retained resource" $ withFixture fixture \_ call -> do
        results <- replicateConcurrently 5 (call "a" "POST" "/objectives" createBody)
        sort (map (statusCode . Http.responseStatus) results) @?= [200, 200, 200, 200, 201]
        let bodies = map Http.responseBody results
        assertBool "all callers receive identical receipt" (all (== head bodies) bodies),
      testCase "bounded listing, strict envelopes, anonymous denial, wire limits and store outage" $ withFixture fixture \store call -> do
        call "" "POST" "/objectives" createBody >>= expect 401
        forM_ [Aeson.object [], setField "format" (Aeson.Number 2) createBody, setField "actor" (Aeson.String "b") createBody] \body -> call "a" "POST" "/objectives" body >>= expect 400
        forM_ ["?limit=0", "?limit=101", "?after=invalid"] \query -> call "a" "GET" ("/objectives" <> query) Aeson.Null >>= expect 400
        forM_ [1 .. 3 :: Int] \i -> call "a" "POST" "/objectives" (setField "operationKey" (Aeson.String ("create-" <> Text.pack (show i))) createBody) >>= expect 201
        first <- decode =<< call "a" "GET" "/objectives?limit=2" Aeson.Null :: IO ObjectivePage
        length first.items @?= 2
        after <- maybe (fail "missing list cursor") pure first.next
        second <- decode =<< call "a" "GET" ("/objectives?limit=2&after=" <> Text.unpack after) Aeson.Null :: IO ObjectivePage
        length second.items @?= 1
        second.next @?= Nothing
        call "a" "POST" "/objectives" (setField "padding" (Aeson.String (Text.replicate 1048577 "x")) createBody) >>= expect 413
        _ <- right =<< Pool.use store.pool (Session.script "DROP TABLE shikigami.objectives CASCADE")
        call "a" "GET" "/objectives" Aeson.Null >>= expect 503,
      testCase "HTTP run associations are atomic and cannot be forged by another caller or trigger text" $ withFixture fixture \store call -> do
        created <- decode =<< call "a" "POST" "/objectives" createBody :: IO ReceiptView
        let path = "/objectives/" <> Text.unpack created.objectiveId
            agent = checked mkAgentName "heartbeat"
            identity = compatibilityIdentity agent
            assignment = checked O.parseObjectiveAssignmentId "work"
            draft = O.AssignmentDraft assignment (checked O.parseInstructions "work") [] identity O.Pending Nothing Nothing Nothing
            selector = Aeson.object ["objectiveId" .= created.objectiveId, "assignmentId" .= assignment]
            runBody key = Aeson.object ["idempotencyKey" .= (key :: Text), "payload" .= Aeson.object [], "objective" .= selector]
        call "a" "POST" (path <> "/commands") (command "assign" 0 (Command.SetAssignments [draft])) >>= expect 200
        call "a" "POST" (path <> "/commands") (command "agent" 1 (Command.GrantMember (O.RecordedAgent identity) [O.Worker])) >>= expect 200
        accepted <- call "a" "POST" "/agents/heartbeat/runs" (runBody "associated")
        expect 202 accepted
        replay <- call "a" "POST" "/agents/heartbeat/runs" (runBody "associated")
        expect 200 replay
        Http.responseBody replay @?= Http.responseBody accepted
        call "b" "POST" "/agents/heartbeat/runs" (runBody "foreign") >>= expect 503
        _ <- right =<< Pool.use store.pool (Session.script "CREATE FUNCTION shikigami.reject_http_run_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected after objective association and queue send'; END $$; CREATE TRIGGER reject_http_run_fixture BEFORE INSERT ON shikigami.agent_run_requests FOR EACH ROW EXECUTE FUNCTION shikigami.reject_http_run_fixture()")
        call "a" "POST" "/agents/heartbeat/runs" (runBody "atomic-failure") >>= expect 503
        _ <- right =<< Pool.use store.pool (Session.script "DROP TRIGGER reject_http_run_fixture ON shikigami.agent_run_requests")
        call "a" "POST" (path <> "/commands") (command "revoke-agent" 2 (Command.RevokeMember (O.RecordedAgent identity))) >>= expect 200
        call "a" "POST" "/agents/heartbeat/runs" (runBody "revoked") >>= expect 503
        -- The still-authorized caller can recover the original accepted run;
        -- revoked agent membership refuses fresh association admission.
        call "a" "POST" "/agents/heartbeat/runs" (runBody "associated") >>= expect 200
        -- An objective-looking trigger remains an ordinary unassociated request.
        let trigger = Aeson.object ["idempotencyKey" .= ("unassociated" :: Text), "payload" .= Aeson.object ["objective" .= selector]]
        plain <- call "b" "POST" "/agents/heartbeat/runs" trigger
        expect 202 plain
        metrics <- right =<< Pool.use store.pool (Pgmq.queueMetrics runQueueName)
        metrics.queueLength @?= 2
        messages <- right =<< Pool.use store.pool (Pgmq.readMessage (Pgmq.ReadMessage runQueueName 30 (Just 10) Nothing))
        jobs <- traverse (right . decodeRunJob . (.body.unMessageBody)) (toList messages)
        length (filter (isJust . (.objective)) jobs) @?= 1
        length (filter (isNothing . (.objective)) jobs) @?= 1
        call "b" "POST" "/agents/heartbeat/runs" trigger >>= expect 200,
      testCase "conversation binding over HTTP uses the actual indexed memory owner" $ withFixture fixture \store call -> do
        created <- decode =<< call "a" "POST" "/objectives" createBody :: IO ReceiptView
        now <- getCurrentTime
        sid <- genSessionId
        tracer <- noopTracer
        let agent = checked mkAgentName "heartbeat"
            resolved = CompatibilityAgent agent
            identity = compatibilityIdentity agent
            context = shikigamiWriteContext resolved
            conversation = checked O.parseConversationRef "http-conversation"
            app = AppEnv (defaultConnectionSettings "") tracer Nothing (Just store)
            path = "/objectives/" <> Text.unpack created.objectiveId <> "/commands"
        started <- right =<< runAppIO app (Memory.startWithContext context (StartSessionData sid shikigamiMemorySpace (agentActor resolved) Nothing (either (error . show) id (identityText identity)) "conversation" (agentScope resolved) (Just (O.conversationRefText conversation)) Nothing Nothing 0 now))
        _ <- right started
        _ <- right =<< runAppIO app (ConversationIndex.rememberConversationSession (O.conversationRefText conversation) (idText sid) now)
        call "a" "POST" path (command "unrelated-conversation" 0 (Command.BindConversation conversation)) >>= expect 403
        call "a" "POST" path (command "conversation-member" 0 (Command.GrantMember (O.RecordedAgent identity) [O.Worker, O.Reader])) >>= expect 200
        bound <- call "a" "POST" path (command "bind-conversation" 1 (Command.BindConversation conversation))
        expect 200 bound
        replay <- call "a" "POST" path (command "bind-conversation" 1 (Command.BindConversation conversation))
        Http.responseBody replay @?= Http.responseBody bound
        call "b" "POST" path (command "foreign-conversation" 2 (Command.BindConversation conversation)) >>= expect 403,
      testCase "disabled vertical refuses every route without falling through" $ withFixture fixture \_ call -> do
        call "disabled" "GET" "/objectives" Aeson.Null >>= expect 503
        call "disabled" "POST" "/objectives" createBody >>= expect 503,
      testCase "development anonymous mode cannot create or inspect objectives" $ withFixture fixture \_ call -> do
        call "development" "POST" "/objectives" createBody >>= expect 403
        call "development" "GET" "/objectives" Aeson.Null >>= expect 403
    ]

createBody :: Aeson.Value
createBody = Aeson.object ["format" .= (1 :: Int), "operationKey" .= ("create" :: Text), "request" .= Aeson.object ["title" .= ("deliver" :: Text), "goal" .= ("goal" :: Text), "instructions" .= ("PRIVATE-CREATE" :: Text), "criteria" .= [O.Criterion (checked O.parseCriterionKey "review") (checked O.parseCriterionDescription "review") O.HumanVerifiable O.JourneyOptional], "external" .= ([] :: [Aeson.Value])]]

command :: Text -> Integer -> Command.Command -> Aeson.Value
command operation revision action = Aeson.object ["format" .= (1 :: Int), "operationKey" .= operation, "expectedRevision" .= revision, "command" .= action]

setField field value (Aeson.Object fields) = Aeson.Object (KeyMap.insert field value fields)
setField _ _ value = value

expect status response = assertEqual (show (Http.responseBody response)) status (statusCode (Http.responseStatus response))

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

decode :: (FromJSON a) => Http.Response Lazy.ByteString -> IO a
decode response = right (Aeson.eitherDecode (Http.responseBody response))

checked parser = either (error . show) id . parser

withFixture fixture body = withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
  registerRuntimeCatalog store
  _ <- right =<< ensureRunQueue store.pool
  agent <- loadAgent "../agents/heartbeat.dhall" >>= right
  provider <- Trace.createTracerProvider [] Trace.emptyTracerProviderOptions
  let tracer = Trace.makeTracer provider "objectives-http" Trace.tracerOptions
      catalog = AgentCatalog (Map.singleton (checked mkAgentName "heartbeat") agent) 0
  manager <- Http.newManager Http.defaultManagerSettings
  body store \caller method path value -> do
    let settings = if caller == "development" then AuthDisabled else auth (if Text.null caller then "a" else caller)
        config = defaultAppConfig & #httpAuth .~ settings & #objectiveSettings . #enabled .~ (if caller == "disabled" then O.ObjectivesDisabled else O.ObjectivesEnabled)
        env = newServerEnvWith tracer config store.pool Log.silentLogger catalog disabledDirectoryHandle (pure Healthy) (pure Healthy) & #store .~ Just store
    testWithApplication (pure (shikigamiApplication env)) \port -> do
      request <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
      Http.httpLbs request {Http.method = method, Http.requestHeaders = [("Content-Type", "application/json")] <> if Text.null caller then [] else [("Authorization", "Bearer 0123456789abcdefXYZ")], Http.requestBody = Http.RequestBodyLBS (Aeson.encode value)} manager
  where
    auth caller = case answer (resolve defaultResolveOptions (cliSources "test" [cliOverride httpAuthModeKey "bearer", cliOverride httpAuthTokenKey "0123456789abcdefXYZ", cliOverride httpAuthCallerKey caller]) appConfig) of
      Right config -> config.httpAuth
      Left _ -> error "invalid auth fixture"

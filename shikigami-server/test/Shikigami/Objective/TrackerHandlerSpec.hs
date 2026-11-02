{-# LANGUAGE DataKinds #-}

module Shikigami.Objective.TrackerHandlerSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (unpack)
import Effectful (Eff)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import Servant.Health (ProbeVerdict (Healthy))
import Shikigami.Action.Authorization (denyAllActionAuthorizer)
import Shikigami.Agent.Catalog (AgentCatalog (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config (AppConfig (..), HttpAuthSettings (..), defaultAppConfig, opaqueSecretText)
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Execution.Identity (OperationId, parseOperationId)
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Objective.Api qualified as Objective
import Shikigami.Objective.Tracker.Api qualified as Api
import Shikigami.Objective.Tracker.Command qualified as C
import Shikigami.Objective.Tracker.Config
import Shikigami.Objective.Tracker.Control qualified as Control
import Shikigami.Objective.Tracker.Control.Types
import Shikigami.Objective.Tracker.Mapping (supportedMappingRevision)
import Shikigami.Objective.Tracker.Provider qualified as Provider
import Shikigami.Objective.Tracker.Runtime qualified as Runtime
import Shikigami.Objective.Tracker.Store qualified as Store
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as O
import Shikigami.Prelude hiding ((.=))
import Shikigami.Runtime (registerRuntimeCatalog)
import Shikigami.Server.App (shikigamiApplication)
import Shikigami.Server.Boot (newServerEnvWith)
import Shikigami.Server.Seam (ServerEnv (..))
import Shikigami.StateRevision (initialRevision)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

-- Real HTTP parser, verifier, handlers, protected store and durable worker owner.
tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "ObjectiveTrackerHttp"
    [ testCase "queued reads, exact replay, resource isolation and stale local commands use typed HTTP results" $
        withFixture fixture \send pump reads -> do
          created <- send "a" "POST" "/objectives" (toJSON (Objective.ObjectiveCreate (operation "create") request))
          expect 201 created
          value <- decode created
          objective <- textField "objectiveId" value
          let route = "/objectives/" <> unpack objective <> "/trackers"
              bind = Api.TrackerCommand (operation "bind") (RunCommand (C.Bind (key "binding") (scope "remote") policy))
          send "" "GET" route Aeson.Null >>= expect 401
          send "a" "POST" (route <> "/commands") (toJSON bind) >>= expect 202
          send "a" "POST" (route <> "/commands") (toJSON bind) >>= expect 200
          readIORef reads >>= (@?= 0)
          pump
          readIORef reads >>= (@?= 1)
          state <- send "a" "GET" (route <> "/operations/bind") Aeson.Null
          expect 200 state
          status <- textField "state" =<< decode state
          status @?= "Finished"
          send "b" "GET" (route <> "/binding") Aeson.Null >>= expect 404
          send "b" "GET" (route <> "/operations/bind") Aeson.Null >>= expect 404
          send "b" "POST" (route <> "/commands") (toJSON bind) >>= expect 403
          let pause = Api.TrackerCommand (operation "pause") (RunCommand (C.Pause (key "binding") initialRevision))
              stale = Api.TrackerCommand (operation "stale") (RunCommand (C.Pause (key "binding") initialRevision))
          send "a" "POST" (route <> "/commands") (toJSON pause) >>= expect 200
          send "a" "POST" (route <> "/commands") (toJSON pause) >>= expect 200
          send "a" "POST" (route <> "/commands") (toJSON stale) >>= expect 409
          send "a" "POST" (route <> "/commands") (toJSON (Api.TrackerCommand (operation "observe-stale") (Observe (key "binding") initialRevision))) >>= expect 409
          let wrong = Api.TrackerCommand (operation "wrong") (RunCommand (C.Bind (key "other") (scope "remote" & #incarnation .~ key "wrong-installation") policy))
          send "a" "POST" (route <> "/commands") (toJSON wrong) >>= expect 403
          let forged = case toJSON bind of Aeson.Object fields -> Aeson.Object (KeyMap.insert "actor" (toJSON actor) fields); other -> other
          send "a" "POST" (route <> "/commands") forged >>= expect 400
          reply <- send "a" "GET" (route <> "/binding") Aeson.Null
          expect 200 reply
          assertBool "protected reply cap" (Lazy.length (Http.responseBody reply) <= 16384),
      testCase "Relay cursors reject another binding or history and page both directions" $
        withFixture fixture \send pump _ -> do
          created <- send "a" "POST" "/objectives" (toJSON (Objective.ObjectiveCreate (operation "create") request))
          objective <- textField "objectiveId" =<< decode created
          let route = "/objectives/" <> unpack objective <> "/trackers"
          forM_ ["a", "b", "c", "d"] \name -> do
            send "a" "POST" (route <> "/commands") (toJSON (Api.TrackerCommand (operation name) (RunCommand (C.Bind (key name) (scope name) policy)))) >>= expect 202
          pump
          first <- send "a" "GET" (route <> "?first=1") Aeson.Null
          expect 200 first
          parsed <- decode first
          cursor <- case parsed of Aeson.Object fields -> case KeyMap.lookup "pageInfo" fields of Just page -> textField "endCursor" page; _ -> fail "missing pageInfo"; _ -> fail "missing connection"
          second <- send "a" "GET" (route <> "?first=1&after=" <> unpack cursor) Aeson.Null
          expect 200 second
          assertBool "keyset advances" (Http.responseBody first /= Http.responseBody second)
          send "a" "GET" (route <> "/a/proposals?first=1&after=" <> unpack cursor) Aeson.Null >>= expect 400
          send "a" "GET" (route <> "?last=1") Aeson.Null >>= expect 200
          send "a" "GET" (route <> "?first=101") Aeson.Null >>= expect 400
    ]

withFixture :: DatabaseFixture -> ((Text -> ByteString -> String -> Aeson.Value -> IO (Http.Response Lazy.ByteString)) -> IO () -> IORef Int -> IO a) -> IO a
withFixture fixture callback = withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
  registerRuntimeCatalog store
  tracer <- noopTracer
  manager <- Http.newManager Http.defaultManagerSettings
  reads <- newIORef (0 :: Int)
  let operator = checked (O.parseOperatorId "tracker-worker")
      objectiveSettings = O.defaultObjectiveSettings & #enabled .~ O.ObjectivesEnabled & #operator .~ Just operator & #administration .~ O.AdministerAll
      provider requested =
        pure
          ( Right
              Provider.Provider
                { capabilities = Capabilities requested.providerRevision OrderedObservations UnconditionalWrites NoIdempotency LookupApplied,
                  readResource = \_ -> do
                    modifyIORef' reads (+ 1)
                    let snapshot = RemoteSnapshot (instructions "display") (instructions "remote guidance") RemoteOpen
                    pure (Provider.Observed (TrackerObservation TrackerV1 requested (Just initialRevision) (observationDigest snapshot) snapshot)),
                  publish = \_ _ -> pure Provider.OutcomeUnknown,
                  reconcile = \_ _ -> pure Provider.StillUnknown,
                  verifyReceipt = \_ _ _ -> pure Nothing
                }
          )
      scheduler = Store.TrackerHost (checked (Runtime.operatorHost objectiveSettings denyAllActionAuthorizer)) settings provider
      run :: Eff AppEffects a -> IO a
      run action = right =<< runAppIO (AppEnv (defaultConnectionSettings connection) tracer Nothing (Just store)) action
      pump = void (right =<< run (Control.runPending scheduler Nothing))
      send caller method path body = do
        let config = defaultAppConfig & #objectiveSettings .~ objectiveSettings & #trackerSettings .~ settings & #httpAuth .~ AuthBearer (opaqueSecretText "fixture-authentication-token") (declarationCoordinate (if caller == "" then "a" else caller))
            env = newServerEnvWith tracer config store.pool Log.silentLogger (AgentCatalog Map.empty 0) disabledDirectoryHandle (pure Healthy) (pure Healthy) & #store .~ Just store & #trackerProvider .~ provider
        testWithApplication (pure (shikigamiApplication env)) \port -> do
          target <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
          Http.httpLbs target {Http.method = method, Http.requestHeaders = [("Content-Type", "application/json")] <> if caller == "" then [] else [("Authorization", "Bearer fixture-authentication-token")], Http.requestBody = Http.RequestBodyLBS (Aeson.encode body)} manager
  callback send pump reads

actor :: O.AccessPrincipal
actor = O.VerifiedCaller (checked (O.parseCallerId "a"))

settings :: TrackerSettings
settings = TrackerSettings TrackersEnabled [Connection (key "connection") (key "installation") (key "neutral-v1") "https://example.test" (key "account") Nothing [actor] [actor]] 60 20 []

scope :: Text -> ResourceScope
scope name = ResourceScope (key "connection") (key "installation") (key name) (key "neutral-v1")

policy :: FieldPolicy
policy = FieldPolicy supportedMappingRevision IgnoreField IgnoreField ProgressSummaries

request :: O.CreateRequest
request = O.CreateRequest (checked (O.parseTitle "local")) (checked (O.parseGoal "independent state")) (instructions "local guidance") [O.Criterion (checked (O.parseCriterionKey "review")) (checked (O.parseCriterionDescription "review")) O.HumanVerifiable O.JourneyOptional] []

instructions :: Text -> O.Instructions
instructions = checked . O.parseInstructions

key :: Text -> TrackerCoordinate scope
key = checked . parseCoordinate

operation :: Text -> OperationId
operation = checked . parseOperationId

checked :: (Show e) => Either e a -> a
checked = either (error . show) id

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

expect :: Int -> Http.Response Lazy.ByteString -> Assertion
expect code response = assertEqual (show (Http.responseBody response)) code (statusCode (Http.responseStatus response))

decode :: (FromJSON a) => Http.Response Lazy.ByteString -> IO a
decode response = right (Aeson.eitherDecode (Http.responseBody response))

textField :: Key -> Aeson.Value -> IO Text
textField key (Aeson.Object fields) = case KeyMap.lookup key fields of Just (Aeson.String value) -> pure value; _ -> fail "missing text field"
textField _ _ = fail "expected object"

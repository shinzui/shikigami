module Shikigami.Caller.VerifierSpec (tests) where

import Data.Generics.Labels ()
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import OpenTelemetry.Trace qualified as Trace
import Servant.Health (ProbeVerdict (Healthy))
import Settei (answer, defaultResolveOptions, resolve)
import Settei.Optparse (cliOverride, cliSources)
import Shikigami.Agent.Catalog (emptyCatalog)
import Shikigami.App.Config
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Server.App (shikigamiApplication)
import Shikigami.Server.Boot (newServerEnvWith)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "bearer verifier"
    [ testCase "missing, malformed, wrong and duplicate headers have identical refusals" do
        withAuth bearerSettings \get -> do
          missing <- get "/agents" []
          statusCode (Http.responseStatus missing) @?= 401
          lookup "Content-Type" (Http.responseHeaders missing) @?= Just "application/problem+json"
          lookup "WWW-Authenticate" (Http.responseHeaders missing) @?= Just "Bearer realm=\"shikigami\""
          forM_ [[("Authorization", "Bearer wrong")], [("Authorization", "Basic wrong")], [("Authorization", "Bearer 0123456789abcdefXYZ"), ("Authorization", "Bearer wrong")]] \headers -> do
            response <- get "/agents" headers
            Http.responseBody response @?= Http.responseBody missing
            statusCode (Http.responseStatus response) @?= 401
          valid <- get "/agents" [("Authorization", "Bearer 0123456789abcdefXYZ")]
          statusCode (Http.responseStatus valid) @?= 200
          health <- get "/health/live" []
          statusCode (Http.responseStatus health) @?= 200,
      testCase "disabled authentication admits anonymous requests" $
        withAuth AuthDisabled \get -> do
          response <- get "/agents" []
          statusCode (Http.responseStatus response) @?= 200
    ]

withAuth settings body = do
  provider <- Trace.createTracerProvider [] Trace.emptyTracerProviderOptions
  let tracer = Trace.makeTracer provider "auth-test" Trace.tracerOptions
      config = defaultAppConfig & #httpAuth .~ settings
      env = newServerEnvWith tracer config Log.silentLogger emptyCatalog disabledDirectoryHandle (pure Healthy) (pure Healthy)
  testWithApplication (pure (shikigamiApplication env)) \port -> do
    manager <- Http.newManager Http.defaultManagerSettings
    body \path headers -> do
      request <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
      Http.httpLbs request {Http.requestHeaders = headers} manager

bearerSettings :: HttpAuthSettings
bearerSettings = case answer (resolve defaultResolveOptions (cliSources "test" [cliOverride httpAuthModeKey "bearer", cliOverride httpAuthTokenKey "0123456789abcdefXYZ"]) appConfig) of
  Right config -> config.httpAuth
  Left _ -> error "invalid auth test fixture"

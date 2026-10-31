module Shikigami.Agent.HandlerSpec (tests) where

import Data.Aeson (eitherDecode)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import OpenTelemetry.Trace qualified as Trace
import Relay.Pagination
import Relay.Pagination.Conformance
import Relay.Pagination.Servant (RelayPageError (..))
import Servant.Health (ProbeVerdict (Healthy))
import Shikigami.Agent.Api (AgentView (..))
import Shikigami.Agent.Catalog (AgentCatalog (..))
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Api.Problem qualified
import Shikigami.App.Config (defaultAppConfig)
import Shikigami.Directory qualified as Directory
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Server.App (shikigamiApplication)
import Shikigami.Server.Boot (newServerEnvWith)
import Test.Tasty
import Test.Tasty.HUnit

-- Exercise the assembled HTTP application, including the pre-handler errors.
tests :: TestTree
tests =
  testGroup
    "agent HTTP catalog"
    [ testCase "known, disabled, unknown and directory lifecycle" do
        withCatalog Directory.disabledDirectoryHandle \get -> do
          (status, bytes) <- get "/agents/a"
          status @?= 200
          view <- decodeBody bytes
          view.lifecycle @?= "unverified"
          view.runnable @?= True
          (_, disabledBytes) <- get "/agents/g"
          disabled <- decodeBody disabledBytes
          disabled.runnable @?= False
          (missing, _) <- get "/agents/absent"
          missing @?= 404
        directory <- Directory.newDirectoryHandle (Directory.staticDirectorySource [Directory.PrincipalRecord "agent_a" "a" Directory.Paused])
        _ <- Directory.refreshDirectory directory
        withCatalog directory \get -> do
          (_, bytes) <- get "/agents/a"
          view <- decodeBody bytes
          view.lifecycle @?= "paused"
          view.runnable @?= False,
      testCase "zero, negative, malformed and foreign cursors retain native Relay errors" $
        withCatalog Directory.disabledDirectoryHandle \get ->
          forM_ [("?first=0", "invalid_page_size"), ("?first=-1", "negative_page_size"), ("?first=bad", "invalid_integer"), ("?after=e30", "invalid_cursor")] \(query, expected) -> do
            (status, bytes) <- get ("/agents" <> query)
            status @?= 400
            details <- either (assertFailure . show) pure (eitherDecode bytes :: Either String RelayPageError)
            details.code @?= expected,
      testCase "an unavailable directory returns 503" do
        directory <- Directory.newDirectoryHandle (pure (Left "unavailable"))
        withCatalog directory \get -> do
          (status, _) <- get "/agents/a"
          status @?= 503,
      testConformance
        "seven agents page in both directions"
        (defaultConformanceConfig 3)
        id
        ( \page -> withCatalog Directory.disabledDirectoryHandle \get -> do
            let size = show page.pageSize
                suffix = maybe "" (("&" <>) . ((if page.direction == Forward then "after=" else "before=") <>) . Text.unpack . cursorToText) page.cursor
                query = (if page.direction == Forward then "?first=" else "?last=") <> size <> suffix
            (_, bytes) <- get ("/agents" <> query)
            connection <- either (assertFailure . show) pure (eitherDecode bytes :: Either String (Connection AgentView))
            pure (fmap (.name) connection)
        )
        (pure ["a", "b", "c", "d", "e", "f", "g"])
    ]

decodeBody :: LBS.ByteString -> IO AgentView
decodeBody = either (assertFailure . show) pure . eitherDecode

withCatalog :: Directory.DirectoryHandle -> ((String -> IO (Int, LBS.ByteString)) -> IO a) -> IO a
withCatalog directory body = do
  declaration <- loadAgent "../agents/heartbeat.dhall" >>= either (assertFailure . show) pure
  let declarations = Map.fromList [(fixtureAgentName name, declaration & #name .~ fixtureAgentName name & #enabled .~ (name /= "g")) | name <- ["a", "b", "c", "d", "e", "f", "g"]]
  pool <- Pool.acquire (PoolConfig.settings [])
  provider <- Trace.createTracerProvider [] Trace.emptyTracerProviderOptions
  let tracer = Trace.makeTracer provider "catalog-test" Trace.tracerOptions
      env = newServerEnvWith tracer defaultAppConfig pool Log.silentLogger (AgentCatalog declarations 0) directory (pure Healthy) (pure Healthy)
  testWithApplication (pure (shikigamiApplication env)) \port -> do
    manager <- Http.newManager Http.defaultManagerSettings
    body \path -> do
      request <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
      response <- Http.httpLbs request manager
      pure (statusCode (Http.responseStatus response), Http.responseBody response)

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

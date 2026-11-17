-- | Process-lifetime HTTP fixtures for pure test dependency builders.
--
-- Production constructs these resources explicitly during boot. Several older
-- workflow fixtures intentionally remain pure because hundreds of tests vary
-- only journal dependencies; this module allocates one token-less manager for
-- those fixtures and keeps the unsafe boundary isolated and non-exported from
-- the library.
module Kikan.Shikigami.Binding.Fixture.SinkHttp
  ( testHttpEnv,
    testHttpLimits,
    testSinkHttp,
    testSinkHttpFor,
  )
where

import Data.Text qualified as Text
import Kikan.Shikigami.Binding.Output.Config (DanwaConfig (..))
import Kikan.Shikigami.Binding.Output.Http (KikanHttp (..))
import Servant.Client (mkClientEnv, parseBaseUrl)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.App.Config (mkByteLimit)
import Shikigami.Sink.Http (HttpEnv (..), HttpLimits (..), newSinkManager, newTypedClientManager)
import System.IO.Unsafe (unsafePerformIO)

testHttpLimits :: HttpLimits
testHttpLimits =
  HttpLimits
    { requestBytes = limit,
      responseBytes = limit
    }
  where
    limit = either (error . show) id (mkByteLimit 8_388_608)

-- | Token-less clients, with Danwa at this configuration's base URL.
testSinkHttpFor :: DanwaConfig -> IO KikanHttp
testSinkHttpFor danwaConfig = do
  shared <- newSinkManager
  danwaManager <- newTypedClientManager testHttpLimits Nothing
  danwaBase <- maybe (error "testSinkHttpFor: invalid Danwa base URL") pure (parseBaseUrl (Text.unpack danwaConfig.baseUrl))
  let env = HttpEnv {manager = shared, token = Nothing, limits = testHttpLimits}
  pure KikanHttp {kawa = env, kizashi = env, kanmon = env, danwa = mkClientEnv danwaManager danwaBase}

-- | Token-less shared clients for tests that never reach danwa or deliberately
-- use the unreachable default endpoint.
testSinkHttp :: KikanHttp
testSinkHttp =
  unsafePerformIO
    ( testSinkHttpFor
        DanwaConfig
          { baseUrl = "http://localhost:1",
            agentParticipant = (declarationCoordinate "part_agent_test")
          }
    )
{-# NOINLINE testSinkHttp #-}

testHttpEnv :: HttpEnv
testHttpEnv = testSinkHttp.kawa

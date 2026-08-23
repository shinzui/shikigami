-- | Process-lifetime HTTP fixtures for pure test dependency builders.
--
-- Production constructs these resources explicitly during boot. Several older
-- workflow fixtures intentionally remain pure because hundreds of tests vary
-- only journal dependencies; this module allocates one token-less manager for
-- those fixtures and keeps the unsafe boundary isolated and non-exported from
-- the library.
module Shikigami.Fixture.SinkHttp
  ( testHttpEnv,
    testHttpLimits,
    testSinkHttp,
    testSinkHttpFor,
  )
where

import Shikigami.App.Config (mkByteLimit)
import Shikigami.Sink.Config (DanwaConfig (..))
import Shikigami.Sink.Http
  ( HttpEnv,
    HttpLimits (..),
    SinkCredentials (..),
    SinkHttp (..),
    newSinkHttp,
  )
import System.IO.Unsafe (unsafePerformIO)

testHttpLimits :: HttpLimits
testHttpLimits =
  HttpLimits
    { requestBytes = limit,
      responseBytes = limit
    }
  where
    limit = either (error . show) id (mkByteLimit 8_388_608)

testSinkHttpFor :: DanwaConfig -> IO SinkHttp
testSinkHttpFor danwaConfig =
  newSinkHttp
    testHttpLimits
    SinkCredentials {kawa = Nothing, kizashi = Nothing, danwa = Nothing}
    danwaConfig
    >>= either (error . show) pure

-- | Token-less shared clients for tests that never reach danwa or deliberately
-- use the unreachable default endpoint.
testSinkHttp :: SinkHttp
testSinkHttp =
  unsafePerformIO
    ( testSinkHttpFor
        DanwaConfig
          { baseUrl = "http://localhost:1",
            agentParticipant = "part_agent_test"
          }
    )
{-# NOINLINE testSinkHttp #-}

testHttpEnv :: HttpEnv
testHttpEnv = case testSinkHttp of
  SinkHttp {kawa} -> kawa

module Main (main) where

import Network.Wai (Application)
import OpenTelemetry.Trace qualified as Trace
import Servant.Health (ProbeCheck)
import Servant.Health.TestKit (probeContractTests)
import Shikigami.App.Config (defaultAppConfig)
import Shikigami.Server.AgentsSpec qualified as AgentsSpec
import Shikigami.Server.App (shikigamiApplication)
import Shikigami.Server.Boot (newServerEnvWith)
import Shikigami.Server.CommandSpec qualified as CommandSpec
import Shikigami.Server.DispatchSpec qualified as DispatchSpec
import Shikigami.Server.KanmonStubSpec qualified as KanmonStubSpec
import Shikigami.Server.KawaStubSpec qualified as KawaStubSpec
import Shikigami.Server.ProblemSpec qualified as ProblemSpec
import Shikigami.Server.RequestLogSpec qualified as RequestLogSpec
import Shikigami.Server.TelemetrySpec qualified as TelemetrySpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "shikigami-server"
        [ probeContractTests "health probes" mkTestApplication,
          AgentsSpec.tests,
          CommandSpec.tests,
          DispatchSpec.tests,
          KawaStubSpec.tests,
          KanmonStubSpec.tests,
          ProblemSpec.tests,
          RequestLogSpec.tests,
          TelemetrySpec.tests
        ]
    )

-- | The real assembled application, with the probe checks supplied from outside.
--
-- The conformance kit flips liveness and readiness independently, which is what
-- proves the two same-typed routes were not wired to each other's checks.
mkTestApplication :: ProbeCheck -> ProbeCheck -> IO Application
mkTestApplication livenessCheck readinessCheck = do
  provider <- Trace.createTracerProvider [] Trace.emptyTracerProviderOptions
  let tracer = Trace.makeTracer provider "shikigami-server-test" Trace.tracerOptions
  pure (shikigamiApplication (newServerEnvWith tracer defaultAppConfig livenessCheck readinessCheck))

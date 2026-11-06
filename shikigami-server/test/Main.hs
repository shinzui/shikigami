module Main (main) where

import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Network.Wai (Application)
import OpenTelemetry.Trace qualified as Trace
import Servant.Health (ProbeCheck)
import Servant.Health.TestKit (probeContractTests)
import Shikigami.Agent.Catalog (emptyCatalog)
import Shikigami.Agent.HandlerSpec qualified as HandlerSpec
import Shikigami.AgentRun.HandlerSpec qualified as RunHandlerSpec
import Shikigami.App.Config (defaultAppConfig)
import Shikigami.Caller.VerifierSpec qualified as VerifierSpec
import Shikigami.Directory (disabledDirectoryHandle)
import Shikigami.InspectionHttpSpec qualified as InspectionHttpSpec
import Shikigami.InspectionSocketSpec qualified as InspectionSocketSpec
import Shikigami.InspectionSpec qualified as InspectionSpec
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (withShikigamiMigratedSuite)
import Shikigami.Objective.HandlerSpec qualified as ObjectiveSpec
import Shikigami.Objective.TrackerHandlerSpec qualified as TrackerHandlerSpec
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
import Shikigami.Server.WatchdogCommandSpec qualified as WatchdogCommandSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = withShikigamiMigratedSuite \databaseFixture ->
  defaultMain
    ( testGroup
        "shikigami-server"
        [ probeContractTests "health probes" mkTestApplication,
          InspectionSpec.tests databaseFixture,
          InspectionHttpSpec.tests databaseFixture,
          InspectionSocketSpec.tests databaseFixture,
          AgentsSpec.tests databaseFixture,
          HandlerSpec.tests,
          RunHandlerSpec.tests databaseFixture,
          ObjectiveSpec.tests databaseFixture,
          TrackerHandlerSpec.tests databaseFixture,
          VerifierSpec.tests,
          WatchdogCommandSpec.tests databaseFixture,
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
  pool <- Pool.acquire (PoolConfig.settings [])
  provider <- Trace.createTracerProvider [] Trace.emptyTracerProviderOptions
  let tracer = Trace.makeTracer provider "shikigami-server-test" Trace.tracerOptions
  pure (shikigamiApplication (newServerEnvWith tracer defaultAppConfig pool Log.silentLogger emptyCatalog disabledDirectoryHandle livenessCheck readinessCheck))

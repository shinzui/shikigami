-- | Tests of what the distribution composes: the watchdog observing work the
-- initiative pack proposed and admitted, the Kikan outputs delivered through
-- the kernel's publisher, and the development stubs of the Kikan services.
-- Each use case's own tests live with it.
module Main (main) where

import Kikan.OutputDeliverySpec qualified as OutputDeliverySpec
import Kikan.Stub.CommandSpec qualified as StubCommandSpec
import Kikan.Stub.KanmonSpec qualified as KanmonStubSpec
import Kikan.Stub.KawaSpec qualified as KawaStubSpec
import Kikan.WatchdogQualificationSpec qualified as WatchdogQualificationSpec
import Kikan.WatchdogSweepSpec qualified as WatchdogSweepSpec
import Kikan.WatchdogTelemetrySpec qualified as WatchdogTelemetrySpec
import Shikigami.Migrations.TestSupport (withShikigamiMigratedSuite)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = withShikigamiMigratedSuite \databaseFixture ->
  defaultMain
    ( testGroup
        "kikan-shikigami"
        [ WatchdogSweepSpec.tests databaseFixture,
          WatchdogQualificationSpec.tests databaseFixture,
          WatchdogTelemetrySpec.tests databaseFixture,
          OutputDeliverySpec.tests databaseFixture,
          KawaStubSpec.tests,
          KanmonStubSpec.tests,
          StubCommandSpec.tests
        ]
    )

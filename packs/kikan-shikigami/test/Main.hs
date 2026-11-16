-- | Tests that span use cases the distribution composes: the watchdog
-- observing work the initiative pack proposed and admitted. Each use case's
-- own tests live with it; only what needs two of them together is here.
module Main (main) where

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
          WatchdogTelemetrySpec.tests databaseFixture
        ]
    )

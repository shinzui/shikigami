-- | The watchdog pack's own tests: the finding vocabulary and its
-- classification, the drift program and cadence, the ledger and observation
-- reads on PostgreSQL, the operator verbs, and the sweep end to end through
-- the real agent-run workflow.
module Main (main) where

import FlowPack.Watchdog.ClassifySpec qualified as ClassifySpec
import FlowPack.Watchdog.CommandSpec qualified as CommandSpec
import FlowPack.Watchdog.DriftCadenceSpec qualified as DriftCadenceSpec
import FlowPack.Watchdog.DriftProgramSpec qualified as DriftProgramSpec
import FlowPack.Watchdog.DriftSpec qualified as DriftSpec
import FlowPack.Watchdog.InspectionSpec qualified as InspectionSpec
import FlowPack.Watchdog.ObservationSpec qualified as ObservationSpec
import FlowPack.Watchdog.PackSpec qualified as PackSpec
import FlowPack.Watchdog.StoreSpec qualified as StoreSpec
import FlowPack.Watchdog.SweepSpec qualified as SweepSpec
import FlowPack.Watchdog.TypesSpec qualified as TypesSpec
import Shikigami.Migrations.TestSupport (withShikigamiMigratedSuite)
import System.Directory (setCurrentDirectory)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = do
  -- The kernel's fixtures read their manifests relative to shikigami-core.
  setCurrentDirectory "../../shikigami-core"
  withShikigamiMigratedSuite \databaseFixture ->
    defaultMain
      ( testGroup
          "flow-pack-watchdog"
          [ TypesSpec.tests,
            ClassifySpec.tests,
            DriftProgramSpec.tests,
            DriftCadenceSpec.tests,
            PackSpec.tests databaseFixture,
            ObservationSpec.tests databaseFixture,
            StoreSpec.tests databaseFixture,
            InspectionSpec.tests databaseFixture,
            CommandSpec.tests databaseFixture,
            DriftSpec.tests databaseFixture,
            SweepSpec.tests databaseFixture
          ]
      )

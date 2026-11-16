-- | The practice-review pack's own tests: the review vocabulary, evidence
-- acquisition, review memory, the orchestrated flow through the real
-- agent-run workflow, and the pack value itself.
module Main (main) where

import FlowPack.PracticeReview.EvidenceSpec qualified as EvidenceSpec
import FlowPack.PracticeReview.MemorySpec qualified as MemorySpec
import FlowPack.PracticeReview.OrchestrationSpec qualified as OrchestrationSpec
import FlowPack.PracticeReview.PackSpec qualified as PackSpec
import FlowPack.PracticeReview.TypesSpec qualified as TypesSpec
import Shikigami.Migrations.TestSupport (withShikigamiMigratedSuite)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = withShikigamiMigratedSuite \databaseFixture ->
  defaultMain
    ( testGroup
        "flow-pack-practice-review"
        [ TypesSpec.tests,
          EvidenceSpec.tests,
          MemorySpec.tests databaseFixture,
          OrchestrationSpec.tests databaseFixture,
          PackSpec.tests databaseFixture
        ]
    )

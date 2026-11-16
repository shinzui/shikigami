-- | The initiative pack's own tests: the proposal vocabulary, the pre-filter,
-- the assessment program, the ledger and standing policies on PostgreSQL,
-- stream intake through the composed hook, and the proposing flow end to end
-- through the real agent-run workflow.
module Main (main) where

import FlowPack.Initiative.AcceptanceSpec qualified as AcceptanceSpec
import FlowPack.Initiative.AdmitProposalSpec qualified as AdmitProposalSpec
import FlowPack.Initiative.AssessmentSpec qualified as AssessmentSpec
import FlowPack.Initiative.AssessmentWorkflowSpec qualified as AssessmentWorkflowSpec
import FlowPack.Initiative.InspectionSpec qualified as InspectionSpec
import FlowPack.Initiative.LedgerSpec qualified as LedgerSpec
import FlowPack.Initiative.PackSpec qualified as PackSpec
import FlowPack.Initiative.PolicySpec qualified as PolicySpec
import FlowPack.Initiative.PrefilterSpec qualified as PrefilterSpec
import FlowPack.Initiative.ProposeWorkSpec qualified as ProposeWorkSpec
import FlowPack.Initiative.StreamIntakeSpec qualified as StreamIntakeSpec
import FlowPack.Initiative.ValueSpec qualified as ValueSpec
import Shikigami.Migrations.TestSupport (withShikigamiMigratedSuite)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = withShikigamiMigratedSuite \databaseFixture ->
  defaultMain
    ( testGroup
        "flow-pack-initiative"
        [ ValueSpec.tests,
          PrefilterSpec.tests,
          AssessmentSpec.tests,
          PackSpec.tests databaseFixture,
          LedgerSpec.tests databaseFixture,
          PolicySpec.tests databaseFixture,
          InspectionSpec.tests databaseFixture,
          AssessmentWorkflowSpec.tests databaseFixture,
          StreamIntakeSpec.tests databaseFixture,
          ProposeWorkSpec.tests databaseFixture,
          AdmitProposalSpec.tests databaseFixture,
          AcceptanceSpec.tests databaseFixture
        ]
    )

module Main (main) where

import Shikigami.AgentRun.LedgerSpec qualified as LedgerSpec
import Shikigami.AgentWorkflowSpec qualified as AgentWorkflowSpec
import Shikigami.DecisionEvidenceSpec qualified as DecisionEvidenceSpec
import Shikigami.DecisionWorkflowSpec qualified as DecisionWorkflowSpec
import Shikigami.DelegationBudgetSpec qualified as DelegationBudgetSpec
import Shikigami.DirectoryStoreSpec qualified as DirectoryStoreSpec
import Shikigami.ExecutionResourcesSpec qualified as ExecutionResourcesSpec
import Shikigami.ExecutionSelectionWorkflowSpec qualified as ExecutionSelectionWorkflowSpec
import Shikigami.ExecutionTranscriptSpec qualified as ExecutionTranscriptSpec
import Shikigami.FlowLifecycleSpec qualified as FlowLifecycleSpec
import Shikigami.GrantStoreSpec qualified as GrantStoreSpec
import Shikigami.Migrations.TestSupport (withShikigamiMigratedSuite)
import Shikigami.PracticeReviewMemorySpec qualified as PracticeReviewMemorySpec
import Shikigami.PracticeReviewOrchestrationSpec qualified as PracticeReviewOrchestrationSpec
import Shikigami.ProfileResolutionSpec qualified as ProfileResolutionSpec
import Shikigami.RouterWorkflowSpec qualified as RouterWorkflowSpec
import Shikigami.RunEvidenceSpec qualified as RunEvidenceSpec
import Shikigami.SinkDeliverySpec qualified as SinkDeliverySpec
import Shikigami.SpikeWorkflowSpec qualified as SpikeWorkflowSpec
import Shikigami.WorkerSessionCapabilitySpec qualified as WorkerSessionCapabilitySpec
import Shikigami.WorkerSessionHandoffSpec qualified as WorkerSessionHandoffSpec
import Shikigami.WorkerSessionSpec qualified as WorkerSessionSpec
import Shikigami.WorkerSessionStoreSpec qualified as WorkerSessionStoreSpec
import Shikigami.WorkflowVersioningSpec qualified as WorkflowVersioningSpec
import Shikigami.WorkspaceTransferSpec qualified as WorkspaceTransferSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = withShikigamiMigratedSuite \databaseFixture ->
  defaultMain
    ( testGroup
        "shikigami postgres"
        [ LedgerSpec.tests databaseFixture,
          AgentWorkflowSpec.tests databaseFixture,
          DecisionEvidenceSpec.tests databaseFixture,
          DecisionWorkflowSpec.tests databaseFixture,
          DelegationBudgetSpec.tests databaseFixture,
          ExecutionResourcesSpec.tests databaseFixture,
          ExecutionSelectionWorkflowSpec.tests databaseFixture,
          ExecutionTranscriptSpec.tests databaseFixture,
          WorkerSessionStoreSpec.tests databaseFixture,
          WorkerSessionSpec.tests databaseFixture,
          WorkerSessionHandoffSpec.tests databaseFixture,
          WorkspaceTransferSpec.tests databaseFixture,
          WorkerSessionCapabilitySpec.tests databaseFixture,
          DirectoryStoreSpec.tests databaseFixture,
          FlowLifecycleSpec.tests databaseFixture,
          GrantStoreSpec.tests databaseFixture,
          PracticeReviewMemorySpec.tests databaseFixture,
          PracticeReviewOrchestrationSpec.tests databaseFixture,
          ProfileResolutionSpec.tests databaseFixture,
          RouterWorkflowSpec.tests databaseFixture,
          RunEvidenceSpec.tests databaseFixture,
          SinkDeliverySpec.tests databaseFixture,
          SpikeWorkflowSpec.tests databaseFixture,
          WorkflowVersioningSpec.tests databaseFixture
        ]
    )

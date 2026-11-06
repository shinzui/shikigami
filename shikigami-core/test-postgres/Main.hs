module Main (main) where

import Shikigami.AdaptiveDeliverySpec qualified as AdaptiveDeliverySpec
import Shikigami.AdaptiveWorkflowSpec qualified as AdaptiveWorkflowSpec
import Shikigami.AgentRun.LedgerSpec qualified as LedgerSpec
import Shikigami.AgentWorkflowSpec qualified as AgentWorkflowSpec
import Shikigami.AppSpec qualified as AppSpec
import Shikigami.DecisionEvidenceSpec qualified as DecisionEvidenceSpec
import Shikigami.DecisionExecutionSpec qualified as DecisionExecutionSpec
import Shikigami.DecisionWorkflowSpec qualified as DecisionWorkflowSpec
import Shikigami.DelegationBudgetSpec qualified as DelegationBudgetSpec
import Shikigami.DirectoryStoreSpec qualified as DirectoryStoreSpec
import Shikigami.ExecutionResourcesSpec qualified as ExecutionResourcesSpec
import Shikigami.ExecutionSelectionWorkflowSpec qualified as ExecutionSelectionWorkflowSpec
import Shikigami.ExecutionTranscriptSpec qualified as ExecutionTranscriptSpec
import Shikigami.FlowLifecycleSpec qualified as FlowLifecycleSpec
import Shikigami.GrantStoreSpec qualified as GrantStoreSpec
import Shikigami.InitiativeAssessmentSpec qualified as InitiativeAssessmentSpec
import Shikigami.InitiativeInspectionSpec qualified as InitiativeInspectionSpec
import Shikigami.InitiativeLedgerSpec qualified as InitiativeLedgerSpec
import Shikigami.InitiativePolicySpec qualified as InitiativePolicySpec
import Shikigami.Migrations.TestSupport (withShikigamiMigratedSuite)
import Shikigami.ObjectiveCheckpointSpec qualified as ObjectiveCheckpointSpec
import Shikigami.ObjectiveStoreSpec qualified as ObjectiveStoreSpec
import Shikigami.ObjectiveTrackerStoreSpec qualified as ObjectiveTrackerStoreSpec
import Shikigami.ObjectiveWorkflowSpec qualified as ObjectiveWorkflowSpec
import Shikigami.PracticeReviewMemorySpec qualified as PracticeReviewMemorySpec
import Shikigami.PracticeReviewOrchestrationSpec qualified as PracticeReviewOrchestrationSpec
import Shikigami.ProfileResolutionSpec qualified as ProfileResolutionSpec
import Shikigami.RouterWorkflowSpec qualified as RouterWorkflowSpec
import Shikigami.RunEvidenceSpec qualified as RunEvidenceSpec
import Shikigami.SinkDeliverySpec qualified as SinkDeliverySpec
import Shikigami.SpikeWorkflowSpec qualified as SpikeWorkflowSpec
import Shikigami.TypeSafeDecisionWorkflowSpec qualified as TypeSafeDecisionWorkflowSpec
import Shikigami.WatchdogObservationSpec qualified as WatchdogObservationSpec
import Shikigami.WatchdogStoreSpec qualified as WatchdogStoreSpec
import Shikigami.WorkerSessionCapabilitySpec qualified as WorkerSessionCapabilitySpec
import Shikigami.WorkerSessionHandoffSpec qualified as WorkerSessionHandoffSpec
import Shikigami.WorkerSessionSpec qualified as WorkerSessionSpec
import Shikigami.WorkerSessionStoreSpec qualified as WorkerSessionStoreSpec
import Shikigami.WorkflowInputSpec qualified as WorkflowInputSpec
import Shikigami.WorkflowVersioningSpec qualified as WorkflowVersioningSpec
import Shikigami.WorkspaceProcessProfileStoreSpec qualified as WorkspaceProcessProfileStoreSpec
import Shikigami.WorkspaceTransferSpec qualified as WorkspaceTransferSpec
import System.Environment (getArgs)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--objective-commit-and-exit"] -> ObjectiveStoreSpec.crashWriter
    ["--tracker-commit-and-exit"] -> ObjectiveTrackerStoreSpec.crashWriter
    _ -> suite

suite :: IO ()
suite = withShikigamiMigratedSuite \databaseFixture ->
  defaultMain
    ( testGroup
        "shikigami postgres"
        [ AppSpec.tests databaseFixture,
          InitiativeAssessmentSpec.tests databaseFixture,
          InitiativeInspectionSpec.tests databaseFixture,
          InitiativeLedgerSpec.tests databaseFixture,
          InitiativePolicySpec.tests databaseFixture,
          AdaptiveDeliverySpec.tests databaseFixture,
          AdaptiveWorkflowSpec.tests databaseFixture,
          WorkflowInputSpec.tests databaseFixture,
          ObjectiveStoreSpec.tests databaseFixture,
          ObjectiveTrackerStoreSpec.tests databaseFixture,
          ObjectiveCheckpointSpec.tests databaseFixture,
          ObjectiveWorkflowSpec.tests databaseFixture,
          LedgerSpec.tests databaseFixture,
          AgentWorkflowSpec.tests databaseFixture,
          DecisionExecutionSpec.tests databaseFixture,
          DecisionEvidenceSpec.tests databaseFixture,
          DecisionWorkflowSpec.tests databaseFixture,
          TypeSafeDecisionWorkflowSpec.tests databaseFixture,
          DelegationBudgetSpec.tests databaseFixture,
          ExecutionResourcesSpec.tests databaseFixture,
          ExecutionSelectionWorkflowSpec.tests databaseFixture,
          ExecutionTranscriptSpec.tests databaseFixture,
          WorkerSessionStoreSpec.tests databaseFixture,
          WatchdogObservationSpec.tests databaseFixture,
          WatchdogStoreSpec.tests databaseFixture,
          WorkerSessionSpec.tests databaseFixture,
          WorkerSessionHandoffSpec.tests databaseFixture,
          WorkspaceTransferSpec.tests databaseFixture,
          WorkspaceProcessProfileStoreSpec.tests databaseFixture,
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

-- | The durable child workflow for one human approval request.
module Shikigami.Agent.Approval.Workflow
  ( ApprovalWorkflowInput (..),
    ApprovalWorkflowResult (..),
    ApprovalNotificationResult (..),
    ApprovalNotificationError (..),
    ApprovalNotificationTransientFailure (..),
    ApprovalNotifier (..),
    ApprovalWorkflowEnv (..),
    defaultApprovalWorkflowEnv,
    approvalWorkflowPatch,
    approvalWorkflowPatchDeclared,
    approvalWorkflowName,
    approvalWorkflow,
    approvalRegistry,
    requestApproval,
  )
where

import Control.Exception (Exception)
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (throwIO)
import Keiro.Workflow
  ( PatchId (..),
    StepName (..),
    Workflow,
    WorkflowJournalEvent (..),
    WorkflowName,
    appendJournalEntry,
    currentRunGeneration,
    currentWorkflow,
    step,
  )
import Keiro.Workflow.Awakeable (AwakeableId)
import Keiro.Workflow.Child (awaitChild, spawnChild)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Kioku.App (AppEffects)
import Kioku.Id (SessionId)
import Kiroku.Store.Effect (Store)
import Shikigami.Agent.Approval
  ( ApprovalDecision,
    ApprovalRequest,
    ReviewRequestId,
    approvalWorkflowId,
    armApprovalDeadline,
    reviewRequestIdFor,
  )
import Shikigami.AgentRun.Generated.WorkflowRuntime qualified as AgentRunGenerated
import Shikigami.Approval.Generated.WorkflowRuntime qualified as Generated
import Shikigami.Prelude

data ApprovalWorkflowInput = ApprovalWorkflowInput
  { reviewRequestId :: !ReviewRequestId,
    sessionId :: !SessionId,
    request :: !ApprovalRequest,
    deadline :: !NominalDiffTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ApprovalWorkflowResult
  = ApprovalResolved !ApprovalDecision
  | ApprovalNotificationFailed !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ApprovalNotificationResult
  = ApprovalNotificationSent
  | ApprovalNotificationPermanentFailure !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ApprovalNotificationError
  = TransientNotification !Text
  | PermanentNotification !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype ApprovalNotificationTransientFailure = ApprovalNotificationTransientFailure Text
  deriving stock (Eq, Show)

instance Exception ApprovalNotificationTransientFailure

-- | Process resources used to publish a human-visible ask. These functions do
-- not cross the workflow journal; only 'ApprovalNotificationResult' does.
data ApprovalNotifier = ApprovalNotifier
  { recordPark :: !(SessionId -> ReviewRequestId -> AwakeableId -> ApprovalRequest -> IO ()),
    postAsk :: !(ReviewRequestId -> AwakeableId -> NominalDiffTime -> ApprovalRequest -> IO (Either ApprovalNotificationError ()))
  }

newtype ApprovalWorkflowEnv = ApprovalWorkflowEnv
  { notifier :: ApprovalNotifier
  }

defaultApprovalWorkflowEnv :: ApprovalWorkflowEnv
defaultApprovalWorkflowEnv =
  ApprovalWorkflowEnv
    { notifier =
        ApprovalNotifier
          { recordPark = \_ _ _ _ -> pure (),
            postAsk = \_ _ _ _ -> pure (Right ())
          }
    }

-- | The permanent parent compatibility branch declared in
-- @domain/shikigami-agent-run.keiro@. Keiro DSL 0.14 generates the checked set
-- but not individual patch constants, so the versioning tests assert this
-- runtime value is a member of that generated set.
approvalWorkflowPatch :: PatchId
approvalWorkflowPatch = PatchId "shikigami-approval-workflow-v1"

-- | Whether the hand-owned runtime value is present in the generated parent
-- contract. Exported for the deploy-simulation test that pins the boundary.
approvalWorkflowPatchDeclared :: Bool
approvalWorkflowPatchDeclared =
  Set.member approvalWorkflowPatch AgentRunGenerated.declaredPatches

approvalWorkflowName :: WorkflowName
approvalWorkflowName = Generated.workflowName

approvalWorkflow ::
  ApprovalWorkflowEnv ->
  Maybe ApprovalWorkflowInput ->
  Eff (Workflow : AppEffects) ApprovalWorkflowResult
approvalWorkflow ApprovalWorkflowEnv {notifier} mInput = do
  input <- step (StepName "ingest-approval") (ingestApproval mInput)
  (awakeableId, awaitDecision) <-
    Generated.allocateDeclaredAwait Generated.decisionAwait
  notification <-
    step (StepName "notify") do
      liftIO
        ( recordPark
            notifier
            (sessionId input)
            (reviewRequestId input)
            awakeableId
            (request input)
        )
      liftIO (postAsk notifier (reviewRequestId input) awakeableId (deadline input) (request input)) >>= \case
        Right () -> pure ApprovalNotificationSent
        Left (PermanentNotification detail) -> pure (ApprovalNotificationPermanentFailure detail)
        Left (TransientNotification detail) -> throwIO (ApprovalNotificationTransientFailure detail)
  case notification of
    ApprovalNotificationPermanentFailure detail -> pure (ApprovalNotificationFailed detail)
    ApprovalNotificationSent -> do
      armApprovalDeadline (StepName "decision") awakeableId (deadline input)
      ApprovalResolved <$> awaitDecision

approvalRegistry :: ApprovalWorkflowEnv -> WorkflowRegistry AppEffects
approvalRegistry env =
  Map.singleton Generated.workflowName (WorkflowDef \_workflowId -> approvalWorkflow env Nothing)

requestApproval ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  Text ->
  SessionId ->
  ApprovalRequest ->
  NominalDiffTime ->
  Eff es ApprovalWorkflowResult
requestApproval requestKey sessionId request deadline = do
  (parentName, parentId) <- currentWorkflow
  generation <- currentRunGeneration
  let reviewRequestId = reviewRequestIdFor parentName parentId generation requestKey
      childId = approvalWorkflowId reviewRequestId
      input = ApprovalWorkflowInput {reviewRequestId, sessionId, request, deadline}
  child <-
    spawnChild
      Generated.workflowName
      childId
      (pure (ApprovalNotificationFailed "approval child is driven from the workflow registry"))
  now <- liftIO getCurrentTime
  appendJournalEntry
    Generated.workflowName
    childId
    StepRecorded
      { stepName = "ingest-approval",
        result = Aeson.toJSON input,
        recordedAt = now
      }
  awaitChild child

ingestApproval :: (IOE :> es) => Maybe ApprovalWorkflowInput -> Eff es ApprovalWorkflowInput
ingestApproval = \case
  Just input -> pure input
  Nothing -> liftIO (ioError (userError "approval workflow resumed before ingest-approval was journaled"))

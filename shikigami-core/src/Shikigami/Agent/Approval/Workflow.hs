{-# LANGUAGE DataKinds #-}

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
    approvalWorkflowName,
    approvalWorkflow,
    approvalRegistry,
    requestApproval,
    requestBoundApproval,
  )
where

import Control.Exception (Exception)
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (throwIO)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow
  ( JournalAppendOutcome (..),
    StepName (..),
    Workflow,
    WorkflowJournalEvent (..),
    WorkflowName,
    currentRunGeneration,
    currentWorkflow,
    prepareJournalAppend,
    step,
  )
import Keiro.Workflow.Awakeable (AwakeableId)
import Keiro.Workflow.Child (awaitChild, spawnChild)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Kioku.Id (SessionId)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Approval
  ( ApprovalDecision,
    ApprovalRequest,
    ReviewRequestId,
    approvalWorkflowId,
    armApprovalDeadline,
    reviewRequestIdFor,
  )
import Shikigami.App (AppEffects)
import Shikigami.Approval.Generated.WorkflowRuntime qualified as Generated
import Shikigami.Approval.Observation (recordApprovalAssociationTx)
import Shikigami.Duration
import Shikigami.Prelude

data ApprovalWorkflowInput = ApprovalWorkflowInput
  { reviewRequestId :: !ReviewRequestId,
    sessionId :: !SessionId,
    request :: !ApprovalRequest,
    deadline :: !(Duration "approval")
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
    postAsk :: !(ReviewRequestId -> AwakeableId -> Duration "approval" -> ApprovalRequest -> IO (Either ApprovalNotificationError ()))
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
        ( (.recordPark)
            notifier
            ((.sessionId) input)
            ((.reviewRequestId) input)
            awakeableId
            ((.request) input)
        )
      liftIO ((.postAsk) notifier ((.reviewRequestId) input) awakeableId ((.deadline) input) ((.request) input)) >>= \case
        Right () -> pure ApprovalNotificationSent
        Left (PermanentNotification detail) -> pure (ApprovalNotificationPermanentFailure detail)
        Left (TransientNotification detail) -> throwIO (ApprovalNotificationTransientFailure detail)
  case notification of
    ApprovalNotificationPermanentFailure detail -> pure (ApprovalNotificationFailed detail)
    ApprovalNotificationSent -> do
      armApprovalDeadline (StepName "decision") awakeableId ((.deadline) input)
      ApprovalResolved <$> awaitDecision

approvalRegistry :: ApprovalWorkflowEnv -> WorkflowRegistry AppEffects
approvalRegistry env =
  Map.singleton Generated.workflowName (WorkflowDef \_workflowId -> approvalWorkflow env Nothing)

requestApproval ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  Text ->
  SessionId ->
  ApprovalRequest ->
  Duration "approval" ->
  Eff es ApprovalWorkflowResult
requestApproval requestKey sessionId request deadline = do
  (parentName, parentId) <- currentWorkflow
  generation <- currentRunGeneration
  let reviewRequestId = reviewRequestIdFor parentName parentId generation requestKey
  requestBoundApproval reviewRequestId sessionId request deadline

-- A caller that has already persisted the immutable permission binding keeps
-- its review identity across driver rotations. Child labels and codecs are the
-- same as the original approval path.
requestBoundApproval ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  ReviewRequestId -> SessionId -> ApprovalRequest -> Duration "approval" -> Eff es ApprovalWorkflowResult
requestBoundApproval reviewRequestId sessionId request deadline = do
  let childId = approvalWorkflowId reviewRequestId
      input = ApprovalWorkflowInput {reviewRequestId, sessionId, request, deadline}
  child <-
    spawnChild
      Generated.workflowName
      childId
      (pure (ApprovalNotificationFailed "approval child is driven from the workflow registry"))
  now <- liftIO getCurrentTime
  (parentName, parentId) <- currentWorkflow
  appendTx <-
    prepareJournalAppend
      Generated.workflowName
      childId
      0
      StepRecorded {stepName = "ingest-approval", result = Aeson.toJSON input, recordedAt = now}
  admitted <- runTransaction do
    recordApprovalAssociationTx reviewRequestId parentName parentId >>= \case
      Left problem -> pure (Left (show problem))
      Right () ->
        appendTx >>= \case
          JournalAppended {} -> pure (Right ())
          JournalAlreadyPresent _ -> pure (Right ())
          other -> Tx.condemn >> pure (Left (show other))
  either (liftIO . ioError . userError) pure admitted
  awaitChild child

ingestApproval :: (IOE :> es) => Maybe ApprovalWorkflowInput -> Eff es ApprovalWorkflowInput
ingestApproval = \case
  Just input -> pure input
  Nothing -> liftIO (ioError (userError "approval workflow resumed before ingest-approval was journaled"))

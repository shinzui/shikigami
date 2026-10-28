-- | One assignment per generation, with event-driven idle retention. The
-- authoritative mailbox, rather than replay-local state, selects accepted work.
module Shikigami.WorkerSession.Workflow
  ( SessionRuntime (..),
    WorkerSessionStart (..),
    WorkerSessionSeed (..),
    WorkerSessionClosed (..),
    SessionAction (..),
    sessionRegistry,
    ensureSession,
    sessionWorkflow,
    selectAssignment,
    sessionAccess,
  )
where

import Control.Exception (fromException)
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (Eff, IOE, raise, (:>))
import Effectful.Exception (throwIO, trySync)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), appendJournalEntry, continueAsNew, currentRunGeneration, currentWorkflow, restoreSeed, step)
import Keiro.Workflow.Awakeable (cancelAwakeable)
import Keiro.Workflow.Child (ChildHandle (..), WorkflowChildCancelled, WorkflowChildFailed, awaitChild)
import Keiro.Workflow.Child qualified as Child
import Keiro.Workflow.Child.Schema (ChildRow (..), lookupChild)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Kioku.App (AppEffects, AppEnv)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Agent.Delegate (Delegated (..), delegateAssignment)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.RunFailure (AgentRunFailure)
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.ContinuingWorker.Generated.WorkflowRuntime qualified as Generated
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Execution.SelectionRuntime qualified as Selection
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript (executionIdFor)
import Shikigami.Prelude
import Shikigami.WorkerSession.Checkpoint (CheckpointProvider (..), ObjectiveVersion (..))
import Shikigami.WorkerSession.Identity
import Shikigami.WorkerSession.Store qualified as Store
import Shikigami.WorkerSession.Types

data SessionRuntime = SessionRuntime
  { appEnv :: !AppEnv,
    agents :: ![AgentDecl],
    directory :: !DirectoryHandle,
    authorize :: AgentIdentity -> IO (Either Text ()),
    checkpoints :: !(Maybe CheckpointProvider)
  }
  deriving stock (Generic)

newtype WorkerSessionStart = WorkerSessionStart {sessionId :: WorkerSessionId}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype WorkerSessionSeed = WorkerSessionSeed {start :: Maybe WorkerSessionStart}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data WorkerSessionClosed = WorkerSessionClosed {sessionId :: WorkerSessionId, phase :: SessionPhase}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SessionAction = WaitForSession | RunAssignment !MessageReceipt | SessionBlocked | SessionDone !SessionPhase
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

sessionRegistry :: SessionRuntime -> WorkflowRegistry AppEffects
sessionRegistry runtime = Map.singleton Generated.workflowName (WorkflowDef \_ -> sessionWorkflow runtime Nothing)

-- | Registration is repeatable and does not wait for the retained session to
-- close. The production resume registry owns its execution.
ensureSession :: WorkerSessionId -> Eff (Workflow : AppEffects) ()
ensureSession session = do
  _ <- Child.spawnChild Generated.workflowName (sessionWorkflowId session) (pure (WorkerSessionClosed session Failed))
  now <- liftIO getCurrentTime
  appendJournalEntry Generated.workflowName (sessionWorkflowId session) (StepRecorded "ingest-session" (toJSON (WorkerSessionStart session)) now)

sessionAccess :: SessionRuntime -> WorkerSessionId -> Eff AppEffects (Either SessionError Store.SessionAccess)
sessionAccess runtime session = do
  Store.inspectSession session >>= \case
    Right (Just (_, binding)) -> Store.authorizeSession session binding.parentIdentity (runtime.authorize binding.parentIdentity)
    Right Nothing -> pure (Left SessionMissing)
    Left err -> pure (Left err)

require :: (IOE :> es) => Either SessionError a -> Eff es a
require = either (throwIO . userError . show) pure

sessionWorkflow :: SessionRuntime -> Maybe WorkerSessionStart -> Eff (Workflow : AppEffects) WorkerSessionClosed
sessionWorkflow runtime initial = do
  seed <- restoreSeed (WorkerSessionSeed Nothing)
  accepted <- step (StepName "ingest-session") (maybe (throwIO (userError "session resumed without its admitted identity")) pure (seed.start <|> initial))
  actual <- currentWorkflow
  unless (actual == (Generated.workflowName, sessionWorkflowId accepted.sessionId)) (throwIO (userError "session workflow identity mismatch"))
  (token, awaitHint) <- Generated.allocateDeclaredAwait Generated.sessionChangedAwait
  generation <- currentRunGeneration
  _ <- step (StepName "observe-session") do
    access <- raise (sessionAccess runtime accepted.sessionId) >>= require
    state <- currentState accepted.sessionId
    if state.phase `elem` [Failed, Cancelled]
      then pure state
      else snd <$> (Store.observeSession access state.revision state.epoch (OperationId ("observe:" <> Text.pack (show generation))) (SessionWake token generation) >>= require)
  action <- step (StepName "select-assignment") (raise (selectAssignment runtime accepted.sessionId) >>= require)
  case action of
    SessionDone phase -> void (cancelAwakeable token) >> pure (WorkerSessionClosed accepted.sessionId phase)
    WaitForSession -> waitAndRotate accepted awaitHint
    SessionBlocked -> waitAndRotate accepted awaitHint
    RunAssignment message -> do
      void (cancelAwakeable token)
      access <- raise (sessionAccess runtime accepted.sessionId) >>= require
      admission <- Store.loadAdmission access >>= require
      instruction <- Store.readInstruction access message.assignmentId >>= require
      findings <- Store.readAssignmentContext access message.assignmentId >>= require
      childId <- maybe (throwIO (userError "started assignment has no child mapping")) (pure . WorkflowId) message.childWorkflowId
      let WorkflowName childName = agentRunWorkflowName
      registered <- lookupChild childId.unWorkflowId childName
      case registered of
        Just row -> do
          let WorkflowName parentName = Generated.workflowName
          unless (row.parentName == parentName && row.parentId == accepted.sessionId.value) (throwIO (userError "assignment child parent changed"))
          finish accepted message access (ChildHandle agentRunWorkflowName childId)
        Nothing -> do
          state <- currentState accepted.sessionId
          current <- liftIO (currentAssignmentAuthority runtime admission state instruction)
          case current of
            Left _ -> do
              _ <- Store.setAssignmentStatus access state.revision state.epoch (OperationId ("unresolved:" <> message.assignmentId.value)) message.assignmentId AssignmentUnresolved >>= require
              continueAsNew (WorkerSessionSeed (Just accepted))
            Right () -> do
              Delegated handle <- delegateAssignment state.owner instruction.selection runtime.agents runtime.directory admission.delegator admission.context (assignmentDelegationKey message.assignmentId) (agentNameText (fromMaybe admission.worker state.worker)) (Aeson.object ["instruction" Aeson..= instruction.text, "assignmentId" Aeson..= message.assignmentId, "objective" Aeson..= admission.objective, "retainedFindings" Aeson..= findings])
              finish accepted message access handle
  where
    waitAndRotate accepted awaitHint = do
      hint <- awaitHint
      unless (hint == accepted.sessionId) (throwIO (userError "session wake identity mismatch"))
      continueAsNew (WorkerSessionSeed (Just accepted))
    currentState session = Store.inspectSession session >>= require >>= maybe (throwIO (userError "session disappeared")) (pure . fst)
    finish accepted message _ handle = do
      completed <- trySync (awaitChild handle :: Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult))
      let (disposition, output) = case completed of
            Right (Right result) -> (AssignmentSucceeded, result.behaviorOutput)
            Right (Left _) -> (AssignmentFailed, Aeson.object ["failure" Aeson..= ("agent run refused" :: Text)])
            Left err | isJust (fromException @WorkflowChildCancelled err) -> (AssignmentCancelled, Aeson.object ["failure" Aeson..= ("child cancelled" :: Text)])
            Left err | isJust (fromException @WorkflowChildFailed err) -> (AssignmentFailed, Aeson.object ["failure" Aeson..= ("child failed" :: Text)])
            Left _ -> (AssignmentFailed, Aeson.Null)
      case completed of
        Left err | isNothing (fromException @WorkflowChildCancelled err) && isNothing (fromException @WorkflowChildFailed err) -> throwIO err
        _ -> pure ()
      _ <- step (StepName "record-assignment-result") do
        access <- raise (sessionAccess runtime accepted.sessionId) >>= require
        state <- currentState accepted.sessionId
        let executionId = executionIdFor (Selection.assignmentIdFor handle.childWfId.unWorkflowId)
        metadata <- Execution.inspectExecution executionId
        reference <- case metadata of
          Right (Just (_, binding, _)) | binding.identity == state.owner -> pure (Just executionId)
          Right Nothing -> pure Nothing
          _ -> throwIO (userError "assignment execution reference is unavailable")
        snd <$> (Store.recordResult access state.revision state.epoch (OperationId ("result:" <> message.assignmentId.value)) (AssignmentResult 1 message.assignmentId disposition reference output []) >>= require)
      continueAsNew (WorkerSessionSeed (Just accepted))

selectAssignment :: SessionRuntime -> WorkerSessionId -> Eff AppEffects (Either SessionError SessionAction)
selectAssignment runtime session = do
  sessionAccess runtime session >>= \case
    Left err -> pure (Left err)
    Right access ->
      Store.inspectSession session >>= \case
        Right (Just (state, _)) -> case state.phase of
          Failed -> pure (Right (SessionDone Failed))
          Cancelled -> pure (Right (SessionDone Cancelled))
          Active -> case state.activeAssignment of
            Nothing -> pure (Left AssignmentConflict)
            Just assignment -> fmap RunAssignment <$> Store.readAssignment access assignment
          Parked -> pure (Right WaitForSession)
          Unresolved -> pure (Right WaitForSession)
          Transferring -> pure (Right WaitForSession)
          Idle ->
            Store.nextAssignment access >>= \case
              Left err -> pure (Left err)
              Right Nothing -> pure (Right WaitForSession)
              Right (Just message) -> do
                admission <- Store.loadAdmission access
                instruction <- Store.readInstruction access message.assignmentId
                case (admission, instruction) of
                  (Right admitted, Right input) ->
                    liftIO (currentAssignmentAuthority runtime admitted state input) >>= \case
                      Left _ -> pure (Right SessionBlocked)
                      Right () -> fmap (RunAssignment . snd) <$> Store.startAssignment access state.revision state.epoch (OperationId ("start:" <> message.assignmentId.value)) message.assignmentId
                  (Left err, _) -> pure (Left err)
                  (_, Left err) -> pure (Left err)
        Right Nothing -> pure (Left SessionMissing)
        Left err -> pure (Left err)

currentAssignmentAuthority :: SessionRuntime -> SessionAdmission -> SessionState -> Instruction -> IO (Either Text ())
currentAssignmentAuthority runtime admission state instruction = case runtime.checkpoints of
  Nothing -> pure (Left "objective provider unavailable")
  Just provider -> do
    now <- getCurrentTime
    authority <- runtime.authorize admission.context.identity
    snapshot <- provider.current admission.objective
    pure do
      authority
      version <- snapshot
      unless (version.active && version.owner == state.owner && version.ownerEpoch == state.epoch && Just version.rootId == admission.context.executionRootId && now < version.cutoff && version.revision == instruction.objectiveRevision && version.assignmentRevision == instruction.assignmentRevision && version.criteriaRevision == instruction.criteriaRevision) (Left "current objective assignment changed or expired")

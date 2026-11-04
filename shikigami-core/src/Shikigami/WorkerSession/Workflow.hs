-- | One assignment per generation, with event-driven idle retention. The
-- authoritative mailbox, rather than replay-local state, selects accepted work.
module Shikigami.WorkerSession.Workflow
  ( SessionRuntime (..),
    ChildObjectiveHost (..),
    childObjectiveHost,
    WorkerSessionStart (..),
    WorkerSessionSeed (..),
    WorkerSessionClosed (..),
    SessionAction (..),
    sessionRegistry,
    ensureSession,
    sessionWorkflow,
    selectAssignment,
    sessionAccess,
    currentAssignmentAuthority,
  )
where

import Control.Exception (fromException)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (Eff, IOE, raise, (:>))
import Effectful.Exception (throwIO, trySync)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), appendJournalEntry, continueAsNew, currentRunGeneration, currentWorkflow, loadStepIndex, restoreSeed, step)
import Keiro.Workflow qualified as Workflow
import Keiro.Workflow.Awakeable (cancelAwakeable)
import Keiro.Workflow.Child (ChildHandle (..), WorkflowChildCancelled, WorkflowChildFailed, awaitChild)
import Keiro.Workflow.Child qualified as Child
import Keiro.Workflow.Child.Schema (ChildRow (..), lookupChild)
import Keiro.Workflow.Child.Schema qualified as ChildSchema
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Agent.Delegate (Delegated (..), delegateAssignment, delegateAssociatedAssignment)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..), DelegationError (..))
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.RunFailure (AgentRunFailure)
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.App (AppEffects, AppEnv)
import Shikigami.ContinuingWorker.Generated.WorkflowRuntime qualified as Generated
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Execution.Identity (OperationId, operationIdWithPrefix)
import Shikigami.Execution.SelectionRuntime qualified as Selection
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript (executionIdFor)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Reference (ObjectiveAssociation)
import Shikigami.Prelude hiding ((.=))
import Shikigami.WorkerSession.Checkpoint (CheckpointIntent, CheckpointProvider (..), ObjectiveVersion (..))
import Shikigami.WorkerSession.CheckpointAuthority (RejectionAuthority)
import Shikigami.WorkerSession.Identity
import Shikigami.WorkerSession.Input
import Shikigami.WorkerSession.Store qualified as Store
import Shikigami.WorkerSession.Types
import Shikigami.Workflow.Versioning (admitWorkflowInput)

data ChildObjectiveHost = ChildObjectiveHost
  { admit :: !(AgentIdentity -> AgentIdentity -> WorkerSessionId -> AssignmentId -> WorkflowId -> IO (Either Text ObjectiveAssociation))
  }

data SessionRuntime
  = SessionRuntime
      { appEnv :: !AppEnv,
        agents :: ![AgentDecl],
        directory :: !DirectoryHandle,
        authorize :: !(AgentIdentity -> IO (Either Text ())),
        checkpoints :: !(Maybe (AgentIdentity -> CheckpointProvider)),
        rejections :: !(Maybe (AgentIdentity -> CheckpointIntent -> IO (Either Text RejectionAuthority)))
      }
  | AssociatedSessionRuntime
      { appEnv :: !AppEnv,
        agents :: ![AgentDecl],
        directory :: !DirectoryHandle,
        authorize :: !(AgentIdentity -> IO (Either Text ())),
        checkpoints :: !(Maybe (AgentIdentity -> CheckpointProvider)),
        rejections :: !(Maybe (AgentIdentity -> CheckpointIntent -> IO (Either Text RejectionAuthority))),
        childObjectives :: !ChildObjectiveHost
      }
  deriving stock (Generic)

childObjectiveHost :: SessionRuntime -> Maybe ChildObjectiveHost
childObjectiveHost SessionRuntime {} = Nothing
childObjectiveHost AssociatedSessionRuntime {childObjectives} = Just childObjectives

newtype WorkerSessionStart = WorkerSessionStart {sessionId :: (WorkerSessionId)}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype WorkerSessionSeed = WorkerSessionSeed {start :: Maybe WorkerSessionStart}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data WorkerSessionClosed = WorkerSessionClosed {sessionId :: !(WorkerSessionId), phase :: !(SessionPhase)}
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
  admitWorkflowInput Generated.workflowName (sessionWorkflowId session) (StepName "ingest-session") (toJSON (WorkerSessionStart session))

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
  generationNumber <- currentRunGeneration
  generation <- either (throwIO . userError . Text.unpack) pure (parseWorkflowGeneration generationNumber)
  _ <- step (StepName "observe-session") do
    access <- raise (sessionAccess runtime accepted.sessionId) >>= require
    state <- currentState accepted.sessionId
    if state.phase `elem` [Failed, Cancelled]
      then pure state
      else snd <$> (Store.observeSession access state.revision state.epoch (operationIdWithPrefix ('o' :| "bserve:") (Text.pack (show generationNumber))) (SessionWake token generation) >>= require)
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
      childId <- maybe (throwIO (userError "started assignment has no child mapping")) pure message.childWorkflowId
      let WorkflowName childName = agentRunWorkflowName
      registered <- lookupChild childId.unWorkflowId childName
      case registered of
        Just row -> do
          let WorkflowName parentName = Generated.workflowName
          unless (row.parentName == parentName && row.parentId == accepted.sessionId.value) (throwIO (userError "assignment child parent changed"))
          entries <- loadStepIndex agentRunWorkflowName childId 0
          if row.status == ChildSchema.Running && Map.notMember "ingest-job" entries
            then spawnAssignment accepted message childId access admission instruction findings
            else finish accepted message access (ChildHandle agentRunWorkflowName childId)
        Nothing -> do
          state <- currentState accepted.sessionId
          current <- liftIO (currentAssignmentAuthority runtime admission state instruction)
          case current of
            Left _ -> do
              _ <- Store.setAssignmentStatus access state.revision state.epoch (operationIdWithPrefix ('u' :| "nresolved:") message.assignmentId.value) message.assignmentId AssignmentUnresolved >>= require
              continueAsNew (WorkerSessionSeed (Just accepted))
            Right () -> spawnAssignment accepted message childId access admission instruction findings
  where
    waitAndRotate accepted awaitHint = do
      hint <- awaitHint
      unless (hint == accepted.sessionId) (throwIO (userError "session wake identity mismatch"))
      continueAsNew (WorkerSessionSeed (Just accepted))
    currentState session = Store.inspectSession session >>= require >>= maybe (throwIO (userError "session disappeared")) (pure . fst)
    spawnAssignment accepted message childId access admission instruction findings = do
      state <- currentState accepted.sessionId
      let permissions = case (admission.context.executionPermissions, message.permittedAliases) of
            (Nothing, additional) -> additional
            (existing, Nothing) -> existing
            (Just existing, Just additional) -> Just (filter (`elem` existing) additional)
          context = admission.context & #executionPermissions .~ permissions
      useAssociated <- Workflow.patch (Workflow.PatchId "shikigami-worker-objective-children-v1")
      reference <- case (useAssociated, childObjectiveHost runtime) of
        (True, Just host) -> do
          associated <- step (StepName "associate-assignment-child") (liftIO (host.admit admission.context.identity state.owner accepted.sessionId message.assignmentId childId))
          either (throwIO . DelegationIdentityRefused) (pure . Just) associated
        _ -> pure Nothing
      let delegateChild = case reference of
            Nothing -> delegateAssignment
            Just objective -> delegateAssociatedAssignment objective
      let declarations = if null (admissionCatalog admission) then runtime.agents else admissionCatalog admission
      spawned <- trySync (delegateChild state.owner instruction.selection declarations runtime.directory admission.delegator context (assignmentDelegationKey message.assignmentId) (fromMaybe admission.worker state.worker) (Aeson.object ["instruction" .= instruction.text, "assignmentId" .= message.assignmentId, "objective" .= admission.objective, "retainedFindings" .= findings]))
      case spawned of
        Right (Delegated handle) -> finish accepted message access handle
        Left err
          | isJust (fromException @DelegationError err) ->
              retainResult accepted message childId AssignmentFailed (Aeson.object ["failure" .= ("governed delegation refused before input admission" :: Text)])
        Left err -> throwIO err
    finish accepted message _ handle = do
      completed <- trySync (awaitChild handle :: Eff (Workflow : AppEffects) (Either AgentRunFailure AgentRunResult))
      let (disposition, output) = case completed of
            Right (Right result) -> (AssignmentSucceeded, result.behaviorOutput)
            Right (Left _) -> (AssignmentFailed, Aeson.object ["failure" .= ("agent run refused" :: Text)])
            Left err | isJust (fromException @WorkflowChildCancelled err) -> (AssignmentCancelled, Aeson.object ["failure" .= ("child cancelled" :: Text)])
            Left err | isJust (fromException @WorkflowChildFailed err) -> (AssignmentFailed, Aeson.object ["failure" .= ("child failed" :: Text)])
            Left _ -> (AssignmentFailed, Aeson.Null)
      case completed of
        Left err | isNothing (fromException @WorkflowChildCancelled err) && isNothing (fromException @WorkflowChildFailed err) -> throwIO err
        _ -> pure ()
      retainResult accepted message handle.childWfId disposition output
    retainResult accepted message childId disposition output = do
      _ <- step (StepName "record-assignment-result") do
        access <- raise (sessionAccess runtime accepted.sessionId) >>= require
        recorded <- Store.readResult access message.assignmentId >>= require
        case recorded of
          Just (receipt, _) -> pure receipt
          Nothing -> do
            state <- currentState accepted.sessionId
            let executionId = executionIdFor (Selection.assignmentIdFor childId.unWorkflowId)
            metadata <- Execution.inspectExecution executionId
            reference <- case metadata of
              Right (Just (_, binding, _)) | binding.identity == state.owner -> pure (Just executionId)
              Right Nothing -> pure Nothing
              _ -> throwIO (userError "assignment execution reference is unavailable")
            snd <$> (Store.recordResult access state.revision message.epoch (operationIdWithPrefix ('r' :| "esult:") message.assignmentId.value) (AssignmentResult V1 message.assignmentId disposition reference output []) >>= require)
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
                      Right () -> fmap (RunAssignment . snd) <$> Store.startAssignment access state.revision state.epoch (operationIdWithPrefix ('s' :| "tart:") message.assignmentId.value) message.assignmentId
                  (Left err, _) -> pure (Left err)
                  (_, Left err) -> pure (Left err)
        Right Nothing -> pure (Left SessionMissing)
        Left err -> pure (Left err)

currentAssignmentAuthority :: SessionRuntime -> SessionAdmission -> SessionState -> Instruction -> IO (Either Text ())
currentAssignmentAuthority runtime admission state instruction = case runtime.checkpoints of
  Nothing -> pure (Left "objective provider unavailable")
  Just providers -> do
    let provider = providers admission.context.identity
    now <- getCurrentTime
    authority <- runtime.authorize admission.context.identity
    snapshot <- provider.current admission.objective
    pure do
      authority
      version <- snapshot
      unless (objectiveIsActive version.active && version.owner == state.owner && version.ownerEpoch == state.epoch && Just version.rootId == admission.context.executionRootId && now < version.cutoff && (if null (admissionCatalog admission) then version.revision == instruction.objectiveRevision else version.revision >= instruction.objectiveRevision) && version.assignmentRevision == instruction.assignmentRevision && version.criteriaRevision == instruction.criteriaRevision) (Left "current objective assignment changed or expired")

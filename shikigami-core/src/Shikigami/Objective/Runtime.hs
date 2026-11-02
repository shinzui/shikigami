{-# LANGUAGE DataKinds #-}

-- | Objective-owned composition for worker services. Missing workspace fencing
-- stays unavailable; accepted checkpoint readers remain installed when disabled.
module Shikigami.Objective.Runtime
  ( coordinationHost,
    ObjectiveRuntime (..),
    hostFor,
    owned,
    resolveExecutionScope,
    resolveConversationScope,
    resolveFlowScope,
    authorizeScope,
    validateRetainedScope,
    rootCutoff,
  )
where

import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.Aeson (Value)
import Data.List (find)
import Data.Text qualified as Text
import Effectful (Eff)
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName)
import Kikan.En.Action (AgentAction (InvokeCapabilityTool), mkCapabilityToolTarget)
import Kioku.Id (SessionId)
import Kioku.Id qualified as KiokuId
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (ActionAuthorizer (..))
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (CoordinatingSkill), DelegationBudget)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Decision.ModelAlias (ModelAlias)
import Shikigami.Directory qualified as Directory
import Shikigami.Execution.AssignmentKey (AssignmentKey)
import Shikigami.Execution.Coordinate (ExecutionDigest, executionDigestFor, executionDigestText)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Association qualified as Association
import Shikigami.Objective.Capability qualified as Capability
import Shikigami.Objective.Checkpoint (checkpointProvider, checkpointRejection)
import Shikigami.Objective.Conversation qualified as Conversation
import Shikigami.Objective.Coordination (coordinationAuthority, objectiveHost)
import Shikigami.Objective.Ownership (ownershipProvider)
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Scope qualified as Scope
import Shikigami.Objective.Store qualified as Goals
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.WorkerSession.Capability qualified as Worker
import Shikigami.WorkerSession.Handoff (TransferServices (..))
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.WorkerSession.Transfer qualified as Transfer
import Shikigami.WorkerSession.Types (SessionBinding (..))
import Shikigami.WorkerSession.Workflow (SessionRuntime (..))

coordinationHost :: AppEnv -> ObjectiveSettings -> Directory.DirectoryHandle -> ActionAuthorizer -> [AgentDecl] -> DelegationBudget -> Maybe Transfer.WorkspaceProvider -> Worker.CoordinationHost
coordinationHost env settings directory actions agents budget workspaces = Worker.CoordinationHost services authority
  where
    host = objectiveHost settings directory actions
    sessions = SessionRuntime env agents directory (Directory.identityLifecycleAdmission directory) (Just (\actor -> checkpointProvider env actor (host actor))) (Just (\actor -> checkpointRejection env actor (host actor)))
    authority = coordinationAuthority env settings directory actions agents budget
    -- The callback selects authority from the retained session owner. An actor
    -- carried in a submitted intent cannot select another authenticated host.
    ownership = Transfer.OwnershipProvider \intent proof -> do
      actual <- runAppIO env (Sessions.inspectSession intent.sessionId)
      case actual of
        Right (Right (Just (_, binding))) -> (ownershipProvider env binding.parentIdentity (host binding.parentIdentity) workspaces).transfer intent proof
        _ -> pure Transfer.OwnershipUnavailable
    services = TransferServices sessions workspaces (Just ownership)

-- Process-local services never cross the snapshot or workflow boundary.
data ObjectiveRuntime = ObjectiveRuntime
  { appEnv :: !AppEnv,
    settings :: !ObjectiveSettings,
    directory :: !Directory.DirectoryHandle,
    actions :: !ActionAuthorizer,
    coordination :: !(Maybe Worker.CoordinationHost)
  }
  deriving stock (Generic)

hostFor :: ObjectiveRuntime -> AgentIdentity -> Capability.ObjectiveHost
hostFor runtime = objectiveHost runtime.settings runtime.directory runtime.actions

owned :: ObjectiveRuntime -> Eff AppEffects (Either ObjectiveError a) -> IO (Either ObjectiveError a)
owned runtime action = runAppIO runtime.appEnv action <&> either (const (Left ObjectiveUnavailable)) id

resolveExecutionScope :: ObjectiveRuntime -> RunJob -> AgentDecl -> SessionId -> ExecutionSelection -> IO (Either ObjectiveError (Maybe Scope.ObjectiveScope))
resolveExecutionScope runtime job declaration session selection = do
  target <- runTarget runtime job selection.rootId
  case target of
    Left err -> pure (Left err)
    Right goal -> do
      coordination <- case declaration.behavior of
        CoordinatingSkill {} -> resolveCoordinator runtime (Worker.CoordinatorRun (runJobWorkflowId job) job.identity session selection.rootId (Just selection.permittedAliases)) Nothing
        _ -> pure (Right Nothing)
      case coordination of
        Left err -> pure (Left err)
        Right pinned -> admitScope runtime (runJobWorkflowId job) job.identity session selection.rootId (Just selection.permittedAliases) goal (Scope.AgentScope selection.assignmentId) pinned

resolveFlowScope :: ObjectiveRuntime -> WorkflowName -> WorkflowId -> Integer -> RunJob -> SessionId -> Maybe (ExecutionDigest "coordination-scope") -> IO (Either ObjectiveError (Maybe Scope.ObjectiveScope))
resolveFlowScope runtime name run generation job session pinned
  | run /= runJobWorkflowId job = pure (Left ObjectiveDenied)
  | otherwise = case parseRevision generation of
      Left _ -> pure (Left ObjectiveDenied)
      Right version -> do
        target <- runTarget runtime job job.executionRootId
        case target of
          Left err -> pure (Left err)
          Right goal -> admitScope runtime run job.identity session job.executionRootId job.executionPermissions goal (Scope.FlowScope name version) pinned

-- A disabled feature must not silently discard an existing binding. Untargeted
-- turns without a creation grant keep their ordinary, unassociated menu. Their
-- accepted execution's absent scope freezes that absence without a new tool.
resolveConversationScope :: ObjectiveRuntime -> WorkflowId -> AgentIdentity -> SessionId -> Maybe ExecutionRootId -> [ModelAlias] -> AssignmentKey -> ConversationRef -> TurnReference -> IO (Either ObjectiveError (Maybe Scope.ObjectiveScope))
resolveConversationScope runtime run identity session root aliases assignment conversation turn = do
  current <- owned runtime (runTransaction (Conversation.currentBinding conversation identity))
  case current of
    Left err -> pure (Left err)
    Right Nothing | not (Goals.creationAllowed runtime.settings (RecordedAgent identity)) -> pure (Right Nothing)
    Right _ | runtime.settings.enabled == ObjectivesDisabled -> pure (Left ObjectiveDenied)
    Right _ -> do
      admitted <- owned runtime (Capability.admitConversationTurn (hostFor runtime identity) (runReference run.unWorkflowId) turn conversation)
      case admitted of
        Left err -> pure (Left err)
        Right admission | admission.participant == identity && admission.sessionId == KiokuId.idText session -> admitScope runtime run identity session root (Just aliases) (fmap (.receipt.objectiveId) admission.binding) (Scope.ConversationScope assignment conversation turn) Nothing
        _ -> pure (Left ObjectiveDenied)

runTarget :: ObjectiveRuntime -> RunJob -> Maybe ExecutionRootId -> IO (Either ObjectiveError (Maybe ObjectiveId))
runTarget runtime job root
  | runtime.settings.enabled == ObjectivesDisabled = pure (if isNothing job.objective then Right Nothing else Left ObjectiveDenied)
  | otherwise = do
      retained <- owned runtime (fmap (either (const (Left ObjectiveUnavailable)) Right) (runTransaction (Association.lookupRunTx (runJobWorkflowId job))))
      case retained of
        Left err -> pure (Left err)
        Right reference | reference /= job.objective -> pure (Left ObjectiveDenied)
        Right Nothing -> pure (Right Nothing)
        Right (Just reference) -> do
          actual <- owned runtime (Capability.readObjective (hostFor runtime job.identity) reference.objectiveId)
          pure do
            goal <- actual
            assignment <- maybe (Left ObjectiveMissing) Right (find ((== reference.assignmentId) . (.definition.assignmentId)) goal.assignments)
            unless (goal.status `elem` [Open, Blocked] && assignment.definition.owner == job.identity && assignment.definition.state /= Withdrawn && maybe True (\bound -> Just bound == root) assignment.definition.rootId) (Left ObjectiveDenied)
            pure (Just reference.objectiveId)

admitScope :: ObjectiveRuntime -> WorkflowId -> AgentIdentity -> SessionId -> Maybe ExecutionRootId -> Maybe [ModelAlias] -> Maybe ObjectiveId -> Scope.ScopeSource -> Maybe (ExecutionDigest "coordination-scope") -> IO (Either ObjectiveError (Maybe Scope.ObjectiveScope))
admitScope runtime run identity session root aliases target source coordination
  | isNothing target && not creator = pure (Right Nothing)
  | runtime.settings.enabled == ObjectivesDisabled = pure (Left ObjectiveDenied)
  | otherwise = do
      live <- rootCutoff runtime root
      case live of
        Left err -> pure (Left err)
        Right cutoff -> do
          let policy = if creator then Just (executionDigestFor "shikigami.objective-creation-policy/1" (toJSON runtime.settings)) else Nothing
              permissions = [Scope.InspectObjectives, Scope.ApplyObjectiveCommands] <> [Scope.CreateObjectives | creator]
              scope = Scope.ObjectiveScope V1 run identity session root cutoff aliases target source coordination permissions policy
          ready <- case policy of
            Nothing -> pure (Right ())
            Just _ -> owned runtime (Capability.checkCreationAdmission (hostFor runtime identity) (toJSON scope))
          permitted <- authorizeScope runtime scope "admit" (toJSON scope)
          pure (Just scope <$ (ready >> permitted))
  where
    creator = Goals.creationAllowed runtime.settings (RecordedAgent identity)

-- This binds exact C13 authority to the retained scope and complete operation.
-- It is additional to the command owner's current membership/action check.
authorizeScope :: ObjectiveRuntime -> Scope.ObjectiveScope -> Text -> Value -> IO (Either ObjectiveError ())
authorizeScope runtime scope label semantic = do
  attempted <- trySync do
    actor <- (hostFor runtime scope.identity).authenticate
    case actor of
      Right (RecordedAgent identity) | identity == scope.identity -> case identityText identity of
        Left _ -> pure (Left ObjectiveDenied)
        Right principal ->
          let revision = "scope-1-" <> Text.replace ":" "-" (executionDigestText (Scope.scopeFingerprint scope))
              digest = Text.replace ":" "-" (executionDigestText (executionDigestFor "shikigami.objective-scoped-action/1" semantic))
           in case mkCapabilityToolTarget "shikigami.objectives" revision (label <> "-" <> digest) of
                Left _ -> pure (Left ObjectiveDenied)
                Right target -> runtime.actions.authorize (declarationCoordinate principal) (InvokeCapabilityTool target) <&> either (const (Left ObjectiveDenied)) (const (Right ()))
      Left err -> pure (Left err)
      _ -> pure (Left ObjectiveDenied)
  pure (either (const (Left ObjectiveUnavailable)) id attempted)

validateRetainedScope :: ObjectiveRuntime -> Scope.ObjectiveScope -> IO (Either ObjectiveError ())
validateRetainedScope runtime scope
  | not (Scope.validScope scope) = pure (Left ObjectiveDenied)
  | otherwise = do
      active <- (hostFor runtime scope.identity).authenticate
      case active of
        Right (RecordedAgent identity) | identity == scope.identity -> case scope.coordination of
          Nothing -> pure (Right ())
          Just pinned -> do
            retained <- owned runtime (Capability.lookupCoordinationScope (hostFor runtime scope.identity) (Worker.CoordinatorRun scope.runId scope.identity scope.sessionId scope.rootId scope.permittedAliases) (Just pinned))
            pure (retained >>= maybe (Left ObjectiveDenied) (const (Right ())))
        Left err -> pure (Left err)
        _ -> pure (Left ObjectiveDenied)

resolveCoordinator :: ObjectiveRuntime -> Worker.CoordinatorRun -> Maybe (ExecutionDigest "coordination-scope") -> IO (Either ObjectiveError (Maybe (ExecutionDigest "coordination-scope")))
resolveCoordinator runtime run pinned = case runtime.coordination of
  Nothing -> pure (Left ObjectiveUnavailable)
  Just host -> do
    result <- runAppIO runtime.appEnv (Worker.resolveGrant host runtime.actions run pinned)
    pure case result of
      Right (Right (Just grant)) -> Right (Just (Worker.grantFingerprint grant))
      _ -> Left ObjectiveDenied

rootCutoff :: ObjectiveRuntime -> Maybe ExecutionRootId -> IO (Either ObjectiveError (Maybe UTCTime))
rootCutoff _ Nothing = pure (Right Nothing)
rootCutoff runtime (Just root) = do
  checked <- owned runtime do
    loaded <- Roots.inspectRoot root
    now <- liftIO getCurrentTime
    pure do
      state <- either (const (Left ObjectiveUnavailable)) Right loaded
      either (const (Left ObjectiveDenied)) (const (Right (Just state.envelope.cutoff))) (Resources.checkRoot now state.revision state)
  pure checked

trySync :: IO a -> IO (Either SomeException a)
trySync action =
  try action >>= \case
    Left err | Just (_ :: SomeAsyncException) <- fromException err -> throwIO err
    answer -> pure answer

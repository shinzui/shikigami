{-# LANGUAGE DataKinds #-}

-- | One closed command admission boundary for Flow, model and operator callers.
-- A declaration requests control; an admitted, retained scope and fresh exact
-- authorization are both required. No generic mutation overlay is enabled.
module Shikigami.WorkerSession.Capability
  ( CoordinatorRun (..),
    WorkerSlot (..),
    CoordinationScope (..),
    CoordinationAuthority (..),
    CoordinationHost (..),
    CoordinationGrant,
    WorkerCommand (..),
    WorkerInstruction (..),
    WorkerReply (..),
    scopeFingerprint,
    resolveGrant,
    executeCommand,
    grantFingerprint,
    grantSupportsSkill,
    subscribeCommand,
    authorizeAdmissionRead,
  )
where

import Data.Aeson ((.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.List (find, nub)
import Data.Text qualified as Text
import Effectful (Eff)
import Effectful.Exception (trySync)
import Keiro.Workflow.Types (WorkflowId (..))
import Kikan.En.Action (AgentAction (InvokeCapabilityTool), mkCapabilityToolTarget)
import Kioku.Id (SessionId)
import Shikigami.Action.Authorization (ActionAuthorizer (..))
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (CoordinatingSkill), IdentityDecl (..))
import Shikigami.Agent.Delegate.Context (DelegateCtx (..), assertMayDelegate)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.App (AppEffects)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Decision.ModelAlias (ModelAlias)
import Shikigami.Directory qualified as Directory
import Shikigami.Execution.Identity (ExecutionRootId, OperationId)
import Shikigami.Execution.Payload (payloadDigestText)
import Shikigami.Execution.Request (ExecutionRequest)
import Shikigami.Execution.Resources (Admission (..), Root (..), checkRoot)
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Transcript (PayloadRef (..))
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Prelude hiding ((.=))
import Shikigami.StateRevision
import Shikigami.WorkerSession.Checkpoint (CheckpointProvider (..), ObjectiveVersion (..))
import Shikigami.WorkerSession.Handoff (TransferOutcome, TransferServices (..), requestHandoff, resumeHandoff)
import Shikigami.WorkerSession.Input
import Shikigami.WorkerSession.Integration (IntegrationOutcome, integrateEvents)
import Shikigami.WorkerSession.Position
import Shikigami.WorkerSession.Store qualified as Store
import Shikigami.WorkerSession.Transfer (TransferIntent, WorkspaceRef)
import Shikigami.WorkerSession.Types
import Shikigami.WorkerSession.Workflow (SessionRuntime (..), currentAssignmentAuthority)

data CoordinatorRun = CoordinatorRun
  { runId :: !WorkflowId,
    identity :: !AgentIdentity,
    sessionId :: !SessionId,
    rootId :: !(Maybe ExecutionRootId),
    permittedAliases :: !(Maybe [ModelAlias])
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON CoordinatorRun where
  toJSON value = Aeson.object ["runId" .= value.runId.unWorkflowId, "identity" .= value.identity, "sessionId" .= value.sessionId, "rootId" .= value.rootId, "permittedAliases" .= value.permittedAliases]

instance FromJSON CoordinatorRun where
  parseJSON = Aeson.withObject "CoordinatorRun" \fields -> CoordinatorRun <$> (WorkflowId <$> fields .: "runId") <*> fields .: "identity" <*> fields .: "sessionId" <*> fields .:? "rootId" <*> fields .:? "permittedAliases"

data WorkerSlot = WorkerSlot
  { workerKey :: !(WorkerCoordinate "worker-slot"),
    target :: !AgentName,
    identity :: !AgentIdentity,
    objective :: !ObjectiveRef,
    sessionId :: !(Maybe WorkerSessionId)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CoordinationScope = CoordinationScope
  { format :: !(FormatVersion "coordination-scope"),
    run :: !CoordinatorRun,
    parentScope :: !(WorkerCoordinate "parent-scope"),
    agent :: !AgentDecl,
    context :: !DelegateCtx,
    workers :: ![WorkerSlot],
    maximumSessions :: !MaximumSessions,
    maximumAssignments :: !MaximumAssignments,
    mailboxLimit :: !MailboxLimit
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show CoordinationScope where show _ = "CoordinationScope <protected>"

-- | The authoritative association owner retains scopes by fingerprint while
-- executions, Flows or sessions refer to them. Reacquisition never substitutes
-- the current objective or a newly minted root for a pinned scope.
-- The source derives delegation depth, lineage and budget from the accepted
-- run/session records; prompt text and caller-supplied context are not grants.
data CoordinationAuthority = CoordinationAuthority
  { admit :: !(CoordinatorRun -> IO (Either Text (Maybe CoordinationScope))),
    reacquire :: !(CoordinatorRun -> Text -> IO (Either Text CoordinationScope))
  }

data CoordinationHost = CoordinationHost
  { services :: !TransferServices,
    authority :: !CoordinationAuthority
  }
  deriving stock (Generic)

newtype CoordinationGrant = CoordinationGrant CoordinationScope

instance Show CoordinationGrant where show _ = "CoordinationGrant <protected>"

data WorkerInstruction = WorkerInstruction
  { text :: !InstructionText,
    objectiveRevision :: !(StateRevision "objective"),
    assignmentRevision :: !(StateRevision "objective-assignment"),
    criteriaRevision :: !(StateRevision "objective-criteria"),
    selection :: !(Maybe ExecutionRequest)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance FromJSON WorkerInstruction where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

instance Show WorkerInstruction where show _ = "WorkerInstruction <protected>"

data WorkerCommand
  = FindWorker {workerKey :: !(WorkerCoordinate "worker-slot")}
  | SendWorker {sessionId :: !WorkerSessionId, expectedRevision :: !(StateRevision "worker-session"), epoch :: !(StateRevision "worker-owner"), instruction :: !WorkerInstruction}
  | InspectWorker {sessionId :: !WorkerSessionId, position :: !MessagePosition, pageSize :: !AssignmentPageSize}
  | ReadWorkerEvents {sessionId :: !WorkerSessionId, after :: !(StateRevision "worker-event"), limit :: !EventPageSize}
  | ReadWorkerResult {sessionId :: !WorkerSessionId, assignmentId :: !AssignmentId}
  | InterruptWorker {sessionId :: !WorkerSessionId, expectedRevision :: !(StateRevision "worker-session"), epoch :: !(StateRevision "worker-owner"), assignmentId :: !AssignmentId, instruction :: !WorkerInstruction}
  | CancelWorker {sessionId :: !WorkerSessionId, expectedRevision :: !(StateRevision "worker-session"), epoch :: !(StateRevision "worker-owner")}
  | TransferWorker {sessionId :: !WorkerSessionId, expectedRevision :: !(StateRevision "worker-session"), epoch :: !(StateRevision "worker-owner"), workspace :: !WorkspaceRef, target :: !AgentName}
  | ReconcileWorker {sessionId :: !WorkerSessionId}
  | IntegrateWorkerEvents {sessionId :: !WorkerSessionId}
  deriving stock (Eq, Generic)

instance ToJSON WorkerCommand where
  toJSON = Aeson.genericToJSON workerCommandOptions

instance FromJSON WorkerCommand where
  parseJSON = Aeson.genericParseJSON workerCommandOptions

workerCommandOptions :: Aeson.Options
workerCommandOptions =
  Aeson.defaultOptions
    { Aeson.rejectUnknownFields = True,
      Aeson.fieldLabelModifier = \field -> case field of "position" -> "after"; "pageSize" -> "limit"; _ -> field
    }

instance Show WorkerCommand where show _ = "WorkerCommand <protected>"

data WorkerReply
  = WorkerFound !SessionState
  | MessageAcceptedReply !Admission !MessageReceipt
  | WorkerInspected !SessionInspection
  | WorkerEvents ![EventReceipt]
  | WorkerResult !(Maybe (ResultReceipt, Maybe AssignmentResult))
  | WorkerClosed !SessionState
  | TransferAccepted !TransferIntent
  | TransferObserved !TransferOutcome
  | EventsIntegratedReply !IntegrationOutcome
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show WorkerReply where show _ = "WorkerReply <protected>"

scopeFingerprint :: CoordinationScope -> Text
scopeFingerprint scope = versionedDigest "shikigami.worker-coordination-scope/1" (toJSON scope)

grantFingerprint :: CoordinationGrant -> Text
grantFingerprint (CoordinationGrant scope) = scopeFingerprint scope

grantSupportsSkill :: CoordinationGrant -> Bool
grantSupportsSkill (CoordinationGrant scope) = case scope.agent.behavior of
  CoordinatingSkill {} -> True
  _ -> False

resolveGrant :: CoordinationHost -> ActionAuthorizer -> CoordinatorRun -> Maybe Text -> Eff AppEffects (Either SessionError (Maybe CoordinationGrant))
resolveGrant host authorizer run pinned = do
  supplied <- trySync (liftIO (case pinned of Nothing -> host.authority.admit run; Just ref -> fmap Just <$> host.authority.reacquire run ref))
  case supplied of
    Right (Right Nothing) -> pure (Right Nothing)
    Right (Right (Just scope)) -> do
      let valid = scope.format == V1 && scope.run == run && scope.context.identity == run.identity && scope.context.sessionId == Just run.sessionId && scope.context.executionRootId == run.rootId && scope.context.executionPermissions == run.permittedAliases && isJust run.rootId && not (Text.null (workerCoordinateText scope.parentScope)) && Text.length (workerCoordinateText scope.parentScope) <= 256 && not (null scope.workers) && length scope.workers <= sessionLimit scope.maximumSessions && length (nub (map (.workerKey) scope.workers)) == length scope.workers && maybe True (== scopeFingerprint scope) pinned
          admissions = [sessionAdmission scope worker | worker <- scope.workers]
      if not valid || any (either (const True) (const False) . validateAdmission) admissions
        then pure (Left SessionOwnerRefused)
        else do
          fresh <- liftIO (host.services.sessions.authorize run.identity)
          case fresh of
            Left _ -> pure (Left SessionOwnerRefused)
            Right () -> do
              root <- maybe (pure (Left SessionOwnerRefused)) (fmap (either (const (Left SessionOwnerRefused)) Right) . Roots.inspectRoot) run.rootId
              now <- liftIO getCurrentTime
              case root of
                Right current | isJust pinned || either (const False) (const True) (checkRoot now current.revision current) -> do
                  accepted <- authorizeExact authorizer scope "admit" (toJSON run)
                  pure (Just (CoordinationGrant scope) <$ accepted)
                _ -> pure (Left SessionOwnerRefused)
    _ -> pure (Left (SessionInputRefused "coordination scope is unavailable"))

executeCommand :: CoordinationHost -> ActionAuthorizer -> CoordinationGrant -> OperationId -> WorkerCommand -> Eff AppEffects (Either SessionError WorkerReply)
executeCommand host authorizer grant@(CoordinationGrant scope) operation command = do
  result <- executeAdmittedCommand host authorizer grant operation command
  case result of
    Right reply
      | Just session <- driverSession reply ->
          Store.authorizeSession session scope.run.identity (host.services.sessions.authorize scope.run.identity) >>= \case
            Left err -> pure (Left err)
            Right access -> Store.ensureSessionDriver access <&> fmap (const reply)
    _ -> pure result
  where
    driverSession = \case
      WorkerFound state -> Just state.sessionId
      MessageAcceptedReply _ receipt -> Just receipt.sessionId
      _ -> Nothing

executeAdmittedCommand :: CoordinationHost -> ActionAuthorizer -> CoordinationGrant -> OperationId -> WorkerCommand -> Eff AppEffects (Either SessionError WorkerReply)
executeAdmittedCommand host authorizer (CoordinationGrant scope) operation command = do
  fresh <- liftIO (host.services.sessions.authorize scope.run.identity)
  case fresh of
    Left _ -> pure (Left SessionOwnerRefused)
    Right () ->
      authorizeExact authorizer scope (commandTag command) (toJSON (operation, command)) >>= \case
        Left err -> pure (Left err)
        Right () -> case command of
          FindWorker key -> case find ((== key) . (.workerKey)) scope.workers of
            Nothing -> pure (Left SessionOwnerRefused)
            Just slot -> do
              let admission = sessionAdmission scope slot
                  session = fromMaybe (sessionIdFor admission) slot.sessionId
              Store.inspectSession session >>= \case
                Right (Just (state, binding)) | matchesScope scope slot binding -> pure (Right (WorkerFound state))
                Right (Just _) -> pure (Left SessionBindingConflict)
                Right Nothing | isNothing slot.sessionId -> do
                  permitted <- currentSlot slot
                  case permitted of
                    Left _ -> pure (Left SessionOwnerRefused)
                    Right () -> fmap (WorkerFound . snd) <$> Store.openSessionWithLimit scope.maximumSessions admission
                Right Nothing -> pure (Left SessionMissing)
                Left err -> pure (Left err)
          _ -> do
            let session = commandSession command
            Store.inspectSession session >>= \case
              Right (Just (_, binding)) | any (\slot -> matchesScope scope slot binding && maybe True (== session) slot.sessionId) scope.workers -> do
                Store.authorizeSession session scope.run.identity (host.services.sessions.authorize scope.run.identity) >>= \case
                  Left err -> pure (Left err)
                  Right access -> dispatch access session
              Right (Just _) -> pure (Left SessionOwnerRefused)
              Right Nothing -> pure (Left SessionMissing)
              Left err -> pure (Left err)
  where
    dispatch access session = case command of
      SendWorker {expectedRevision, epoch, instruction} -> send access session expectedRevision epoch (message FollowUp instruction)
      InterruptWorker {expectedRevision, epoch, assignmentId, instruction} -> send access session expectedRevision epoch (message (Interrupt assignmentId) instruction)
      InspectWorker {position, pageSize} -> Store.inspectSessionPage session position (sessionLimit pageSize) <&> (>>= maybe (Left SessionMissing) (Right . WorkerInspected))
      ReadWorkerEvents {after, limit} -> fmap WorkerEvents <$> Store.readEvents access after (sessionLimit limit)
      ReadWorkerResult {assignmentId} -> fmap (WorkerResult . fmap (\(receipt, result) -> (receipt, if Lazy.length (Aeson.encode result) <= 16384 then Just result else Nothing))) <$> Store.readResult access assignmentId
      CancelWorker {expectedRevision, epoch} -> fmap (WorkerClosed . snd) <$> Store.closeSession access expectedRevision epoch operation AssignmentCancelled
      TransferWorker {expectedRevision, epoch, workspace, target} -> fmap TransferAccepted <$> requestHandoff host.services session expectedRevision epoch operation workspace target
      ReconcileWorker {} -> fmap TransferObserved <$> resumeHandoff host.services session
      IntegrateWorkerEvents {} -> fmap EventsIntegratedReply <$> integrateEvents host.services.sessions session operation
      FindWorker {} -> pure (Left SessionCommandRefused)
    send access session expected epoch instruction = do
      Store.readMessageAcceptance access operation >>= \case
        Right (Just accepted) ->
          Store.readInstruction access accepted.assignmentId <&> \case
            Right original | original == instruction && accepted.epoch == epoch -> Right (MessageAcceptedReply AlreadyAccepted accepted)
            Right _ -> Left MessageConflict
            Left err -> Left err
        Left err -> pure (Left err)
        Right Nothing -> do
          admission <- Store.loadAdmission access
          metadata <- Store.inspectSession session
          case (admission, metadata) of
            (Right admitted, Right (Just (state, _))) | revisionNumber state.nextSequence < toInteger (sessionLimit scope.maximumAssignments) -> do
              let permissions = case (admitted.context.executionPermissions, scope.context.executionPermissions) of
                    (Nothing, narrowed) -> narrowed
                    (existing, Nothing) -> existing
                    (Just existing, Just narrowed) -> Just (filter (`elem` existing) narrowed)
                  sameRole = admitted.context.depth == scope.context.depth && admitted.context.lineage == scope.context.lineage && admitted.context.delegationBudgetId == scope.context.delegationBudgetId && admitted.context.budgetLimit == scope.context.budgetLimit
                  target = fromMaybe admitted.worker state.worker
              current <- trySync (liftIO (currentAssignmentAuthority host.services.sessions admitted state instruction))
              case current of
                Right (Right ()) | sameRole && permissions /= Just [] && either (const False) (const True) (assertMayDelegate scope.agent target) -> fmap (uncurry MessageAcceptedReply) <$> Store.acceptScopedMessage access expected epoch operation permissions instruction
                _ -> pure (Left SessionOwnerRefused)
            (Right _, Right (Just _)) -> pure (Left SessionLimitExceeded)
            (Left err, _) -> pure (Left err)
            (_, Left err) -> pure (Left err)
            _ -> pure (Left SessionMissing)
    currentSlot slot = case (host.services.sessions.checkpoints, find (\decl -> decl.name == slot.target && decl.enabled) host.services.sessions.agents) of
      (Just provider, Just decl) -> do
        actual <- liftIO (Directory.identityAdmission host.services.sessions.directory ((.principal) <$> decl.identity) slot.target)
        version <- trySync (liftIO (provider.current slot.objective))
        now <- liftIO getCurrentTime
        pure case (actual, version) of
          (Right identity, Right (Right current)) | identity == slot.identity && objectiveIsActive current.active && current.owner == identity && current.ownerEpoch == initialRevision && Just current.rootId == scope.run.rootId && now < current.cutoff -> Right ()
          _ -> Left SessionOwnerRefused
      _ -> pure (Left SessionOwnerRefused)
    message kind draft = Instruction V1 kind draft.text draft.objectiveRevision draft.assignmentRevision draft.criteriaRevision draft.selection

sessionAdmission :: CoordinationScope -> WorkerSlot -> SessionAdmission
sessionAdmission scope slot = SessionAdmission V1 (SessionScope scope.parentScope slot.workerKey) slot.objective scope.agent scope.context slot.target slot.identity scope.maximumAssignments scope.mailboxLimit

matchesScope :: CoordinationScope -> WorkerSlot -> SessionBinding -> Bool
matchesScope scope slot binding = binding.parentIdentity == scope.run.identity && Just binding.rootId == scope.run.rootId && binding.scope == SessionScope scope.parentScope slot.workerKey && binding.objective == slot.objective

authorizeExact :: ActionAuthorizer -> CoordinationScope -> Text -> Aeson.Value -> Eff AppEffects (Either SessionError ())
authorizeExact authorizer scope label input = case identityText scope.run.identity of
  Left _ -> pure (Left SessionOwnerRefused)
  Right principal -> do
    let digest = Text.replace ":" "-" (versionedDigest "shikigami.worker-command-action/1" input)
        revision = "1-" <> Text.replace ":" "-" (scopeFingerprint scope)
    case mkCapabilityToolTarget "shikigami.worker-sessions" revision (label <> "-" <> digest) of
      Left _ -> pure (Left SessionOwnerRefused)
      Right target -> liftIO (authorizer.authorize principal (InvokeCapabilityTool target)) <&> either (const (Left SessionOwnerRefused)) (const (Right ()))

-- | Bootstrap an operator's scope from protected accepted admission, using only
-- public binding coordinates until both lifecycle and exact C13 checks pass.
authorizeAdmissionRead :: ActionAuthorizer -> (AgentIdentity -> IO (Either Text ())) -> WorkerSessionId -> SessionBinding -> IO (Either Text ())
authorizeAdmissionRead authorizer lifecycle session binding = do
  current <- lifecycle binding.parentIdentity
  case (current, identityText binding.parentIdentity, mkCapabilityToolTarget "shikigami.worker-sessions" ("admission-1-" <> Text.replace ":" "-" (payloadDigestText binding.admission.digest)) ("read-admission-" <> session.value)) of
    (Right (), Right principal, Right target) ->
      authorizer.authorize principal (InvokeCapabilityTool target) >>= \case
        Right _ -> pure (Right ())
        Left _ -> pure (Left "fresh protected admission read refused")
    _ -> pure (Left "parent admission read refused")

commandTag :: WorkerCommand -> Text
commandTag = \case
  FindWorker {} -> "find"
  SendWorker {} -> "send"
  InspectWorker {} -> "inspect"
  ReadWorkerEvents {} -> "events"
  ReadWorkerResult {} -> "result"
  InterruptWorker {} -> "interrupt"
  CancelWorker {} -> "cancel"
  TransferWorker {} -> "transfer"
  ReconcileWorker {} -> "reconcile"
  IntegrateWorkerEvents {} -> "integrate"

commandSession :: WorkerCommand -> WorkerSessionId
commandSession = \case
  FindWorker {} -> error "find has no caller-selected session"
  SendWorker {sessionId} -> sessionId
  InspectWorker {sessionId} -> sessionId
  ReadWorkerEvents {sessionId} -> sessionId
  ReadWorkerResult {sessionId} -> sessionId
  InterruptWorker {sessionId} -> sessionId
  CancelWorker {sessionId} -> sessionId
  TransferWorker {sessionId} -> sessionId
  ReconcileWorker {sessionId} -> sessionId
  IntegrateWorkerEvents {sessionId} -> sessionId

-- | Only the Flow interpreter supplies this listener; it is absent from model
-- command input and must belong to the admitted parent run.
subscribeCommand :: CoordinationHost -> ActionAuthorizer -> CoordinationGrant -> OperationId -> WorkerSessionId -> SessionListener -> Eff AppEffects (Either SessionError (StateRevision "worker-event"))
subscribeCommand host authorizer (CoordinationGrant scope) operation session listener
  | listener.ownerId /= scope.run.runId = pure (Left SessionOwnerRefused)
  | otherwise =
      authorizeExact authorizer scope "subscribe" (toJSON (operation, session, listener)) >>= \case
        Left err -> pure (Left err)
        Right () ->
          Store.inspectSession session >>= \case
            Right (Just (state, binding))
              | any (\slot -> matchesScope scope slot binding && maybe True (== session) slot.sessionId) scope.workers ->
                  Store.authorizeSession session scope.run.identity (host.services.sessions.authorize scope.run.identity) >>= \case
                    Right access -> fmap snd <$> Store.subscribeEvents access state.revision state.epoch operation listener
                    Left err -> pure (Left err)
            Right Nothing -> pure (Left SessionMissing)
            Right _ -> pure (Left SessionOwnerRefused)
            Left err -> pure (Left err)

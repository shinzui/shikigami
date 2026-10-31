{-# LANGUAGE DataKinds #-}

-- | Conditional process admission and one-shot launch ownership. No model or
-- socket caller supplies commands, host paths, Unix ids or systemd properties.
-- Installation remains gated on the complete Linux supervisor qualification.
module Shikigami.Workspace.Supervisor
  ( SupervisorError (..),
    SupervisorRequest (..),
    SupervisorRuntime (..),
    SupervisorBackend (..),
    systemdSupervisorBackend,
    workspaceExecDescriptor,
    transferredWorkspaceExecDescriptor,
    transferredWorkspaceExecBinding,
    workspaceExecSchema,
    workspaceExecBinding,
    superviseProcess,
    reconcileProcess,
    ProcessPublication (..),
    publishProcessReceipt,
    processToolResult,
    renderProcessResult,
    processDirectory,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception, IOException, catch, onException, throwIO)
import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (addUTCTime)
import Effectful (Eff)
import Hasql.Transaction (Transaction)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (ActionAuthorizer (..))
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Capability.Overlay
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Claim
import Shikigami.Execution.Identity
import Shikigami.Execution.Policy.Types (RecoveryClass (..), ToolInvoiceCost (..))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Runner (DispatchContext (..), OperationContext (..))
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.ToolPosition
import Shikigami.Execution.Transcript
import Shikigami.Prelude hiding ((.=))
import Shikigami.StateRevision
import Shikigami.Workspace.Allocation (workspaceFiles, workspaceMetadata, workspaceScratch)
import Shikigami.Workspace.Collector
import Shikigami.Workspace.ContainedFile
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessStore qualified as Processes
import Shikigami.Workspace.Provider (workspaceProcessAction, workspaceTransferredProcessAction)
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Store qualified as Workspaces
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.TransferStore qualified as Transfers
import Shikigami.Workspace.Types
import Shikumi.Tool (ToolError (ToolRunFailed), renderToolError)
import Shikumi.Tool.Output (ToolOutput, textToolOutput)
import System.Directory (createDirectory, doesPathExist)
import System.FilePath ((</>))

-- An error carries no completion/no-launch proof: another request may already
-- have committed intent. Only a retained ProcessRefused record proves a
-- pre-launch refusal; only a matching settled receipt proves completion.
data SupervisorError = SupervisorRefused | SupervisorUnavailable | SupervisorUnresolved | SupervisorUnsupported
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SupervisorRequest = SupervisorRequest
  { executionId :: !ExecutionId,
    operationId :: !OperationId,
    attemptId :: !AttemptId,
    owner :: !ClaimOwner,
    generation :: !(StateRevision "execution-attempt")
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance FromJSON SupervisorRequest where
  parseJSON = Aeson.withObject "supervisor request" \fields -> do
    unless (length fields == 5 && all (`KeyMap.member` fields) ["executionId", "operationId", "attemptId", "owner", "generation"]) (fail "unsupported supervisor request")
    Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object fields)

instance Show SupervisorRequest where show _ = "SupervisorRequest <protected>"

-- Trusted service configuration. Rule lookup must resolve the retained policy
-- revision, complete reviewed instruction digest and immutable command/root
-- profile. It must not reinterpret an old revision through current defaults.
data SupervisorRuntime = SupervisorRuntime
  { appEnv :: !AppEnv,
    authorizer :: !ActionAuthorizer,
    replayAuthority :: !(AgentIdentity -> IO (Either Text ())),
    lifecycle :: !(ExecutionSnapshot -> IO (Either Text ())),
    selectRule :: !(WorkspaceBinding -> WorkspaceAdmission -> Text -> IO (Either Text (ProcessCommand, Systemd.SystemdProfile))),
    backend :: !SupervisorBackend
  }
  deriving stock (Generic)

-- Test interpreters establish admission/registration evidence only. Production
-- installation uses the qualified systemd interpreter, with no local fallback.
data SupervisorBackend = SupervisorBackend
  { bootIdentity :: !(IO (Either Systemd.SystemdError Text)),
    capture :: !(Systemd.SystemdProfile -> FilePath -> ProcessRecord -> IO (Either Systemd.SystemdError ())),
    launch :: !(Systemd.SystemdProfile -> FilePath -> FilePath -> FilePath -> ProcessRecord -> IO (Either Systemd.SystemdError ())),
    collectorActive :: !(ProcessRecord -> IO (Either Systemd.SystemdError Bool)),
    stop :: !(ProcessRecord -> IO (Either Systemd.SystemdError ()))
  }
  deriving stock (Generic)

systemdSupervisorBackend :: SupervisorBackend
systemdSupervisorBackend = SupervisorBackend Systemd.systemdBootIdentity Systemd.startCollector Systemd.startProcess Systemd.collectorActive Systemd.stopProcess

data AcceptedProcess = AcceptedProcess
  { snapshot :: !ExecutionSnapshot,
    access :: !Execution.ReplayAccess,
    binding :: !WorkspaceBinding,
    admission :: !WorkspaceAdmission,
    dispatch :: !DispatchContext,
    command :: !ProcessCommand,
    profile :: !Systemd.SystemdProfile,
    routing :: !ProcessRouting
  }

newtype SupervisorAbort = SupervisorAbort SupervisorError deriving stock (Show)

instance Exception SupervisorAbort

workspaceExecDescriptor :: CapabilityDescriptor
workspaceExecDescriptor = execDescriptorFor False

transferredWorkspaceExecDescriptor :: CapabilityDescriptor
transferredWorkspaceExecDescriptor = execDescriptorFor True

execDescriptorFor :: Bool -> CapabilityDescriptor
execDescriptorFor transferable = CapabilityDescriptor (must (mkCapabilityId "workspace.exec")) (must (mkCapabilityRevision (if transferable then "2" else "1"))) [CapabilityToolDescriptor "validate" IdempotentMutation]
  where
    must :: (Show e) => Either e a -> a; must = either (error . show) id

workspaceExecSchema :: Aeson.Value
workspaceExecSchema = Aeson.object ["type" .= ("object" :: Text), "properties" .= Aeson.object ["rule" .= Aeson.object ["type" .= ("string" :: Text), "maxLength" .= (256 :: Int)]], "required" .= ["rule" :: Text], "additionalProperties" .= False]

workspaceExecBinding :: ToolBinding
workspaceExecBinding = execBindingFor False

transferredWorkspaceExecBinding :: ToolBinding
transferredWorkspaceExecBinding = execBindingFor True

execBindingFor :: Bool -> ToolBinding
execBindingFor transferable = ToolBinding "overlay__workspace-exec__validate" (if transferable then "workspace.exec:2" else "workspace.exec:1") (versionedDigest "shikigami.tool-schema/1" workspaceExecSchema) UncertainEffect NoInvoiceCost

superviseProcess :: SupervisorRuntime -> SupervisorRequest -> IO (Either SupervisorError ProcessRecord)
superviseProcess runtime request = protect do
  unless (validRequest request) (abort SupervisorRefused)
  accepted <- loadAccepted runtime request
  let binding = accepted.binding
      metadata = workspaceMetadata binding.storageRoot binding
  needFile =<< checkPrivateDirectory binding.storageRoot
  needFile =<< checkPrivateDirectory metadata
  locked <- withWorkspaceLock metadata $ Right <$> lockedProcess runtime accepted
  either (const (abort SupervisorUnresolved)) pure locked

-- Independent service recovery needs no current model/worker authority. It
-- reads only provider facts and returns metadata. It cannot issue a launch.
reconcileProcess :: SupervisorRuntime -> OperationId -> IO (Either SupervisorError ProcessRecord)
reconcileProcess runtime operation = protect do
  (binding, _) <- readRegisteredProcess runtime operation >>= maybe (abort SupervisorRefused) pure
  let metadata = workspaceMetadata binding.storageRoot binding
  needFile =<< checkPrivateDirectory binding.storageRoot
  needFile =<< checkPrivateDirectory metadata
  locked <-
    withWorkspaceLock metadata $
      Right <$> do
        record <- readProcess runtime operation >>= maybe (abort SupervisorUnavailable) pure
        unless (record.bindingDigest == workspaceBindingDigest binding && record.unit == processUnit operation record.fingerprint) (abort SupervisorUnresolved)
        if record.phase == ProcessReserved
          then do
            transact runtime (Processes.refuseReservedProcessTx record) >>= either (const (abort SupervisorUnresolved)) pure
            readProcess runtime operation >>= maybe (abort SupervisorUnavailable) pure
          else observe runtime binding record
  either (const (abort SupervisorUnresolved)) pure locked

loadAccepted :: SupervisorRuntime -> SupervisorRequest -> IO AcceptedProcess
loadAccepted runtime request = do
  metadata <- execute runtime (Execution.inspectExecution request.executionId)
  (_, retained, _) <- maybe (abort SupervisorRefused) pure metadata
  access <- execute runtime (Execution.authorizeReplay request.executionId retained.identity (runtime.replayAuthority retained.identity))
  (snapshot, _) <- execute runtime (Execution.loadExecution access)
  operation <- execute runtime (Execution.inspectOperation request.operationId) >>= maybe (abort SupervisorRefused) pure
  admission <- maybe (abort SupervisorRefused) pure snapshot.workspace
  let transferable = admission.filePolicy == Just transferableFilePolicy
      expected = execBindingFor transferable
  unless (admission.filePolicy == Just (if transferable then transferableFilePolicy else supervisedFilePolicy) && execDescriptorFor transferable `elem` resolvedCapabilities snapshot.capabilities && operation.executionId == snapshot.executionId && operation.specification.kind == ToolOperation && operation.specification.name == expected.name && operation.specification.recovery == UncertainEffect && operation.specification.scopeDigest == toolScopeDigest expected && operation.specification.policyDigest == versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy)) (abort SupervisorRefused)
  tool <- execute runtime (Execution.readReplayPayload @ToolOperationInput access "operation-input" operation.input)
  unless (tool.binding == expected && tool.binding `elem` snapshot.toolBindings && tool.invocation.name == expected.name && operation.specification.responsePosition == Just tool.position) (abort SupervisorRefused)
  response <- execute runtime (Execution.readReplayPayload @OperationOutcome access "operation-outcome" tool.response)
  assistant <- case response of ModelReturned value _ -> pure value; _ -> abort SupervisorRefused
  unless (take 1 (drop (toolPositionNumber tool.position) (toolInvocations assistant)) == [tool.invocation]) (abort SupervisorRefused)
  let next = toolContinuation tool assistant
      routing = ProcessRouting ProcessRoutingV1 snapshot.executionId snapshot.identity operation.input.digest next
  unless (validProcessRouting routing) (abort SupervisorRefused)
  rule <- either (const (abort SupervisorRefused)) pure (parseEither (Aeson.withObject "validation rule" (\fields -> if length fields /= 1 then fail "invalid rule request" else fields .: "rule")) tool.invocation.arguments)
  unless (bounded rule) (abort SupervisorRefused)
  (binding, state) <- transact runtime (Workspaces.inspectWorkspaceTx admission.workspace) >>= either (const (abort SupervisorRefused)) pure >>= maybe (abort SupervisorRefused) pure
  unless (state == Ready && matchesWorkspaceAdmission binding admission && admission.runId == snapshot.runId && admission.assignmentId == snapshot.selection.assignmentId && Just admission.rootId == snapshot.selection.rootId && admission.rootId == binding.request.rootId && admission.owner == snapshot.identity && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base) (abort SupervisorRefused)
  (command, profile) <- runtime.selectRule binding admission rule >>= either (const (abort SupervisorRefused)) pure
  profileIdentity <- Systemd.systemdProfileIdentity profile
  unless (validProcessCommand command && command.rule == rule && command.profile == profileIdentity) (abort SupervisorRefused)
  let key = operationIdText request.operationId
      context = OperationContext snapshot.executionId request.operationId key operation.fingerprint operation.specification.scopeDigest
      dispatch = DispatchContext context request.attemptId request.owner request.generation
  pure (AcceptedProcess snapshot access binding admission dispatch command profile routing)

lockedProcess :: SupervisorRuntime -> AcceptedProcess -> IO ProcessRecord
lockedProcess runtime accepted = do
  let binding = accepted.binding
      dispatch = accepted.dispatch
      command = accepted.command
  -- An existing registration is observed without rechecking the former claim
  -- or reserving a new deadline. It can never produce another launch request.
  existing <- readProcess runtime dispatch.operation.operationId
  case existing of
    Just record -> do
      unless (record.bindingDigest == workspaceBindingDigest binding && record.instructionDigest == bundleDigest accepted.admission.instructions && record.command == command && record.routing == Just accepted.routing && record.fingerprint == processFingerprint binding record.instructionDigest dispatch.operation command) (abort SupervisorRefused)
      if record.phase == ProcessReserved
        then do
          transact runtime (Processes.refuseReservedProcessTx record) >>= either (const (abort SupervisorUnresolved)) pure
          readProcess runtime record.operationId >>= maybe (abort SupervisorUnavailable) pure
        else observe runtime binding record
    Nothing -> do
      boot <- runtime.backend.bootIdentity >>= either (abort . backendError) pure
      current runtime accepted Nothing
      root <- runAppIO runtime.appEnv (Roots.inspectRoot binding.request.rootId) >>= either (const (abort SupervisorUnavailable)) (either (const (abort SupervisorRefused)) pure)
      now <- getCurrentTime
      either (const (abort SupervisorRefused)) pure (Resources.checkRoot now root.revision root)
      let deadline = min root.envelope.cutoff (addUTCTime (fromIntegral command.timeoutSeconds) now)
          fingerprint = processFingerprint binding (bundleDigest accepted.admission.instructions) dispatch.operation command
          proposed = ProcessRecord dispatch.operation.operationId dispatch.attemptId dispatch.owner dispatch.generation (workspaceBindingDigest binding) (bundleDigest accepted.admission.instructions) fingerprint command deadline (processUnit dispatch.operation.operationId fingerprint) Nothing Nothing ProcessReserved Nothing (Just accepted.routing)
      record <- transact runtime ((if accepted.admission.filePolicy == Just transferableFilePolicy then Processes.reserveAdmittedProcessTx binding accepted.admission else Processes.reserveProcessTx binding) proposed) >>= either (const (abort SupervisorRefused)) pure
      unless (record == proposed) (abort SupervisorUnresolved)
      let candidate = record & #bootId .~ Just boot & #phase .~ ProcessLaunchRequested
          directory = processDirectory binding record
          files = workspaceFiles binding.storageRoot binding
          scratch = workspaceScratch binding.storageRoot binding
          path = (if Text.null command.directory then "" else command.directory <> "/") <> ".shikigami-process-target"
      -- Validate all serialization constraints before consuming the transition.
      _ <- Systemd.processArguments now accepted.profile files scratch directory candidate >>= either (abort . backendError) pure
      let refuseUnlaunched = void (transact runtime (Processes.refuseReservedProcessTx record))
      resolved <-
        ( withContainedFile files path $ \target ->
            Right <$> do
              identity <- containedTargetIdentity target >>= either (const (abort SupervisorRefused)) pure
              authorize runtime accepted candidate boot identity
              exists <- doesPathExist directory
              unless exists do
                createDirectory directory
                needFile =<< ensurePrivateDirectory directory
              needFile =<< checkPrivateDirectory directory
              runtime.backend.capture accepted.profile directory candidate >>= either (abort . backendError) pure
              waitReady directory 100
              -- Retain the resolved parent identity through capture preparation.
              parent <- withContainedFile files path containedTargetIdentity
              unless (parent == Right identity) (abort SupervisorRefused)
              authorize runtime accepted candidate boot identity
              granted <- transact runtime ((if accepted.admission.filePolicy == Just transferableFilePolicy then Processes.requestAdmittedProcessLaunchTx binding accepted.admission else Processes.requestProcessLaunchTx binding) record boot) >>= either (const (abort SupervisorUnresolved)) pure
              unless granted (abort SupervisorUnresolved)
              -- The committed intent survives exceptions or acknowledgement loss.
              -- A new caller observes it and never issues another start request.
              let uncertain = void (transact runtime (Processes.markProcessUnresolvedTx candidate))
              ( do
                  result <- protect do
                    current runtime accepted (Just candidate)
                    launched <- runtime.backend.launch accepted.profile files scratch directory candidate
                    either (const (abort SupervisorUnresolved)) pure launched
                    observe runtime binding candidate
                  either (const (uncertain >> abort SupervisorUnresolved)) pure result
                )
                `onException` uncertain
        )
          `onException` refuseUnlaunched
      either (const (refuseUnlaunched >> abort SupervisorRefused)) pure resolved

current :: SupervisorRuntime -> AcceptedProcess -> Maybe ProcessRecord -> IO ()
current runtime accepted record = do
  runtime.lifecycle accepted.snapshot >>= either (const (abort SupervisorRefused)) pure
  let dispatch = accepted.dispatch
      claim = Attempt.AttemptClaim (Attempt.JobReference 1 accepted.snapshot.executionId dispatch.operation.operationId dispatch.attemptId) dispatch.owner dispatch.generation
  execute runtime (Execution.checkStartedExecutionAttempt accepted.access claim)
  transact runtime (if accepted.admission.filePolicy == Just transferableFilePolicy then Transfers.checkWorkspaceAdmissionOwnerTx accepted.binding accepted.admission else Workspaces.checkWorkspaceOwnerTx accepted.binding accepted.admission.owner accepted.admission.epoch) >>= either (const (abort SupervisorRefused)) pure
  forM_ record \retained -> getCurrentTime >>= \now -> when (now >= retained.deadline) (abort SupervisorRefused)

authorize :: SupervisorRuntime -> AcceptedProcess -> ProcessRecord -> Text -> Text -> IO ()
authorize runtime accepted record boot target = do
  principal <- either (const (abort SupervisorRefused)) pure (identityText accepted.admission.owner)
  action <- either (const (abort SupervisorRefused)) pure ((if accepted.admission.filePolicy == Just transferableFilePolicy then workspaceTransferredProcessAction else workspaceProcessAction) accepted.binding accepted.admission accepted.dispatch record boot target)
  runtime.authorizer.authorize principal action >>= either (const (abort SupervisorRefused)) (const (pure ()))
  current runtime accepted (Just record)

observe :: SupervisorRuntime -> WorkspaceBinding -> ProcessRecord -> IO ProcessRecord
observe runtime binding record = do
  let directory = processDirectory binding record
  case record.phase of
    ProcessReserved -> pure record
    ProcessRefused -> pure record
    ProcessSettled -> pure record
    _ -> do
      stopControlled runtime binding record directory
      receipt <- reconcileCollector runtime.appEnv directory record
      case receipt of
        Left _ -> do
          _ <- transact runtime (Processes.markProcessUnresolvedTx record)
          pure ()
        Right Nothing -> do
          failed <- collectorFailed directory
          alive <- runtime.backend.collectorActive record
          unless (failed == Right False && alive == Right True) do
            _ <- transact runtime (Processes.markProcessUnresolvedTx record)
            pure ()
        Right (Just _) -> pure ()
      readProcess runtime record.operationId >>= maybe (abort SupervisorUnavailable) pure

-- Retained root control and the original cutoff govern already admitted work.
-- Failure to read current control never invents a stop decision or prevents
-- factual receipt recovery. The private cancellation marker precedes the stop
-- request; neither is a receipt or permission to reuse this workspace.
stopControlled :: SupervisorRuntime -> WorkspaceBinding -> ProcessRecord -> FilePath -> IO ()
stopControlled runtime binding record directory = do
  now <- getCurrentTime
  root <- runAppIO runtime.appEnv (Roots.inspectRoot binding.request.rootId)
  control <- runAppIO runtime.appEnv (runTransaction (Workspaces.inspectWorkspaceControlTx binding))
  let controlled =
        either (const False) (either (const False) (maybe False (.frozen))) control || now >= record.deadline || case root of
          Right (Right currentRoot) -> isLeft (Resources.checkRoot now currentRoot.revision currentRoot)
          _ -> False
  when controlled do
    needFile =<< checkPrivateDirectory directory
    marker <- withContainedFile directory "cancel" \file -> do
      old <- readContainedFile 16 file
      case old of
        Left err -> pure (Left err)
        Right Nothing -> replaceContainedFile directory file Nothing "1\n"
        Right (Just bytes) | bytes == "1\n" -> pure (Right ())
        _ -> pure (Left FilePathRefused)
    needFile marker
    requested <- runtime.backend.stop record
    when (isLeft requested) (void (transact runtime (Processes.markProcessUnresolvedTx record)))
  where
    isLeft (Left _) = True
    isLeft _ = False

-- One deterministic result encoding is shared by the live adapter and the
-- factual late-receipt publisher. Command arguments and output bodies are absent.
processToolResult :: ProcessRecord -> Maybe (Either ToolError ToolOutput)
processToolResult record = case (record.phase, record.receipt) of
  (ProcessSettled, Just receipt) | validProcessReceipt record receipt -> Just (renderProcessResult (Just receipt))
  (ProcessRefused, Nothing) -> Just (renderProcessResult Nothing)
  _ -> Nothing

-- Rendering only: callers must first validate the retained completion or
-- pre-launch refusal. Keep live and independent acknowledgement bytes equal.
renderProcessResult :: Maybe ProcessReceipt -> Either ToolError ToolOutput
renderProcessResult Nothing = Left (ToolRunFailed "validate" "workspace validation refused")
renderProcessResult (Just receipt) = Right (textToolOutput (Encoding.decodeUtf8 (Lazy.toStrict (Aeson.encode receipt))))

data ProcessPublication = AwaitingProcessReceipt | AwaitingExecutionExpiry | ProcessReceiptAcknowledged
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- This path consumes already accepted provider facts only. It creates no
-- actual attempt, replay-read grant, command or authority to continue model IO.
publishProcessReceipt :: SupervisorRuntime -> OperationId -> IO (Either SupervisorError ProcessPublication)
publishProcessReceipt runtime operationId = protect do
  (binding, initial) <- readRegisteredProcess runtime operationId >>= maybe (abort SupervisorRefused) pure
  record <-
    if initial.phase `elem` [ProcessSettled, ProcessRefused]
      then pure initial
      else reconcileProcess runtime operationId >>= either abort pure
  case processToolResult record of
    Nothing -> pure AwaitingProcessReceipt
    Just result -> do
      routing <- maybe (abort SupervisorUnresolved) pure record.routing
      unless (validProcessRouting routing && record.bindingDigest == workspaceBindingDigest binding) (abort SupervisorUnresolved)
      metadata <- execute runtime (Execution.inspectExecution routing.executionId) >>= maybe (abort SupervisorUnresolved) pure
      let (state, retained, _) = metadata
      operation <- execute runtime (Execution.inspectOperation operationId) >>= maybe (abort SupervisorUnresolved) pure
      let key = operationIdText operationId
          context = OperationContext routing.executionId operationId key operation.fingerprint operation.specification.scopeDigest
      unless (routing.identity == retained.identity && retained.rootId == Just binding.request.rootId && operation.executionId == routing.executionId && operation.specification.kind == ToolOperation && operation.specification.name == workspaceExecBinding.name && operation.specification.scopeDigest `elem` map toolScopeDigest [workspaceExecBinding, transferredWorkspaceExecBinding] && operation.specification.recovery == UncertainEffect && operation.input.digest == routing.inputDigest && record.fingerprint == processFingerprint binding record.instructionDigest context record.command) (abort SupervisorUnresolved)
      actual <- execute runtime (Execution.inspectExecutionAttempt record.attemptId) >>= maybe (abort SupervisorUnresolved) pure
      unless (actual.executionId == routing.executionId && actual.operationId == operationId && actual.owner == Just record.claimOwner && actual.generation == record.generation && isNothing actual.call) (abort SupervisorUnresolved)
      let reference = Attempt.JobReference 1 routing.executionId operationId record.attemptId
          claim = Attempt.AttemptClaim reference record.claimOwner record.generation
          outcome = either (\err -> ToolReturned [TextBlock (renderToolError err)] True) (RichToolReturned . captureToolOutput) result
          receipt = Attempt.AttemptResult outcome routing.next Nothing
          acknowledged = execute runtime (Execution.publishExecutionWake reference) >> pure ProcessReceiptAcknowledged
      case actual.phase of
        Attempt.DispatchStarted -> do
          now <- getCurrentTime
          if maybe False (now >=) actual.expiresAt
            then do
              _ <- execute runtime (Execution.markExpiredExecutionAttemptUncertain routing.identity state.revision reference)
              publishProcessReceipt runtime operationId >>= either abort pure
            else pure AwaitingExecutionExpiry
        Attempt.AttemptUncertain -> do
          _ <- execute runtime (Execution.recordIndependentToolReceipt routing.identity state.revision claim receipt)
          (changed, _, _) <- execute runtime (Execution.inspectExecution routing.executionId) >>= maybe (abort SupervisorUnresolved) pure
          _ <- execute runtime (Execution.reconcileExecutionControlAttempt routing.identity routing.executionId changed.revision record.attemptId)
          acknowledged
        Attempt.AttemptSuperseded -> do
          _ <- execute runtime (Execution.recordIndependentToolReceipt routing.identity state.revision claim receipt)
          acknowledged
        Attempt.AttemptCommitted -> do
          _ <- execute runtime (Execution.recordIndependentToolReceipt routing.identity state.revision claim receipt)
          acknowledged
        _ -> abort SupervisorUnresolved

processDirectory :: WorkspaceBinding -> ProcessRecord -> FilePath
processDirectory binding record = workspaceMetadata binding.storageRoot binding </> Text.unpack ("process-" <> Text.drop 7 (versionedDigest "shikigami.workspace-process-directory/1" (toJSON (record.operationId, record.fingerprint))))

waitReady :: FilePath -> Int -> IO ()
waitReady directory remaining = do
  ready <- withContainedFile directory "ready" (readContainedFile 2)
  case ready of
    Right (Just "1\n") -> pure ()
    Right Nothing | remaining > 0 -> threadDelay 50000 >> waitReady directory (remaining - 1)
    _ -> abort SupervisorUnresolved

validRequest :: SupervisorRequest -> Bool
validRequest request = bounded request.executionId.value && bounded operation && bounded attempt && request.generation > initialRevision && revisionNumber request.generation < 9223372036854775808
  where
    operation = operationIdText request.operationId; attempt = attemptIdText request.attemptId

execute :: SupervisorRuntime -> Eff AppEffects (Either ExecutionError a) -> IO a
execute runtime action = do
  result <- runAppIO runtime.appEnv action
  case result of
    Right (Right value) -> pure value
    Right (Left err) | err `elem` [ExecutionStorageUnavailable, ProjectionUnavailable] -> abort SupervisorUnavailable
    Right (Left _) -> abort SupervisorRefused
    Left _ -> abort SupervisorUnavailable

-- Invalid retained facts cannot authorize a replacement launch or a receipt.
readProcess :: SupervisorRuntime -> OperationId -> IO (Maybe ProcessRecord)
readProcess runtime operation = transact runtime (Processes.inspectProcessTx operation) >>= either (const (abort SupervisorUnresolved)) pure

readRegisteredProcess :: SupervisorRuntime -> OperationId -> IO (Maybe (WorkspaceBinding, ProcessRecord))
readRegisteredProcess runtime operation = transact runtime (Processes.inspectRegisteredProcessTx operation) >>= either (const (abort SupervisorUnresolved)) pure

transact :: SupervisorRuntime -> Transaction a -> IO a
transact runtime action = runAppIO runtime.appEnv (runTransaction action) >>= either (const (abort SupervisorUnavailable)) pure

needFile :: Either FileError a -> IO a
needFile = either (const (abort SupervisorUnavailable)) pure

backendError :: Systemd.SystemdError -> SupervisorError
backendError Systemd.SystemdUnsupported = SupervisorUnsupported
backendError Systemd.SystemdRefused = SupervisorRefused
backendError Systemd.SystemdUncertain = SupervisorUnresolved

abort :: SupervisorError -> IO a
abort = throwIO . SupervisorAbort

protect :: IO a -> IO (Either SupervisorError a)
protect work = catch (catch (Right <$> work) (\(SupervisorAbort err) -> pure (Left err))) (\(_ :: IOException) -> pure (Left SupervisorUnavailable))

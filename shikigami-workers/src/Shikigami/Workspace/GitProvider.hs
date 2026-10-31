-- | Exact accepted Git tools. Model arguments never select a host path, Git
-- executable, environment, branch or helper. Commit recovery only observes the
-- retained original result after publication admission has been consumed.
module Shikigami.Workspace.GitProvider
  ( GitBackend (..),
    nativeGitBackend,
    workspaceGitDescriptor,
    transferredWorkspaceGitDescriptor,
    transferredGitBinding,
    transferredWorkspaceGitAdapter,
    transferredWorkspaceGitAdapterWithBackend,
    gitSchema,
    gitBinding,
    workspaceGitAdapter,
    workspaceGitAdapterWithBackend,
    runGitTool,
    reconcileGitEffect,
    workspaceIntegrationDescriptor,
    workspaceIntegrationAdapter,
    workspaceIntegrationAdapterWithBackend,
    integrationBinding,
    GitPublication (..),
    publishGitReceipt,
  )
where

import Control.Exception (Exception, IOException, catch, throwIO)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Effectful (Eff)
import Effectful.Dispatch.Static (unsafeEff_)
import Hasql.Transaction (Transaction)
import Kikan.En.Action (AgentAction)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (ActionAuthorizer (..))
import Shikigami.Agent.Principal (identityText)
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Capability.Overlay
import Shikigami.Capability.Provider (DurableAdapter (..), DurableToolContract (..))
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Identity
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Runner (DispatchContext (..), OperationContext (..))
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.ToolPosition
import Shikigami.Execution.Transcript
import Shikigami.Prelude hiding ((.=))
import Shikigami.Workspace.Allocation (workspaceFiles, workspaceMetadata)
import Shikigami.Workspace.ContainedFile
import Shikigami.Workspace.FileProvider (FileRuntime (..))
import Shikigami.Workspace.GitCapture
import Shikigami.Workspace.GitObjects qualified as Objects
import Shikigami.Workspace.GitStore qualified as Git
import Shikigami.Workspace.GitTypes
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Integration qualified as Integration
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.Profile (retainedFileProfile)
import Shikigami.Workspace.Provider
import Shikigami.Workspace.Store qualified as Workspaces
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.TransferStore qualified as Transfers
import Shikigami.Workspace.Types
import Shikumi.Tool (ToolError (..), mkDynTool, renderToolError)
import Shikumi.Tool.Output (ToolOutput, textToolOutput)

data GitBackend = GitBackend
  { host :: !(IO (Either Systemd.SystemdError Text)),
    capture :: !(WorkspaceBinding -> ProcessProfile -> Text -> (Text -> IO (Either WorkspaceError ())) -> IO (Either WorkspaceError CapturedTree)),
    afterPublication :: !(IO ())
  }
  deriving stock (Generic)

nativeGitBackend :: GitBackend
nativeGitBackend = GitBackend Systemd.systemdBootIdentity captureGitTree (pure ())

data AcceptedGit = AcceptedGit
  { snapshot :: !ExecutionSnapshot,
    access :: !Execution.ReplayAccess,
    binding :: !WorkspaceBinding,
    admission :: !WorkspaceAdmission,
    dispatch :: !DispatchContext,
    routing :: !GitRouting
  }

newtype GitAbort = GitAbort FileEffectError deriving stock (Show)

instance Exception GitAbort

workspaceGitDescriptor :: CapabilityDescriptor
workspaceGitDescriptor = gitDescriptorFor False

transferredWorkspaceGitDescriptor :: CapabilityDescriptor
transferredWorkspaceGitDescriptor = gitDescriptorFor True

gitDescriptorFor :: Bool -> CapabilityDescriptor
gitDescriptorFor transferable = CapabilityDescriptor (must (mkCapabilityId "workspace.git")) (must (mkCapabilityRevision (if transferable then "2" else "1"))) [CapabilityToolDescriptor "status" Observation, CapabilityToolDescriptor "diff" Observation, CapabilityToolDescriptor "commit" IdempotentMutation]
  where
    must :: (Show e) => Either e a -> a; must = either (error . show) id

gitSchema :: Text -> Aeson.Value
gitSchema "commit" = Aeson.object ["type" .= ("object" :: Text), "properties" .= Aeson.object ["expectedParent" .= Aeson.object ["type" .= ("string" :: Text), "pattern" .= ("^[a-f0-9]{40}([a-f0-9]{24})?$" :: Text)], "message" .= Aeson.object ["type" .= ("string" :: Text), "maxLength" .= (4096 :: Int)]], "required" .= ["expectedParent", "message" :: Text], "additionalProperties" .= False]
gitSchema _ = Aeson.object ["type" .= ("object" :: Text), "properties" .= Aeson.object [], "additionalProperties" .= False]

gitBinding :: Text -> ToolBinding
gitBinding = gitBindingFor False

transferredGitBinding :: Text -> ToolBinding
transferredGitBinding = gitBindingFor True

gitBindingFor :: Bool -> Text -> ToolBinding
gitBindingFor transferable name = ToolBinding ("overlay__workspace-git__" <> name) (if transferable then "workspace.git:2" else "workspace.git:1") (versionedDigest "shikigami.tool-schema/1" (gitSchema name)) (if name == "commit" then IdempotentEffect else RepeatableObservation) NoInvoiceCost

gitDescription :: Text -> Text
gitDescription "status" = "Inspect the isolated local repository's exact HEAD, captured tree and changed paths."
gitDescription "diff" = "Read a bounded local diff from HEAD to the admitted workspace; external helpers are disabled."
gitDescription _ = "Commit the isolated workspace against an expected exact parent, without hooks or helpers; retain the exact result across retries."

workspaceGitAdapter :: FileRuntime -> DurableAdapter
workspaceGitAdapter = workspaceGitAdapterWithBackend nativeGitBackend

workspaceGitAdapterWithBackend :: GitBackend -> FileRuntime -> DurableAdapter
workspaceGitAdapterWithBackend = gitAdapterFor False

transferredWorkspaceGitAdapter :: FileRuntime -> DurableAdapter
transferredWorkspaceGitAdapter = transferredWorkspaceGitAdapterWithBackend nativeGitBackend

transferredWorkspaceGitAdapterWithBackend :: GitBackend -> FileRuntime -> DurableAdapter
transferredWorkspaceGitAdapterWithBackend = gitAdapterFor True

gitAdapterFor :: Bool -> GitBackend -> FileRuntime -> DurableAdapter
gitAdapterFor transferable backend runtime =
  DurableAdapter
    (gitDescriptorFor transferable)
    [DurableToolContract name (gitDescription name) (gitSchema name) (gitBindingFor transferable name).recovery NoInvoiceCost | name <- ["status", "diff", "commit"]]
    ( \snapshot dispatch name ->
        pure
          ( Right
              ( mkDynTool
                  name
                  (gitDescription name)
                  (gitSchema name)
                  ( \input -> unsafeEff_ do
                      result <- runGitToolFor transferable backend runtime snapshot dispatch name input
                      case result of
                        Left FileEffectUnresolved -> throwIO (userError "workspace Git effect requires reconciliation")
                        Left FileEffectUnavailable -> throwIO (userError "workspace Git evidence is unavailable")
                        _ -> pure (either (const (Left (ToolRunFailed name "workspace operation refused"))) (Right . textToolOutput . Encoding.decodeUtf8 . Lazy.toStrict . Aeson.encode) result)
                  )
              )
          )
    )

runGitTool :: GitBackend -> FileRuntime -> ExecutionSnapshot -> DispatchContext -> Text -> Aeson.Value -> IO (Either FileEffectError Aeson.Value)
runGitTool = runGitToolFor False

runGitToolFor :: Bool -> GitBackend -> FileRuntime -> ExecutionSnapshot -> DispatchContext -> Text -> Aeson.Value -> IO (Either FileEffectError Aeson.Value)
runGitToolFor transferable backend runtime snapshot dispatch name input = protect do
  unless (name `elem` ["status", "diff", "commit"]) (abort FileEffectRefused)
  requested <- if name == "commit" then Just <$> parseCommit input else emptyInput input >> pure Nothing
  accepted <- loadAccepted transferable runtime snapshot dispatch name input
  _ <- backend.host >>= either (const (abort FileEffectRefused)) pure
  let binding = accepted.binding; metadata = workspaceMetadata binding.storageRoot binding
  needFile =<< checkPrivateDirectory binding.storageRoot
  needFile =<< checkPrivateDirectory metadata
  locked <-
    withWorkspaceLock metadata $
      Right <$> do
        current runtime accepted
        profile <- retainedFileProfile runtime.appEnv binding accepted.admission >>= either (const (abort FileEffectRefused)) pure
        anchored <- withContainedFile (workspaceFiles binding.storageRoot binding) ".shikigami-git-target" \target ->
          Right <$> do
            identity <- containedTargetIdentity target >>= either (const (abort FileEffectRefused)) pure
            case requested of
              Just request -> commit backend runtime accepted profile identity request
              Nothing -> observe backend runtime accepted profile identity name
        either (const (abort FileEffectUnresolved)) pure anchored
  either (const (abort FileEffectUnresolved)) pure locked

parseCommit :: Aeson.Value -> IO GitCommitRequest
parseCommit value = do
  request <- either (const (abort FileEffectRefused)) pure (parseEither Aeson.parseJSON value)
  unless (validGitObject request.expectedParent && not (Text.null (Text.strip request.message)) && Bytes.length (Encoding.encodeUtf8 request.message) <= 4096 && not (Text.any (== '\0') request.message)) (abort FileEffectRefused)
  pure request

emptyInput :: Aeson.Value -> IO ()
emptyInput (Aeson.Object fields) | null fields = pure ()
emptyInput _ = abort FileEffectRefused

loadAccepted :: Bool -> FileRuntime -> ExecutionSnapshot -> DispatchContext -> Text -> Aeson.Value -> IO AcceptedGit
loadAccepted transferable runtime snapshot dispatch name input = loadAcceptedTool transferable (gitDescriptorFor transferable) (gitBindingFor transferable name) runtime snapshot dispatch input

loadAcceptedTool :: Bool -> CapabilityDescriptor -> ToolBinding -> FileRuntime -> ExecutionSnapshot -> DispatchContext -> Aeson.Value -> IO AcceptedGit
loadAcceptedTool transferable descriptor expected runtime snapshot dispatch input = do
  access <- execute runtime.appEnv (Execution.authorizeReplay snapshot.executionId snapshot.identity (runtime.replayAuthority snapshot))
  (retained, _) <- execute runtime.appEnv (Execution.loadExecution access)
  operation <- execute runtime.appEnv (Execution.inspectOperation dispatch.operation.operationId) >>= maybe (abort FileEffectRefused) pure
  admission <- maybe (abort FileEffectRefused) pure snapshot.workspace
  let key = operationIdText dispatch.operation.operationId
  unless (retained == snapshot && admission.filePolicy == Just (if transferable then transferableFilePolicy else supervisedFilePolicy) && descriptor `elem` resolvedCapabilities snapshot.capabilities && dispatch.operation == OperationContext snapshot.executionId dispatch.operation.operationId key operation.fingerprint operation.specification.scopeDigest && operation.executionId == snapshot.executionId && operation.specification.kind == ToolOperation && operation.specification.name == expected.name && operation.specification.recovery == expected.recovery && operation.specification.scopeDigest == toolScopeDigest expected && operation.specification.policyDigest == versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy)) (abort FileEffectRefused)
  tool <- execute runtime.appEnv (Execution.readReplayPayload @ToolOperationInput access "operation-input" operation.input)
  unless (tool.binding == expected && expected `elem` snapshot.toolBindings && tool.invocation.name == expected.name && tool.invocation.arguments == input && operation.specification.responsePosition == Just tool.position) (abort FileEffectRefused)
  response <- execute runtime.appEnv (Execution.readReplayPayload @OperationOutcome access "operation-outcome" tool.response)
  assistant <- case response of ModelReturned value _ -> pure value; _ -> abort FileEffectRefused
  unless (take 1 (drop (toolPositionNumber tool.position) (toolInvocations assistant)) == [tool.invocation]) (abort FileEffectRefused)
  (binding, state) <- transact runtime.appEnv (Workspaces.inspectWorkspaceTx admission.workspace) >>= maybe (abort FileEffectRefused) pure
  unless (state == Ready && matchesWorkspaceAdmission binding admission && admission.runId == snapshot.runId && admission.assignmentId == snapshot.selection.assignmentId && Just admission.rootId == snapshot.selection.rootId && admission.rootId == binding.request.rootId && admission.owner == snapshot.identity && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base) (abort FileEffectRefused)
  let next = toolContinuation tool assistant
  pure (AcceptedGit snapshot access binding admission dispatch (GitRouting snapshot.executionId snapshot.identity operation.input.digest next))

current :: FileRuntime -> AcceptedGit -> IO ()
current runtime accepted = do
  runtime.lifecycle accepted.snapshot >>= either (const (abort FileEffectRefused)) pure
  let dispatch = accepted.dispatch
      claim = Attempt.AttemptClaim (Attempt.JobReference 1 accepted.snapshot.executionId dispatch.operation.operationId dispatch.attemptId) dispatch.owner dispatch.generation
  execute runtime.appEnv (Execution.checkStartedExecutionAttempt accepted.access claim)
  transact runtime.appEnv (if accepted.admission.filePolicy == Just transferableFilePolicy then Transfers.checkWorkspaceAdmissionTx accepted.binding accepted.admission dispatch.operation.operationId else Workspaces.checkWorkspaceOperationTx accepted.binding accepted.admission.owner accepted.admission.epoch dispatch.operation.operationId) >>= either (const (abort FileEffectRefused)) pure

admitPath :: FileRuntime -> AcceptedGit -> ProcessProfile -> Text -> Text -> IO ()
admitPath runtime accepted profile kind path = do
  unless (processFileAllowed profile.policy kind path) (abort FileEffectRefused)
  instructions <- either (const (abort FileEffectRefused)) pure (instructionsForPath accepted.admission.instructions path)
  runtime.admitTarget accepted.binding accepted.admission instructions kind path >>= either (const (abort FileEffectRefused)) pure

capture :: GitBackend -> FileRuntime -> AcceptedGit -> ProcessProfile -> Text -> IO CapturedTree
capture backend runtime accepted profile target = do
  let allowed path = (protect (admitPath runtime accepted profile "read" path)) <&> either (const (Left WorkspaceAllocationRefused)) Right
  backend.capture accepted.binding profile target allowed >>= either (const (abort FileEffectRefused)) pure

grant :: FileRuntime -> AcceptedGit -> Either FileEffectError AgentAction -> IO ()
grant runtime accepted action = do
  principal <- either (const (abort FileEffectRefused)) pure (identityText accepted.admission.owner)
  selected <- either abort pure action
  runtime.authorizer.authorize principal selected >>= either (const (abort FileEffectRefused)) (const (current runtime accepted))

observe :: GitBackend -> FileRuntime -> AcceptedGit -> ProcessProfile -> Text -> Text -> IO Aeson.Value
observe backend runtime accepted profile target name = do
  grant runtime accepted ((if accepted.admission.filePolicy == Just transferableFilePolicy then workspaceTransferredGitObservationAction else workspaceGitObservationAction) accepted.binding accepted.admission accepted.dispatch profile name accepted.routing.inputDigest target)
  headId <- Objects.readHead metadata >>= either (const (abort FileEffectRefused)) pure
  captured <- capture backend runtime accepted profile target
  paths <- Objects.changedPaths metadata headId captured.tree >>= either (const (abort FileEffectTooLarge)) pure
  mapM_ (admitPath runtime accepted profile "read") paths
  current runtime accepted
  let common = ["repository" .= accepted.binding.repository, "base" .= accepted.binding.base, "head" .= headId, "tree" .= captured.tree, "paths" .= paths, "instructionDigest" .= bundleDigest accepted.admission.instructions]
  value <-
    if name == "status"
      then pure (Aeson.object common)
      else do
        bytes <- Objects.objectDiff metadata headId captured.tree >>= either (const (abort FileEffectTooLarge)) pure
        patch <- either (const (abort FileEffectRefused)) pure (Encoding.decodeUtf8' bytes)
        pure (Aeson.object (common <> ["patch" .= patch]))
  bounded value
  where
    metadata = workspaceMetadata accepted.binding.storageRoot accepted.binding

commit :: GitBackend -> FileRuntime -> AcceptedGit -> ProcessProfile -> Text -> GitCommitRequest -> IO Aeson.Value
commit backend runtime accepted profile target request = do
  now <- getCurrentTime
  let binding = accepted.binding
      dispatch = accepted.dispatch
      raw = GitRecord GitRecordV1 dispatch.operation dispatch.attemptId dispatch.owner dispatch.generation (workspaceBindingDigest binding) (bundleDigest accepted.admission.instructions) (gitProfileDigest profile) target request.expectedParent "" now accepted.routing GitReserved Nothing
      proposed = raw & #fingerprint .~ gitFingerprint binding raw
  existing <- readGit runtime.appEnv dispatch.operation.operationId
  case existing of
    Just old -> do
      unless (samePlanInput old proposed) (abort FileEffectUnresolved)
      reconciled <- reconcileLocked runtime.appEnv binding old
      resultValue binding reconciled
    Nothing -> do
      original <- transact runtime.appEnv ((if accepted.admission.filePolicy == Just transferableFilePolicy then Git.reserveAdmittedGitTx binding accepted.admission else Git.reserveGitTx binding) proposed) >>= either (const (abort FileEffectRefused)) pure
      unless (original == proposed) (abort FileEffectUnresolved)
      attempted <- protect do
        grant runtime accepted ((if accepted.admission.filePolicy == Just transferableFilePolicy then workspaceTransferredGitAction else workspaceGitAction) binding accepted.admission dispatch profile original)
        headId <- Objects.readHead metadata >>= either (const (abort FileEffectRefused)) pure
        unless (headId == request.expectedParent) (abort FileEffectConflict)
        captured <- capture backend runtime accepted profile target
        paths <- Objects.changedPaths metadata headId captured.tree >>= either (const (abort FileEffectTooLarge)) pure
        unless (not (null paths)) (abort FileEffectRefused)
        mapM_ (admitPath runtime accepted profile "replace") paths
        current runtime accepted
        object <- Objects.storeCommit metadata headId captured.tree (Objects.GitAuthor "Shikigami Agent" "shikigami@example.invalid") original.createdAt original.operation.operationId request.message >>= either (const (abort FileEffectUnresolved)) pure
        let candidate = GitCandidate headId captured.tree object paths
        unless (validGitCandidate candidate) (abort FileEffectTooLarge)
        prepared <- transact runtime.appEnv ((if accepted.admission.filePolicy == Just transferableFilePolicy then Git.prepareAdmittedGitTx binding accepted.admission else Git.prepareGitTx binding) original candidate) >>= either (const (abort FileEffectUnresolved)) pure
        _ <- bounded (gitEvidence binding prepared)
        writePrivate metadata prepared
        grant runtime accepted ((if accepted.admission.filePolicy == Just transferableFilePolicy then workspaceTransferredGitAction else workspaceGitAction) binding accepted.admission dispatch profile prepared)
        permitted <- transact runtime.appEnv ((if accepted.admission.filePolicy == Just transferableFilePolicy then Git.requestAdmittedGitPublicationTx binding accepted.admission else Git.requestGitPublicationTx binding) prepared) >>= either (const (abort FileEffectUnresolved)) pure
        unless permitted (abort FileEffectUnresolved)
        current runtime accepted
        Objects.publishCommit metadata candidate.parent candidate.result >>= either (const (abort FileEffectUnresolved)) pure
        backend.afterPublication
        Just requested <- readGit runtime.appEnv original.operation.operationId
        reconcileLocked runtime.appEnv binding requested
      case attempted of
        Right record -> resultValue binding record
        Left err -> do
          Just retained <- readGit runtime.appEnv original.operation.operationId
          if retained.phase `elem` [GitReserved, GitPrepared]
            then do
              _ <- transact runtime.appEnv (Git.refuseGitBeforePublicationTx retained) >>= either (const (abort FileEffectUnresolved)) pure
              abort err
            else abort FileEffectUnresolved
  where
    metadata = workspaceMetadata accepted.binding.storageRoot accepted.binding

samePlanInput :: GitRecord -> GitRecord -> Bool
samePlanInput a b = a.operation == b.operation && a.fingerprint == b.fingerprint && a.bindingDigest == b.bindingDigest && a.instructionDigest == b.instructionDigest && a.profileDigest == b.profileDigest && a.target == b.target && a.expectedParent == b.expectedParent && a.routing == b.routing

resultValue :: WorkspaceBinding -> GitRecord -> IO Aeson.Value
resultValue binding record = case record.phase of
  GitApplied -> bounded (gitEvidence binding record)
  GitRefused -> abort FileEffectRefused
  _ -> abort FileEffectUnresolved

gitEvidence :: WorkspaceBinding -> GitRecord -> Aeson.Value
gitEvidence binding record = Aeson.object ["repository" .= binding.repository, "base" .= binding.base, "bindingDigest" .= record.bindingDigest, "instructionDigest" .= record.instructionDigest, "operationId" .= record.operation.operationId, "attemptId" .= record.attemptId, "generation" .= record.generation, "commit" .= record.candidate]

bounded :: Aeson.Value -> IO Aeson.Value
bounded value = if Lazy.length (Aeson.encode value) <= 32768 then pure value else abort FileEffectTooLarge

reconcileGitEffect :: AppEnv -> OperationId -> IO (Either FileEffectError GitRecord)
reconcileGitEffect env operation = protect do
  (binding, record) <- readRegisteredGit env operation >>= maybe (abort FileEffectUnresolved) pure
  if record.phase `elem` [GitApplied, GitRefused]
    then validateRecord binding record >> pure record
    else do
      let metadata = workspaceMetadata binding.storageRoot binding
      needFile =<< checkPrivateDirectory binding.storageRoot
      needFile =<< checkPrivateDirectory metadata
      locked <- withWorkspaceLock metadata (Right <$> reconcileLocked env binding record)
      either (const (abort FileEffectUnresolved)) pure locked

reconcileLocked :: AppEnv -> WorkspaceBinding -> GitRecord -> IO GitRecord
reconcileLocked env binding original = do
  record <- readGit env original.operation.operationId >>= maybe (abort FileEffectUnresolved) pure
  validateRecord binding record
  if record.phase `elem` [GitApplied, GitRefused]
    then pure record
    else do
      saved <- readPrivate metadata record
      forM_ saved \previous -> unless (previous.phase `elem` [GitPrepared, GitApplied] && (previous & #phase .~ record.phase) == record) (abort FileEffectUnresolved)
      case record.phase of
        GitReserved -> refuse record saved
        GitPrepared -> refuse record saved
        _ -> do
          let already = maybe False ((== GitApplied) . (.phase)) saved
          candidate <- maybe (abort FileEffectUnresolved) pure record.candidate
          published <- if already then pure True else Objects.verifyPublishedCommit metadata candidate >>= either (const (abort FileEffectUnresolved)) pure
          if published
            then do
              writePrivate metadata (record & #phase .~ GitApplied)
              transact env (Git.recordGitAppliedTx record) >>= either (const (abort FileEffectUnresolved)) pure
            else transact env (Git.markGitUnresolvedTx record) >>= either (const (abort FileEffectUnresolved)) pure
  where
    metadata = workspaceMetadata binding.storageRoot binding
    refuse record saved = do
      when (maybe False ((== GitApplied) . (.phase)) saved) (abort FileEffectUnresolved)
      transact env (Git.refuseGitBeforePublicationTx record) >>= either (const (abort FileEffectUnresolved)) pure

validateRecord :: WorkspaceBinding -> GitRecord -> IO ()
validateRecord binding record = unless (validGitRecord record && record.bindingDigest == workspaceBindingDigest binding && record.fingerprint == gitFingerprint binding record) (abort FileEffectUnresolved)

privateName :: GitRecord -> Text
privateName record = "git-receipt-" <> Text.drop 7 (versionedDigest "shikigami.workspace-git-receipt/1" (toJSON record.operation.operationId)) <> ".json"

readPrivate :: FilePath -> GitRecord -> IO (Maybe GitRecord)
readPrivate metadata record = do
  result <- withContainedFile metadata (privateName record) (readContainedFile 65536)
  bytes <- either (const (abort FileEffectUnresolved)) pure result
  traverse (either (const (abort FileEffectUnresolved)) pure . Aeson.eitherDecodeStrict) bytes

writePrivate :: FilePath -> GitRecord -> IO ()
writePrivate metadata record = do
  result <- withContainedFile metadata (privateName record) \file -> do
    existing <- readContainedFile 65536 file
    case existing of Left err -> pure (Left err); Right before -> replaceContainedFile metadata file before (Lazy.toStrict (Aeson.encode record))
  either (const (abort FileEffectUnresolved)) pure result

data GitPublication = AwaitingGitReceipt | AwaitingGitExecutionExpiry | GitReceiptAcknowledged deriving stock (Eq, Show)

publishGitReceipt :: AppEnv -> OperationId -> IO (Either FileEffectError GitPublication)
publishGitReceipt env operationId = protect do
  (binding, _) <- readRegisteredGit env operationId >>= maybe (abort FileEffectUnresolved) pure
  record <- reconcileGitEffect env operationId >>= either abort pure
  case gitToolResult binding record of
    Nothing -> pure AwaitingGitReceipt
    Just result -> do
      let routing = record.routing
      (state, retained, _) <- execute env (Execution.inspectExecution routing.executionId) >>= maybe (abort FileEffectUnresolved) pure
      operation <- execute env (Execution.inspectOperation operationId) >>= maybe (abort FileEffectUnresolved) pure
      expected <- case filter (\tool -> operation.specification.scopeDigest == toolScopeDigest tool) [gitBinding "commit", transferredGitBinding "commit"] of
        [tool] -> pure tool
        _ -> abort FileEffectUnresolved
      let key = operationIdText operationId
      unless (routing.identity == retained.identity && retained.rootId == Just binding.request.rootId && record.operation == OperationContext routing.executionId operationId key operation.fingerprint operation.specification.scopeDigest && operation.executionId == routing.executionId && operation.specification.kind == ToolOperation && operation.specification.name == expected.name && operation.specification.recovery == expected.recovery && operation.specification.scopeDigest == toolScopeDigest expected && operation.input.digest == routing.inputDigest) (abort FileEffectUnresolved)
      actual <- execute env (Execution.inspectExecutionAttempt record.attemptId) >>= maybe (abort FileEffectUnresolved) pure
      unless (actual.executionId == routing.executionId && actual.operationId == operationId && actual.owner == Just record.claimOwner && actual.generation == record.generation && isNothing actual.call) (abort FileEffectUnresolved)
      let reference = Attempt.JobReference 1 routing.executionId operationId record.attemptId
          claim = Attempt.AttemptClaim reference record.claimOwner record.generation
          outcome = either (\err -> ToolReturned [TextBlock (renderToolError err)] True) (RichToolReturned . captureToolOutput) result
          receipt = Attempt.AttemptResult outcome routing.next Nothing
          acknowledge = execute env (Execution.publishExecutionWake reference) >> pure GitReceiptAcknowledged
      case actual.phase of
        Attempt.DispatchStarted -> do
          now <- getCurrentTime
          if maybe False (now >=) actual.expiresAt
            then do
              _ <- execute env (Execution.markExpiredExecutionAttemptUncertain routing.identity state.revision reference)
              publishGitReceipt env operationId >>= either abort pure
            else pure AwaitingGitExecutionExpiry
        Attempt.AttemptUncertain -> do
          _ <- execute env (Execution.recordIndependentToolReceipt routing.identity state.revision claim receipt)
          (changed, _, _) <- execute env (Execution.inspectExecution routing.executionId) >>= maybe (abort FileEffectUnresolved) pure
          _ <- execute env (Execution.reconcileExecutionControlAttempt routing.identity routing.executionId changed.revision record.attemptId)
          acknowledge
        Attempt.AttemptSuperseded -> execute env (Execution.recordIndependentToolReceipt routing.identity state.revision claim receipt) >> acknowledge
        Attempt.AttemptCommitted -> execute env (Execution.recordIndependentToolReceipt routing.identity state.revision claim receipt) >> acknowledge
        _ -> abort FileEffectUnresolved

gitToolResult :: WorkspaceBinding -> GitRecord -> Maybe (Either ToolError ToolOutput)
gitToolResult binding record = case record.phase of
  GitApplied -> Just (Right (textToolOutput (Encoding.decodeUtf8 (Lazy.toStrict (Aeson.encode (gitEvidence binding record))))))
  GitRefused -> Just (Left (ToolRunFailed "commit" "workspace operation refused"))
  _ -> Nothing

execute :: AppEnv -> Eff AppEffects (Either ExecutionError a) -> IO a
execute env action = runAppIO env action >>= either (const (abort FileEffectUnavailable)) (either (const (abort FileEffectRefused)) pure)

-- A malformed retained intent cannot authorize a replacement or a receipt.
-- Storage failures keep transact's availability path; data refuses unresolved.
readGit :: AppEnv -> OperationId -> IO (Maybe GitRecord)
readGit env operation = transact env (Git.inspectGitTx operation) >>= either (const (abort FileEffectUnresolved)) pure

readRegisteredGit :: AppEnv -> OperationId -> IO (Maybe (WorkspaceBinding, GitRecord))
readRegisteredGit env operation = transact env (Git.inspectRegisteredGitTx operation) >>= either (const (abort FileEffectUnresolved)) pure

transact :: AppEnv -> Transaction a -> IO a
transact env action = runAppIO env (runTransaction action) >>= either (const (abort FileEffectUnavailable)) pure

needFile :: Either FileError () -> IO ()
needFile = either (const (abort FileEffectUnavailable)) pure

abort :: FileEffectError -> IO a
abort = throwIO . GitAbort

protect :: IO a -> IO (Either FileEffectError a)
protect action = catch (catch (Right <$> action) (\(GitAbort err) -> pure (Left err))) (\(_ :: IOException) -> pure (Left FileEffectUnresolved))

-- A separate exact revision avoids changing the accepted Git tool menu.
workspaceIntegrationDescriptor :: CapabilityDescriptor
workspaceIntegrationDescriptor = CapabilityDescriptor (must (mkCapabilityId "workspace.integrate")) (must (mkCapabilityRevision "1")) [CapabilityToolDescriptor "plan" Observation]
  where
    must :: (Show e) => Either e a -> a; must = either (error . show) id

integrationBinding :: ToolBinding
integrationBinding = ToolBinding "overlay__workspace-integrate__plan" "workspace.integrate:1" (versionedDigest "shikigami.tool-schema/1" Integration.schema) RepeatableObservation NoInvoiceCost

workspaceIntegrationAdapter :: FileRuntime -> DurableAdapter
workspaceIntegrationAdapter = workspaceIntegrationAdapterWithBackend nativeGitBackend

workspaceIntegrationAdapterWithBackend :: GitBackend -> FileRuntime -> DurableAdapter
workspaceIntegrationAdapterWithBackend backend runtime = DurableAdapter workspaceIntegrationDescriptor [DurableToolContract "plan" description Integration.schema RepeatableObservation NoInvoiceCost] \snapshot dispatch name ->
  pure
    ( Right
        ( mkDynTool
            name
            description
            Integration.schema
            ( \input -> unsafeEff_ do
                result <- protect (integration backend runtime snapshot dispatch name input)
                pure (either (const (Left (ToolRunFailed name "workspace integration refused"))) (Right . textToolOutput . Encoding.decodeUtf8 . Lazy.toStrict . Aeson.encode) result)
            )
        )
    )
  where
    description = "Plan exact retained worker artifacts in this separate clean workspace. Conflicts change no files or HEAD. Apply returned replacements, validate and commit using the governed tools."

integration :: GitBackend -> FileRuntime -> ExecutionSnapshot -> DispatchContext -> Text -> Aeson.Value -> IO Aeson.Value
integration backend runtime snapshot dispatch name input = do
  unless (name == "plan") (abort FileEffectRefused)
  request <- either (const (abort FileEffectRefused)) pure (parseEither Aeson.parseJSON input)
  unless (Integration.validRequest request) (abort FileEffectRefused)
  accepted <- loadAcceptedTool True workspaceIntegrationDescriptor integrationBinding runtime snapshot dispatch input
  _ <- backend.host >>= either (const (abort FileEffectRefused)) pure
  sources <- forM request.artifacts \artifact -> do
    (source, record) <- readRegisteredGit runtime.appEnv artifact.operationId >>= maybe (abort FileEffectRefused) pure
    unless (workspaceBindingDigest source == artifact.bindingDigest && source.base == artifact.base && maybe False ((== artifact.revision) . (.result)) record.candidate) (abort FileEffectRefused)
    pure (source, record)
  let binding = accepted.binding; metadata = workspaceMetadata binding.storageRoot binding
  needFile =<< checkPrivateDirectory binding.storageRoot
  needFile =<< checkPrivateDirectory metadata
  locked <-
    withWorkspaceLock
      metadata
      ( Right <$> do
          current runtime accepted
          profile <- retainedFileProfile runtime.appEnv binding accepted.admission >>= either (const (abort FileEffectRefused)) pure
          anchored <-
            withContainedFile
              (workspaceFiles binding.storageRoot binding)
              ".shikigami-git-target"
              ( \anchor ->
                  Right <$> do
                    target <- containedTargetIdentity anchor >>= either (const (abort FileEffectRefused)) pure
                    grant runtime accepted (workspaceIntegrationAction binding accepted.admission dispatch profile accepted.routing.inputDigest target sources)
                    headId <- Objects.readHead metadata >>= either (const (abort FileEffectRefused)) pure
                    unless (headId == request.expectedParent) (abort FileEffectConflict)
                    captured <- capture backend runtime accepted profile target
                    (headTree, _) <- Objects.readCommit metadata headId >>= either (const (abort FileEffectRefused)) pure
                    unless (captured.tree == headTree) (abort FileEffectConflict)
                    result <- Integration.planIntegration binding request sources (admitPath runtime accepted profile "replace") >>= either (const (abort FileEffectRefused)) pure
                    current runtime accepted
                    bounded result
              )
          either (const (abort FileEffectRefused)) pure anchored
      )
  either (const (abort FileEffectUnresolved)) pure locked

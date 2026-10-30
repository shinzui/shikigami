-- | Concrete, serialized read and compare-and-replace effects. Process and Git
-- mutation adapters are deliberately separate owners.
module Shikigami.Workspace.FileProvider
  ( FileRuntime (..),
    workspaceEditDescriptor,
    supervisedWorkspaceEditDescriptor,
    supervisedWorkspaceEditAdapter,
    supervisedWorkspaceEditAdapterWithCheckpoint,
    workspaceEditAdapter,
    workspaceEditAdapterWithCheckpoint,
    readWorkspaceFile,
    replaceWorkspaceFile,
    replaceWorkspaceFileWithCheckpoint,
    FilePublication (..),
    reconcileFileEffect,
    publishFileReceipt,
  )
where

import Control.Exception (Exception, IOException, catch, throwIO)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Effectful (Eff)
import Effectful.Dispatch.Static (unsafeEff_)
import Hasql.Transaction (Transaction)
import Kioku.App (AppEffects, AppEnv, runAppIO)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Action.Authorization (ActionAuthorizer (..))
import Shikigami.Agent.Principal (identityText)
import Shikigami.Capability.Overlay
import Shikigami.Capability.Provider (DurableAdapter (..), DurableToolContract (..))
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Runner (DispatchContext (..), OperationContext (..))
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript
import Shikigami.Prelude
import Shikigami.Workspace.Allocation (workspaceFiles, workspaceMetadata)
import Shikigami.Workspace.ContainedFile
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Process (ProcessRouting (..), validProcessRouting)
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.Profile (retainedFileProfile)
import Shikigami.Workspace.Provider
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Types
import Shikumi.Tool (ToolError (..), mkDynTool, renderToolError)
import Shikumi.Tool.Output (textToolOutput)

-- Runtime callbacks check current lifecycle and protected replay authority.
-- They are operator configuration and never supplied through model arguments.
data FileRuntime = FileRuntime
  { appEnv :: !AppEnv,
    authorizer :: !ActionAuthorizer,
    lifecycle :: !(ExecutionSnapshot -> IO (Either Text ())),
    replayAuthority :: !(ExecutionSnapshot -> IO (Either Text ())),
    -- Resolve the exact retained policy revision and reject explicit conflicts.
    -- Repository text is input to restrictions and never grants a capability.
    admitTarget :: !(WorkspaceBinding -> WorkspaceAdmission -> [RepositoryInstruction] -> Text -> Text -> IO (Either Text ()))
  }
  deriving stock (Generic)

workspaceEditDescriptor :: CapabilityDescriptor
workspaceEditDescriptor = fileDescriptor FileOnly

supervisedWorkspaceEditDescriptor :: CapabilityDescriptor
supervisedWorkspaceEditDescriptor = fileDescriptor Supervised

data FileMode = FileOnly | Supervised deriving stock (Eq)

fileDescriptor :: FileMode -> CapabilityDescriptor
fileDescriptor mode = CapabilityDescriptor (must (mkCapabilityId "workspace.edit")) (must (mkCapabilityRevision (fileRevision mode))) [CapabilityToolDescriptor "read" Observation, CapabilityToolDescriptor "replace" IdempotentMutation]
  where
    must :: (Show e) => Either e a -> a
    must = either (error . show) id

workspaceEditAdapter :: FileRuntime -> DurableAdapter
workspaceEditAdapter = workspaceEditAdapterWithCheckpoint (pure ())

workspaceEditAdapterWithCheckpoint :: IO () -> FileRuntime -> DurableAdapter
workspaceEditAdapterWithCheckpoint = fileAdapter FileOnly

supervisedWorkspaceEditAdapter :: FileRuntime -> DurableAdapter
supervisedWorkspaceEditAdapter = supervisedWorkspaceEditAdapterWithCheckpoint (pure ())

supervisedWorkspaceEditAdapterWithCheckpoint :: IO () -> FileRuntime -> DurableAdapter
supervisedWorkspaceEditAdapterWithCheckpoint = fileAdapter Supervised

fileRevision :: FileMode -> Text
fileRevision FileOnly = "1"
fileRevision Supervised = "2"

filePolicyFor :: FileMode -> Text
filePolicyFor FileOnly = nativeFilePolicy
filePolicyFor Supervised = supervisedFilePolicy

fileAdapter :: FileMode -> IO () -> FileRuntime -> DurableAdapter
fileAdapter mode checkpoint runtime =
  DurableAdapter
    (fileDescriptor mode)
    [ DurableToolContract "read" readDescription readSchema RepeatableObservation NoInvoiceCost,
      DurableToolContract "replace" replaceDescription replaceSchema IdempotentEffect NoInvoiceCost
    ]
    ( \snapshot dispatch name ->
        pure
          ( Right
              ( mkDynTool
                  name
                  (description name)
                  (if name == "read" then readSchema else replaceSchema)
                  ( \input -> unsafeEff_ do
                      result <- if name == "read" then readFileFor mode runtime snapshot dispatch input else replaceFileFor mode checkpoint runtime snapshot dispatch input
                      case result of
                        Left FileEffectUnresolved -> throwIO (userError "workspace effect requires reconciliation")
                        Left FileEffectUnavailable -> throwIO (userError "workspace effect evidence is unavailable")
                        _ -> pure (either (const (Left (ToolRunFailed name "workspace operation refused"))) (Right . textToolOutput . Encoding.decodeUtf8 . Lazy.toStrict . Aeson.encode) result)
                  )
              )
          )
    )
  where
    description "read" = readDescription
    description _ = replaceDescription

readDescription, replaceDescription :: Text
readDescription = "Read a contained UTF-8 file at an exact relative ASCII path and return its content hash (256 KiB maximum)."
replaceDescription = "Compare-and-replace a UTF-8 file at an exact relative ASCII path (256 KiB maximum); creation requires an existing directory."

readSchema, replaceSchema :: Aeson.Value
readSchema = Aeson.object ["type" Aeson..= ("object" :: Text), "properties" Aeson..= Aeson.object ["path" Aeson..= pathSchema], "required" Aeson..= ["path" :: Text], "additionalProperties" Aeson..= False]
replaceSchema = Aeson.object ["type" Aeson..= ("object" :: Text), "properties" Aeson..= Aeson.object ["path" Aeson..= pathSchema, "expected" Aeson..= Aeson.object ["type" Aeson..= ["string", "null" :: Text]], "content" Aeson..= stringSchema], "required" Aeson..= ["path", "expected", "content" :: Text], "additionalProperties" Aeson..= False]

pathSchema :: Aeson.Value
pathSchema = Aeson.object ["type" Aeson..= ("string" :: Text), "pattern" Aeson..= ("^[ -~]+$" :: Text), "maxLength" Aeson..= (4096 :: Int)]

stringSchema :: Aeson.Value
stringSchema = Aeson.object ["type" Aeson..= ("string" :: Text)]

-- Load the authoritative snapshot, accepted arguments and actual attempt. A
-- prepared tool closure is not permission to substitute caller coordinates.
withAccess :: FileMode -> FileRuntime -> ExecutionSnapshot -> DispatchContext -> Text -> Aeson.Value -> (WorkspaceBinding -> WorkspaceAdmission -> Maybe ProcessProfile -> IO (Either FileEffectError ()) -> (FileReceipt -> IO (Either FileEffectError ())) -> (FileReceipt -> IO (Either FileEffectError ())) -> IO (Either FileEffectError Aeson.Value)) -> IO (Either FileEffectError Aeson.Value)
withAccess mode runtime snapshot dispatch logical input perform = catch work (\(_ :: IOException) -> pure (Left FileEffectUnavailable))
  where
    owned :: Eff AppEffects (Either ExecutionError a) -> IO (Either FileEffectError a)
    owned action = runAppIO runtime.appEnv action <&> either (const (Left FileEffectUnavailable)) (either (const (Left FileEffectRefused)) Right)
    claim = Attempt.AttemptClaim (Attempt.JobReference 1 snapshot.executionId dispatch.operation.operationId dispatch.attemptId) dispatch.owner dispatch.generation
    work = do
      access <- owned (Execution.authorizeReplay snapshot.executionId snapshot.identity (runtime.replayAuthority snapshot))
      case access of
        Left err -> pure (Left err)
        Right permit -> do
          loaded <- owned (Execution.loadExecution permit)
          accepted <- owned (Execution.inspectOperation dispatch.operation.operationId)
          case (loaded, accepted, snapshot.workspace) of
            (Right (retained, _), Right (Just operation), Just admission)
              | admission.filePolicy == Just (filePolicyFor mode) && retained == snapshot && fileDescriptor mode `elem` resolvedCapabilities snapshot.capabilities && dispatch.operation.executionId == snapshot.executionId && dispatch.operation.fingerprint == operation.fingerprint && dispatch.operation.scopeDigest == operation.specification.scopeDigest && operation.specification.name == wireName logical && operation.specification.kind == ToolOperation && dispatch.operation.idempotencyKey == operationKey dispatch.operation.operationId -> do
                  arguments <- owned (Execution.readReplayPayload @ToolOperationInput permit "operation-input" operation.input)
                  binding <- runTx runtime (Store.inspectWorkspaceTx admission.workspace)
                  case (arguments, binding) of
                    (Right tool, Right (Just (bound, Ready)))
                      | tool.invocation.arguments == input && tool.invocation.name == wireName logical && tool.binding `elem` snapshot.toolBindings && tool.binding.name == wireName logical && tool.binding.revision == "workspace.edit:" <> fileRevision mode && tool.binding.schemaDigest == versionedDigest "shikigami.tool-schema/1" (if logical == "read" then readSchema else replaceSchema) && tool.binding.recovery == (if logical == "read" then RepeatableObservation else IdempotentEffect) && tool.binding.invoiceCost == NoInvoiceCost && admission.bindingDigest == workspaceBindingDigest bound && admission.runId == bound.request.runId && admission.owner == snapshot.identity && Just admission.rootId == snapshot.selection.rootId -> do
                          let check = do
                                lifecycle <- runtime.lifecycle snapshot
                                if isLeft lifecycle
                                  then pure (Left FileEffectRefused)
                                  else do
                                    current <- owned (Execution.checkStartedExecutionAttempt permit claim)
                                    owner <- runTx runtime (Store.checkWorkspaceOperationTx bound admission.owner admission.epoch dispatch.operation.operationId)
                                    pure (current >> owner >>= either (const (Left FileEffectRefused)) Right)
                          ready <- check
                          case ready of
                            Left err -> pure (Left err)
                            Right () -> do
                              private <- case mode of
                                FileOnly -> ensurePrivateDirectory bound.storageRoot
                                Supervised -> do
                                  root <- checkPrivateDirectory bound.storageRoot
                                  metadata <- checkPrivateDirectory (workspaceMetadata bound.storageRoot bound)
                                  pure (root >> metadata)
                              case private of
                                Left _ -> pure (Left FileEffectUnavailable)
                                Right () ->
                                  flattenFile
                                    <$> withWorkspaceLock
                                      (workspaceMetadata bound.storageRoot bound)
                                      ( Right <$> do
                                          current <- check
                                          case current of
                                            Left err -> pure (Left err)
                                            Right () -> do
                                              profile <- case mode of
                                                FileOnly -> pure (Right Nothing)
                                                Supervised -> fmap (either (const (Left FileEffectRefused)) (Right . Just)) (retainedFileProfile runtime.appEnv bound admission)
                                              case profile of
                                                Left err -> pure (Left err)
                                                Right selected -> perform bound admission selected check (prepareReceipt permit tool operation bound admission) (completeReceipt permit tool)
                                      )
                    _ -> pure (Left FileEffectRefused)
            _ -> pure (Left FileEffectRefused)
    prepareReceipt permit tool operation bound admission receipt = do
      source <- owned (Execution.readReplayPayload @OperationOutcome permit "operation-outcome" tool.response)
      case source of
        Right (ModelReturned assistant _) -> do
          let next = if tool.position + 1 < length (toolInvocations assistant) then NeedTool tool.response (tool.position + 1) else NeedModel
              routing = ProcessRouting 1 snapshot.executionId snapshot.identity operation.input.digest next
              registration = FileRegistration dispatch.operation dispatch.owner routing receipt
          saved <- runTx runtime do
            reserved <- Store.reserveWorkspaceEffectTx bound admission.owner admission.epoch receipt.operationId receipt.fingerprint
            case reserved of
              Left err -> pure (Left err)
              Right _ -> Store.registerFileTx bound registration
          pure (saved >>= either (const (Left FileEffectUnresolved)) Right)
        _ -> pure (Left FileEffectUnresolved)
    -- A recovered private receipt settles only its original actual attempt.
    -- The new attempt still owns logical completion through the executor.
    completeReceipt permit tool receipt
      | receipt.attemptId == dispatch.attemptId = pure (if receipt.generation == dispatch.generation then Right () else Left FileEffectUnresolved)
      | otherwise = do
          previous <- owned (Execution.inspectExecutionAttempt receipt.attemptId)
          source <- owned (Execution.readReplayPayload @OperationOutcome permit "operation-outcome" tool.response)
          metadata <- owned (Execution.inspectExecution snapshot.executionId)
          case (previous, source, metadata) of
            (Right (Just old), Right (ModelReturned assistant _), Right (Just (state, _, _)))
              | old.phase == Attempt.AttemptSuperseded && old.operationId == receipt.operationId && old.executionId == snapshot.executionId && old.generation == receipt.generation,
                Just owner <- old.owner -> do
                  let next = if tool.position + 1 < length (toolInvocations assistant) then NeedTool tool.response (tool.position + 1) else NeedModel
                      output =
                        if receipt.state == EditRefused
                          then ToolReturned [TextBlock (renderToolError (ToolRunFailed "replace" "workspace operation refused"))] True
                          else RichToolReturned (captureToolOutput (textToolOutput (Encoding.decodeUtf8 (Lazy.toStrict (Aeson.encode receipt)))))
                      original = Attempt.AttemptClaim (Attempt.JobReference 1 snapshot.executionId receipt.operationId receipt.attemptId) owner receipt.generation
                  accepted <- owned (Execution.recordLateExecutionReceipt permit state.revision original (Attempt.AttemptResult output next Nothing))
                  pure (either (const (Left FileEffectUnresolved)) (const (Right ())) accepted)
            _ -> pure (Left FileEffectUnresolved)
    operationKey (OperationId key) = key
    wireName name = "overlay__workspace-edit__" <> name
    isLeft (Left _) = True
    isLeft _ = False

readWorkspaceFile :: FileRuntime -> ExecutionSnapshot -> DispatchContext -> Aeson.Value -> IO (Either FileEffectError Aeson.Value)
readWorkspaceFile = readFileFor FileOnly

readFileFor :: FileMode -> FileRuntime -> ExecutionSnapshot -> DispatchContext -> Aeson.Value -> IO (Either FileEffectError Aeson.Value)
readFileFor mode runtime snapshot dispatch input = case parseEither (Aeson.withObject "read" (\fields -> if length fields /= 1 then fail "unsupported read" else fields Aeson..: "path")) input of
  Left _ -> pure (Left FileEffectRefused)
  Right path -> withAccess mode runtime snapshot dispatch "read" input \binding admission profile check _prepare _complete ->
    flattenFile
      <$> withContainedFile
        (workspaceFiles binding.storageRoot binding)
        path
        ( \file ->
            Right <$> do
              target <- containedTargetIdentity file
              case target of
                Left _ -> pure (Left FileEffectRefused)
                Right identity -> do
                  granted <- authorize runtime profile binding admission dispatch "read" path identity input check
                  case granted of
                    Left err -> pure (Left err)
                    Right () -> do
                      bytes <- readContainedFile 262144 file
                      pure do
                        actual <- mapFile bytes >>= maybe (Left FileEffectConflict) Right
                        text <- either (const (Left FileEffectRefused)) Right (Encoding.decodeUtf8' actual)
                        pure (Aeson.object ["path" Aeson..= path, "content" Aeson..= text, "hash" Aeson..= contentDigest text])
        )

replaceWorkspaceFile :: FileRuntime -> ExecutionSnapshot -> DispatchContext -> Aeson.Value -> IO (Either FileEffectError Aeson.Value)
replaceWorkspaceFile = replaceWorkspaceFileWithCheckpoint (pure ())

-- The fixture interrupts after durable file publication, before final receipt
-- acknowledgement. The prepared private receipt must already be on disk.
replaceWorkspaceFileWithCheckpoint :: IO () -> FileRuntime -> ExecutionSnapshot -> DispatchContext -> Aeson.Value -> IO (Either FileEffectError Aeson.Value)
replaceWorkspaceFileWithCheckpoint = replaceFileFor FileOnly

replaceFileFor :: FileMode -> IO () -> FileRuntime -> ExecutionSnapshot -> DispatchContext -> Aeson.Value -> IO (Either FileEffectError Aeson.Value)
replaceFileFor mode checkpoint runtime snapshot dispatch input = case parseEither
  ( Aeson.withObject
      "Replacement"
      ( \fields -> do
          unless (length fields == 3 && all (`AesonKeyMap.member` fields) ["path", "expected", "content"]) (fail "unsupported replacement")
          Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object fields)
      )
  )
  input of
  Left _ -> pure (Left FileEffectRefused)
  Right (replacement :: Replacement)
    | not (validWorkspacePath replacement.path) -> pure (Left FileEffectRefused)
    | Bytes.length (Encoding.encodeUtf8 replacement.content) > 262144 -> pure (Left FileEffectTooLarge)
    | otherwise -> withAccess mode runtime snapshot dispatch "replace" input \binding admission profile check prepare complete ->
        flattenFile
          <$> withContainedFile
            (workspaceFiles binding.storageRoot binding)
            replacement.path
            ( \file ->
                Right <$> do
                  target <- containedTargetIdentity file
                  case target of
                    Left _ -> pure (Left FileEffectRefused)
                    Right identity -> do
                      granted <- authorize runtime profile binding admission dispatch "replace" replacement.path identity input check
                      case granted of
                        Left err -> pure (Left err)
                        Right () -> replace profile binding admission check prepare complete file identity replacement
            )
  where
    replace profile binding admission check prepare complete file identity replacement = do
      let fingerprint = case profile of
            Nothing -> versionedDigest "shikigami.workspace-replacement/1" (toJSON (workspaceBindingDigest binding, dispatch.operation, input, identity))
            Just retained -> versionedDigest "shikigami.workspace-replacement/2" (toJSON (workspaceBindingDigest binding, dispatch.operation, input, identity, retained))
          receipt = FileReceipt dispatch.operation.operationId dispatch.attemptId dispatch.generation fingerprint (workspaceBindingDigest binding) (bundleDigest admission.instructions) replacement.path identity replacement.expected (contentDigest replacement.content) EditPrepared
          metadata = workspaceMetadata binding.storageRoot binding
          receiptName = "receipt-" <> Text.drop 7 (versionedDigest "shikigami.workspace-receipt/1" (toJSON dispatch.operation.operationId)) <> ".json"
      existing <- readPrivateReceipt metadata receiptName
      case existing of
        Left err -> pure (Left err)
        Right (Just previous) | (previous & #attemptId .~ receipt.attemptId & #generation .~ receipt.generation & #state .~ receipt.state) /= receipt || previous.generation <= 0 -> pure (Left FileEffectUnresolved)
        Right (Just previous) | previous.state == EditApplied -> do
          saved <- runTx runtime (Store.recordWorkspaceReceiptTx binding previous)
          case saved of
            Right (Right ()) -> complete previous <&> fmap (const (toJSON previous))
            _ -> pure (Left FileEffectUnresolved)
        Right (Just previous) | previous.state == EditRefused -> do
          saved <- runTx runtime (Store.recordWorkspaceReceiptTx binding previous)
          case saved of
            Right (Right ()) -> complete previous <&> (>> Left FileEffectRefused)
            _ -> pure (Left FileEffectUnresolved)
        Right previous -> do
          observed <- readContainedFile 262144 file
          let text = mapFile observed >>= traverse (either (const (Left FileEffectRefused)) Right . Encoding.decodeUtf8')
              actual = fmap contentDigest <$> text
          case actual of
            Left err -> pure (Left err)
            Right current | current == Just receipt.result && isJust previous -> settle complete binding metadata receiptName (fromMaybe receipt previous)
            -- A prepared receipt proves intent, not publication by its original
            -- actual attempt. A replacement may observe an applied effect, but
            -- cannot execute it and attribute that new work to the old attempt.
            Right _ | Just original <- previous, original.attemptId /= dispatch.attemptId || original.generation /= dispatch.generation -> pure (Left FileEffectUnresolved)
            Right current | current /= replacement.expected -> pure (Left FileEffectConflict)
            Right _ -> do
              reserved <- prepare receipt
              case reserved of
                Right () -> do
                  let prepared = fromMaybe receipt previous
                  retained <- writePrivateReceipt metadata receiptName prepared
                  case retained of
                    Left err -> pure (Left err)
                    Right () -> do
                      saved <- runTx runtime (Store.recordWorkspaceReceiptTx binding prepared)
                      gate <- authorize runtime profile binding admission dispatch "replace" replacement.path identity input check
                      case (saved, gate, mapFile observed) of
                        (Right (Right ()), Right (), Right old) -> do
                          applied <- case profile of
                            Nothing -> replaceContainedFile metadata file old (Encoding.encodeUtf8 replacement.content)
                            Just retained -> replaceContainedFileOwned retained.userId metadata file old (Encoding.encodeUtf8 replacement.content)
                          case applied of
                            Left FileContentConflict -> refusePrepared binding metadata receiptName prepared
                            Left _ -> pure (Left FileEffectUnresolved)
                            Right () -> checkpoint >> settle complete binding metadata receiptName prepared
                        _ -> refusePrepared binding metadata receiptName prepared
                Left err -> pure (Left err)
    refusePrepared binding metadata name prepared = do
      let refused = prepared & #state .~ EditRefused
      retained <- writePrivateReceipt metadata name refused
      case retained of
        Left _ -> pure (Left FileEffectUnresolved)
        Right () -> do
          saved <- runTx runtime (Store.recordWorkspaceReceiptTx binding refused)
          pure (saved >>= either (const (Left FileEffectUnresolved)) (const (Left FileEffectRefused)))
    settle complete binding metadata name prepared = do
      let completed = prepared & #state .~ EditApplied
      retained <- writePrivateReceipt metadata name completed
      case retained of
        Left err -> pure (Left err)
        Right () -> do
          saved <- runTx runtime (Store.recordWorkspaceReceiptTx binding completed)
          case saved of
            Right (Right ()) -> complete completed <&> fmap (const (toJSON completed))
            _ -> pure (Left FileEffectUnresolved)

authorize :: FileRuntime -> Maybe ProcessProfile -> WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> Text -> Text -> Text -> Aeson.Value -> IO (Either FileEffectError ()) -> IO (Either FileEffectError ())
authorize runtime profile binding admission dispatch kind path target input check = case (identityText admission.owner, maybe workspaceFileAction workspaceSupervisedFileAction profile binding admission dispatch kind path target (versionedDigest "shikigami.workspace-file-input/1" input), instructionsForPath admission.instructions path) of
  (Right principal, Right action, Right instructions) -> do
    policy <- runtime.admitTarget binding admission instructions kind path
    case policy of
      Left _ -> pure (Left FileEffectRefused)
      Right () -> do
        granted <- runtime.authorizer.authorize principal action
        case granted of Left _ -> pure (Left FileEffectRefused); Right _ -> check
  _ -> pure (Left FileEffectRefused)

runTx :: FileRuntime -> Transaction a -> IO (Either FileEffectError a)
runTx runtime action = runAppIO runtime.appEnv (runTransaction action) <&> either (const (Left FileEffectUnavailable)) Right

mapFile :: Either FileError a -> Either FileEffectError a
mapFile = either (Left . classify) Right
  where
    classify FileBusy = FileEffectUnresolved
    classify FileUnavailable = FileEffectUnavailable
    classify FileTooLarge = FileEffectTooLarge
    classify FileContentConflict = FileEffectConflict
    classify FilePathRefused = FileEffectRefused

flattenFile :: Either FileError (Either FileEffectError a) -> Either FileEffectError a
flattenFile = (>>= id) . mapFile

readPrivateReceipt :: FilePath -> Text -> IO (Either FileEffectError (Maybe FileReceipt))
readPrivateReceipt metadata name =
  flattenFile
    <$> withContainedFile
      metadata
      name
      ( \file ->
          Right <$> do
            bytes <- readContainedFile 65536 file
            pure (mapFile bytes >>= traverse (either (const (Left FileEffectUnresolved)) Right . Aeson.eitherDecodeStrict))
      )

writePrivateReceipt :: FilePath -> Text -> FileReceipt -> IO (Either FileEffectError ())
writePrivateReceipt metadata name receipt =
  either (const (Left FileEffectUnresolved)) Right
    <$> withContainedFile
      metadata
      name
      ( \file -> do
          previous <- readContainedFile 65536 file
          case previous of
            Left err -> pure (Left err)
            Right old -> replaceContainedFile metadata file old (Lazy.toStrict (Aeson.encode receipt))
      )

data FilePublication = AwaitingFileReceipt | AwaitingFileExecutionExpiry | FileReceiptAcknowledged deriving stock (Eq, Show)

newtype FileRecoveryAbort = FileRecoveryAbort FileEffectError deriving stock (Show)

instance Exception FileRecoveryAbort

recoveryAbort :: FileEffectError -> IO a
recoveryAbort = throwIO . FileRecoveryAbort

protectRecovery :: IO a -> IO (Either FileEffectError a)
protectRecovery work = catch (catch (Right <$> work) (\(FileRecoveryAbort err) -> pure (Left err))) (\(_ :: IOException) -> pure (Left FileEffectUnresolved))

recoveryTx :: AppEnv -> Transaction a -> IO a
recoveryTx env work = runAppIO env (runTransaction work) >>= either (const (recoveryAbort FileEffectUnavailable)) pure

recoveryExecution :: AppEnv -> Eff AppEffects (Either ExecutionError a) -> IO a
recoveryExecution env work = runAppIO env work >>= either (const (recoveryAbort FileEffectUnavailable)) (either (const (recoveryAbort FileEffectUnresolved)) pure)

-- Factual recovery never calls the authorizer, reads protected model payloads,
-- or performs a repository write. It shares the same lock as every writer.
reconcileFileEffect :: AppEnv -> OperationId -> IO (Either FileEffectError FileReceipt)
reconcileFileEffect env operation = protectRecovery do
  (binding, registration, completed) <- recoveryTx env (Store.inspectRegisteredFileTx operation) >>= maybe (recoveryAbort FileEffectUnresolved) pure
  let original = registration.receipt
      matches receipt = (receipt & #state .~ EditPrepared) == original
      validate receipt = unless (original.state == EditPrepared && matches receipt && original.operationId == operation && original.bindingDigest == workspaceBindingDigest binding && original.generation > 0 && validWorkspacePath original.path && validProcessRouting registration.routing) (recoveryAbort FileEffectUnresolved)
  validate original
  case completed of
    Just receipt | receipt.state `elem` [EditApplied, EditRefused] -> validate receipt >> pure receipt
    _ -> do
      let metadata = workspaceMetadata binding.storageRoot binding
          name = "receipt-" <> Text.drop 7 (versionedDigest "shikigami.workspace-receipt/1" (toJSON operation)) <> ".json"
      forM_ [binding.storageRoot, metadata] \path -> checkPrivateDirectory path >>= either (const (recoveryAbort FileEffectUnavailable)) pure
      locked <- withWorkspaceLock metadata do
        -- A worker may have completed while this scanner waited for the lock.
        current <- recoveryTx env (Store.inspectRegisteredFileTx operation)
        case current of
          Just (same, retained, saved) | same == binding && retained == registration -> do
            forM_ saved validate
            private <- readPrivateReceipt metadata name >>= either recoveryAbort (maybe (recoveryAbort FileEffectUnresolved) pure)
            validate private
            receipt <- case private.state of
              EditPrepared -> do
                observed <- withContainedFile (workspaceFiles binding.storageRoot binding) original.path \file -> do
                  target <- containedTargetIdentity file
                  bytes <- readContainedFile 262144 file
                  pure do
                    identity <- target
                    unless (identity == original.target) (Left FilePathRefused)
                    actual <- bytes >>= maybe (Left FileContentConflict) Right
                    text <- either (const (Left FilePathRefused)) Right (Encoding.decodeUtf8' actual)
                    unless (contentDigest text == original.result) (Left FileContentConflict)
                either (const (recoveryAbort FileEffectUnresolved)) pure observed
                let applied = private & #state .~ EditApplied
                writePrivateReceipt metadata name applied >>= either recoveryAbort pure
                pure applied
              _ -> pure private
            recoveryTx env (Store.recordWorkspaceReceiptTx binding receipt) >>= either (const (recoveryAbort FileEffectUnresolved)) pure
            pure (Right receipt)
          _ -> recoveryAbort FileEffectUnresolved
      either (const (recoveryAbort FileEffectUnresolved)) pure locked

publishFileReceipt :: AppEnv -> OperationId -> IO (Either FileEffectError FilePublication)
publishFileReceipt env operationId = protectRecovery do
  (binding, registration, _) <- recoveryTx env (Store.inspectRegisteredFileTx operationId) >>= maybe (recoveryAbort FileEffectUnresolved) pure
  reconciled <- reconcileFileEffect env operationId
  case reconciled of
    Left FileEffectUnresolved -> pure AwaitingFileReceipt
    Left err -> recoveryAbort err
    Right completed -> do
      let routing = registration.routing
          original = registration.receipt
          OperationId key = operationId
      (state, retained, _) <- recoveryExecution env (Execution.inspectExecution routing.executionId) >>= maybe (recoveryAbort FileEffectUnresolved) pure
      operation <- recoveryExecution env (Execution.inspectOperation operationId) >>= maybe (recoveryAbort FileEffectUnresolved) pure
      -- Match the executor's immutable specification and original claim before
      -- publishing any outcome. No caller-supplied continuation is accepted.
      unless (validProcessRouting routing && routing.identity == retained.identity && retained.rootId == Just binding.request.rootId && registration.operation == OperationContext routing.executionId operationId key operation.fingerprint operation.specification.scopeDigest && operation.executionId == routing.executionId && operation.specification.kind == ToolOperation && operation.specification.name == "overlay__workspace-edit__replace" && operation.specification.recovery == IdempotentEffect && operation.input.digest == routing.inputDigest) (recoveryAbort FileEffectUnresolved)
      actual <- recoveryExecution env (Execution.inspectExecutionAttempt original.attemptId) >>= maybe (recoveryAbort FileEffectUnresolved) pure
      unless (actual.executionId == routing.executionId && actual.operationId == operationId && actual.owner == Just registration.claimOwner && actual.generation == original.generation && isNothing actual.call) (recoveryAbort FileEffectUnresolved)
      let reference = Attempt.JobReference 1 routing.executionId operationId original.attemptId
          claim = Attempt.AttemptClaim reference registration.claimOwner original.generation
          outcome = if completed.state == EditRefused then ToolReturned [TextBlock (renderToolError (ToolRunFailed "replace" "workspace operation refused"))] True else RichToolReturned (captureToolOutput (textToolOutput (Encoding.decodeUtf8 (Lazy.toStrict (Aeson.encode completed)))))
          receipt = Attempt.AttemptResult outcome routing.next Nothing
          acknowledge = recoveryExecution env (Execution.publishExecutionWake reference) >> pure FileReceiptAcknowledged
      case actual.phase of
        Attempt.DispatchStarted -> do
          now <- getCurrentTime
          if maybe False (now >=) actual.expiresAt
            then do
              _ <- recoveryExecution env (Execution.markExpiredExecutionAttemptUncertain routing.identity state.revision reference)
              publishFileReceipt env operationId >>= either recoveryAbort pure
            else pure AwaitingFileExecutionExpiry
        Attempt.AttemptUncertain -> do
          _ <- recoveryExecution env (Execution.recordIndependentToolReceipt routing.identity state.revision claim receipt)
          (changed, _, _) <- recoveryExecution env (Execution.inspectExecution routing.executionId) >>= maybe (recoveryAbort FileEffectUnresolved) pure
          _ <- recoveryExecution env (Execution.reconcileExecutionControlAttempt routing.identity routing.executionId changed.revision original.attemptId)
          acknowledge
        Attempt.AttemptSuperseded -> recoveryExecution env (Execution.recordIndependentToolReceipt routing.identity state.revision claim receipt) >> acknowledge
        Attempt.AttemptCommitted -> recoveryExecution env (Execution.recordIndependentToolReceipt routing.identity state.revision claim receipt) >> acknowledge
        _ -> recoveryAbort FileEffectUnresolved

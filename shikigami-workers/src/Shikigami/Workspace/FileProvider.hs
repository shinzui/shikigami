-- | Concrete, serialized read and compare-and-replace effects. Process and Git
-- mutation adapters are deliberately separate owners.
module Shikigami.Workspace.FileProvider
  ( FileRuntime (..),
    workspaceEditDescriptor,
    workspaceEditAdapter,
    workspaceEditAdapterWithCheckpoint,
    readWorkspaceFile,
    replaceWorkspaceFile,
    replaceWorkspaceFileWithCheckpoint,
  )
where

import Control.Exception (IOException, catch, throwIO)
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
workspaceEditDescriptor = CapabilityDescriptor (must (mkCapabilityId "workspace.edit")) (must (mkCapabilityRevision "1")) [CapabilityToolDescriptor "read" Observation, CapabilityToolDescriptor "replace" IdempotentMutation]
  where
    must :: (Show e) => Either e a -> a
    must = either (error . show) id

workspaceEditAdapter :: FileRuntime -> DurableAdapter
workspaceEditAdapter = workspaceEditAdapterWithCheckpoint (pure ())

workspaceEditAdapterWithCheckpoint :: IO () -> FileRuntime -> DurableAdapter
workspaceEditAdapterWithCheckpoint checkpoint runtime =
  DurableAdapter
    workspaceEditDescriptor
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
                      result <- if name == "read" then readWorkspaceFile runtime snapshot dispatch input else replaceWorkspaceFileWithCheckpoint checkpoint runtime snapshot dispatch input
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
withAccess :: FileRuntime -> ExecutionSnapshot -> DispatchContext -> Text -> Aeson.Value -> (WorkspaceBinding -> WorkspaceAdmission -> IO (Either FileEffectError ()) -> (FileReceipt -> IO (Either FileEffectError ())) -> IO (Either FileEffectError Aeson.Value)) -> IO (Either FileEffectError Aeson.Value)
withAccess runtime snapshot dispatch logical input perform = catch work (\(_ :: IOException) -> pure (Left FileEffectUnavailable))
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
              | admission.filePolicy == Just nativeFilePolicy && retained == snapshot && workspaceEditDescriptor `elem` resolvedCapabilities snapshot.capabilities && dispatch.operation.executionId == snapshot.executionId && dispatch.operation.fingerprint == operation.fingerprint && dispatch.operation.scopeDigest == operation.specification.scopeDigest && operation.specification.name == wireName logical && operation.specification.kind == ToolOperation && dispatch.operation.idempotencyKey == operationKey dispatch.operation.operationId -> do
                  arguments <- owned (Execution.readReplayPayload @ToolOperationInput permit "operation-input" operation.input)
                  binding <- runTx runtime (Store.inspectWorkspaceTx admission.workspace)
                  case (arguments, binding) of
                    (Right tool, Right (Just (bound, Ready)))
                      | tool.invocation.arguments == input && tool.invocation.name == wireName logical && tool.binding `elem` snapshot.toolBindings && tool.binding.name == wireName logical && tool.binding.revision == "workspace.edit:1" && tool.binding.schemaDigest == versionedDigest "shikigami.tool-schema/1" (if logical == "read" then readSchema else replaceSchema) && tool.binding.recovery == (if logical == "read" then RepeatableObservation else IdempotentEffect) && tool.binding.invoiceCost == NoInvoiceCost && admission.bindingDigest == workspaceBindingDigest bound && admission.runId == bound.request.runId && admission.owner == snapshot.identity && Just admission.rootId == snapshot.selection.rootId -> do
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
                              private <- ensurePrivateDirectory bound.storageRoot
                              case private of
                                Left _ -> pure (Left FileEffectUnavailable)
                                Right () -> flattenFile <$> withWorkspaceLock (workspaceMetadata bound.storageRoot bound) (Right <$> perform bound admission check (completeReceipt permit tool))
                    _ -> pure (Left FileEffectRefused)
            _ -> pure (Left FileEffectRefused)
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
readWorkspaceFile runtime snapshot dispatch input = case parseEither (Aeson.withObject "read" (\fields -> if length fields /= 1 then fail "unsupported read" else fields Aeson..: "path")) input of
  Left _ -> pure (Left FileEffectRefused)
  Right path -> withAccess runtime snapshot dispatch "read" input \binding admission check _complete ->
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
                  granted <- authorize runtime binding admission dispatch "read" path identity input check
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
replaceWorkspaceFileWithCheckpoint checkpoint runtime snapshot dispatch input = case parseEither
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
    | otherwise -> withAccess runtime snapshot dispatch "replace" input \binding admission check complete ->
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
                      granted <- authorize runtime binding admission dispatch "replace" replacement.path identity input check
                      case granted of
                        Left err -> pure (Left err)
                        Right () -> replace binding admission check complete file identity replacement
            )
  where
    replace binding admission check complete file identity replacement = do
      let fingerprint = versionedDigest "shikigami.workspace-replacement/1" (toJSON (workspaceBindingDigest binding, dispatch.operation, input, identity))
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
            Right current | current /= replacement.expected -> pure (Left FileEffectConflict)
            Right _ -> do
              reserved <- runTx runtime (Store.reserveWorkspaceEffectTx binding admission.owner admission.epoch dispatch.operation.operationId fingerprint)
              case reserved of
                Right (Right _) -> do
                  let prepared = fromMaybe receipt previous
                  retained <- writePrivateReceipt metadata receiptName prepared
                  case retained of
                    Left err -> pure (Left err)
                    Right () -> do
                      saved <- runTx runtime (Store.recordWorkspaceReceiptTx binding prepared)
                      gate <- authorize runtime binding admission dispatch "replace" replacement.path identity input check
                      case (saved, gate, mapFile observed) of
                        (Right (Right ()), Right (), Right old) -> do
                          applied <- replaceContainedFile metadata file old (Encoding.encodeUtf8 replacement.content)
                          case applied of
                            Left FileContentConflict -> refusePrepared binding metadata receiptName prepared
                            Left _ -> pure (Left FileEffectUnresolved)
                            Right () -> checkpoint >> settle complete binding metadata receiptName prepared
                        _ -> refusePrepared binding metadata receiptName prepared
                Left err -> pure (Left err)
                _ -> pure (Left FileEffectConflict)
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

authorize :: FileRuntime -> WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> Text -> Text -> Text -> Aeson.Value -> IO (Either FileEffectError ()) -> IO (Either FileEffectError ())
authorize runtime binding admission dispatch kind path target input check = case (identityText admission.owner, workspaceFileAction binding admission dispatch kind path target (versionedDigest "shikigami.workspace-file-input/1" input), instructionsForPath admission.instructions path) of
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

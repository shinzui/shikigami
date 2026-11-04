{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ViewPatterns #-}

-- | Reserve before filesystem effects. Matching duplicate requests converge;
-- reservation metadata remains immutable after the workspace becomes ready.
module Shikigami.Workspace.Store (sessionWorkspaceTx, inspectWorkspaceBindingsTx, workspaceEffectsSettledTx, workspaceRefForAssignment, reserveWorkspaceTx, inspectWorkspaceTx, markWorkspaceReadyTx, checkWorkspaceOwnerTx, checkWorkspaceOperationTx, reserveWorkspaceEffectTx, recordWorkspaceReceiptTx, freezeWorkspaceTx, registerFileTx, registerFileForOwnerTx, inspectRegisteredFileTx, inspectFilePageTx, WorkspaceControl (..), FreezeState (..), workspaceFrozen, inspectWorkspaceControlTx) where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId, executionRootIdText, operationIdText, parseOperationId)
import Shikigami.Execution.Runner (OperationContext (..))
import Shikigami.Prelude
import Shikigami.StateRevision
import Shikigami.WorkerSession.Transfer (WorkspaceRef (..))
import Shikigami.WorkerSession.Types (AssignmentId (..), WorkerSessionId (..))
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.GitTypes qualified as Git
import Shikigami.Workspace.Instructions (validWorkspacePath)
import Shikigami.Workspace.Process (ProcessPhase (..), ProcessRecord (..), ProcessRouting (..), digestText, processUnit, validProcessCommand, validProcessReceipt, validProcessRouting)
import Shikigami.Workspace.Provider (FileReceipt (..), FileRegistration (..), ReceiptState (..))
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value
import System.FilePath (isAbsolute, normalise, splitDirectories)

reserveWorkspaceTx :: FilePath -> WorkspaceRequest -> ResolvedRepository -> Transaction (Either WorkspaceError (WorkspaceBinding, AllocationState))
reserveWorkspaceTx storageRoot request repository = do
  result <- if not valid then pure (Left InvalidWorkspaceRequest) else reserve
  case result of Left _ -> Tx.condemn; Right _ -> pure ()
  pure result
  where
    reserve = do
      allocated <- Tx.statement () allocateWorkspaceId
      case allocated of
        Left _ -> pure (Left WorkspaceBindingConflict)
        Right identifier -> do
          let proposed = bindingFor identifier
          Tx.statement (key, resource, workspaceIdText identifier, proposed) insertBinding
          existing <- inspectWorkspaceTx proposed.workspace
          retired <- Tx.statement resource hasCleanup
          case existing of
            Right (Just pair@(stored, _)) | stored == bindingFor stored.id && not retired -> do
              Tx.statement (resource, request.owner, revisionNumber request.epoch) insertControl
              pure (Right pair)
            _ -> pure (Left WorkspaceBindingConflict)
    valid = validWorkspaceRequest storageRoot request
    key = workspaceOriginKey (maybe (toJSON request.runId.unWorkflowId) toJSON request.assignment)
    -- This is the provider address of the natural origin, not its entity ID.
    resource = workspaceCoordinateText (workspaceRefForKey key).resource
    bindingFor identifier = WorkspaceBinding identifier request (workspaceRefForKey key) (repositoryIdentity repository) (repositoryBase repository) (repositoryPolicyRevision repository) (workspaceLocator storageRoot) (repositorySource repository)

validWorkspaceRequest :: FilePath -> WorkspaceRequest -> Bool
validWorkspaceRequest storageRoot request =
  let root = executionRootIdText request.rootId
      validKey value = not (Text.null value) && Text.length value <= 256 && not (Text.any (== '\0') value)
      validIdentity = either (const False) validKey . identityText
   in storageRoot /= "/" && ".." `notElem` splitDirectories storageRoot && isAbsolute storageRoot && normalise storageRoot == storageRoot && not ('\0' `elem` storageRoot) && validKey request.runId.unWorkflowId && validKey root && validIdentity request.principal && validIdentity request.owner && revisionNumber request.epoch < 9223372036854775808 && maybe True (\(session, assignment) -> validKey session.value && validKey assignment.value) request.assignment

-- | Reconstruct the existing provider locator from relational session/message
-- coordinates, without trusting a JSON binding to discover its own location.
-- This is exactly the allocator's historical origin formula, not a new ID.
workspaceRefForAssignment :: WorkerSessionId -> AssignmentId -> WorkspaceRef
workspaceRefForAssignment session assignment = workspaceRefForKey (workspaceOriginKey (toJSON (session, assignment)))

workspaceOriginKey :: Aeson.Value -> Text
workspaceOriginKey = versionedDigest "shikigami.workspace-assignment/1"

workspaceRefForKey :: Text -> WorkspaceRef
workspaceRefForKey key = WorkspaceRef (workspaceCoordinate "shikigami.workspace/1") (workspaceCoordinate (Text.drop 7 (versionedDigest "shikigami.workspace-resource/1" (toJSON key))))

-- PostgreSQL 18 owns UUIDv7 allocation. Only the committed logical-origin
-- winner escapes; concurrent/transaction retries return its retained identity.
allocateWorkspaceId :: Statement () (Either Text WorkspaceId)
allocateWorkspaceId = preparable "SELECT pg_catalog.uuidv7()" E.noParams (D.singleRow (workspaceIdFromUUID <$> D.column (D.nonNullable D.uuid)))

inspectWorkspaceTx :: WorkspaceRef -> Transaction (Either WorkspaceError (Maybe (WorkspaceBinding, AllocationState)))
inspectWorkspaceTx ref
  | ref.provider /= workspaceCoordinate "shikigami.workspace/1" = pure (Right Nothing)
  | otherwise = do
      retained <- Tx.statement (workspaceCoordinateText ref.resource) selectBinding
      checkedRead (traverse (>>= checkedBinding ref) retained)

checkedBinding :: WorkspaceRef -> (WorkspaceBinding, AllocationState) -> Either Text (WorkspaceBinding, AllocationState)
checkedBinding ref pair@(binding, _)
  | binding.workspace == ref && workspaceRefForKey (workspaceOriginKey (maybe (toJSON binding.request.runId.unWorkflowId) toJSON binding.request.assignment)) == ref && validWorkspaceRequest (workspaceLocatorPath binding.storageRoot) binding.request = Right pair
  | otherwise = Left "workspace address or request mismatch"

-- A session with several workspace origins needs an explicit broader fencing
-- protocol. Never guess which one a transfer may fence. The caller holds the
-- objective lock and supplies its exact current owner/epoch/root.
sessionWorkspaceTx :: WorkerSessionId -> ExecutionRootId -> AgentIdentity -> StateRevision "worker-owner" -> Transaction (Either WorkspaceError (Maybe WorkspaceRef))
sessionWorkspaceTx session root owner epoch = do
  rows <- Tx.statement session.value (preparable "SELECT resource,binding,state,workspace_id FROM shikigami.workspace_bindings WHERE binding->'request'->'assignment'->>0=$1 ORDER BY resource LIMIT 2" (E.param (E.nonNullable E.text)) (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> bindingRow)))
  case rows of
    [] -> pure (Right Nothing)
    [(resource, parsed)] -> case parsed >>= checkedBinding (WorkspaceRef (workspaceCoordinate "shikigami.workspace/1") (workspaceCoordinate resource)) of
      Right (binding, Ready)
        | binding.request.rootId == root,
          Just (actual, _) <- binding.request.assignment,
          actual == session -> do
            control <- inspectWorkspaceControlTx binding
            pure $ case control of
              Left err -> Left err
              Right (Just current) | current.owner == owner && current.epoch == epoch && current.frozen == AdmissionOpen -> Right (Just binding.workspace)
              _ -> Right Nothing
      Right (_, Reserved) -> pure (Right Nothing)
      _ -> Tx.condemn >> pure (Left WorkspaceBindingConflict)
    _ -> pure (Right Nothing)

-- | Keep the original bounded page while decoding attribution before filtering
-- by storage root. Unreadable attribution refuses; it cannot hide a member.
inspectWorkspaceBindingsTx :: FilePath -> Maybe Text -> Transaction (Either WorkspaceError [WorkspaceBinding])
inspectWorkspaceBindingsTx storageRoot cursor = Tx.statement cursor statement >>= checkedRead
  where
    statement = preparable "SELECT resource,binding,state,workspace_id FROM shikigami.workspace_bindings WHERE ($1::text IS NULL OR resource>$1) ORDER BY resource" (E.param (E.nullable E.text)) (D.foldlRows collect (Right []) row)
    row = (,) <$> D.column (D.nonNullable D.text) <*> bindingRow
    collect prior (resource, parsed) = do
      page <- prior
      (binding, _) <- parsed >>= checkedBinding (WorkspaceRef (workspaceCoordinate "shikigami.workspace/1") (workspaceCoordinate resource))
      let next = if workspaceLocatorPath binding.storageRoot == storageRoot && length page < 20 then page <> [binding] else page
      length next `seq` pure next

-- | Only the allocator calls this after atomic publication of a complete copy.
-- Comparing the full immutable binding also protects against stale callbacks.
markWorkspaceReadyTx :: WorkspaceBinding -> Transaction (Either WorkspaceError ())
markWorkspaceReadyTx binding = do
  changed <- Tx.statement ((workspaceCoordinateText binding.workspace.resource), binding) readyBinding
  pure (if changed then Right () else Left WorkspaceBindingConflict)

textParam :: E.Value Text
textParam = E.text

insertBinding :: Statement (Text, Text, Text, WorkspaceBinding) ()
insertBinding = preparable "INSERT INTO shikigami.workspace_bindings(assignment_key,resource,workspace_id,binding,state) VALUES($1,$2,$3,$4,'reserved') ON CONFLICT DO NOTHING" (contrazip4 (E.param (E.nonNullable textParam)) (E.param (E.nonNullable textParam)) (E.param (E.nonNullable textParam)) jsonParam) D.noResult

hasCleanup :: Statement Text Bool
hasCleanup = preparable "SELECT EXISTS(SELECT 1 FROM shikigami.workspace_cleanup WHERE resource=$1)" (E.param (E.nonNullable E.text)) (D.singleRow (D.column (D.nonNullable D.bool)))

selectBinding :: Statement Text (Maybe (Either Text (WorkspaceBinding, AllocationState)))
selectBinding = preparable "SELECT binding,state,workspace_id FROM shikigami.workspace_bindings WHERE resource=$1" (E.param (E.nonNullable E.text)) (D.rowMaybe bindingRow)

bindingRow :: D.Row (Either Text (WorkspaceBinding, AllocationState))
bindingRow = assemble <$> jsonRow <*> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)
  where
    assemble value state identifier = do
      binding <- value
      unless (workspaceIdText binding.id == identifier) (Left "workspace identity mismatch")
      allocation <- case state of
        "ready" -> Right Ready
        "reserved" -> Right Reserved
        _ -> Left "unknown workspace allocation state"
      pure (binding, allocation)

readyBinding :: Statement (Text, WorkspaceBinding) Bool
readyBinding = preparable "UPDATE shikigami.workspace_bindings SET state='ready' WHERE resource=$1 AND binding=$2 RETURNING true" (contrazip2 (E.param (E.nonNullable E.text)) jsonParam) (maybe False id <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

jsonRow :: (FromJSON a) => D.Row (Either Text a)
jsonRow = decodeJSON <$> D.column (D.nonNullable D.jsonb)

nullableJSONRow :: (FromJSON a) => D.Row (Either Text (Maybe a))
nullableJSONRow = traverse decodeJSON <$> D.column (D.nullable D.jsonb)

decodeJSON :: (FromJSON a) => Aeson.Value -> Either Text a
decodeJSON value = case Aeson.fromJSON value of
  Aeson.Error err -> Left (Text.pack err)
  Aeson.Success result -> Right result

checkedRead :: Either Text a -> Transaction (Either WorkspaceError a)
checkedRead = \case
  Left _ -> Tx.condemn >> pure (Left WorkspaceBindingConflict)
  Right value -> pure (Right value)

inspectEffectTx :: Text -> Transaction (Either WorkspaceError (Maybe (Text, Text, Maybe FileReceipt)))
inspectEffectTx key = do
  retained <- Tx.statement key selectEffect
  checkedRead (traverse checked retained)
  where
    checked (resource, fingerprint, parsed) = do
      receipt <- parsed
      forM_ receipt \value -> unless (operationIdText value.operationId == key && (workspaceCoordinateText value.fingerprint) == fingerprint && value.generation > initialRevision && validWorkspacePath (workspaceCoordinateText value.path)) (Left "inconsistent retained file receipt")
      pure (resource, fingerprint, receipt)

-- The concrete provider holds the independent workspace lock throughout these
-- checks and its effect. Freeze/transfer must use that same lock before acting.
checkWorkspaceOwnerTx :: WorkspaceBinding -> AgentIdentity -> StateRevision "worker-owner" -> Transaction (Either WorkspaceError ())
checkWorkspaceOwnerTx binding owner epoch = do
  retained <- inspectWorkspaceTx binding.workspace
  control <- Tx.statement (workspaceCoordinateText binding.workspace.resource) lockControl >>= checkedRead . sequence
  pure case (retained, control) of
    (Right (Just (actual, Ready)), Right (Just current)) | actual == binding && current.owner == owner && current.epoch == epoch && current.frozen == AdmissionOpen -> Right ()
    _ -> Left WorkspaceBindingConflict

-- An unresolved effect blocks reuse by another logical operation, including
-- ordinary reads. Only that effect's reconciliation can inspect its target.
checkWorkspaceOperationTx :: WorkspaceBinding -> AgentIdentity -> StateRevision "worker-owner" -> OperationId -> Transaction (Either WorkspaceError ())
checkWorkspaceOperationTx binding owner epoch (operationIdText -> operation) = do
  current <- checkWorkspaceOwnerTx binding owner epoch
  case current of
    Left err -> pure (Left err)
    Right () -> do
      pending <- Tx.statement ((workspaceCoordinateText binding.workspace.resource), operation) pendingOtherEffect
      processes <- Tx.statement (workspaceCoordinateText binding.workspace.resource) pendingProcess
      pure (if pending || processes then Left WorkspaceBindingConflict else Right ())

reserveWorkspaceEffectTx :: WorkspaceBinding -> AgentIdentity -> StateRevision "worker-owner" -> OperationId -> WorkspaceCoordinate "file-fingerprint" -> Transaction (Either WorkspaceError (Maybe FileReceipt))
reserveWorkspaceEffectTx binding owner epoch identifier@(operationIdText -> operation) (workspaceCoordinateText -> fingerprint) = do
  checked <- checkWorkspaceOperationTx binding owner epoch identifier
  case checked of
    Left err -> pure (Left err)
    Right () -> do
      existing <- inspectEffectTx operation
      case existing of
        Right (Just (resource, previous, receipt)) | resource == (workspaceCoordinateText binding.workspace.resource) && previous == fingerprint -> pure (Right receipt)
        Right (Just _) -> pure (Left WorkspaceBindingConflict)
        Left err -> pure (Left err)
        Right Nothing -> do
          pending <- Tx.statement (workspaceCoordinateText binding.workspace.resource) hasPendingEffect
          if pending
            then pure (Left WorkspaceBindingConflict)
            else do
              Tx.statement (operation, (workspaceCoordinateText binding.workspace.resource), fingerprint) insertEffect
              actual <- inspectEffectTx operation
              pure case actual of
                Right (Just (resource, previous, receipt)) | resource == (workspaceCoordinateText binding.workspace.resource) && previous == fingerprint -> Right receipt
                _ -> Left WorkspaceBindingConflict

-- Factual receipt acceptance survives authority revocation. It cannot create a
-- reservation, change identity or release a different operation's uncertainty.
recordWorkspaceReceiptTx :: WorkspaceBinding -> FileReceipt -> Transaction (Either WorkspaceError ())
recordWorkspaceReceiptTx binding receipt
  | receipt.bindingDigest /= workspaceBindingDigest binding || receipt.generation <= initialRevision = pure (Left WorkspaceBindingConflict)
  | otherwise = do
      let operation = operationIdText receipt.operationId
      retained <- inspectEffectTx operation
      case retained of
        Left err -> pure (Left err)
        Right _ -> do
          changed <- Tx.statement (operation, (workspaceCoordinateText binding.workspace.resource), (workspaceCoordinateText receipt.fingerprint), receipt) saveReceipt
          pure (if changed then Right () else Left WorkspaceBindingConflict)

-- Called in the reservation transaction before writing any private intent or
-- repository bytes. A duplicate cannot replace the original actual routing.
registerFileTx :: WorkspaceBinding -> FileRegistration -> Transaction (Either WorkspaceError ())
registerFileTx binding = registerFileForOwnerTx binding binding.request.owner binding.request.epoch

registerFileForOwnerTx :: WorkspaceBinding -> AgentIdentity -> StateRevision "worker-owner" -> FileRegistration -> Transaction (Either WorkspaceError ())
registerFileForOwnerTx binding owner epoch registration = do
  current <- checkWorkspaceOwnerTx binding owner epoch
  let receipt = registration.receipt
      key = operationIdText receipt.operationId
  existing <- inspectEffectTx key
  if current == Right () && validProcessRouting registration.routing && registration.routing.identity == owner && registration.routing.executionId == registration.operation.executionId && registration.operation.operationId == receipt.operationId && receipt.bindingDigest == workspaceBindingDigest binding && receipt.generation > initialRevision && receipt.state == EditPrepared && maybe False (\(resource, fingerprint, _) -> resource == (workspaceCoordinateText binding.workspace.resource) && fingerprint == (workspaceCoordinateText receipt.fingerprint)) (either (const Nothing) id existing)
    then do
      Tx.statement (key, registration) insertFileRegistration
      retained <- inspectRegisteredFileTx receipt.operationId
      pure (if maybe False (\(_, actual, _) -> actual == registration) (either (const Nothing) id retained) then Right () else Left WorkspaceBindingConflict)
    else pure (Left WorkspaceBindingConflict)

inspectRegisteredFileTx :: OperationId -> Transaction (Either WorkspaceError (Maybe (WorkspaceBinding, FileRegistration, Maybe FileReceipt)))
inspectRegisteredFileTx (operationIdText -> key) = Tx.statement key selectRegisteredFile >>= checkedRead . sequence

inspectFilePageTx :: Maybe OperationId -> Transaction (Either WorkspaceError [OperationId])
inspectFilePageTx cursor = Tx.statement (maybe "" operationIdText cursor) selectFilePage >>= checkedRead . sequence

freezeWorkspaceTx :: WorkspaceBinding -> AgentIdentity -> StateRevision "worker-owner" -> Transaction (Either WorkspaceError ())
freezeWorkspaceTx binding owner epoch = do
  checked <- checkWorkspaceOwnerTx binding owner epoch
  case checked of
    Left err -> pure (Left err)
    Right () -> Tx.statement (workspaceCoordinateText binding.workspace.resource) freezeControl >> pure (Right ())

-- | Admission is permanently closed by cleanup or transfer. This state does
-- not suppress factual inspection/recovery of already accepted effects.
data FreezeState = AdmissionOpen | AdmissionFrozen
  deriving stock (Eq, Show)

instance FromJSON FreezeState where
  parseJSON value = (\flag -> if flag then AdmissionFrozen else AdmissionOpen) <$> Aeson.parseJSON value

instance ToJSON FreezeState where
  toJSON state = Aeson.toJSON (state == AdmissionFrozen)

workspaceFrozen :: WorkspaceControl -> Bool
workspaceFrozen control = control.frozen == AdmissionFrozen

data WorkspaceControl = WorkspaceControl {owner :: !AgentIdentity, epoch :: !(StateRevision "worker-owner"), frozen :: !FreezeState}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

-- The IO owner holds the workspace OS lock across conditional control and IO.
-- This locked metadata read is also used to reconcile an existing freeze.
inspectWorkspaceControlTx :: WorkspaceBinding -> Transaction (Either WorkspaceError (Maybe WorkspaceControl))
inspectWorkspaceControlTx binding = do
  actual <- inspectWorkspaceTx binding.workspace
  case actual of
    Left err -> pure (Left err)
    Right (Just (retained, Ready)) | retained == binding -> Tx.statement (workspaceCoordinateText binding.workspace.resource) lockControl >>= checkedRead . sequence
    _ -> pure (Right Nothing)

insertControl :: Statement (Text, AgentIdentity, Integer) ()
insertControl = preparable "INSERT INTO shikigami.workspace_controls(resource,owner,epoch) VALUES($1,$2,$3) ON CONFLICT DO NOTHING" (contrazip3 (E.param (E.nonNullable E.text)) jsonParam (fromInteger >$< E.param (E.nonNullable E.int8))) D.noResult

lockControl :: Statement Text (Maybe (Either Text WorkspaceControl))
lockControl = preparable "SELECT jsonb_build_object('owner',owner,'epoch',epoch,'frozen',frozen) FROM shikigami.workspace_controls WHERE resource=$1 FOR UPDATE" (E.param (E.nonNullable E.text)) (D.rowMaybe (fmap validate jsonRow))
  where
    validate parsed = do
      control <- parsed
      _ <- identityText control.owner
      pure control

freezeControl :: Statement Text ()
freezeControl = preparable "UPDATE shikigami.workspace_controls SET frozen=true WHERE resource=$1" (E.param (E.nonNullable E.text)) D.noResult

selectEffect :: Statement Text (Maybe (Text, Text, Either Text (Maybe FileReceipt)))
selectEffect = preparable "SELECT resource,fingerprint,receipt FROM shikigami.workspace_effects WHERE operation_id=$1 AND kind='file'" (E.param (E.nonNullable E.text)) (D.rowMaybe ((,,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text) <*> nullableJSONRow))

hasPendingEffect :: Statement Text Bool
hasPendingEffect = preparable "SELECT EXISTS(SELECT 1 FROM shikigami.workspace_effects WHERE resource=$1 AND NOT settled)" (E.param (E.nonNullable E.text)) (D.singleRow (D.column (D.nonNullable D.bool)))

insertEffect :: Statement (Text, Text, Text) ()
insertEffect = preparable "INSERT INTO shikigami.workspace_effects(operation_id,resource,fingerprint) VALUES($1,$2,$3) ON CONFLICT DO NOTHING" (contrazip3 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text))) D.noResult

saveReceipt :: Statement (Text, Text, Text, FileReceipt) Bool
saveReceipt = preparable "UPDATE shikigami.workspace_effects SET receipt=$4,settled=($4->>'state' IN ('EditApplied','EditRefused')) WHERE operation_id=$1 AND kind='file' AND resource=$2 AND fingerprint=$3 AND (receipt IS NULL OR receipt=$4 OR (NOT settled AND receipt->>'state'='EditPrepared' AND $4->>'state' IN ('EditApplied','EditRefused') AND receipt-'state'=$4-'state')) RETURNING true" (contrazip4 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)) jsonParam) (maybe False id <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

pendingOtherEffect :: Statement (Text, Text) Bool
pendingOtherEffect = preparable "SELECT EXISTS(SELECT 1 FROM shikigami.workspace_effects WHERE resource=$1 AND operation_id<>$2 AND NOT settled)" (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text))) (D.singleRow (D.column (D.nonNullable D.bool)))

pendingProcess :: Statement Text Bool
pendingProcess = preparable "SELECT EXISTS(SELECT 1 FROM shikigami.workspace_processes WHERE resource=$1 AND NOT settled)" (E.param (E.nonNullable E.text)) (D.singleRow (D.column (D.nonNullable D.bool)))

insertFileRegistration :: Statement (Text, FileRegistration) ()
insertFileRegistration = preparable "INSERT INTO shikigami.workspace_file_registrations(operation_id,registration) VALUES($1,$2) ON CONFLICT DO NOTHING" (contrazip2 (E.param (E.nonNullable E.text)) jsonParam) D.noResult

selectRegisteredFile :: Statement Text (Maybe (Either Text (WorkspaceBinding, FileRegistration, Maybe FileReceipt)))
selectRegisteredFile = preparable "SELECT b.binding,r.registration,e.receipt,e.fingerprint,e.kind,b.state,r.operation_id FROM shikigami.workspace_file_registrations r LEFT JOIN shikigami.workspace_effects e USING(operation_id) LEFT JOIN shikigami.workspace_bindings b ON b.resource=e.resource WHERE r.operation_id=$1" (E.param (E.nonNullable E.text)) (D.rowMaybe row)
  where
    row = assemble <$> nullableJSONRow <*> jsonRow <*> nullableJSONRow <*> nullableText <*> nullableText <*> nullableText <*> D.column (D.nonNullable D.text)
    nullableText = D.column (D.nullable D.text)
    assemble bound registered completed fingerprint kind state operation = do
      binding <- bound >>= maybe (Left "missing binding") Right
      registration <- registered
      receipt <- completed
      let original = registration.receipt
      unless (kind == Just "file" && state == Just "ready" && fingerprint == Just (workspaceCoordinateText original.fingerprint) && original.bindingDigest == workspaceBindingDigest binding && operationIdText original.operationId == operation && original.state == EditPrepared && original.generation > initialRevision && validWorkspacePath (workspaceCoordinateText original.path) && validProcessRouting registration.routing && registration.routing.executionId == registration.operation.executionId && registration.operation.operationId == original.operationId && maybe True (\value -> (value & #state .~ EditPrepared) == original) receipt) (Left "inconsistent file registration")
      pure (binding, registration, receipt)

selectFilePage :: Statement Text [Either Text OperationId]
selectFilePage = preparable "SELECT operation_id FROM shikigami.workspace_file_registrations WHERE operation_id>$1 ORDER BY operation_id LIMIT 20" (E.param (E.nonNullable E.text)) (D.rowList (D.column (D.nonNullable (fmap parseOperationId D.text))))

-- | Retained settlement is proved by complete typed receipts, not by treating
-- unreadable JSON as zero pending work or trusting a denormalized Boolean alone.
workspaceEffectsSettledTx :: WorkspaceBinding -> Transaction (Either WorkspaceError Bool)
workspaceEffectsSettledTx binding = do
  effects <- Tx.statement (workspaceCoordinateText binding.workspace.resource) selectEffectSettlement
  processes <- Tx.statement (workspaceCoordinateText binding.workspace.resource) selectProcessSettlement
  checkedRead ((&&) <$> effects <*> processes)
  where
    selectEffectSettlement = preparable "SELECT operation_id,fingerprint,kind,receipt,settled FROM shikigami.workspace_effects WHERE resource=$1" (E.param (E.nonNullable E.text)) (D.foldlRows effect (Right True) effectRow)
    effectRow = (,,,,) <$> text <*> text <*> text <*> D.column (D.nullable D.jsonb) <*> boolean
    selectProcessSettlement = preparable "SELECT operation_id,fingerprint,record,settled FROM shikigami.workspace_processes WHERE resource=$1" (E.param (E.nonNullable E.text)) (D.foldlRows process (Right True) processRow)
    processRow = (,,,) <$> text <*> text <*> D.column (D.nonNullable D.jsonb) <*> boolean
    text = D.column (D.nonNullable D.text)
    boolean = D.column (D.nonNullable D.bool)
    effect prior (operation, fingerprint, kind, raw, settled) = do
      previous <- prior
      terminal <- case kind of
        "file" -> do
          receipt <- (traverse decodeJSON raw :: Either Text (Maybe FileReceipt))
          case receipt of
            Nothing -> Right False
            Just value -> do
              unless (operationIdText value.operationId == operation && (workspaceCoordinateText value.fingerprint) == fingerprint && value.bindingDigest == workspaceBindingDigest binding && value.generation > initialRevision && validWorkspacePath (workspaceCoordinateText value.path)) (Left "inconsistent file settlement")
              pure (value.state `elem` [EditApplied, EditRefused])
        "git" -> do
          value <- (maybe (Left "missing Git settlement") decodeJSON raw :: Either Text Git.GitRecord)
          unless (Git.validGitRecord value && operationIdText value.operation.operationId == operation && (workspaceCoordinateText value.fingerprint) == fingerprint && value.bindingDigest == workspaceBindingDigest binding) (Left "inconsistent Git settlement")
          pure (value.phase `elem` [Git.GitApplied, Git.GitRefused])
        _ -> Left "unknown workspace effect kind"
      unless (terminal == settled) (Left "inconsistent effect settlement flag")
      let allSettled = previous && terminal
      allSettled `seq` pure allSettled
    process prior (operation, fingerprint, raw, settled) = do
      previous <- prior
      value <- (decodeJSON raw :: Either Text ProcessRecord)
      unless (operationIdText value.operationId == operation && (workspaceCoordinateText value.fingerprint) == fingerprint && value.bindingDigest == workspaceBindingDigest binding && digestText (workspaceCoordinateText value.instructionDigest) && value.generation > initialRevision && validProcessCommand value.command && maybe True validProcessRouting value.routing && value.unit == processUnit value.operationId value.fingerprint) (Left "inconsistent process settlement")
      terminal <- case value.phase of
        ProcessSettled -> case value.receipt of
          Just receipt | validProcessReceipt value receipt -> Right True
          _ -> Left "invalid process settlement receipt"
        ProcessRefused | isNothing value.bootId && isNothing value.invocationId && isNothing value.receipt -> Right True
        ProcessRefused -> Left "invalid prelaunch refusal"
        _ -> Right False
      unless (terminal == settled) (Left "inconsistent process settlement flag")
      let allSettled = previous && terminal
      allSettled `seq` pure allSettled

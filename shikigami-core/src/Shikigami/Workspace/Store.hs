-- | Reserve before filesystem effects. Matching duplicate requests converge;
-- reservation metadata remains immutable after the workspace becomes ready.
module Shikigami.Workspace.Store (reserveWorkspaceTx, inspectWorkspaceTx, markWorkspaceReadyTx, checkWorkspaceOwnerTx, checkWorkspaceOperationTx, reserveWorkspaceEffectTx, recordWorkspaceReceiptTx, freezeWorkspaceTx, registerFileTx, inspectRegisteredFileTx, inspectFilePageTx, WorkspaceControl (..), inspectWorkspaceControlTx) where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (ExecutionRootId (..), OperationId (..))
import Shikigami.Execution.Runner (OperationContext (..))
import Shikigami.Prelude
import Shikigami.WorkerSession.Transfer (WorkspaceRef (..))
import Shikigami.WorkerSession.Types (AssignmentId (..), WorkerSessionId (..))
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.Process (ProcessRouting (..), validProcessRouting)
import Shikigami.Workspace.Provider (FileReceipt (..), FileRegistration (..), ReceiptState (..))
import Shikigami.Workspace.Types
import System.FilePath (isAbsolute, normalise, splitDirectories)

reserveWorkspaceTx :: FilePath -> WorkspaceRequest -> ResolvedRepository -> Transaction (Either WorkspaceError (WorkspaceBinding, AllocationState))
reserveWorkspaceTx storageRoot request repository
  | not valid = pure (Left InvalidWorkspaceRequest)
  | otherwise = do
      Tx.statement (key, resource, binding) insertBinding
      existing <- inspectWorkspaceTx binding.workspace
      retired <- Tx.statement resource hasCleanup
      case existing of
        Just pair@(stored, _) | stored == binding && not retired -> do
          Tx.statement (resource, request.owner, request.epoch) insertControl
          pure (Right pair)
        _ -> pure (Left WorkspaceBindingConflict)
  where
    ExecutionRootId root = request.rootId
    validKey value = not (Text.null value) && Text.length value <= 256 && not (Text.any (== '\0') value)
    validIdentity = either (const False) validKey . identityText
    valid = storageRoot /= "/" && ".." `notElem` splitDirectories storageRoot && isAbsolute storageRoot && normalise storageRoot == storageRoot && not ('\0' `elem` storageRoot) && validKey request.runId && validKey root && validIdentity request.principal && validIdentity request.owner && request.epoch >= 0 && request.epoch < 9223372036854775808 && maybe True (\(session, assignment) -> validKey session.value && validKey assignment.value) request.assignment
    key = versionedDigest "shikigami.workspace-assignment/1" (maybe (toJSON request.runId) toJSON request.assignment)
    resource = Text.drop 7 (versionedDigest "shikigami.workspace-resource/1" (toJSON key))
    binding = WorkspaceBinding request (WorkspaceRef "shikigami.workspace/1" resource) (repositoryIdentity repository) (repositoryBase repository) (repositoryPolicyRevision repository) storageRoot (repositorySource repository)

inspectWorkspaceTx :: WorkspaceRef -> Transaction (Maybe (WorkspaceBinding, AllocationState))
inspectWorkspaceTx ref
  | ref.provider /= "shikigami.workspace/1" = pure Nothing
  | otherwise = Tx.statement ref.resource selectBinding

-- | Only the allocator calls this after atomic publication of a complete copy.
-- Comparing the full immutable binding also protects against stale callbacks.
markWorkspaceReadyTx :: WorkspaceBinding -> Transaction (Either WorkspaceError ())
markWorkspaceReadyTx binding = do
  changed <- Tx.statement (binding.workspace.resource, binding) readyBinding
  pure (if changed then Right () else Left WorkspaceBindingConflict)

textParam :: E.Value Text
textParam = E.text

insertBinding :: Statement (Text, Text, WorkspaceBinding) ()
insertBinding = preparable "INSERT INTO shikigami.workspace_bindings(assignment_key,resource,binding,state) VALUES($1,$2,$3,'reserved') ON CONFLICT DO NOTHING" (contrazip3 (E.param (E.nonNullable textParam)) (E.param (E.nonNullable textParam)) jsonParam) D.noResult

hasCleanup :: Statement Text Bool
hasCleanup = preparable "SELECT EXISTS(SELECT 1 FROM shikigami.workspace_cleanup WHERE resource=$1)" (E.param (E.nonNullable E.text)) (D.singleRow (D.column (D.nonNullable D.bool)))

selectBinding :: Statement Text (Maybe (WorkspaceBinding, AllocationState))
selectBinding = preparable "SELECT binding,state='ready' FROM shikigami.workspace_bindings WHERE resource=$1" (E.param (E.nonNullable E.text)) (D.rowMaybe ((,) <$> jsonRow <*> ((\ready -> if ready then Ready else Reserved) <$> D.column (D.nonNullable D.bool))))

readyBinding :: Statement (Text, WorkspaceBinding) Bool
readyBinding = preparable "UPDATE shikigami.workspace_bindings SET state='ready' WHERE resource=$1 AND binding=$2 RETURNING true" (contrazip2 (E.param (E.nonNullable E.text)) jsonParam) (maybe False id <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

jsonRow :: (FromJSON a) => D.Row a
jsonRow = D.column (D.nonNullable (D.refine decode D.jsonb))
  where
    decode value = case Aeson.fromJSON value of
      Aeson.Error err -> Left (Text.pack err)
      Aeson.Success result -> Right result

-- The concrete provider holds the independent workspace lock throughout these
-- checks and its effect. Freeze/transfer must use that same lock before acting.
checkWorkspaceOwnerTx :: WorkspaceBinding -> AgentIdentity -> Integer -> Transaction (Either WorkspaceError ())
checkWorkspaceOwnerTx binding owner epoch = do
  retained <- inspectWorkspaceTx binding.workspace
  control <- Tx.statement binding.workspace.resource lockControl
  pure case (retained, control) of
    (Just (actual, Ready), Just current) | actual == binding && current.owner == owner && current.epoch == epoch && not current.frozen -> Right ()
    _ -> Left WorkspaceBindingConflict

-- An unresolved effect blocks reuse by another logical operation, including
-- ordinary reads. Only that effect's reconciliation can inspect its target.
checkWorkspaceOperationTx :: WorkspaceBinding -> AgentIdentity -> Integer -> OperationId -> Transaction (Either WorkspaceError ())
checkWorkspaceOperationTx binding owner epoch (OperationId operation) = do
  current <- checkWorkspaceOwnerTx binding owner epoch
  case current of
    Left err -> pure (Left err)
    Right () -> do
      pending <- Tx.statement (binding.workspace.resource, operation) pendingOtherEffect
      processes <- Tx.statement binding.workspace.resource pendingProcess
      pure (if pending || processes then Left WorkspaceBindingConflict else Right ())

reserveWorkspaceEffectTx :: WorkspaceBinding -> AgentIdentity -> Integer -> OperationId -> Text -> Transaction (Either WorkspaceError (Maybe FileReceipt))
reserveWorkspaceEffectTx binding owner epoch (OperationId operation) fingerprint = do
  checked <- checkWorkspaceOperationTx binding owner epoch (OperationId operation)
  case checked of
    Left err -> pure (Left err)
    Right () -> do
      existing <- Tx.statement operation selectEffect
      case existing of
        Just (resource, previous, receipt) | resource == binding.workspace.resource && previous == fingerprint -> pure (Right receipt)
        Just _ -> pure (Left WorkspaceBindingConflict)
        Nothing -> do
          pending <- Tx.statement binding.workspace.resource hasPendingEffect
          if pending
            then pure (Left WorkspaceBindingConflict)
            else do
              Tx.statement (operation, binding.workspace.resource, fingerprint) insertEffect
              actual <- Tx.statement operation selectEffect
              pure case actual of
                Just (resource, previous, receipt) | resource == binding.workspace.resource && previous == fingerprint -> Right receipt
                _ -> Left WorkspaceBindingConflict

-- Factual receipt acceptance survives authority revocation. It cannot create a
-- reservation, change identity or release a different operation's uncertainty.
recordWorkspaceReceiptTx :: WorkspaceBinding -> FileReceipt -> Transaction (Either WorkspaceError ())
recordWorkspaceReceiptTx binding receipt
  | receipt.bindingDigest /= workspaceBindingDigest binding || receipt.generation <= 0 = pure (Left WorkspaceBindingConflict)
  | otherwise = do
      let OperationId operation = receipt.operationId
      changed <- Tx.statement (operation, binding.workspace.resource, receipt.fingerprint, receipt) saveReceipt
      pure (if changed then Right () else Left WorkspaceBindingConflict)

-- Called in the reservation transaction before writing any private intent or
-- repository bytes. A duplicate cannot replace the original actual routing.
registerFileTx :: WorkspaceBinding -> FileRegistration -> Transaction (Either WorkspaceError ())
registerFileTx binding registration = do
  let receipt = registration.receipt
      OperationId key = receipt.operationId
  existing <- Tx.statement key selectEffect
  if validProcessRouting registration.routing && registration.routing.identity == binding.request.owner && registration.routing.executionId == registration.operation.executionId && registration.operation.operationId == receipt.operationId && receipt.bindingDigest == workspaceBindingDigest binding && receipt.generation > 0 && receipt.state == EditPrepared && registration.claimOwner /= "" && maybe False (\(resource, fingerprint, _) -> resource == binding.workspace.resource && fingerprint == receipt.fingerprint) existing
    then do
      Tx.statement (key, registration) insertFileRegistration
      retained <- inspectRegisteredFileTx receipt.operationId
      pure (if maybe False (\(_, actual, _) -> actual == registration) retained then Right () else Left WorkspaceBindingConflict)
    else pure (Left WorkspaceBindingConflict)

inspectRegisteredFileTx :: OperationId -> Transaction (Maybe (WorkspaceBinding, FileRegistration, Maybe FileReceipt))
inspectRegisteredFileTx (OperationId key) = Tx.statement key selectRegisteredFile

inspectFilePageTx :: Maybe OperationId -> Transaction [OperationId]
inspectFilePageTx cursor = Tx.statement (maybe "" (\(OperationId key) -> key) cursor) selectFilePage

freezeWorkspaceTx :: WorkspaceBinding -> AgentIdentity -> Integer -> Transaction (Either WorkspaceError ())
freezeWorkspaceTx binding owner epoch = do
  checked <- checkWorkspaceOwnerTx binding owner epoch
  case checked of
    Left err -> pure (Left err)
    Right () -> Tx.statement binding.workspace.resource freezeControl >> pure (Right ())

data WorkspaceControl = WorkspaceControl {owner :: !AgentIdentity, epoch :: !Integer, frozen :: !Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

-- The IO owner holds the workspace OS lock across conditional control and IO.
-- This locked metadata read is also used to reconcile an existing freeze.
inspectWorkspaceControlTx :: WorkspaceBinding -> Transaction (Maybe WorkspaceControl)
inspectWorkspaceControlTx binding = do
  actual <- inspectWorkspaceTx binding.workspace
  if actual == Just (binding, Ready) then Tx.statement binding.workspace.resource lockControl else pure Nothing

insertControl :: Statement (Text, AgentIdentity, Integer) ()
insertControl = preparable "INSERT INTO shikigami.workspace_controls(resource,owner,epoch) VALUES($1,$2,$3) ON CONFLICT DO NOTHING" (contrazip3 (E.param (E.nonNullable E.text)) jsonParam (fromInteger >$< E.param (E.nonNullable E.int8))) D.noResult

lockControl :: Statement Text (Maybe WorkspaceControl)
lockControl = preparable "SELECT jsonb_build_object('owner',owner,'epoch',epoch,'frozen',frozen) FROM shikigami.workspace_controls WHERE resource=$1 FOR UPDATE" (E.param (E.nonNullable E.text)) (D.rowMaybe jsonRow)

freezeControl :: Statement Text ()
freezeControl = preparable "UPDATE shikigami.workspace_controls SET frozen=true WHERE resource=$1" (E.param (E.nonNullable E.text)) D.noResult

selectEffect :: Statement Text (Maybe (Text, Text, Maybe FileReceipt))
selectEffect = preparable "SELECT resource,fingerprint,receipt FROM shikigami.workspace_effects WHERE operation_id=$1 AND kind='file'" (E.param (E.nonNullable E.text)) (D.rowMaybe ((,,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text) <*> D.column (D.nullable (D.refine decode D.jsonb))))
  where
    decode value = case Aeson.fromJSON value of Aeson.Success result -> Right result; Aeson.Error err -> Left (Text.pack err)

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

selectRegisteredFile :: Statement Text (Maybe (WorkspaceBinding, FileRegistration, Maybe FileReceipt))
selectRegisteredFile = preparable "SELECT b.binding,r.registration,e.receipt FROM shikigami.workspace_file_registrations r JOIN shikigami.workspace_effects e USING(operation_id) JOIN shikigami.workspace_bindings b ON b.resource=e.resource WHERE r.operation_id=$1 AND e.kind='file' AND b.state='ready' AND e.fingerprint=r.registration->'receipt'->>'fingerprint'" (E.param (E.nonNullable E.text)) (D.rowMaybe ((,,) <$> jsonRow <*> jsonRow <*> D.column (D.nullable (D.refine decode D.jsonb))))
  where
    decode value = case Aeson.fromJSON value of Aeson.Success result -> Right result; Aeson.Error err -> Left (Text.pack err)

selectFilePage :: Statement Text [OperationId]
selectFilePage = preparable "SELECT operation_id FROM shikigami.workspace_file_registrations WHERE operation_id>$1 ORDER BY operation_id LIMIT 20" (E.param (E.nonNullable E.text)) (D.rowList (OperationId <$> D.column (D.nonNullable D.text)))

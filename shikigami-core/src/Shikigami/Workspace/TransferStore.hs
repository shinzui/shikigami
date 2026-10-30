-- | Workspace-side handoff facts and successor authority. Allocation and all
-- original effect receipts remain immutable. The IO owner holds the shared OS
-- lock across freeze, proof publication and conditional successor admission.
module Shikigami.Workspace.TransferStore
  ( SessionChild (..),
    lookupSessionChildTx,
    inspectTransferTx,
    beginTransferTx,
    retainFenceTx,
    pendingWorkspaceOperationsTx,
    admitSuccessorTx,
    checkWorkspaceAdmissionTx,
    checkSessionWriteTx,
    currentWorkspaceRequestTx,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip6)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId (..))
import Shikigami.Execution.SelectionRuntime (assignmentIdFor)
import Shikigami.Prelude
import Shikigami.WorkerSession.Transfer
import Shikigami.WorkerSession.Types hiding (assignmentIdFor)
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Types

data SessionChild = SessionChild
  { session :: !WorkerSessionId,
    assignment :: !AssignmentId,
    sequence :: !Integer,
    owner :: !AgentIdentity,
    epoch :: !Integer,
    rootId :: !ExecutionRootId,
    handoff :: !(Maybe HandoffProgress)
  }
  deriving stock (Eq, Generic)

instance Show SessionChild where show _ = "SessionChild <protected>"

-- A trigger payload cannot supply session or assignment authority. A historical
-- child mapping that no longer matches current ownership refuses fallback to a
-- new standalone allocation.
lookupSessionChildTx :: Text -> Transaction (Either WorkspaceError (Maybe SessionChild))
lookupSessionChildTx run = do
  matches <- Tx.statement run selectChild
  pure case matches of
    [] -> Right Nothing
    [(state, binding, message)]
      | state.sessionId == binding.sessionId && message.sessionId == state.sessionId && message.childWorkflowId == Just run && state.phase == Active && state.activeAssignment == Just message.assignmentId && message.phase == Running && message.epoch == state.epoch ->
          Right (Just (SessionChild state.sessionId message.assignmentId message.sequence state.owner state.epoch binding.rootId state.handoff))
    _ -> Left WorkspaceBindingConflict

inspectTransferTx :: WorkspaceBinding -> Integer -> Transaction (Maybe (TransferIntent, Maybe FenceProof))
inspectTransferTx binding epoch = Tx.statement (binding.workspace.resource, epoch) selectTransfer

-- The retained session command is authoritative. No caller can freeze a
-- workspace merely by manufacturing a structurally plausible transfer intent.
beginTransferTx :: WorkspaceBinding -> TransferIntent -> Transaction (Either WorkspaceError (Maybe FenceProof))
beginTransferTx binding intent = do
  control <- Store.inspectWorkspaceControlTx binding
  existing <- inspectTransferTx binding intent.oldEpoch
  case existing of
    Just (original, proof) | original == intent -> pure (Right proof)
    Just _ -> pure (Left WorkspaceBindingConflict)
    Nothing -> do
      session <- retainedTransferTx intent
      let associated = maybe False ((== intent.sessionId) . fst) binding.request.assignment
      if validIntent binding intent && associated && session && control == Just (Store.WorkspaceControl intent.oldOwner intent.oldEpoch False)
        then do
          frozen <- Store.freezeWorkspaceTx binding intent.oldOwner intent.oldEpoch
          case frozen of
            Left err -> pure (Left err)
            Right () -> do
              Tx.statement (binding.workspace.resource, intent.oldEpoch, intent) insertTransfer
              actual <- inspectTransferTx binding intent.oldEpoch
              pure (if actual == Just (intent, Nothing) then Right Nothing else Left WorkspaceBindingConflict)
        else pure (Left WorkspaceBindingConflict)

retainedTransferTx :: TransferIntent -> Transaction Bool
retainedTransferTx intent = do
  row <- Tx.statement (intent.sessionId.value, operationKey intent.operationId) selectSessionTransfer
  pure case row of
    Just (state, binding, actual) -> actual == intent && binding.sessionId == intent.sessionId && binding.rootId == intent.rootId && binding.parentIdentity == intent.actor && binding.objective == intent.objective && state.phase == Transferring && state.owner == intent.oldOwner && state.epoch == intent.oldEpoch && maybe False (\progress -> progress.operationId == intent.operationId && progress.stage /= TransferEstablished) state.handoff
    _ -> False

validIntent :: WorkspaceBinding -> TransferIntent -> Bool
validIntent binding intent = intent.format == 1 && intent.workspace == binding.workspace && intent.rootId == binding.request.rootId && intent.oldEpoch >= binding.request.epoch && intent.newEpoch == intent.oldEpoch + 1 && intent.newEpoch < 9223372036854775808 && intent.oldOwner /= intent.newOwner && intent.actor /= intent.newOwner

-- Only retained settlement of every file/Git/process effect permits a fence.
-- A free OS lock, missing unit or expired claim alone cannot satisfy this query.
retainFenceTx :: WorkspaceBinding -> TransferIntent -> Transaction (Either WorkspaceError FenceProof)
retainFenceTx binding intent = do
  control <- Store.inspectWorkspaceControlTx binding
  existing <- inspectTransferTx binding intent.oldEpoch
  case existing of
    Just (original, Just proof) | original == intent && matchesFence intent proof -> pure (Right proof)
    Just (original, Nothing) | original == intent -> do
      session <- retainedTransferTx intent
      settled <- Tx.statement binding.workspace.resource settledWorkspace
      if control == Just (Store.WorkspaceControl intent.oldOwner intent.oldEpoch True) && session && settled
        then do
          let proof = FenceProof 1 binding.workspace intent.operationId (transferFingerprint intent) intent.oldEpoch intent.newEpoch (versionedDigest "shikigami.workspace-fence/1" (toJSON (workspaceBindingDigest binding, intent)))
          Tx.statement (binding.workspace.resource, intent.oldEpoch, proof) saveFence
          pure (Right proof)
        else pure (Left WorkspaceBindingConflict)
    _ -> pure (Left WorkspaceBindingConflict)

pendingWorkspaceOperationsTx :: WorkspaceBinding -> Transaction [(OperationId, Text)]
pendingWorkspaceOperationsTx binding = Tx.statement binding.workspace.resource pendingOperations

-- The checked session owner has already received its separately owned objective
-- receipt. Only its actual new child can receive this explicit admission. The
-- original allocation, policy, Unix identity and operation history do not move.
admitSuccessorTx :: WorkspaceBinding -> WorkspaceAdmission -> Transaction (Either WorkspaceError ())
admitSuccessorTx binding admission = do
  control <- Store.inspectWorkspaceControlTx binding
  child <- lookupSessionChildTx admission.runId
  case child of
    Right (Just current) | current.owner == admission.owner && current.epoch == admission.epoch && current.rootId == admission.rootId && admission.epoch > binding.request.epoch && admission.assignmentId == assignmentIdFor admission.runId && matchesAdmission binding admission && admission.filePolicy == Just transferableFilePolicy -> case current.handoff of
      Just progress | progress.stage == TransferEstablished && isJust progress.fence && isJust progress.checkpoint -> do
        transferred <- inspectTransferTx binding (admission.epoch - 1)
        case transferred of
          Just (intent, Just proof) | matchesFence intent proof && intent.sessionId == current.session && intent.operationId == progress.operationId && intent.newOwner == current.owner && intent.newEpoch == current.epoch && intent.rootId == current.rootId -> do
            settled <- Tx.statement binding.workspace.resource settledWorkspace
            let old = Store.WorkspaceControl intent.oldOwner intent.oldEpoch True
                new = Store.WorkspaceControl intent.newOwner intent.newEpoch False
            if settled && (control == Just old || control == Just new)
              then do
                Tx.statement (admission.runId, binding.workspace.resource, current.session.value, current.assignment.value, current.sequence, admission) insertAdmission
                stored <- Tx.statement admission.runId selectAdmission
                if stored == Just admission
                  then Tx.statement (binding.workspace.resource, toJSON intent.newOwner, intent.newEpoch) establishControl >> pure (Right ())
                  else pure (Left WorkspaceBindingConflict)
              else pure (Left WorkspaceBindingConflict)
          _ -> pure (Left WorkspaceBindingConflict)
      _ -> pure (Left WorkspaceBindingConflict)
    _ -> pure (Left WorkspaceBindingConflict)

matchesAdmission :: WorkspaceBinding -> WorkspaceAdmission -> Bool
matchesAdmission binding admission = admission.workspace == binding.workspace && admission.bindingDigest == workspaceBindingDigest binding && admission.rootId == binding.request.rootId && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base

checkWorkspaceAdmissionTx :: WorkspaceBinding -> WorkspaceAdmission -> OperationId -> Transaction (Either WorkspaceError ())
checkWorkspaceAdmissionTx binding admission operation = do
  admitted <-
    if admission.runId == binding.request.runId && admission.owner == binding.request.owner && admission.epoch == binding.request.epoch
      then pure True
      else do
        retained <- Tx.statement admission.runId selectAdmission
        child <- lookupSessionChildTx admission.runId
        pure (admission.filePolicy == Just transferableFilePolicy && retained == Just admission && either (const False) (maybe False (\current -> current.owner == admission.owner && current.epoch == admission.epoch && current.rootId == admission.rootId)) child)
  if admitted && matchesAdmission binding admission then Store.checkWorkspaceOperationTx binding admission.owner admission.epoch operation else pure (Left WorkspaceBindingConflict)

-- Consumer-side admission is not a bearer grant. Actual tool providers still
-- validate their protected snapshot, actual claim and fresh exact IO authority.
checkSessionWriteTx :: WorkspaceBinding -> WorkerSessionId -> AgentIdentity -> Integer -> OperationId -> Transaction (Either WorkspaceError ())
checkSessionWriteTx binding session owner epoch operation = do
  retained <- Tx.statement session.value selectSession
  case retained of
    Just (state, bound) | state.sessionId == session && bound.sessionId == session && state.phase `elem` [Idle, Active] && state.owner == owner && state.epoch == epoch && bound.rootId == binding.request.rootId && maybe False ((== session) . fst) binding.request.assignment -> Store.checkWorkspaceOperationTx binding owner epoch operation
    _ -> pure (Left WorkspaceBindingConflict)

-- Cleanup follows the latest accepted owner/run without rewriting allocation.
-- Unknown ownership has no terminal fallback to the original execution.
currentWorkspaceRequestTx :: WorkspaceBinding -> Transaction (Maybe WorkspaceRequest)
currentWorkspaceRequestTx binding = do
  control <- Store.inspectWorkspaceControlTx binding
  case control of
    Just current | current.owner == binding.request.owner && current.epoch == binding.request.epoch -> pure (Just binding.request)
    Just current -> do
      admission <- Tx.statement (binding.workspace.resource, toJSON current.owner, current.epoch) selectCurrentAdmission
      pure (fmap (\(run, session, assignment) -> WorkspaceRequest run (Just (WorkerSessionId session, AssignmentId assignment)) binding.request.rootId current.owner current.owner current.epoch) admission)
    Nothing -> pure Nothing

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

integerParam :: E.Params Integer
integerParam = fromInteger >$< E.param (E.nonNullable E.int8)

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

jsonRow :: (FromJSON a) => D.Row a
jsonRow = D.column (D.nonNullable (D.refine (\value -> case Aeson.fromJSON value of Aeson.Success result -> Right result; Aeson.Error err -> Left (Text.pack err)) D.jsonb))

operationKey :: OperationId -> Text
operationKey (OperationId key) = key

selectChild :: Statement Text [(SessionState, SessionBinding, MessageReceipt)]
selectChild = preparable "SELECT s.state,s.binding,m.state FROM shikigami.worker_session_messages m JOIN shikigami.worker_sessions s USING(session_id) WHERE m.state->>'childWorkflowId'=$1 LIMIT 2" textParam (D.rowList ((,,) <$> jsonRow <*> jsonRow <*> jsonRow))

selectSession :: Statement Text (Maybe (SessionState, SessionBinding))
selectSession = preparable "SELECT state,binding FROM shikigami.worker_sessions WHERE session_id=$1" textParam (D.rowMaybe ((,) <$> jsonRow <*> jsonRow))

selectSessionTransfer :: Statement (Text, Text) (Maybe (SessionState, SessionBinding, TransferIntent))
selectSessionTransfer = preparable "SELECT s.state,s.binding,c.state FROM shikigami.worker_sessions s JOIN shikigami.worker_session_commands c USING(session_id) WHERE s.session_id=$1 AND c.operation_id=$2" (contrazip2 textParam textParam) (D.rowMaybe ((,,) <$> jsonRow <*> jsonRow <*> jsonRow))

selectTransfer :: Statement (Text, Integer) (Maybe (TransferIntent, Maybe FenceProof))
selectTransfer = preparable "SELECT intent,proof FROM shikigami.workspace_transfers WHERE resource=$1 AND old_epoch=$2" (contrazip2 textParam integerParam) (D.rowMaybe ((,) <$> jsonRow <*> D.column (D.nullable (D.refine (\value -> case Aeson.fromJSON value of Aeson.Success result -> Right result; Aeson.Error err -> Left (Text.pack err)) D.jsonb))))

insertTransfer :: Statement (Text, Integer, TransferIntent) ()
insertTransfer = preparable "INSERT INTO shikigami.workspace_transfers(resource,old_epoch,intent) VALUES($1,$2,$3) ON CONFLICT DO NOTHING" (contrazip3 textParam integerParam jsonParam) D.noResult

saveFence :: Statement (Text, Integer, FenceProof) ()
saveFence = preparable "UPDATE shikigami.workspace_transfers SET proof=$3 WHERE resource=$1 AND old_epoch=$2 AND proof IS NULL" (contrazip3 textParam integerParam jsonParam) D.noResult

settledWorkspace :: Statement Text Bool
settledWorkspace = preparable "SELECT NOT EXISTS(SELECT 1 FROM shikigami.workspace_effects WHERE resource=$1 AND NOT settled) AND NOT EXISTS(SELECT 1 FROM shikigami.workspace_processes WHERE resource=$1 AND NOT settled) AND NOT EXISTS(SELECT 1 FROM shikigami.workspace_cleanup WHERE resource=$1)" textParam (D.singleRow (D.column (D.nonNullable D.bool)))

pendingOperations :: Statement Text [(OperationId, Text)]
pendingOperations = preparable "SELECT operation_id,kind FROM (SELECT operation_id,kind FROM shikigami.workspace_effects WHERE resource=$1 AND NOT settled UNION ALL SELECT operation_id,'process' AS kind FROM shikigami.workspace_processes WHERE resource=$1 AND NOT settled) pending ORDER BY operation_id LIMIT 64" textParam (D.rowList ((,) <$> (OperationId <$> D.column (D.nonNullable D.text)) <*> D.column (D.nonNullable D.text)))

establishControl :: Statement (Text, Aeson.Value, Integer) ()
establishControl = preparable "UPDATE shikigami.workspace_controls SET owner=$2,epoch=$3,frozen=false WHERE resource=$1" (contrazip3 textParam (E.param (E.nonNullable E.jsonb)) integerParam) D.noResult

insertAdmission :: Statement (Text, Text, Text, Text, Integer, WorkspaceAdmission) ()
insertAdmission = preparable "INSERT INTO shikigami.workspace_successor_admissions(run_id,resource,session_id,assignment_id,sequence,admission) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING" (contrazip6 textParam textParam textParam textParam integerParam jsonParam) D.noResult

selectAdmission :: Statement Text (Maybe WorkspaceAdmission)
selectAdmission = preparable "SELECT admission FROM shikigami.workspace_successor_admissions WHERE run_id=$1" textParam (D.rowMaybe jsonRow)

selectCurrentAdmission :: Statement (Text, Aeson.Value, Integer) (Maybe (Text, Text, Text))
selectCurrentAdmission = preparable "SELECT run_id,session_id,assignment_id FROM shikigami.workspace_successor_admissions WHERE resource=$1 AND admission->'owner'=$2 AND (admission->>'epoch')::bigint=$3 ORDER BY sequence DESC LIMIT 1" (contrazip3 textParam (E.param (E.nonNullable E.jsonb)) integerParam) (D.rowMaybe ((,,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))

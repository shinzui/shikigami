{-# LANGUAGE DataKinds #-}

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
    checkWorkspaceAdmissionOwnerTx,
    checkSessionWriteTx,
    currentWorkspaceRequestTx,
    successorWorkspaceTx,
    findFollowupWorkspaceTx,
    admitFollowupTx,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip6)
import Control.Applicative (liftA2, liftA3)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Maybe (catMaybes)
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId, operationIdText, parseOperationId)
import Shikigami.Execution.Progress (noPendingReceipts)
import Shikigami.Execution.SelectionRuntime (assignmentIdFor)
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript (executionIdFor)
import Shikigami.Execution.Transcript qualified as Transcript
import Shikigami.Prelude
import Shikigami.StateRevision
import Shikigami.WorkerSession.Transfer
import Shikigami.WorkerSession.Types hiding (assignmentIdFor)
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Types

data SessionChild = SessionChild
  { session :: !WorkerSessionId,
    assignment :: !AssignmentId,
    sequence :: !(StateRevision "worker-message"),
    owner :: !AgentIdentity,
    epoch :: !(StateRevision "worker-owner"),
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
  matches <- Tx.statement () (selectChild run) >>= checkedRead
  pure case matches of
    Right [] -> Right Nothing
    Right [(state, binding, message)]
      | state.sessionId == binding.sessionId && message.sessionId == state.sessionId && message.childWorkflowId == Just run && state.phase == Active && state.activeAssignment == Just message.assignmentId && message.phase == Running && message.epoch == state.epoch ->
          Right (Just (SessionChild state.sessionId message.assignmentId message.sequence state.owner state.epoch binding.rootId state.handoff))
    _ -> Left WorkspaceBindingConflict

inspectTransferTx :: WorkspaceBinding -> StateRevision "worker-owner" -> Transaction (Either WorkspaceError (Maybe (TransferIntent, Maybe FenceProof)))
inspectTransferTx binding epoch = do
  retained <- Tx.statement (binding.workspace.resource, epoch) selectTransfer
  checkedRead do
    parsed <- sequence retained
    case parsed of
      Just pair@(intent, proof)
        | intent.oldEpoch == epoch && validIntent binding intent && maybe True (matchesFence intent) proof -> Right (Just pair)
        | otherwise -> Left "inconsistent retained transfer"
      Nothing -> Right Nothing

-- The retained session command is authoritative. No caller can freeze a
-- workspace merely by manufacturing a structurally plausible transfer intent.
beginTransferTx :: WorkspaceBinding -> TransferIntent -> Transaction (Either WorkspaceError (Maybe FenceProof))
beginTransferTx binding intent = do
  control <- Store.inspectWorkspaceControlTx binding
  existing <- inspectTransferTx binding intent.oldEpoch
  case existing of
    Right (Just (original, proof)) | original == intent -> pure (Right proof)
    Right (Just _) -> pure (Left WorkspaceBindingConflict)
    Left err -> pure (Left err)
    Right Nothing -> do
      session <- retainedTransferTx intent
      let associated = maybe False ((== intent.sessionId) . fst) binding.request.assignment
      if validIntent binding intent && associated && session && control == Right (Just (Store.WorkspaceControl intent.oldOwner intent.oldEpoch False))
        then do
          frozen <- Store.freezeWorkspaceTx binding intent.oldOwner intent.oldEpoch
          case frozen of
            Left err -> pure (Left err)
            Right () -> do
              Tx.statement (binding.workspace.resource, intent.oldEpoch, intent) insertTransfer
              actual <- inspectTransferTx binding intent.oldEpoch
              pure (if actual == Right (Just (intent, Nothing)) then Right Nothing else Left WorkspaceBindingConflict)
        else pure (Left WorkspaceBindingConflict)

retainedTransferTx :: TransferIntent -> Transaction Bool
retainedTransferTx intent = do
  row <- Tx.statement (intent.sessionId.value, operationKey intent.operationId) selectSessionTransfer >>= checkedRead . sequence
  pure case row of
    Right (Just (state, binding, actual)) -> actual == intent && binding.sessionId == intent.sessionId && binding.rootId == intent.rootId && binding.parentIdentity == intent.actor && binding.objective == intent.objective && state.phase == Transferring && state.owner == intent.oldOwner && state.epoch == intent.oldEpoch && maybe False (\progress -> progress.operationId == intent.operationId && progress.stage /= TransferEstablished) state.handoff
    _ -> False

validIntent :: WorkspaceBinding -> TransferIntent -> Bool
validIntent binding intent = intent.format == 1 && intent.workspace == binding.workspace && intent.rootId == binding.request.rootId && intent.oldEpoch >= binding.request.epoch && intent.newEpoch == advanceRevision intent.oldEpoch && revisionNumber intent.newEpoch < 9223372036854775808 && intent.oldOwner /= intent.newOwner && intent.actor /= intent.newOwner

-- Only retained settlement of every file/Git/process effect permits a fence.
-- A free OS lock, missing unit or expired claim alone cannot satisfy this query.
retainFenceTx :: WorkspaceBinding -> TransferIntent -> Transaction (Either WorkspaceError FenceProof)
retainFenceTx binding intent = do
  control <- Store.inspectWorkspaceControlTx binding
  existing <- inspectTransferTx binding intent.oldEpoch
  case existing of
    Right (Just (original, Just proof)) | original == intent && matchesFence intent proof -> pure (Right proof)
    Right (Just (original, Nothing)) | original == intent -> do
      session <- retainedTransferTx intent
      settled <- workspaceSettledTx binding
      if control == Right (Just (Store.WorkspaceControl intent.oldOwner intent.oldEpoch True)) && session && settled == Right True
        then do
          let proof = FenceProof 1 binding.workspace intent.operationId (transferFingerprint intent) intent.oldEpoch intent.newEpoch (versionedDigest "shikigami.workspace-fence/1" (toJSON (workspaceBindingDigest binding, intent)))
          Tx.statement (binding.workspace.resource, intent.oldEpoch, proof) saveFence
          pure (Right proof)
        else pure (Left WorkspaceBindingConflict)
    _ -> pure (Left WorkspaceBindingConflict)

pendingWorkspaceOperationsTx :: WorkspaceBinding -> Transaction (Either WorkspaceError [(OperationId, Text)])
pendingWorkspaceOperationsTx binding = do
  retained <- Tx.statement binding.workspace.resource pendingOperations
  case traverse checked retained of
    Left err -> Tx.condemn >> pure (Left err)
    Right values -> pure (Right values)
  where
    checked (Left _, _) = Left WorkspaceBindingConflict
    checked (Right operation, kind) = Right (operation, kind)

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
        transferred <- maybe (pure (Right Nothing)) (inspectTransferTx binding) (previousRevision admission.epoch)
        case transferred of
          Right (Just (intent, Just proof)) | matchesFence intent proof && intent.sessionId == current.session && intent.operationId == progress.operationId && intent.newOwner == current.owner && intent.newEpoch == current.epoch && intent.rootId == current.rootId -> do
            settled <- workspaceSettledTx binding
            earlier <- priorAdmissionsSettledTx binding current
            let old = Store.WorkspaceControl intent.oldOwner intent.oldEpoch True
                new = Store.WorkspaceControl intent.newOwner intent.newEpoch False
            if settled == Right True && earlier == Right True && (control == Right (Just old) || control == Right (Just new))
              then do
                Tx.statement (admission.runId, binding.workspace.resource, current.session.value, current.assignment.value, current.sequence, admission) insertAdmission
                stored <- inspectAdmissionTx binding admission.runId
                if stored == Right (Just admission)
                  then Tx.statement (binding.workspace.resource, toJSON intent.newOwner, intent.newEpoch) establishControl >> pure (Right ())
                  else pure (Left WorkspaceBindingConflict)
              else pure (Left WorkspaceBindingConflict)
          _ -> pure (Left WorkspaceBindingConflict)
      _ -> pure (Left WorkspaceBindingConflict)
    _ -> pure (Left WorkspaceBindingConflict)

-- Same-owner follow-ups reuse accepted files only after earlier assignments and
-- their execution receipts are terminal. No ownership receipt or epoch change
-- is invented for a subsequent assignment belonging to the same owner.
admitFollowupTx :: WorkspaceBinding -> WorkspaceAdmission -> Transaction (Either WorkspaceError ())
admitFollowupTx binding admission = do
  control <- Store.inspectWorkspaceControlTx binding
  child <- lookupSessionChildTx admission.runId
  case (child, binding.request.assignment) of
    (Right (Just current), Just (session, originalAssignment))
      | current.session == session && isNothing current.handoff && current.sequence > initialRevision && current.owner == binding.request.owner && current.epoch == binding.request.epoch && admission.owner == current.owner && admission.epoch == current.epoch && admission.runId /= binding.request.runId && admission.assignmentId == assignmentIdFor admission.runId && admission.filePolicy == Just transferableFilePolicy && matchesAdmission binding admission -> do
          original <- assignmentTerminalTx session originalAssignment True (executionIdFor (assignmentIdFor binding.request.runId)) current.owner current.rootId
          earlier <- priorAdmissionsSettledTx binding current
          let prior = (&&) <$> original <*> earlier
          settled <- workspaceSettledTx binding
          if prior == Right True && settled == Right True && control == Right (Just (Store.WorkspaceControl current.owner current.epoch False))
            then do
              Tx.statement (admission.runId, binding.workspace.resource, session.value, current.assignment.value, current.sequence, admission) insertAdmission
              actual <- inspectAdmissionTx binding admission.runId
              pure (if actual == Right (Just admission) then Right () else Left WorkspaceBindingConflict)
            else pure (Left WorkspaceBindingConflict)
    _ -> pure (Left WorkspaceBindingConflict)

findFollowupWorkspaceTx :: Text -> SessionChild -> FilePath -> ResolvedRepository -> Transaction (Either WorkspaceError (Maybe WorkspaceBinding))
findFollowupWorkspaceTx run child storage repository = do
  retained <- priorWorkspacesTx child
  pure do
    candidates <- retained
    let matches binding = binding.request.runId /= run && binding.repository == repositoryIdentity repository && binding.base == repositoryBase repository && binding.policyRevision == repositoryPolicyRevision repository && binding.source == repositorySource repository && binding.storageRoot == storage && binding.request.rootId == child.rootId && binding.request.owner == child.owner && binding.request.epoch == child.epoch
    case filter matches candidates of
      [] -> Right Nothing
      [binding] -> Right (Just binding)
      _ -> Left WorkspaceBindingConflict

-- Discovery uses the session's relational assignment coordinates, then asks the
-- binding owner to decode each exact retained origin. A corrupt binding cannot
-- hide by losing one of the JSON fields previously used to find it.
priorWorkspacesTx :: SessionChild -> Transaction (Either WorkspaceError [WorkspaceBinding])
priorWorkspacesTx child = do
  assignments <- Tx.statement (child.session.value, child.sequence) selectPriorAssignments
  retained <- traverse (Store.inspectWorkspaceTx . Store.workspaceRefForAssignment child.session . AssignmentId) assignments
  pure (map fst . catMaybes <$> sequence retained)

matchesAdmission :: WorkspaceBinding -> WorkspaceAdmission -> Bool
matchesAdmission binding admission = admission.workspace == binding.workspace && admission.bindingDigest == workspaceBindingDigest binding && admission.rootId == binding.request.rootId && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base

checkWorkspaceAdmissionTx :: WorkspaceBinding -> WorkspaceAdmission -> OperationId -> Transaction (Either WorkspaceError ())
checkWorkspaceAdmissionTx binding admission operation = do
  current <- checkWorkspaceAdmissionOwnerTx binding admission
  case current of
    Left err -> pure (Left err)
    Right () -> Store.checkWorkspaceOperationTx binding admission.owner admission.epoch operation

-- Launch transitions must validate ownership without treating their own
-- already registered process as an unrelated unsettled process.
checkWorkspaceAdmissionOwnerTx :: WorkspaceBinding -> WorkspaceAdmission -> Transaction (Either WorkspaceError ())
checkWorkspaceAdmissionOwnerTx binding admission = do
  admitted <-
    if admission.runId == binding.request.runId && admission.owner == binding.request.owner && admission.epoch == binding.request.epoch
      then pure True
      else do
        retained <- inspectAdmissionTx binding admission.runId
        child <- lookupSessionChildTx admission.runId
        pure (admission.filePolicy == Just transferableFilePolicy && retained == Right (Just admission) && either (const False) (maybe False (\current -> current.owner == admission.owner && current.epoch == admission.epoch && current.rootId == admission.rootId)) child)
  if admitted && matchesAdmission binding admission then Store.checkWorkspaceOwnerTx binding admission.owner admission.epoch else pure (Left WorkspaceBindingConflict)

-- Consumer-side admission is not a bearer grant. Actual tool providers still
-- validate their protected snapshot, actual claim and fresh exact IO authority.
checkSessionWriteTx :: WorkspaceBinding -> WorkerSessionId -> AgentIdentity -> StateRevision "worker-owner" -> OperationId -> Transaction (Either WorkspaceError ())
checkSessionWriteTx binding session owner epoch operation = do
  retained <- Tx.statement session.value selectSession >>= checkedRead . sequence
  case retained of
    Right (Just (state, bound)) | state.sessionId == session && bound.sessionId == session && state.phase `elem` [Idle, Active] && state.owner == owner && state.epoch == epoch && bound.rootId == binding.request.rootId && maybe False ((== session) . fst) binding.request.assignment -> Store.checkWorkspaceOperationTx binding owner epoch operation
    _ -> pure (Left WorkspaceBindingConflict)

-- Cleanup follows the latest accepted owner/run without rewriting allocation.
-- Unknown ownership has no terminal fallback to the original execution.
currentWorkspaceRequestTx :: WorkspaceBinding -> Transaction (Either WorkspaceError (Maybe WorkspaceRequest))
currentWorkspaceRequestTx binding = do
  control <- Store.inspectWorkspaceControlTx binding
  case control of
    Right (Just current) -> do
      retained <- Tx.statement binding.workspace.resource selectCurrentAdmission >>= checkedRead . sequence
      case retained of
        Left err -> pure (Left err)
        Right admissions
          | any (\(run, _, _, admission) -> run /= admission.runId || not (matchesAdmission binding admission)) admissions -> Tx.condemn >> pure (Left WorkspaceBindingConflict)
          | otherwise ->
              pure
                ( Right case filter (\(_, _, _, admission) -> admission.owner == current.owner && admission.epoch == current.epoch) admissions of
                    (run, session, assignment, _) : _ -> Just (WorkspaceRequest run (Just (WorkerSessionId session, AssignmentId assignment)) binding.request.rootId current.owner current.owner current.epoch)
                    [] | current.owner == binding.request.owner && current.epoch == binding.request.epoch -> Just binding.request
                    _ -> Nothing
                )
    Right Nothing -> pure (Right Nothing)
    Left err -> pure (Left err)

successorWorkspaceTx :: SessionChild -> Transaction (Either WorkspaceError WorkspaceBinding)
successorWorkspaceTx child = case (child.handoff, previousRevision child.epoch) of
  (Just progress, Just previous) | progress.stage == TransferEstablished && isJust progress.fence && isJust progress.checkpoint -> do
    prior <- priorWorkspacesTx child
    case prior of
      Left err -> pure (Left err)
      Right candidates -> do
        retained <- traverse (\binding -> fmap (fmap (\transfer -> (binding, transfer))) <$> inspectTransferTx binding previous) candidates
        pure do
          transfers <- catMaybes <$> sequence retained
          case [(binding, intent, proof) | (binding, (intent, Just proof)) <- transfers, intent.operationId == progress.operationId] of
            [(binding, intent, proof)] | matchesFence intent proof && intent.sessionId == child.session && intent.newOwner == child.owner && intent.newEpoch == child.epoch && intent.rootId == child.rootId && binding.request.rootId == child.rootId && maybe False ((== child.session) . fst) binding.request.assignment -> Right binding
            _ -> Left WorkspaceBindingConflict
  _ -> pure (Left WorkspaceBindingConflict)

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

epochParam :: E.Params (StateRevision "worker-owner")
epochParam = revisionNumber >$< integerParam

sequenceParam :: E.Params (StateRevision "worker-message")
sequenceParam = revisionNumber >$< integerParam

integerParam :: E.Params Integer
integerParam = fromInteger >$< E.param (E.nonNullable E.int8)

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

jsonRow :: (FromJSON a) => D.Row (Either Text a)
jsonRow = decodeJSON <$> D.column (D.nonNullable D.jsonb)

nullableJSONRow :: (FromJSON a) => D.Row (Either Text (Maybe a))
nullableJSONRow = traverse decodeJSON <$> D.column (D.nullable D.jsonb)

decodeJSON :: (FromJSON a) => Aeson.Value -> Either Text a
decodeJSON value = case Aeson.fromJSON value of
  Aeson.Success result -> Right result
  Aeson.Error err -> Left (Text.pack err)

checkedRead :: Either Text a -> Transaction (Either WorkspaceError a)
checkedRead = \case
  Left _ -> Tx.condemn >> pure (Left WorkspaceBindingConflict)
  Right value -> pure (Right value)

operationKey :: OperationId -> Text
operationKey = operationIdText

selectChild :: Text -> Statement () (Either Text [(SessionState, SessionBinding, MessageReceipt)])
selectChild run = preparable "SELECT s.state,s.binding,m.state FROM shikigami.worker_session_messages m JOIN shikigami.worker_sessions s USING(session_id)" E.noParams (D.foldlRows collect (Right []) row)
  where
    row = liftA3 (,,) <$> jsonRow <*> jsonRow <*> jsonRow
    collect prior parsed = do
      matches <- prior
      pair@(state, binding, message) <- parsed
      unless (state.sessionId == binding.sessionId && message.sessionId == state.sessionId) (Left "inconsistent session child attribution")
      -- Unreadable attribution cannot authorize a standalone-allocation
      -- fallback. Keep at most two matches while validating the whole scan.
      let next = if message.childWorkflowId == Just run then take 2 (pair : matches) else matches
      length next `seq` pure next

selectSession :: Statement Text (Maybe (Either Text (SessionState, SessionBinding)))
selectSession = preparable "SELECT state,binding FROM shikigami.worker_sessions WHERE session_id=$1" textParam (D.rowMaybe (liftA2 (,) <$> jsonRow <*> jsonRow))

selectSessionTransfer :: Statement (Text, Text) (Maybe (Either Text (SessionState, SessionBinding, TransferIntent)))
selectSessionTransfer = preparable "SELECT s.state,s.binding,c.state FROM shikigami.worker_sessions s JOIN shikigami.worker_session_commands c USING(session_id) WHERE s.session_id=$1 AND c.operation_id=$2" (contrazip2 textParam textParam) (D.rowMaybe (liftA3 (,,) <$> jsonRow <*> jsonRow <*> jsonRow))

selectTransfer :: Statement (Text, StateRevision "worker-owner") (Maybe (Either Text (TransferIntent, Maybe FenceProof)))
selectTransfer = preparable "SELECT intent,proof FROM shikigami.workspace_transfers WHERE resource=$1 AND old_epoch=$2" (contrazip2 textParam epochParam) (D.rowMaybe (liftA2 (,) <$> jsonRow <*> nullableJSONRow))

insertTransfer :: Statement (Text, StateRevision "worker-owner", TransferIntent) ()
insertTransfer = preparable "INSERT INTO shikigami.workspace_transfers(resource,old_epoch,intent) VALUES($1,$2,$3) ON CONFLICT DO NOTHING" (contrazip3 textParam epochParam jsonParam) D.noResult

saveFence :: Statement (Text, StateRevision "worker-owner", FenceProof) ()
saveFence = preparable "UPDATE shikigami.workspace_transfers SET proof=$3 WHERE resource=$1 AND old_epoch=$2 AND proof IS NULL" (contrazip3 textParam epochParam jsonParam) D.noResult

workspaceSettledTx :: WorkspaceBinding -> Transaction (Either WorkspaceError Bool)
workspaceSettledTx binding = do
  effects <- Store.workspaceEffectsSettledTx binding
  noCleanup <- Tx.statement binding.workspace.resource noCleanupPlan
  pure ((&& noCleanup) <$> effects)

noCleanupPlan :: Statement Text Bool
noCleanupPlan = preparable "SELECT NOT EXISTS(SELECT 1 FROM shikigami.workspace_cleanup WHERE resource=$1)" textParam (D.singleRow (D.column (D.nonNullable D.bool)))

pendingOperations :: Statement Text [(Either Text OperationId, Text)]
pendingOperations = preparable "SELECT operation_id,kind FROM (SELECT operation_id,kind FROM shikigami.workspace_effects WHERE resource=$1 AND NOT settled UNION ALL SELECT operation_id,'process' AS kind FROM shikigami.workspace_processes WHERE resource=$1 AND NOT settled) pending ORDER BY operation_id LIMIT 64" textParam (D.rowList ((,) <$> (parseOperationId <$> D.column (D.nonNullable D.text)) <*> D.column (D.nonNullable D.text)))

establishControl :: Statement (Text, Aeson.Value, StateRevision "worker-owner") ()
establishControl = preparable "UPDATE shikigami.workspace_controls SET owner=$2,epoch=$3,frozen=false WHERE resource=$1" (contrazip3 textParam (E.param (E.nonNullable E.jsonb)) epochParam) D.noResult

insertAdmission :: Statement (Text, Text, Text, Text, StateRevision "worker-message", WorkspaceAdmission) ()
insertAdmission = preparable "INSERT INTO shikigami.workspace_successor_admissions(run_id,resource,session_id,assignment_id,sequence,admission) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING" (contrazip6 textParam textParam textParam textParam sequenceParam jsonParam) D.noResult

selectAdmission :: Statement Text (Maybe (Either Text WorkspaceAdmission))
selectAdmission = preparable "SELECT admission FROM shikigami.workspace_successor_admissions WHERE run_id=$1" textParam (D.rowMaybe jsonRow)

inspectAdmissionTx :: WorkspaceBinding -> Text -> Transaction (Either WorkspaceError (Maybe WorkspaceAdmission))
inspectAdmissionTx binding run = do
  retained <- Tx.statement run selectAdmission
  checkedRead do
    parsed <- sequence retained
    case parsed of
      Just admission | admission.runId /= run || admission.assignmentId /= assignmentIdFor run || not (matchesAdmission binding admission) -> Left "inconsistent retained admission"
      _ -> Right parsed

admissionRow :: D.Row (Either Text (Text, Text, Text, WorkspaceAdmission))
admissionRow = assemble <$> text <*> text <*> text <*> jsonRow
  where
    text = D.column (D.nonNullable D.text)
    assemble run session assignment admission = (\value -> (run, session, assignment, value)) <$> admission

selectCurrentAdmission :: Statement Text [Either Text (Text, Text, Text, WorkspaceAdmission)]
selectCurrentAdmission = preparable "SELECT run_id,session_id,assignment_id,admission FROM shikigami.workspace_successor_admissions WHERE resource=$1 ORDER BY sequence DESC" textParam (D.rowList admissionRow)

selectPriorAssignments :: Statement (Text, StateRevision "worker-message") [Text]
selectPriorAssignments = preparable "SELECT assignment_id FROM shikigami.worker_session_messages WHERE session_id=$1 AND sequence<$2 ORDER BY sequence" (contrazip2 textParam sequenceParam) (D.rowList (D.column (D.nonNullable D.text)))

-- Read exact relational associations before deciding settlement. JSON fields
-- cannot hide a present corrupt message/result/execution behind a SQL join.
assignmentTerminalTx :: WorkerSessionId -> AssignmentId -> Bool -> Transcript.ExecutionId -> AgentIdentity -> ExecutionRootId -> Transaction (Either WorkspaceError Bool)
assignmentTerminalTx session assignment requireResult execution owner root = do
  message <- Tx.statement (session.value, assignment.value) assignmentSettlement >>= checkedRead . sequence
  retained <- Execution.inspectExecutionTx execution
  checkedRead do
    found <- either (const (Left "corrupt assignment receipt")) Right message
    actual <- either (const (Left "corrupt assignment execution")) Right retained
    case (found, actual) of
      (Just (receipt, result), Just (state, binding)) -> do
        unless (receipt.sessionId == session && receipt.assignmentId == assignment && maybe True (== execution) receipt.executionId && binding.identity == owner && binding.rootId == Just root) (Left "inconsistent prior assignment association")
        forM_ result \value -> unless (value.format == 1 && value.sessionId == session && value.assignmentId == assignment) (Left "inconsistent prior result association")
        pure (receipt.phase == AssignmentFinished && (not requireResult || isJust result) && state.phase `elem` [Transcript.Succeeded, Transcript.Failed, Transcript.Cancelled] && state.pendingReceipts == noPendingReceipts && isNothing state.activeOperation)
      _ -> Right False

assignmentSettlement :: Statement (Text, Text) (Maybe (Either Text (MessageReceipt, Maybe ResultReceipt)))
assignmentSettlement = preparable "SELECT m.state,r.state FROM shikigami.worker_session_messages m LEFT JOIN shikigami.worker_session_results r USING(assignment_id) WHERE m.session_id=$1 AND m.assignment_id=$2" (contrazip2 textParam textParam) (D.rowMaybe (liftA2 (,) <$> jsonRow <*> nullableJSONRow))

priorAdmissionsSettledTx :: WorkspaceBinding -> SessionChild -> Transaction (Either WorkspaceError Bool)
priorAdmissionsSettledTx binding child = do
  retained <- Tx.statement (binding.workspace.resource, child.sequence) priorAdmissions >>= checkedRead . sequence
  case retained of
    Left err -> pure (Left err)
    Right rows -> do
      checked <- checkedRead (traverse valid rows)
      case checked of
        Left err -> pure (Left err)
        Right admissions -> do
          states <- traverse (\(session, assignment, admission) -> assignmentTerminalTx session assignment False (executionIdFor admission.assignmentId) admission.owner admission.rootId) admissions
          pure (and <$> sequence states)
  where
    valid (run, session, assignment, admission) = do
      unless (run == admission.runId && admission.assignmentId == assignmentIdFor run && matchesAdmission binding admission) (Left "inconsistent prior workspace admission")
      pure (WorkerSessionId session, AssignmentId assignment, admission)

priorAdmissions :: Statement (Text, StateRevision "worker-message") [Either Text (Text, Text, Text, WorkspaceAdmission)]
priorAdmissions = preparable "SELECT run_id,session_id,assignment_id,admission FROM shikigami.workspace_successor_admissions WHERE resource=$1 AND sequence<$2 ORDER BY sequence" (contrazip2 textParam sequenceParam) (D.rowList admissionRow)

-- | Conditional terminal cleanup, separate from allocation and effect receipts.
-- A pending cleanup freezes admission permanently; no lease or idle session
-- supplies terminal evidence. The IO owner must hold the workspace OS lock.
module Shikigami.Workspace.CleanupStore
  ( CleanupPlan (..),
    inspectCleanupTx,
    prepareCleanupTx,
    completeCleanupTx,
    listWorkspacesTx,
    cleanupEligibleTx,
  )
where

import Contravariant.Extras (contrazip2, contrazip4)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Execution.SelectionRuntime (assignmentIdFor)
import Shikigami.Execution.Transcript (ExecutionId (..), executionIdFor)
import Shikigami.Prelude
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.TransferStore (currentWorkspaceRequestTx)
import Shikigami.Workspace.Types

data CleanupPlan = CleanupPlan
  { bindingDigest :: !Text,
    filesTarget :: !Text,
    scratchTarget :: !Text,
    userId :: !Int,
    ownership :: !(Maybe WorkspaceRequest)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON)

instance ToJSON CleanupPlan where
  toJSON = Aeson.genericToJSON Aeson.defaultOptions {Aeson.omitNothingFields = True}

instance Show CleanupPlan where show _ = "CleanupPlan <protected>"

inspectCleanupTx :: WorkspaceBinding -> Transaction (Either WorkspaceError (Maybe (CleanupPlan, Bool)))
inspectCleanupTx binding = do
  retained <- Tx.statement binding.workspace.resource inspectPlan
  decodeRetained (traverse checked retained)
  where
    checked (value, done) = do
      plan <- decodeJson value
      if validPlan binding plan then Right (plan, done) else Left WorkspaceBindingConflict

prepareCleanupTx :: WorkspaceBinding -> CleanupPlan -> Transaction (Either WorkspaceError Bool)
prepareCleanupTx binding plan
  | not (validPlan binding plan) = pure (Left InvalidWorkspaceRequest)
  | otherwise = do
      retained <- inspectCleanupTx binding
      case retained of
        Left err -> pure (Left err)
        Right (Just (original, done)) | original == plan -> pure (Right done)
        Right (Just _) -> pure (Left WorkspaceBindingConflict)
        Right Nothing -> do
          current <- currentWorkspaceRequestTx binding
          owner <- maybe (pure (Left WorkspaceBindingConflict)) (\request -> Store.checkWorkspaceOwnerTx binding request.owner request.epoch) current
          terminal <- cleanupEligibleTx binding
          case owner of
            Right () | terminal && maybe (current == Just binding.request) (\request -> current == Just request) plan.ownership -> do
              frozen <- maybe (pure (Left WorkspaceBindingConflict)) (\request -> Store.freezeWorkspaceTx binding request.owner request.epoch) current
              case frozen of
                Left err -> pure (Left err)
                Right () -> do
                  Tx.statement (binding.workspace.resource, plan) insertPlan
                  saved <- inspectCleanupTx binding
                  pure (if saved == Right (Just (plan, False)) then Right False else Left WorkspaceBindingConflict)
            _ -> pure (Left WorkspaceBindingConflict)

validPlan :: WorkspaceBinding -> CleanupPlan -> Bool
validPlan binding plan = plan.bindingDigest == workspaceBindingDigest binding && plan.userId >= 0 && plan.userId <= 2147483647 && all target [plan.filesTarget, plan.scratchTarget]
  where
    target value = not (Text.null value) && Text.length value <= 128 && Text.all (\c -> c >= '0' && c <= '9' || c == ':') value

completeCleanupTx :: WorkspaceBinding -> CleanupPlan -> Transaction (Either WorkspaceError ())
completeCleanupTx binding plan = do
  retained <- inspectCleanupTx binding
  case retained of
    Left err -> pure (Left err)
    Right (Just (original, _)) | original == plan -> do
      changed <- Tx.statement (binding.workspace.resource, plan) completePlan
      pure (if changed then Right () else Left WorkspaceBindingConflict)
    _ -> pure (Left WorkspaceBindingConflict)

-- A bounded protected metadata page. Render only public resource/repository/base
-- and cleanup status at the operator boundary, never these local paths.
listWorkspacesTx :: FilePath -> Maybe Text -> Transaction (Either WorkspaceError [WorkspaceBinding])
listWorkspacesTx storageRoot cursor = do
  retained <- Tx.statement (Text.pack storageRoot, cursor) listBindings
  decodeRetained (traverse decodeJson retained)

cleanupEligibleTx :: WorkspaceBinding -> Transaction Bool
cleanupEligibleTx binding = do
  current <- currentWorkspaceRequestTx binding
  case current of
    Nothing -> pure False
    Just request -> do
      let ExecutionId execution = executionIdFor (assignmentIdFor request.runId)
      Tx.statement (binding.workspace.resource, execution, toJSON binding, toJSON request) terminalWorkspace

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

-- Decode owned metadata inside the transaction so an ignored refusal still
-- rolls back earlier writes. SQL and connection failures keep their own path.
decodeJson :: (FromJSON a) => Aeson.Value -> Either WorkspaceError a
decodeJson value = case Aeson.fromJSON value of
  Aeson.Success result -> Right result
  Aeson.Error _ -> Left WorkspaceBindingConflict

decodeRetained :: Either WorkspaceError a -> Transaction (Either WorkspaceError a)
decodeRetained result = do
  case result of Left _ -> Tx.condemn; Right _ -> pure ()
  pure result

jsonRow :: D.Row Aeson.Value
jsonRow = D.column (D.nonNullable D.jsonb)

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

inspectPlan :: Statement Text (Maybe (Aeson.Value, Bool))
inspectPlan = preparable "SELECT plan,complete FROM shikigami.workspace_cleanup WHERE resource=$1" textParam (D.rowMaybe ((,) <$> jsonRow <*> D.column (D.nonNullable D.bool)))

insertPlan :: Statement (Text, CleanupPlan) ()
insertPlan = preparable "INSERT INTO shikigami.workspace_cleanup(resource,plan) VALUES($1,$2) ON CONFLICT DO NOTHING" (contrazip2 textParam jsonParam) D.noResult

completePlan :: Statement (Text, CleanupPlan) Bool
completePlan = preparable "UPDATE shikigami.workspace_cleanup SET complete=true WHERE resource=$1 AND plan=$2 RETURNING true" (contrazip2 textParam jsonParam) (maybe False id <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

listBindings :: Statement (Text, Maybe Text) [Aeson.Value]
listBindings = preparable "SELECT binding FROM shikigami.workspace_bindings WHERE binding->>'storageRoot'=$1 AND ($2::text IS NULL OR resource>$2) ORDER BY resource LIMIT 20" (contrazip2 textParam (E.param (E.nullable E.text))) (D.rowList jsonRow)

-- The retained execution is terminal and receipt-complete, all external effects
-- are settled, and no continuing session sharing this root remains live. A
-- missing execution or missing ownership metadata refuses orphan adoption.
terminalWorkspace :: Statement (Text, Text, Aeson.Value, Aeson.Value) Bool
terminalWorkspace =
  preparable
    "SELECT EXISTS(SELECT 1 FROM shikigami.workspace_bindings w JOIN shikigami.executions e ON e.execution_id=$2 WHERE w.resource=$1 AND w.binding=$3 AND w.state='ready' AND e.binding->'identity'=$4->'owner' AND e.binding->'rootId'=$4->'rootId' AND e.state->>'phase' IN ('Succeeded','Failed','Cancelled') AND COALESCE((e.state->>'pendingReceipts')::bigint,0)=0 AND (e.state->'activeOperation' IS NULL OR e.state->'activeOperation'='null'::jsonb)) AND NOT EXISTS(SELECT 1 FROM shikigami.workspace_effects WHERE resource=$1 AND NOT settled) AND NOT EXISTS(SELECT 1 FROM shikigami.workspace_processes WHERE resource=$1 AND NOT settled) AND NOT EXISTS(SELECT 1 FROM shikigami.worker_sessions s WHERE s.binding->'rootId'=$4->'rootId' AND s.state->>'phase' NOT IN ('Failed','Cancelled'))"
    (contrazip4 textParam textParam (E.param (E.nonNullable E.jsonb)) (E.param (E.nonNullable E.jsonb)))
    (D.singleRow (D.column (D.nonNullable D.bool)))

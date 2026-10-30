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

import Contravariant.Extras (contrazip2, contrazip3)
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
import Shikigami.Workspace.Types

data CleanupPlan = CleanupPlan
  { bindingDigest :: !Text,
    filesTarget :: !Text,
    scratchTarget :: !Text,
    userId :: !Int
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show CleanupPlan where show _ = "CleanupPlan <protected>"

inspectCleanupTx :: WorkspaceBinding -> Transaction (Maybe (CleanupPlan, Bool))
inspectCleanupTx binding = Tx.statement binding.workspace.resource inspectPlan

prepareCleanupTx :: WorkspaceBinding -> CleanupPlan -> Transaction (Either WorkspaceError Bool)
prepareCleanupTx binding plan
  | plan.bindingDigest /= workspaceBindingDigest binding || plan.userId < 0 || plan.userId > 2147483647 || not (all target [plan.filesTarget, plan.scratchTarget]) = pure (Left InvalidWorkspaceRequest)
  | otherwise = do
      retained <- inspectCleanupTx binding
      case retained of
        Just (original, done) | original == plan -> pure (Right done)
        Just _ -> pure (Left WorkspaceBindingConflict)
        Nothing -> do
          owner <- Store.checkWorkspaceOwnerTx binding binding.request.owner binding.request.epoch
          terminal <- cleanupEligibleTx binding
          case owner of
            Right () | terminal -> do
              frozen <- Store.freezeWorkspaceTx binding binding.request.owner binding.request.epoch
              case frozen of
                Left err -> pure (Left err)
                Right () -> do
                  Tx.statement (binding.workspace.resource, plan) insertPlan
                  saved <- inspectCleanupTx binding
                  pure (if saved == Just (plan, False) then Right False else Left WorkspaceBindingConflict)
            _ -> pure (Left WorkspaceBindingConflict)
  where
    target value = not (Text.null value) && Text.length value <= 128 && Text.all (\c -> c >= '0' && c <= '9' || c == ':') value

completeCleanupTx :: WorkspaceBinding -> CleanupPlan -> Transaction (Either WorkspaceError ())
completeCleanupTx binding plan = do
  changed <- Tx.statement (binding.workspace.resource, plan) completePlan
  pure (if changed then Right () else Left WorkspaceBindingConflict)

-- A bounded protected metadata page. Render only public resource/repository/base
-- and cleanup status at the operator boundary, never these local paths.
listWorkspacesTx :: FilePath -> Maybe Text -> Transaction [WorkspaceBinding]
listWorkspacesTx storageRoot cursor = Tx.statement (Text.pack storageRoot, cursor) listBindings

cleanupEligibleTx :: WorkspaceBinding -> Transaction Bool
cleanupEligibleTx binding = do
  let ExecutionId execution = executionIdFor (assignmentIdFor binding.request.runId)
  Tx.statement (binding.workspace.resource, execution, toJSON binding) terminalWorkspace

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

jsonRow :: (FromJSON a) => D.Row a
jsonRow = D.column (D.nonNullable (D.refine (\value -> case Aeson.fromJSON value of Aeson.Success result -> Right result; Aeson.Error err -> Left (Text.pack err)) D.jsonb))

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

inspectPlan :: Statement Text (Maybe (CleanupPlan, Bool))
inspectPlan = preparable "SELECT plan,complete FROM shikigami.workspace_cleanup WHERE resource=$1" textParam (D.rowMaybe ((,) <$> jsonRow <*> D.column (D.nonNullable D.bool)))

insertPlan :: Statement (Text, CleanupPlan) ()
insertPlan = preparable "INSERT INTO shikigami.workspace_cleanup(resource,plan) VALUES($1,$2) ON CONFLICT DO NOTHING" (contrazip2 textParam jsonParam) D.noResult

completePlan :: Statement (Text, CleanupPlan) Bool
completePlan = preparable "UPDATE shikigami.workspace_cleanup SET complete=true WHERE resource=$1 AND plan=$2 RETURNING true" (contrazip2 textParam jsonParam) (maybe False id <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

listBindings :: Statement (Text, Maybe Text) [WorkspaceBinding]
listBindings = preparable "SELECT binding FROM shikigami.workspace_bindings WHERE binding->>'storageRoot'=$1 AND ($2::text IS NULL OR resource>$2) ORDER BY resource LIMIT 20" (contrazip2 textParam (E.param (E.nullable E.text))) (D.rowList jsonRow)

-- The retained execution is terminal and receipt-complete, all external effects
-- are settled, and no continuing session sharing this root remains live. A
-- missing execution or missing ownership metadata refuses orphan adoption.
terminalWorkspace :: Statement (Text, Text, Aeson.Value) Bool
terminalWorkspace =
  preparable
    "SELECT EXISTS(SELECT 1 FROM shikigami.workspace_bindings w JOIN shikigami.executions e ON e.execution_id=$2 WHERE w.resource=$1 AND w.binding=$3 AND w.state='ready' AND e.binding->'identity'=$3->'request'->'owner' AND e.binding->'rootId'=$3->'request'->'rootId' AND e.state->>'phase' IN ('Succeeded','Failed','Cancelled') AND COALESCE((e.state->>'pendingReceipts')::bigint,0)=0 AND (e.state->'activeOperation' IS NULL OR e.state->'activeOperation'='null'::jsonb)) AND NOT EXISTS(SELECT 1 FROM shikigami.workspace_effects WHERE resource=$1 AND NOT settled) AND NOT EXISTS(SELECT 1 FROM shikigami.workspace_processes WHERE resource=$1 AND NOT settled) AND NOT EXISTS(SELECT 1 FROM shikigami.worker_sessions s WHERE s.binding->'rootId'=$3->'request'->'rootId' AND s.state->>'phase' NOT IN ('Failed','Cancelled'))"
    (contrazip3 textParam textParam (E.param (E.nonNullable E.jsonb)))
    (D.singleRow (D.column (D.nonNullable D.bool)))

{-# LANGUAGE DataKinds #-}

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

import Contravariant.Extras (contrazip2)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Shikigami.Execution.Progress (noPendingReceipts)
import Shikigami.Execution.SelectionRuntime (assignmentIdFor)
import Shikigami.Execution.Store qualified as Execution
import Shikigami.Execution.Transcript (executionIdFor)
import Shikigami.Execution.Transcript qualified as Transcript
import Shikigami.Prelude
import Shikigami.WorkerSession.Store qualified as Sessions
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.TransferStore (currentWorkspaceRequestTx)
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value

data CleanupPlan = CleanupPlan
  { bindingDigest :: !(WorkspaceCoordinate "binding-digest"),
    filesTarget :: !(WorkspaceCoordinate "file-target"),
    scratchTarget :: !(WorkspaceCoordinate "file-target"),
    userId :: !(CleanupIdentity),
    ownership :: !(Maybe WorkspaceRequest)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON)

instance ToJSON CleanupPlan where
  toJSON = Aeson.genericToJSON Aeson.defaultOptions {Aeson.omitNothingFields = True}

instance Show CleanupPlan where show _ = "CleanupPlan <protected>"

inspectCleanupTx :: WorkspaceBinding -> Transaction (Either WorkspaceError (Maybe (CleanupPlan, Bool)))
inspectCleanupTx binding = do
  retained <- Tx.statement (workspaceCoordinateText binding.workspace.resource) inspectPlan
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
          owner <- maybe (pure (Left WorkspaceBindingConflict)) (\request -> Store.checkWorkspaceOwnerTx binding request.owner request.epoch) (either (const Nothing) id current)
          terminal <- cleanupEligibleTx binding
          case owner of
            Right () | terminal == Right True && maybe (current == Right (Just binding.request)) (\request -> current == Right (Just request)) plan.ownership -> do
              frozen <- maybe (pure (Left WorkspaceBindingConflict)) (\request -> Store.freezeWorkspaceTx binding request.owner request.epoch) (either (const Nothing) id current)
              case frozen of
                Left err -> pure (Left err)
                Right () -> do
                  Tx.statement ((workspaceCoordinateText binding.workspace.resource), plan) insertPlan
                  saved <- inspectCleanupTx binding
                  pure (if saved == Right (Just (plan, False)) then Right False else Left WorkspaceBindingConflict)
            _ -> pure (Left WorkspaceBindingConflict)

validPlan :: WorkspaceBinding -> CleanupPlan -> Bool
validPlan binding plan = plan.bindingDigest == workspaceBindingDigest binding && cleanupIdentityNumber plan.userId >= 0 && cleanupIdentityNumber plan.userId <= 2147483647 && all target [plan.filesTarget, plan.scratchTarget]
  where
    target claim =
      let value = workspaceCoordinateText claim
       in not (Text.null value) && Text.length value <= 128 && Text.all (\c -> c >= '0' && c <= '9' || c == ':') value

completeCleanupTx :: WorkspaceBinding -> CleanupPlan -> Transaction (Either WorkspaceError ())
completeCleanupTx binding plan = do
  retained <- inspectCleanupTx binding
  case retained of
    Left err -> pure (Left err)
    Right (Just (original, _)) | original == plan -> do
      changed <- Tx.statement ((workspaceCoordinateText binding.workspace.resource), plan) completePlan
      pure (if changed then Right () else Left WorkspaceBindingConflict)
    _ -> pure (Left WorkspaceBindingConflict)

-- A bounded protected metadata page. Render only public resource/repository/base
-- and cleanup status at the operator boundary, never these local paths.
listWorkspacesTx :: FilePath -> Maybe Text -> Transaction (Either WorkspaceError [WorkspaceBinding])
listWorkspacesTx = Store.inspectWorkspaceBindingsTx

cleanupEligibleTx :: WorkspaceBinding -> Transaction (Either WorkspaceError Bool)
cleanupEligibleTx binding = do
  current <- currentWorkspaceRequestTx binding
  case current of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right False)
    Right (Just request) -> do
      let execution = executionIdFor (assignmentIdFor request.runId.unWorkflowId)
      retained <- Store.inspectWorkspaceTx binding.workspace
      executed <- Execution.inspectExecutionTx execution
      sessions <- Sessions.rootSessionsTerminalTx request.rootId
      effects <- Store.workspaceEffectsSettledTx binding
      decodeRetained do
        actual <- retained
        terminalSessions <- either (const (Left WorkspaceBindingConflict)) Right sessions
        settled <- effects
        candidate <- either (const (Left WorkspaceBindingConflict)) Right executed
        pure case candidate of
          Just (state, owner) -> actual == Just (binding, Ready) && owner.identity == request.owner && owner.rootId == Just request.rootId && state.phase `elem` [Transcript.Succeeded, Transcript.Failed, Transcript.Cancelled] && state.pendingReceipts == noPendingReceipts && isNothing state.activeOperation && settled && terminalSessions
          Nothing -> False

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

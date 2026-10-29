-- | Reserve before filesystem effects. Matching duplicate requests converge;
-- reservation metadata remains immutable after the workspace becomes ready.
module Shikigami.Workspace.Store (reserveWorkspaceTx, inspectWorkspaceTx, markWorkspaceReadyTx) where

import Contravariant.Extras (contrazip2, contrazip3)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Agent.Principal (identityText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (ExecutionRootId (..))
import Shikigami.Prelude
import Shikigami.WorkerSession.Transfer (WorkspaceRef (..))
import Shikigami.WorkerSession.Types (AssignmentId (..), WorkerSessionId (..))
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.Types
import System.FilePath (isAbsolute, normalise, splitDirectories)

reserveWorkspaceTx :: FilePath -> WorkspaceRequest -> ResolvedRepository -> Transaction (Either WorkspaceError (WorkspaceBinding, AllocationState))
reserveWorkspaceTx storageRoot request repository
  | not valid = pure (Left InvalidWorkspaceRequest)
  | otherwise = do
      Tx.statement (key, resource, binding) insertBinding
      existing <- inspectWorkspaceTx binding.workspace
      pure case existing of
        Just pair@(stored, _) | stored == binding -> Right pair
        _ -> Left WorkspaceBindingConflict
  where
    ExecutionRootId root = request.rootId
    validKey value = not (Text.null value) && Text.length value <= 256 && not (Text.any (== '\0') value)
    validIdentity = either (const False) validKey . identityText
    valid = storageRoot /= "/" && ".." `notElem` splitDirectories storageRoot && isAbsolute storageRoot && normalise storageRoot == storageRoot && not ('\0' `elem` storageRoot) && validKey request.runId && validKey root && validIdentity request.principal && validIdentity request.owner && request.epoch >= 0 && maybe True (\(session, assignment) -> validKey session.value && validKey assignment.value) request.assignment
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

selectBinding :: Statement Text (Maybe (WorkspaceBinding, AllocationState))
selectBinding = preparable "SELECT binding,state='ready' FROM shikigami.workspace_bindings WHERE resource=$1" (E.param (E.nonNullable E.text)) (D.rowMaybe ((,) <$> jsonRow <*> ((\ready -> if ready then Ready else Reserved) <$> D.column (D.nonNullable D.bool))))

readyBinding :: Statement (Text, WorkspaceBinding) Bool
readyBinding = preparable "UPDATE shikigami.workspace_bindings SET state='ready' WHERE resource=$1 AND binding=$2 RETURNING true" (contrazip2 (E.param (E.nonNullable E.text)) jsonParam) (maybe False id <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

jsonParam :: E.Params WorkspaceBinding
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

jsonRow :: D.Row WorkspaceBinding
jsonRow = D.column (D.nonNullable (D.refine decode D.jsonb))
  where
    decode value = case Aeson.fromJSON value of
      Aeson.Error err -> Left (Text.pack err)
      Aeson.Success result -> Right result

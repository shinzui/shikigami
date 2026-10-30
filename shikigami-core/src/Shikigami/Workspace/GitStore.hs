-- | Commit intent and the single conditional publication transition. Factual
-- settlement preserves the original actual claim after authority is revoked.
module Shikigami.Workspace.GitStore
  ( reserveGitTx,
    prepareGitTx,
    requestGitPublicationTx,
    recordGitAppliedTx,
    markGitUnresolvedTx,
    refuseGitBeforePublicationTx,
    inspectGitTx,
    inspectRegisteredGitTx,
    inspectGitPageTx,
  )
where

import Contravariant.Extras (contrazip3, contrazip4)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Execution.Runner (OperationContext (..))
import Shikigami.Prelude
import Shikigami.Workspace.GitTypes
import Shikigami.Workspace.ProcessStore (inspectProcessTx)
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Types

reserveGitTx :: WorkspaceBinding -> GitRecord -> Transaction (Either WorkspaceError GitRecord)
reserveGitTx binding proposed
  | not (validGitRecord proposed && proposed.phase == GitReserved && proposed.bindingDigest == workspaceBindingDigest binding && proposed.routing.identity == binding.request.owner && proposed.fingerprint == gitFingerprint binding proposed) = pure (Left InvalidWorkspaceRequest)
  | otherwise = do
      available <- Store.checkWorkspaceOperationTx binding binding.request.owner binding.request.epoch proposed.operation.operationId
      case available of
        Left err -> pure (Left err)
        Right () -> do
          existing <- inspectGitTx proposed.operation.operationId
          case existing of
            Just actual | sameReservation actual proposed -> pure (Right actual)
            Just _ -> pure (Left WorkspaceBindingConflict)
            Nothing -> do
              process <- inspectProcessTx proposed.operation.operationId
              case process of
                Just _ -> pure (Left WorkspaceBindingConflict)
                Nothing -> do
                  Tx.statement (key, binding.workspace.resource, proposed.fingerprint, proposed) insertGit
                  retained <- inspectGitTx proposed.operation.operationId
                  pure (maybe (Left WorkspaceBindingConflict) (\actual -> if sameReservation actual proposed then Right actual else Left WorkspaceBindingConflict) retained)
  where
    OperationId key = proposed.operation.operationId

prepareGitTx :: WorkspaceBinding -> GitRecord -> GitCandidate -> Transaction (Either WorkspaceError GitRecord)
prepareGitTx binding expected candidate = do
  checked <- Store.checkWorkspaceOperationTx binding binding.request.owner binding.request.epoch expected.operation.operationId
  if isLeft checked || expected.bindingDigest /= workspaceBindingDigest binding || not (validGitCandidate candidate && candidate.parent == expected.expectedParent)
    then pure (Left WorkspaceBindingConflict)
    else do
      current <- inspectGitTx expected.operation.operationId
      case current of
        Just actual | actual == expected && actual.phase == GitReserved -> save actual (actual & #phase .~ GitPrepared & #candidate .~ Just candidate)
        Just actual | sameOrigin actual expected && actual.phase == GitPrepared && actual.candidate == Just candidate -> pure (Right actual)
        _ -> pure (Left WorkspaceBindingConflict)

-- True consumes the only publication transition. An acknowledgement loss is
-- observation-only; neither another worker nor the same worker receives it twice.
requestGitPublicationTx :: WorkspaceBinding -> GitRecord -> Transaction (Either WorkspaceError Bool)
requestGitPublicationTx binding expected = do
  checked <- Store.checkWorkspaceOperationTx binding binding.request.owner binding.request.epoch expected.operation.operationId
  if isLeft checked || expected.bindingDigest /= workspaceBindingDigest binding
    then pure (Left WorkspaceBindingConflict)
    else do
      current <- inspectGitTx expected.operation.operationId
      case current of
        Just actual | actual == expected && actual.phase == GitPrepared -> fmap (const True) <$> save actual (actual & #phase .~ GitPublishRequested)
        Just actual | sameOrigin actual expected && actual.candidate == expected.candidate && actual.phase `elem` [GitPublishRequested, GitUnresolved, GitApplied] -> pure (Right False)
        _ -> pure (Left WorkspaceBindingConflict)

recordGitAppliedTx :: GitRecord -> Transaction (Either WorkspaceError GitRecord)
recordGitAppliedTx expected = factual expected \actual ->
  case actual.phase of
    GitApplied -> pure (Right actual)
    GitPublishRequested -> save actual (actual & #phase .~ GitApplied)
    GitUnresolved -> save actual (actual & #phase .~ GitApplied)
    _ -> pure (Left WorkspaceBindingConflict)

markGitUnresolvedTx :: GitRecord -> Transaction (Either WorkspaceError GitRecord)
markGitUnresolvedTx expected = factual expected \actual ->
  case actual.phase of
    GitPublishRequested -> save actual (actual & #phase .~ GitUnresolved)
    GitUnresolved -> pure (Right actual)
    GitApplied -> pure (Right actual)
    _ -> pure (Left WorkspaceBindingConflict)

-- This competes with publication while it is still provable no HEAD update was
-- requested. A prepared tree is intent, never evidence of its publication.
refuseGitBeforePublicationTx :: GitRecord -> Transaction (Either WorkspaceError GitRecord)
refuseGitBeforePublicationTx expected = factual expected \actual ->
  if actual == expected && actual.phase `elem` [GitReserved, GitPrepared]
    then save actual (actual & #phase .~ GitRefused)
    else if actual.phase == GitRefused then pure (Right actual) else pure (Left WorkspaceBindingConflict)

inspectGitTx :: OperationId -> Transaction (Maybe GitRecord)
inspectGitTx (OperationId key) = Tx.statement key selectGit

inspectRegisteredGitTx :: OperationId -> Transaction (Maybe (WorkspaceBinding, GitRecord))
inspectRegisteredGitTx (OperationId key) = Tx.statement key selectRegisteredGit

inspectGitPageTx :: Maybe OperationId -> Transaction [OperationId]
inspectGitPageTx cursor = Tx.statement (maybe "" (\(OperationId key) -> key) cursor) selectGitPage

factual :: GitRecord -> (GitRecord -> Transaction (Either WorkspaceError GitRecord)) -> Transaction (Either WorkspaceError GitRecord)
factual expected apply = do
  current <- inspectGitTx expected.operation.operationId
  case current of
    Just actual | validGitRecord expected && sameOrigin actual expected && actual.candidate == expected.candidate -> apply actual
    _ -> pure (Left WorkspaceBindingConflict)

sameReservation :: GitRecord -> GitRecord -> Bool
sameReservation a b = a.operation == b.operation && a.fingerprint == b.fingerprint && a.bindingDigest == b.bindingDigest && a.instructionDigest == b.instructionDigest && a.profileDigest == b.profileDigest && a.target == b.target && a.expectedParent == b.expectedParent && a.routing == b.routing

sameOrigin :: GitRecord -> GitRecord -> Bool
sameOrigin a b = (a & #phase .~ GitReserved & #candidate .~ Nothing) == (b & #phase .~ GitReserved & #candidate .~ Nothing)

save :: GitRecord -> GitRecord -> Transaction (Either WorkspaceError GitRecord)
save previous next
  | not (validGitRecord next && sameOrigin previous next) = pure (Left WorkspaceBindingConflict)
  | otherwise = do
      let OperationId key = previous.operation.operationId
      changed <- Tx.statement (key, previous, next) updateGit
      pure (if changed then Right next else Left WorkspaceBindingConflict)

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

jsonRow :: (FromJSON a) => D.Row a
jsonRow = D.column (D.nonNullable (D.refine decode D.jsonb))
  where
    decode value = case Aeson.fromJSON value of Aeson.Success result -> Right result; Aeson.Error err -> Left (Text.pack err)

insertGit :: Statement (Text, Text, Text, GitRecord) ()
insertGit = preparable "INSERT INTO shikigami.workspace_effects(operation_id,resource,fingerprint,kind,receipt) VALUES($1,$2,$3,'git',$4) ON CONFLICT DO NOTHING" (contrazip4 textParam textParam textParam jsonParam) D.noResult

selectGit :: Statement Text (Maybe GitRecord)
selectGit = preparable "SELECT receipt FROM shikigami.workspace_effects WHERE operation_id=$1 AND kind='git' FOR UPDATE" textParam (D.rowMaybe jsonRow)

selectRegisteredGit :: Statement Text (Maybe (WorkspaceBinding, GitRecord))
selectRegisteredGit = preparable "SELECT b.binding,e.receipt FROM shikigami.workspace_effects e JOIN shikigami.workspace_bindings b ON b.resource=e.resource WHERE e.operation_id=$1 AND e.kind='git' AND b.state='ready'" textParam (D.rowMaybe ((,) <$> jsonRow <*> jsonRow))

selectGitPage :: Statement Text [OperationId]
selectGitPage = preparable "SELECT operation_id FROM shikigami.workspace_effects WHERE kind='git' AND operation_id>$1 ORDER BY operation_id LIMIT 64" textParam (D.rowList (OperationId <$> D.column (D.nonNullable D.text)))

updateGit :: Statement (Text, GitRecord, GitRecord) Bool
updateGit = preparable "UPDATE shikigami.workspace_effects SET receipt=$3,settled=($3->>'phase' IN ('GitApplied','GitRefused')) WHERE operation_id=$1 AND kind='git' AND receipt=$2 RETURNING true" (contrazip3 textParam jsonParam jsonParam) (maybe False id <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

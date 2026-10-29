-- | Launch intent precedes systemd IO. A duplicate never receives another
-- launch grant; factual observations/receipts remain writable after revocation.
module Shikigami.Workspace.ProcessStore
  ( reserveProcessTx,
    requestProcessLaunchTx,
    observeProcessInvocationTx,
    recordProcessReceiptTx,
    refuseReservedProcessTx,
    markProcessUnresolvedTx,
    inspectProcessTx,
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
import Shikigami.Prelude
import Shikigami.Workspace.Process
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.Types

reserveProcessTx :: WorkspaceBinding -> ProcessRecord -> Transaction (Either WorkspaceError ProcessRecord)
reserveProcessTx binding proposed
  | not valid = pure (Left InvalidWorkspaceRequest)
  | otherwise = do
      owner <- Store.checkWorkspaceOwnerTx binding binding.request.owner binding.request.epoch
      case owner of
        Left err -> pure (Left err)
        Right () -> do
          existing <- inspectProcessTx proposed.operationId
          case existing of
            Just actual | sameReservation actual proposed -> pure (Right actual)
            Just _ -> pure (Left WorkspaceBindingConflict)
            Nothing -> do
              available <- Store.checkWorkspaceOperationTx binding binding.request.owner binding.request.epoch proposed.operationId
              fileOperation <- Tx.statement key hasFileOperation
              case available of
                Right () | not fileOperation -> do
                  Tx.statement (key, binding.workspace.resource, proposed.fingerprint, proposed) insertProcess
                  retained <- inspectProcessTx proposed.operationId
                  pure (maybe (Left WorkspaceBindingConflict) (\actual -> if sameReservation actual proposed then Right actual else Left WorkspaceBindingConflict) retained)
                _ -> pure (Left WorkspaceBindingConflict)
  where
    OperationId key = proposed.operationId
    valid = proposed.bindingDigest == workspaceBindingDigest binding && digestText proposed.instructionDigest && digestText proposed.fingerprint && bounded key && bounded proposed.claimOwner && proposed.generation > 0 && validProcessCommand proposed.command && proposed.unit == processUnit proposed.operationId proposed.fingerprint && proposed.phase == ProcessReserved && isNothing proposed.bootId && isNothing proposed.invocationId && isNothing proposed.receipt
    sameReservation actual candidate = actual.operationId == candidate.operationId && actual.bindingDigest == candidate.bindingDigest && actual.instructionDigest == candidate.instructionDigest && actual.fingerprint == candidate.fingerprint && actual.command == candidate.command && actual.unit == candidate.unit

-- True is the single committed transition that may issue the launch request.
-- Losing its acknowledgement intentionally does not permit a second launch.
-- It is not authority: the supervisor must independently recheck the actual
-- attempt claim, lifecycle, deadline and fresh exact action before protected IO.
requestProcessLaunchTx :: WorkspaceBinding -> ProcessRecord -> Text -> Transaction (Either WorkspaceError Bool)
requestProcessLaunchTx binding expected boot
  | expected.bindingDigest /= workspaceBindingDigest binding || not (hostIdentity boot) = pure (Left WorkspaceBindingConflict)
  | otherwise = do
      owner <- Store.checkWorkspaceOwnerTx binding binding.request.owner binding.request.epoch
      if isLeft owner
        then pure (Left WorkspaceBindingConflict)
        else do
          current <- inspectProcessTx expected.operationId
          case current of
            Just actual | actual == expected && actual.phase == ProcessReserved -> do
              save actual (actual & #phase .~ ProcessLaunchRequested & #bootId .~ Just boot) <&> fmap (const True)
            Just actual | actual.phase `elem` [ProcessLaunchRequested, ProcessRunning, ProcessUnresolved, ProcessSettled] && actual.fingerprint == expected.fingerprint && actual.bindingDigest == expected.bindingDigest && actual.bootId == Just boot -> pure (Right False)
            _ -> pure (Left WorkspaceBindingConflict)
  where
    isLeft (Left _) = True; isLeft _ = False

observeProcessInvocationTx :: ProcessRecord -> Text -> Text -> Transaction (Either WorkspaceError ())
observeProcessInvocationTx expected boot invocation
  | not (hostIdentity boot && hostIdentity invocation) = pure (Left WorkspaceBindingConflict)
  | otherwise = do
      current <- inspectProcessTx expected.operationId
      case current of
        Just actual | actual.fingerprint == expected.fingerprint && actual.bindingDigest == expected.bindingDigest && actual.unit == expected.unit && actual.bootId == Just boot && maybe True (== invocation) actual.invocationId ->
          case actual.phase of
            ProcessLaunchRequested -> save actual (actual & #phase .~ ProcessRunning & #invocationId .~ Just invocation)
            ProcessUnresolved -> save actual (actual & #phase .~ ProcessRunning & #invocationId .~ Just invocation)
            _ | actual.invocationId == Just invocation -> pure (Right ())
            _ -> pure (Left WorkspaceBindingConflict)
        _ -> pure (Left WorkspaceBindingConflict)

recordProcessReceiptTx :: ProcessReceipt -> Transaction (Either WorkspaceError ())
recordProcessReceiptTx receipt = do
  current <- inspectProcessTx receipt.operationId
  case current of
    Just actual | validProcessReceipt actual receipt -> case actual.receipt of
      Just previous | previous == receipt -> pure (Right ())
      Nothing | actual.phase `elem` [ProcessRunning, ProcessUnresolved] -> save actual (actual & #phase .~ ProcessSettled & #receipt .~ Just receipt)
      _ -> pure (Left WorkspaceBindingConflict)
    _ -> pure (Left WorkspaceBindingConflict)

markProcessUnresolvedTx :: ProcessRecord -> Transaction (Either WorkspaceError ())
markProcessUnresolvedTx expected = do
  current <- inspectProcessTx expected.operationId
  case current of
    Just actual
      | actual.fingerprint == expected.fingerprint && actual.bindingDigest == expected.bindingDigest && actual.unit == expected.unit && actual.phase /= ProcessReserved ->
          if actual.phase `elem` [ProcessSettled, ProcessRefused] then pure (Right ()) else save actual (actual & #phase .~ ProcessUnresolved)
    _ -> pure (Left WorkspaceBindingConflict)

-- A reservation with no committed launch grant proves no provider launch was
-- requested. It can settle as refused without inventing an invocation receipt.
-- This competes atomically with the only transition allowed to issue a launch.
refuseReservedProcessTx :: ProcessRecord -> Transaction (Either WorkspaceError ())
refuseReservedProcessTx expected = do
  current <- inspectProcessTx expected.operationId
  case current of
    Just actual | actual == expected && actual.phase == ProcessReserved -> save actual (actual & #phase .~ ProcessRefused)
    Just actual | actual.phase == ProcessRefused && actual.fingerprint == expected.fingerprint && actual.bindingDigest == expected.bindingDigest -> pure (Right ())
    _ -> pure (Left WorkspaceBindingConflict)

inspectProcessTx :: OperationId -> Transaction (Maybe ProcessRecord)
inspectProcessTx (OperationId key) = Tx.statement key selectProcess

save :: ProcessRecord -> ProcessRecord -> Transaction (Either WorkspaceError ())
save expected changed = do
  let OperationId key = expected.operationId
  accepted <- Tx.statement (key, expected, changed) updateProcess
  pure (if accepted then Right () else Left WorkspaceBindingConflict)

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

selectProcess :: Statement Text (Maybe ProcessRecord)
selectProcess = preparable "SELECT record FROM shikigami.workspace_processes WHERE operation_id=$1 FOR UPDATE" textParam (D.rowMaybe (D.column (D.nonNullable (D.refine decode D.jsonb))))
  where
    decode value = case Aeson.fromJSON value of Aeson.Success record -> Right record; Aeson.Error err -> Left (Text.pack err)

insertProcess :: Statement (Text, Text, Text, ProcessRecord) ()
insertProcess = preparable "INSERT INTO shikigami.workspace_processes(operation_id,resource,fingerprint,record) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING" (contrazip4 textParam textParam textParam jsonParam) D.noResult

updateProcess :: Statement (Text, ProcessRecord, ProcessRecord) Bool
updateProcess = preparable "UPDATE shikigami.workspace_processes SET record=$3,settled=($3->>'phase' IN ('ProcessSettled','ProcessRefused')) WHERE operation_id=$1 AND record=$2 RETURNING true" (contrazip3 textParam jsonParam jsonParam) (maybe False id <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

hasFileOperation :: Statement Text Bool
hasFileOperation = preparable "SELECT EXISTS(SELECT 1 FROM shikigami.workspace_effects WHERE operation_id=$1)" textParam (D.singleRow (D.column (D.nonNullable D.bool)))

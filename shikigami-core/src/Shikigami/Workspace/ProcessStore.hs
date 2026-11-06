{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ViewPatterns #-}

-- | Launch intent precedes systemd IO. A duplicate never receives another
-- launch grant; factual observations/receipts remain writable after revocation.
module Shikigami.Workspace.ProcessStore
  ( module Shikigami.Workspace.ProcessObservation,
    reserveProcessTx,
    reserveAdmittedProcessTx,
    requestAdmittedProcessLaunchTx,
    requestProcessLaunchTx,
    observeProcessInvocationTx,
    recordProcessReceiptTx,
    refuseReservedProcessTx,
    markProcessUnresolvedTx,
    inspectProcessTx,
    inspectRegisteredProcessTx,
    inspectProcessPageTx,
  )
where

import Contravariant.Extras (contrazip3, contrazip4)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Execution.Identity (OperationId, operationIdText, parseOperationId)
import Shikigami.Prelude
import Shikigami.StateRevision
import Shikigami.Workspace.Instructions (WorkspaceAdmission (..))
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessObservation
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Store qualified as Store
import Shikigami.Workspace.TransferStore qualified as Transfers
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value

reserveProcessTx :: WorkspaceBinding -> ProcessRecord -> Transaction (Either WorkspaceError ProcessRecord)
reserveProcessTx binding = reserveProcessFor (Store.checkWorkspaceOwnerTx binding binding.request.owner binding.request.epoch) (Store.checkWorkspaceOperationTx binding binding.request.owner binding.request.epoch) binding

reserveAdmittedProcessTx :: WorkspaceBinding -> WorkspaceAdmission -> ProcessRecord -> Transaction (Either WorkspaceError ProcessRecord)
reserveAdmittedProcessTx binding admission = reserveProcessFor (Transfers.checkWorkspaceAdmissionOwnerTx binding admission) (Transfers.checkWorkspaceAdmissionTx binding admission) binding

reserveProcessFor :: Transaction (Either WorkspaceError ()) -> (OperationId -> Transaction (Either WorkspaceError ())) -> WorkspaceBinding -> ProcessRecord -> Transaction (Either WorkspaceError ProcessRecord)
reserveProcessFor checkOwner checkOperation binding proposed
  | not valid = pure (Left InvalidWorkspaceRequest)
  | otherwise = do
      owner <- checkOwner
      case owner of
        Left err -> pure (Left err)
        Right () -> do
          existing <- inspectProcessTx proposed.operationId
          case existing of
            Left err -> pure (Left err)
            Right (Just actual) | sameReservation actual proposed -> pure (Right actual)
            Right (Just _) -> pure (Left WorkspaceBindingConflict)
            Right Nothing -> do
              available <- checkOperation proposed.operationId
              fileOperation <- Tx.statement key hasFileOperation
              case available of
                Right () | not fileOperation -> do
                  Tx.statement (key, workspaceCoordinateText binding.workspace.resource, workspaceCoordinateText proposed.fingerprint, proposed) insertProcess
                  retained <- inspectProcessTx proposed.operationId
                  pure (retained >>= maybe (Left WorkspaceBindingConflict) (\actual -> if sameReservation actual proposed then Right actual else Left WorkspaceBindingConflict))
                _ -> pure (Left WorkspaceBindingConflict)
  where
    key = operationIdText proposed.operationId
    valid = proposed.bindingDigest == workspaceBindingDigest binding && digestText (workspaceCoordinateText proposed.instructionDigest) && digestText (workspaceCoordinateText proposed.fingerprint) && bounded key && proposed.generation > initialRevision && validProcessCommand proposed.command && maybe True validProcessRouting proposed.routing && proposed.unit == processUnit proposed.operationId proposed.fingerprint && proposed.phase == ProcessReserved && isNothing proposed.bootId && isNothing proposed.invocationId && isNothing proposed.receipt
    sameReservation actual candidate = actual.operationId == candidate.operationId && actual.bindingDigest == candidate.bindingDigest && actual.instructionDigest == candidate.instructionDigest && actual.fingerprint == candidate.fingerprint && actual.command == candidate.command && actual.unit == candidate.unit && actual.routing == candidate.routing

-- True is the single committed transition that may issue the launch request.
-- Losing its acknowledgement intentionally does not permit a second launch.
-- It is not authority: the supervisor must independently recheck the actual
-- attempt claim, lifecycle, deadline and fresh exact action before protected IO.
requestProcessLaunchTx :: WorkspaceBinding -> ProcessRecord -> WorkspaceCoordinate "boot-id" -> Transaction (Either WorkspaceError Bool)
requestProcessLaunchTx binding = requestProcessLaunchFor (Store.checkWorkspaceOwnerTx binding binding.request.owner binding.request.epoch) binding

requestAdmittedProcessLaunchTx :: WorkspaceBinding -> WorkspaceAdmission -> ProcessRecord -> WorkspaceCoordinate "boot-id" -> Transaction (Either WorkspaceError Bool)
requestAdmittedProcessLaunchTx binding admission = requestProcessLaunchFor (Transfers.checkWorkspaceAdmissionOwnerTx binding admission) binding

requestProcessLaunchFor :: Transaction (Either WorkspaceError ()) -> WorkspaceBinding -> ProcessRecord -> WorkspaceCoordinate "boot-id" -> Transaction (Either WorkspaceError Bool)
requestProcessLaunchFor checkOwner binding expected boot
  | expected.bindingDigest /= workspaceBindingDigest binding || not (hostIdentity (workspaceCoordinateText boot)) = pure (Left WorkspaceBindingConflict)
  | otherwise = do
      owner <- checkOwner
      if isLeft owner
        then pure (Left WorkspaceBindingConflict)
        else do
          current <- inspectProcessTx expected.operationId
          case current of
            Left err -> pure (Left err)
            Right (Just actual) | actual == expected && actual.phase == ProcessReserved -> do
              save actual (actual & #phase .~ ProcessLaunchRequested & #bootId .~ Just boot) <&> fmap (const True)
            Right (Just actual) | actual.phase `elem` [ProcessLaunchRequested, ProcessRunning, ProcessUnresolved, ProcessSettled] && actual.fingerprint == expected.fingerprint && actual.bindingDigest == expected.bindingDigest && actual.bootId == Just boot -> pure (Right False)
            Right _ -> pure (Left WorkspaceBindingConflict)
  where
    isLeft (Left _) = True; isLeft _ = False

observeProcessInvocationTx :: ProcessRecord -> WorkspaceCoordinate "boot-id" -> WorkspaceCoordinate "invocation-id" -> Transaction (Either WorkspaceError ())
observeProcessInvocationTx expected boot invocation
  | not (hostIdentity (workspaceCoordinateText boot) && hostIdentity (workspaceCoordinateText invocation)) = pure (Left WorkspaceBindingConflict)
  | otherwise = do
      current <- inspectProcessTx expected.operationId
      case current of
        Left err -> pure (Left err)
        Right (Just actual) | actual.fingerprint == expected.fingerprint && actual.bindingDigest == expected.bindingDigest && actual.unit == expected.unit && actual.bootId == Just boot && maybe True (== invocation) actual.invocationId ->
          case actual.phase of
            ProcessLaunchRequested -> save actual (actual & #phase .~ ProcessRunning & #invocationId .~ Just invocation)
            ProcessUnresolved -> save actual (actual & #phase .~ ProcessRunning & #invocationId .~ Just invocation)
            _ | actual.invocationId == Just invocation -> pure (Right ())
            _ -> pure (Left WorkspaceBindingConflict)
        Right _ -> pure (Left WorkspaceBindingConflict)

recordProcessReceiptTx :: ProcessReceipt -> Transaction (Either WorkspaceError ())
recordProcessReceiptTx receipt = do
  current <- inspectProcessTx receipt.operationId
  case current of
    Left err -> pure (Left err)
    Right (Just actual) | validProcessReceipt actual receipt -> case actual.receipt of
      Just previous | previous == receipt -> pure (Right ())
      Nothing | actual.phase `elem` [ProcessRunning, ProcessUnresolved] -> save actual (actual & #phase .~ ProcessSettled & #receipt .~ Just receipt)
      _ -> pure (Left WorkspaceBindingConflict)
    Right _ -> pure (Left WorkspaceBindingConflict)

markProcessUnresolvedTx :: ProcessRecord -> Transaction (Either WorkspaceError ())
markProcessUnresolvedTx expected = do
  current <- inspectProcessTx expected.operationId
  case current of
    Left err -> pure (Left err)
    Right (Just actual)
      | actual.fingerprint == expected.fingerprint && actual.bindingDigest == expected.bindingDigest && actual.unit == expected.unit && actual.phase /= ProcessReserved ->
          if actual.phase `elem` [ProcessSettled, ProcessRefused] then pure (Right ()) else save actual (actual & #phase .~ ProcessUnresolved)
    Right _ -> pure (Left WorkspaceBindingConflict)

-- A reservation with no committed launch grant proves no provider launch was
-- requested. It can settle as refused without inventing an invocation receipt.
-- This competes atomically with the only transition allowed to issue a launch.
refuseReservedProcessTx :: ProcessRecord -> Transaction (Either WorkspaceError ())
refuseReservedProcessTx expected = do
  current <- inspectProcessTx expected.operationId
  case current of
    Left err -> pure (Left err)
    Right (Just actual) | actual == expected && actual.phase == ProcessReserved -> save actual (actual & #phase .~ ProcessRefused)
    Right (Just actual) | actual.phase == ProcessRefused && actual.fingerprint == expected.fingerprint && actual.bindingDigest == expected.bindingDigest -> pure (Right ())
    Right _ -> pure (Left WorkspaceBindingConflict)

inspectProcessTx :: OperationId -> Transaction (Either WorkspaceError (Maybe ProcessRecord))
inspectProcessTx (operationIdText -> key) = readRows key selectProcess

-- Factual recovery derives the provider directory from the immutable database
-- association, never a path supplied by a worker or socket request.
inspectRegisteredProcessTx :: OperationId -> Transaction (Either WorkspaceError (Maybe (WorkspaceBinding, ProcessRecord)))
inspectRegisteredProcessTx (operationIdText -> key) = readRows key selectRegisteredProcess

-- Bounded keyset scan for the independent factual owner. Advancing past an
-- unresolved registration prevents it from starving later receipts. Include
-- settled rows: a crash can separate receipt persistence from acknowledgement.
-- A complete sweep is safe to repeat; publication is independently idempotent.
inspectProcessPageTx :: Maybe OperationId -> Transaction [OperationId]
inspectProcessPageTx cursor = Tx.statement (maybe "" operationIdText cursor) selectProcessPage

save :: ProcessRecord -> ProcessRecord -> Transaction (Either WorkspaceError ())
save expected changed = do
  let key = operationIdText expected.operationId
  accepted <- Tx.statement (key, expected, changed) updateProcess
  pure (if accepted then Right () else Left WorkspaceBindingConflict)

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

selectProcess :: Statement Text (Maybe (Either () ProcessRecord))
selectProcess = preparable "SELECT record FROM shikigami.workspace_processes WHERE operation_id=$1 FOR UPDATE" textParam (D.rowMaybe jsonColumn)

selectRegisteredProcess :: Statement Text (Maybe (Either () (WorkspaceBinding, ProcessRecord)))
selectRegisteredProcess = preparable "SELECT b.binding,p.record FROM shikigami.workspace_processes p JOIN shikigami.workspace_bindings b ON b.resource=p.resource WHERE p.operation_id=$1 AND b.state='ready'" textParam (D.rowMaybe ((\binding record -> (,) <$> binding <*> record) <$> jsonColumn <*> jsonColumn))

selectProcessPage :: Statement Text [OperationId]
selectProcessPage = preparable "SELECT operation_id FROM shikigami.workspace_processes WHERE operation_id>$1 ORDER BY operation_id LIMIT 64" textParam (D.rowList (D.column (D.nonNullable (D.refine parseOperationId D.text))))

jsonColumn :: (FromJSON a) => D.Row (Either () a)
jsonColumn = decode <$> D.column (D.nonNullable D.jsonb)
  where
    decode value = case Aeson.fromJSON value of Aeson.Success record -> Right record; Aeson.Error _ -> Left ()

readRows :: (Traversable rows) => parameters -> Statement parameters (rows (Either () a)) -> Transaction (Either WorkspaceError (rows a))
readRows parameters statement = do
  rows <- Tx.statement parameters statement
  case traverse id rows of
    Left () -> Tx.condemn >> pure (Left WorkspaceBindingConflict)
    Right values -> pure (Right values)

insertProcess :: Statement (Text, Text, Text, ProcessRecord) ()
insertProcess = preparable "INSERT INTO shikigami.workspace_processes(operation_id,resource,fingerprint,record) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING" (contrazip4 textParam textParam textParam jsonParam) D.noResult

updateProcess :: Statement (Text, ProcessRecord, ProcessRecord) Bool
updateProcess = preparable "UPDATE shikigami.workspace_processes SET record=$3,settled=($3->>'phase' IN ('ProcessSettled','ProcessRefused')) WHERE operation_id=$1 AND record=$2 RETURNING true" (contrazip3 textParam jsonParam jsonParam) (maybe False id <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

hasFileOperation :: Statement Text Bool
hasFileOperation = preparable "SELECT EXISTS(SELECT 1 FROM shikigami.workspace_effects WHERE operation_id=$1)" textParam (D.singleRow (D.column (D.nonNullable D.bool)))

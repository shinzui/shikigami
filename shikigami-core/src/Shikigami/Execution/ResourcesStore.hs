-- | Every mutation locks the root before any operation/allocation/attempt.
-- Transaction-level hooks let an executor commit its outcome and usage together.
module Shikigami.Execution.ResourcesStore
  ( enrollRoot,
    reserveOperation,
    reserveOperationsTx,
    beginAttempt,
    beginAttemptTx,
    settleAttempt,
    settleAttemptTx,
    reconcileAttempt,
    reconcileAttemptTx,
    reconcileSettlementTx,
    narrowAllocation,
    setRootControl,
    inspectRoot,
    inspectRootTx,
    inspectAttempt,
    reserveOperations,
    enrollRootTx,
  )
where

import Contravariant.Extras (contrazip2, contrazip3)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Execution.Identity
import Shikigami.Execution.Resources
import Shikigami.Prelude
import Shikigami.StateRevision

enrollRoot :: (Store :> es) => ExecutionRootId -> Envelope -> Eff es (Either ResourceError Admission)
enrollRoot root envelope = runTransaction (enrollRootTx root envelope)

-- | Only an admitted new-root boundary calls this. Descendant commands never
-- create a row; the immutable envelope is compared even after policy changes.
enrollRootTx :: ExecutionRootId -> Envelope -> Transaction (Either ResourceError Admission)
enrollRootTx (ExecutionRootId key) envelope = case validateKey key >> validateEnvelope envelope of
  Left err -> pure (Left err)
  Right () -> do
    let initial = Root envelope initialRevision False Nothing False 0 0 Map.empty emptyUsage
    inserted <- Tx.statement (key, initial) insertRoot
    stored <- Tx.statement key lockRoot
    pure case stored of
      Just root | root.envelope == envelope -> Right (if inserted then Accepted else AlreadyAccepted)
      _ -> Left IdentityConflict

reserveOperation :: (Store :> es) => ExecutionRootId -> StateRevision "execution-root" -> OperationRequest -> UTCTime -> Eff es (Either ResourceError Admission)
reserveOperation root revision request now = reserveOperations root revision [request] now

reserveOperations :: (Store :> es) => ExecutionRootId -> StateRevision "execution-root" -> [OperationRequest] -> UTCTime -> Eff es (Either ResourceError Admission)
reserveOperations root revision requests now = runTransaction (reserveOperationsTx root revision requests now)

-- | Batch failure condemns the transaction, including any other owner writes.
-- Callers must propagate Left. The same primitive serves singleton admission.
reserveOperationsTx :: ExecutionRootId -> StateRevision "execution-root" -> [OperationRequest] -> UTCTime -> Transaction (Either ResourceError Admission)
reserveOperationsTx root expected requests now = do
  result <- withRoot root \state -> go state AlreadyAccepted requests
  case result of
    Left _ -> Tx.condemn
    Right _ -> pure ()
  pure result
  where
    go state admission [] = saveRoot root state >> pure (Right admission)
    go state admission (request : rest) = case validateOperation request of
      Left err -> pure (Left err)
      Right () -> do
        existing <- readOperation root request.operationId
        case existing of
          Just old | old == request -> go state admission rest
          Just _ -> pure (Left IdentityConflict)
          Nothing -> case checkRoot now expected state of
            Left err -> pure (Left err)
            Right () -> do
              charged <- charge root state request.allocationId now request.quantities
              case charged of
                Left err -> pure (Left err)
                Right next -> do
                  writeOperation root request
                  go next Accepted rest

beginAttempt :: (Store :> es) => ExecutionRootId -> StateRevision "execution-root" -> AttemptRequest -> UTCTime -> Eff es (Either ResourceError Admission)
beginAttempt root expected request now = runTransaction (beginAttemptTx root expected request now)

beginAttemptTx :: ExecutionRootId -> StateRevision "execution-root" -> AttemptRequest -> UTCTime -> Transaction (Either ResourceError Admission)
beginAttemptTx root expected request now = withRoot root \state -> do
  existing <- readAttempt root request.attemptId
  case existing of
    Just old | old.request == request -> pure (Right AlreadyAccepted)
    Just _ -> pure (Left IdentityConflict)
    Nothing -> do
      operation <- readOperation root request.operationId
      case operation of
        Nothing -> pure (Left OperationMissing)
        Just operationRequest -> do
          scope <- loadScope root state operationRequest.allocationId
          case scope >>= \(limits, _, _) -> checkRoot now expected state >> validateAttempt limits operationRequest request >> checkActive state of
            Left err -> pure (Left err)
            Right () -> do
              charged <- charge root state operationRequest.allocationId now request.quantities
              case charged of
                Left err -> pure (Left err)
                Right next -> do
                  writeAttempt root (Attempt request Nothing)
                  saveRoot root (next & #active .~ state.active + 1)
                  pure (Right Accepted)
  where
    checkActive state = case Map.lookup ActiveWork (effectiveLimits state) of
      Just (Limited n) | state.active >= n -> Left (ResourceExhausted ActiveWork)
      _ -> Right ()

settleAttempt :: (Store :> es) => ExecutionRootId -> AttemptId -> Settlement -> Eff es (Either ResourceError Admission)
settleAttempt root attempt outcome = runTransaction (settleAttemptTx root attempt outcome)

settleAttemptTx :: ExecutionRootId -> AttemptId -> Settlement -> Transaction (Either ResourceError Admission)
settleAttemptTx = recordSettlement False

reconcileAttempt :: (Store :> es) => ExecutionRootId -> AttemptId -> Quantities -> Eff es (Either ResourceError Admission)
reconcileAttempt root attempt measured = runTransaction (reconcileAttemptTx root attempt measured)

reconcileAttemptTx :: ExecutionRootId -> AttemptId -> Quantities -> Transaction (Either ResourceError Admission)
reconcileAttemptTx root attempt = recordSettlement True root attempt . KnownUsage

-- Transport recovery may establish that a call stopped while billing remains
-- partial. Preserve the unresolved billing hold without charging counters twice.
reconcileSettlementTx :: ExecutionRootId -> AttemptId -> Settlement -> Transaction (Either ResourceError Admission)
reconcileSettlementTx root attempt outcome = case outcome of
  UnknownUsage _ -> pure (Left SettlementConflict)
  _ -> recordSettlement True root attempt outcome

recordSettlement :: Bool -> ExecutionRootId -> AttemptId -> Settlement -> Transaction (Either ResourceError Admission)
recordSettlement reconcile root attemptId outcome = withRoot root \state -> do
  stored <- readAttempt root attemptId
  case stored of
    Nothing -> pure (Left AttemptMissing)
    Just attempt
      | attempt.outcome == Just outcome -> pure (Right AlreadyAccepted)
      | isJust attempt.outcome && not (reconcile && wasUncertain attempt) -> pure (Left SettlementConflict)
      | reconcile && not (wasUncertain attempt) -> pure (Left SettlementConflict)
      | reconcile && wasPartial attempt, PartialUsage {} <- outcome -> pure (Left SettlementConflict)
      | otherwise -> case outcome of
          UnknownUsage reason
            | Text.null reason || Text.length reason > 512 -> pure (Left (InvalidResourceRequest "unknown reason must contain 1..512 characters"))
            | otherwise -> do
                writeAttempt root (Attempt attempt.request (Just outcome))
                saveRoot root (state & #unknown .~ state.unknown + 1)
                pure (Right Accepted)
          KnownUsage measured -> do
            operation <- readOperation root attempt.request.operationId
            case operation of
              Nothing -> pure (Left OperationMissing)
              Just operationRequest -> do
                scope <- loadScope root state operationRequest.allocationId
                let (reservation, newlyMeasured) = case attempt.outcome of
                      Just (PartialUsage _ missing _) -> (Map.filterWithKey (\d _ -> d `elem` missing) attempt.request.quantities, Map.filterWithKey (\d _ -> d `elem` missing) measured)
                      _ -> (attempt.request.quantities, measured)
                    preservePartial =
                      validateQuantities measured >> unless (all (`elem` [Tokens, CostMicroUsd]) (Map.keys measured)) (Left SettlementConflict) >> case attempt.outcome of
                        Just (PartialUsage previous missing _) -> do
                          unless (all (\(d, n) -> Map.lookup d measured == Just n) (Map.toList previous) && all (`Map.member` measured) missing) (Left SettlementConflict)
                        _ -> Right ()
                case scope >>= \(_, _, usage) -> preservePartial >> validateQuantities (add state.known newlyMeasured) >> settleUsage reservation newlyMeasured usage of
                  Left err -> pure (Left err)
                  Right usage -> do
                    next <- saveScopeUsage root state operationRequest.allocationId usage
                    let exceeded = any (\(d, n) -> Map.member d reservation && n > Map.findWithDefault 0 d reservation) (Map.toList newlyMeasured)
                        counters = Map.filterWithKey (\d _ -> d `elem` [ModelAttempts, ToolAttempts]) reservation
                        recorded =
                          next
                            & #active
                            .~ state.active
                            - (if wasPartial attempt then 0 else 1)
                              & #unknown
                              .~ state.unknown
                            - (if wasUncertain attempt then 1 else 0)
                              & #known
                              .~ add state.known (add counters newlyMeasured)
                              & #overage
                              .~ (state.overage || exceeded)
                    writeAttempt root (Attempt attempt.request (Just outcome))
                    saveRoot root recorded
                    pure (Right Accepted)
          PartialUsage measured missing reason
            | null missing || any (`notElem` [Tokens, CostMicroUsd]) missing || any (`Map.member` measured) missing || Text.null reason || Text.length reason > 512 -> pure (Left (InvalidResourceRequest "partial usage requires disjoint known measurements, unknown billing dimensions and a bounded reason"))
            | otherwise -> do
                operation <- readOperation root attempt.request.operationId
                case operation of
                  Nothing -> pure (Left OperationMissing)
                  Just operationRequest -> do
                    scope <- loadScope root state operationRequest.allocationId
                    let knownReservation = Map.filterWithKey (\d _ -> d `notElem` missing) attempt.request.quantities
                    case scope >>= \(_, _, usage) -> validateQuantities (add state.known measured) >> settleUsage knownReservation measured usage of
                      Left err -> pure (Left err)
                      Right usage -> do
                        next <- saveScopeUsage root state operationRequest.allocationId usage
                        let counters = Map.filterWithKey (\d _ -> d `elem` [ModelAttempts, ToolAttempts]) knownReservation
                            exceeded = any (\(d, n) -> Map.member d knownReservation && n > Map.findWithDefault 0 d knownReservation) (Map.toList measured)
                        writeAttempt root (Attempt attempt.request (Just outcome))
                        saveRoot root (next & #active .~ (state.active - 1) & #unknown .~ (state.unknown + if wasUncertain attempt then 0 else 1) & #known .~ add state.known (add counters measured) & #overage .~ (state.overage || exceeded))
                        pure (Right Accepted)
  where
    wasUncertain attempt = case attempt.outcome of
      Just (UnknownUsage _) -> True
      Just (PartialUsage _ _ _) -> True
      _ -> False
    wasPartial attempt = case attempt.outcome of
      Just (PartialUsage _ _ _) -> True
      _ -> False

-- | Creating an allocation holds its entire finite ceiling in its parent.
-- Later narrowing returns only unused capacity; consumption is never refunded.
narrowAllocation :: (Store :> es) => ExecutionRootId -> StateRevision "execution-root" -> AllocationId -> Maybe AllocationId -> Envelope -> UTCTime -> Eff es (Either ResourceError Admission)
narrowAllocation root expected allocationId@(AllocationId key) parent envelope now = runTransaction $ withRoot root \state -> do
  existing <- readAllocation root allocationId
  case existing of
    Just allocation | allocation.parent == parent && allocation.current == envelope -> pure (Right AlreadyAccepted)
    _ -> case checkRoot now expected state >> validateKey key >> validateEnvelope envelope >> finiteLimits envelope of
      Left err -> pure (Left err)
      Right quantities -> do
        parentScope <- loadScope root state parent
        case parentScope of
          Left err -> pure (Left err)
          Right (limits, cutoff, parentUsage)
            | envelope.cutoff > cutoff -> pure (Left (InvalidResourceRequest "allocation cannot extend its parent's cutoff"))
            | otherwise -> case existing of
                Nothing -> case admit limits parentUsage quantities of
                  Left err -> pure (Left err)
                  Right usage -> do
                    next <- saveScopeUsage root state parent usage
                    writeAllocation root allocationId (Allocation parent envelope envelope emptyUsage)
                    saveRoot root next
                    pure (Right Accepted)
                Just old
                  | old.parent /= parent -> pure (Left IdentityConflict)
                  | envelope.cutoff > old.current.cutoff -> pure (Left (InvalidResourceRequest "allocation cutoff cannot increase"))
                  | otherwise -> case finiteLimits old.current of
                      Left err -> pure (Left err)
                      Right previous -> do
                        let delta = subtractAmounts previous quantities
                            occupancy = occupied old.usage
                            narrowed =
                              all (>= 0) delta
                                && all (\(d, n) -> n >= Map.findWithDefault 0 d occupancy) (Map.toList quantities)
                                && all (\(d, n) -> n <= Map.findWithDefault 0 d quantities) (Map.toList occupancy)
                        if not narrowed
                          then pure (Left (InvalidResourceRequest "allocation must narrow without releasing spent or held work"))
                          else do
                            next <- saveScopeUsage root state parent (Usage parentUsage.settled (subtractAmounts parentUsage.held delta))
                            writeAllocation root allocationId (Allocation parent old.admitted envelope old.usage)
                            saveRoot root next
                            pure (Right Accepted)

finiteLimits :: Envelope -> Either ResourceError Quantities
finiteLimits Envelope {limits} = traverse finite limits
  where
    finite (Limited n) = Right n
    finite ExplicitlyUnbounded = Left (InvalidResourceRequest "suballocations require finite exclusive ceilings")

-- | Policy revisions change only here. Usage recording remains permitted
-- after cancellation/cutoff/revision changes; accepted work must drain truthfully.
setRootControl :: (Store :> es) => ExecutionRootId -> StateRevision "execution-root" -> Bool -> Maybe Integer -> Eff es (Either ResourceError ())
setRootControl root expected cancelled activeLimit = runTransaction $ withRoot root \state ->
  if expected /= state.revision
    then pure (Left RevisionConflict)
    else
      if maybe False (not . validQuantity) activeLimit
        then pure (Left (InvalidResourceRequest "invalid active limit"))
        else
          if state.cancelled && not cancelled
            then pure (Left (InvalidResourceRequest "cancellation is irreversible"))
            else
              if maybe False (\n -> case Map.lookup ActiveWork state.envelope.limits of Just (Limited maximumAmount) -> n > maximumAmount; Nothing -> n > 0; _ -> False) activeLimit
                then pure (Left (InvalidResourceRequest "control cannot widen the admitted envelope"))
                else do
                  saveRoot root (state & #revision .~ advanceRevision expected & #cancelled .~ cancelled & #activeLimit .~ activeLimit)
                  pure (Right ())

-- | One bounded row: no transcript, operation history, tool payload or secret.
inspectRoot :: (Store :> es) => ExecutionRootId -> Eff es (Either ResourceError Root)
inspectRoot root = runTransaction (withRoot root (pure . Right))

inspectRootTx :: ExecutionRootId -> Transaction (Either ResourceError Root)
inspectRootTx root = withRoot root (pure . Right)

-- | An accepted identity is a receipt, never permission to redispatch. Executors
-- recover this record alongside their own dispatch claim and protected outcome.
inspectAttempt :: (Store :> es) => ExecutionRootId -> AttemptId -> Eff es (Either ResourceError (Maybe Attempt))
inspectAttempt root attempt = runTransaction (withRoot root (\_ -> Right <$> readAttempt root attempt))

withRoot :: ExecutionRootId -> (Root -> Transaction (Either ResourceError a)) -> Transaction (Either ResourceError a)
withRoot (ExecutionRootId key) action = Tx.statement key lockRoot >>= maybe (pure (Left RootMissing)) action

loadScope :: ExecutionRootId -> Root -> Maybe AllocationId -> Transaction (Either ResourceError (Limits, UTCTime, Usage))
loadScope _ state Nothing = pure (Right (effectiveLimits state, state.envelope.cutoff, state.usage))
loadScope root state (Just allocationId) = do
  allocation <- readAllocation root allocationId
  case allocation of
    Nothing -> pure (Left AllocationMissing)
    Just a -> do
      parent <- loadScope root state a.parent
      pure ((\(_, cutoff, _) -> (a.current.limits, min cutoff a.current.cutoff, a.usage)) <$> parent)

charge :: ExecutionRootId -> Root -> Maybe AllocationId -> UTCTime -> Quantities -> Transaction (Either ResourceError Root)
charge root state scope now amounts = do
  loaded <- loadScope root state scope
  case loaded >>= \(limits, cutoff, usage) -> if now >= cutoff then Left CutoffReached else admit limits usage amounts of
    Left err -> pure (Left err)
    Right usage -> do
      let descendants = Map.filterWithKey (\dimension _ -> dimension == LifetimeDescendants) amounts
          next = Usage (add usage.settled descendants) (subtractAmounts usage.held descendants)
      updated <- saveScopeUsage root state scope next
      pure (Right (updated & #known .~ add state.known descendants))

saveScopeUsage :: ExecutionRootId -> Root -> Maybe AllocationId -> Usage -> Transaction Root
saveScopeUsage _ state Nothing usage = pure (state & #usage .~ usage)
saveScopeUsage root state (Just allocationId) usage = do
  -- The root lock serializes all access, so this row cannot disappear or change.
  stored <- readAllocation root allocationId
  forM_ stored \allocation -> writeAllocation root allocationId (allocation & #usage .~ usage)
  pure state

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

jsonRow :: (FromJSON a) => D.Row a
jsonRow = D.column (D.nonNullable (D.refine decode D.jsonb))
  where
    decode value = case Aeson.fromJSON value of Aeson.Error err -> Left (Text.pack err); Aeson.Success a -> Right a

insertRoot :: Statement (Text, Root) Bool
insertRoot =
  preparable
    "INSERT INTO shikigami.execution_roots (root_id, state) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING true"
    (contrazip2 textParam jsonParam)
    (fromMaybe False <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

lockRoot :: Statement Text (Maybe Root)
lockRoot = preparable "SELECT state FROM shikigami.execution_roots WHERE root_id=$1 FOR UPDATE" textParam (D.rowMaybe jsonRow)

saveRoot :: ExecutionRootId -> Root -> Transaction ()
saveRoot (ExecutionRootId key) state = Tx.statement (key, state) updateRoot

updateRoot :: Statement (Text, Root) ()
updateRoot = preparable "UPDATE shikigami.execution_roots SET state=$2 WHERE root_id=$1" (contrazip2 textParam jsonParam) D.noResult

readOperation :: ExecutionRootId -> OperationId -> Transaction (Maybe OperationRequest)
readOperation (ExecutionRootId root) (OperationId key) = flip Tx.statement getOperation (root, key)

getOperation :: Statement (Text, Text) (Maybe OperationRequest)
getOperation = preparable "SELECT request FROM shikigami.execution_operations WHERE root_id=$1 AND operation_id=$2" (contrazip2 textParam textParam) (D.rowMaybe jsonRow)

writeOperation :: ExecutionRootId -> OperationRequest -> Transaction ()
writeOperation (ExecutionRootId root) request = let OperationId key = request.operationId in Tx.statement (root, key, request) putOperation

putOperation :: Statement (Text, Text, OperationRequest) ()
putOperation = preparable "INSERT INTO shikigami.execution_operations (root_id,operation_id,request) VALUES ($1,$2,$3)" (contrazip3 textParam textParam jsonParam) D.noResult

readAttempt :: ExecutionRootId -> AttemptId -> Transaction (Maybe Attempt)
readAttempt (ExecutionRootId root) (AttemptId key) = flip Tx.statement getAttempt (root, key)

getAttempt :: Statement (Text, Text) (Maybe Attempt)
getAttempt = preparable "SELECT state FROM shikigami.execution_attempts WHERE root_id=$1 AND attempt_id=$2" (contrazip2 textParam textParam) (D.rowMaybe jsonRow)

writeAttempt :: ExecutionRootId -> Attempt -> Transaction ()
writeAttempt (ExecutionRootId root) attempt = let AttemptId key = attempt.request.attemptId in Tx.statement (root, key, attempt) putAttempt

putAttempt :: Statement (Text, Text, Attempt) ()
putAttempt = preparable "INSERT INTO shikigami.execution_attempts (root_id,attempt_id,state) VALUES ($1,$2,$3) ON CONFLICT (root_id,attempt_id) DO UPDATE SET state=EXCLUDED.state" (contrazip3 textParam textParam jsonParam) D.noResult

readAllocation :: ExecutionRootId -> AllocationId -> Transaction (Maybe Allocation)
readAllocation (ExecutionRootId root) (AllocationId key) = flip Tx.statement getAllocation (root, key)

getAllocation :: Statement (Text, Text) (Maybe Allocation)
getAllocation = preparable "SELECT state FROM shikigami.execution_allocations WHERE root_id=$1 AND allocation_id=$2" (contrazip2 textParam textParam) (D.rowMaybe jsonRow)

writeAllocation :: ExecutionRootId -> AllocationId -> Allocation -> Transaction ()
writeAllocation (ExecutionRootId root) (AllocationId key) allocation = Tx.statement (root, key, allocation) putAllocation

putAllocation :: Statement (Text, Text, Allocation) ()
putAllocation = preparable "INSERT INTO shikigami.execution_allocations (root_id,allocation_id,state) VALUES ($1,$2,$3) ON CONFLICT (root_id,allocation_id) DO UPDATE SET state=EXCLUDED.state" (contrazip3 textParam textParam jsonParam) D.noResult

-- | Assignment-local actual call facts. Root reservations and these facts
-- share one transaction; neither store claims to be the execution transcript.
module Shikigami.Store.ExecutionSelection where

import Contravariant.Extras (contrazip2, contrazip5)
import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Attestation.CallFacts (CallComplianceFacts)
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile (..))
import Shikigami.Execution.Identity
import Shikigami.Execution.Resources
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Prelude
import Shikigami.Store.ExecutionResources qualified as Resources

data CallLimits = CallLimits
  { calls :: !(Maybe Integer),
    retries :: !(Maybe Integer),
    concurrency :: !(Maybe Integer),
    cutoff :: !(Maybe UTCTime),
    tokens :: !(Maybe Integer)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

callLimitsFor :: ExecutionSelection -> Maybe ResolvedProfile -> CallLimits
callLimitsFor selection profile =
  CallLimits
    { calls = toInteger <$> (profile >>= (\p -> p.profile.limits.maxCalls)),
      retries = toInteger <$> (profile >>= (\p -> p.profile.limits.maxRetries)),
      concurrency = toInteger <$> (profile >>= (\p -> p.profile.limits.maxConcurrency)),
      cutoff = case maybe [] pure ((\seconds -> addUTCTime (fromIntegral seconds) selection.admittedAt) <$> (profile >>= (\p -> p.profile.limits.maxDurationSeconds))) <> maybe [] pure (profile >>= (\p -> p.profile.validUntil)) of [] -> Nothing; deadlines -> Just (minimum deadlines),
      tokens = toInteger <$> (profile >>= (\p -> p.profile.limits.maxTokens))
    }

callLimitsWithin :: CallLimits -> CallLimits -> Bool
callLimitsWithin proposed admitted = and [within proposed.calls admitted.calls, within proposed.retries admitted.retries, within proposed.concurrency admitted.concurrency, within proposed.tokens admitted.tokens, within proposed.cutoff admitted.cutoff]
  where
    within wanted maximumValue = maybe True (\bound -> maybe False (<= bound) wanted) maximumValue

data Assignment = Assignment
  { selection :: !ExecutionSelection,
    limits :: !CallLimits,
    attempts :: !Integer,
    active :: !Integer,
    usage :: !Usage,
    unknown :: !Integer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CallReceipt = CallReceipt
  { assignmentId :: !Text,
    rootId :: !(Maybe ExecutionRootId),
    request :: !AttemptRequest,
    fingerprint :: !Text,
    ordinal :: !Integer,
    startedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CallPhase = CallTerminal | CallTransportUnknown | CallRefused
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CallOutcome = CallOutcome
  { phase :: !CallPhase,
    known :: !Quantities,
    missing :: ![Dimension],
    reportedModel :: !(Maybe Text),
    providerCallId :: !(Maybe Text),
    compliance :: !(Maybe CallComplianceFacts)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SelectionCall = SelectionCall
  { receipt :: !CallReceipt,
    outcome :: !(Maybe CallOutcome)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CallReservation = NewCall !CallReceipt | ExistingCall !CallReceipt
  deriving stock (Eq, Show)

data CallAdmissionFailure
  = AssignmentConflict
  | AssignmentCallLimitExceeded
  | AssignmentConcurrencyExceeded
  | AssignmentCutoffReached
  | CallRetryLimitExceeded
  | CallResourcesRefused !ResourceError
  | CallIdentityConflict
  | CallMissing
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

reserveSelectionCall :: (Store :> es) => ExecutionSelection -> CallLimits -> AttemptRequest -> Text -> UTCTime -> Eff es (Either CallAdmissionFailure CallReservation)
reserveSelectionCall selection limits request fingerprint now = runTransaction (reserveSelectionCallTx selection limits request fingerprint now)

reserveSelectionCallTx :: ExecutionSelection -> CallLimits -> AttemptRequest -> Text -> UTCTime -> Transaction (Either CallAdmissionFailure CallReservation)
reserveSelectionCallTx selection limits request fingerprint now = do
  result <- reserve
  case result of Left _ -> Tx.condemn; Right _ -> pure ()
  pure result
  where
    assignmentId = selection.assignmentId
    reserve = case validate of
      Left err -> pure (Left (CallResourcesRefused err))
      Right () -> reserveValidated
    validate = do
      validateKey assignmentId
      validateKey fingerprint
      validateOperation (OperationRequest request.operationId Nothing ModelOperation Map.empty fingerprint)
      validateAttempt (assignmentLimits limits) (OperationRequest request.operationId Nothing ModelOperation Map.empty fingerprint) request
      forM_ [limits.calls, limits.retries, limits.concurrency, limits.tokens] (traverse_ (\n -> unless (validQuantity n) (Left (InvalidResourceRequest "invalid assignment limit"))))
    reserveValidated = do
      root <- traverse Resources.inspectRootTx selection.rootId
      case sequence root of
        Left err -> pure (Left (CallResourcesRefused err))
        Right state -> do
          Tx.statement (assignmentId, Assignment selection limits 0 0 emptyUsage 0) insertAssignment
          stored <- Tx.statement assignmentId lockAssignment
          case stored of
            Nothing -> pure (Left AssignmentConflict)
            Just assignment
              | assignment.selection /= selection || assignment.limits /= limits -> pure (Left AssignmentConflict)
              | otherwise -> do
                  oldCall <- readCall request.attemptId
                  case oldCall of
                    Just old | old.receipt.assignmentId == assignmentId && old.receipt.request == request && old.receipt.fingerprint == fingerprint -> pure (Right (ExistingCall old.receipt))
                    Just _ -> pure (Left CallIdentityConflict)
                    Nothing
                      | maybe False (now >=) limits.cutoff -> pure (Left AssignmentCutoffReached)
                      | maybe False (assignment.active >=) limits.concurrency -> pure (Left AssignmentConcurrencyExceeded)
                      | maybe False (assignment.attempts >=) limits.calls -> pure (Left AssignmentCallLimitExceeded)
                      | not (validQuantity (assignment.attempts + 1)) -> pure (Left AssignmentCallLimitExceeded)
                      | otherwise -> do
                          previous <- Tx.statement (assignmentId, operationKey request.operationId) countOperationCalls
                          admitted <- case admit (assignmentLimits limits) assignment.usage request.quantities of
                            Left err -> pure (Left (CallResourcesRefused err))
                            Right usage -> do
                              rootAdmission <-
                                if maybe False (previous >=) ((+ 1) <$> limits.retries)
                                  then pure (Left CallRetryLimitExceeded)
                                  else case (selection.rootId, state) of
                                    (Just rootId, Just rootState) -> do
                                      let operation = OperationRequest request.operationId Nothing ModelOperation Map.empty fingerprint
                                      reserved <- Resources.reserveOperationsTx rootId rootState.revision [operation] now
                                      case reserved of
                                        Left err -> pure (Left (CallResourcesRefused err))
                                        Right _ ->
                                          Resources.beginAttemptTx rootId rootState.revision request now >>= \case
                                            Left err -> pure (Left (CallResourcesRefused err))
                                            Right Accepted -> pure (Right ())
                                            Right AlreadyAccepted -> pure (Left CallIdentityConflict)
                                    (Nothing, Nothing) -> pure (Right ())
                                    _ -> pure (Left AssignmentConflict)
                              pure (usage <$ rootAdmission)
                          case admitted of
                            Left err -> pure (Left err)
                            Right usage -> do
                              let receipt = CallReceipt assignmentId selection.rootId request fingerprint (assignment.attempts + 1) now
                              Tx.statement (assignmentId, assignment & #attempts .~ receipt.ordinal & #active .~ (assignment.active + 1) & #usage .~ usage) updateAssignment
                              writeCall (SelectionCall receipt Nothing)
                              pure (Right (NewCall receipt))

finishSelectionCall :: (Store :> es) => CallReceipt -> CallOutcome -> Eff es (Either CallAdmissionFailure Admission)
finishSelectionCall receipt outcome = runTransaction (finishSelectionCallTx receipt outcome)

finishSelectionCallTx :: CallReceipt -> CallOutcome -> Transaction (Either CallAdmissionFailure Admission)
finishSelectionCallTx receipt outcome = do
  root <- traverse Resources.inspectRootTx receipt.rootId
  case sequence root of
    Left err -> pure (Left (CallResourcesRefused err))
    Right _ -> do
      assignment <- Tx.statement receipt.assignmentId lockAssignment
      stored <- readCall receipt.request.attemptId
      case stored of
        Nothing -> pure (Left CallMissing)
        Just call
          | isNothing assignment -> pure (Left CallMissing)
          | call.receipt /= receipt -> pure (Left CallIdentityConflict)
          | call.outcome == Just outcome -> pure (Right AlreadyAccepted)
          | isJust call.outcome -> pure (Left CallIdentityConflict)
          | otherwise -> do
              let settlement = case outcome.phase of
                    CallTransportUnknown -> UnknownUsage "transport outcome unavailable"
                    CallRefused -> KnownUsage (Map.fromList [(Tokens, 0), (CostMicroUsd, 0)])
                    CallTerminal | null outcome.missing -> KnownUsage outcome.known
                    CallTerminal -> PartialUsage outcome.known outcome.missing "terminal billing facts unavailable"
              let localUsage = maybe (Left (InvalidResourceRequest "assignment missing")) (settleAssignment receipt.request.quantities settlement . (.usage)) assignment
              case localUsage of
                Left err -> pure (Left (CallResourcesRefused err))
                Right usage -> do
                  settled <- case receipt.rootId of
                    Nothing -> pure (Right Accepted)
                    Just rootId -> Resources.settleAttemptTx rootId receipt.request.attemptId settlement
                  case settled of
                    Left err -> Tx.condemn >> pure (Left (CallResourcesRefused err))
                    Right _ -> do
                      forM_ assignment \current -> do
                        let active = current.active - (if outcome.phase == CallTransportUnknown then 0 else 1)
                        Tx.statement (receipt.assignmentId, current & #active .~ active & #usage .~ usage & #unknown .~ (current.unknown + if outcome.phase == CallTransportUnknown || not (null outcome.missing) then 1 else 0)) updateAssignment
                      writeCall (SelectionCall receipt (Just outcome))
                      pure (Right Accepted)

-- Reconcile retained terminal evidence without replacing any previously known
-- measurement or observed identity. Active work is released only once.
reconcileSelectionCallTx :: CallReceipt -> CallOutcome -> Transaction (Either CallAdmissionFailure Admission)
reconcileSelectionCallTx receipt outcome = do
  root <- traverse Resources.inspectRootTx receipt.rootId
  case sequence root of
    Left err -> pure (Left (CallResourcesRefused err))
    Right _ -> do
      assignment <- Tx.statement receipt.assignmentId lockAssignment
      stored <- readCall receipt.request.attemptId
      case (assignment, stored) of
        (Just current, Just call)
          | call.receipt /= receipt -> pure (Left CallIdentityConflict)
          | call.outcome == Just outcome -> pure (Right AlreadyAccepted)
          | Just previous <- call.outcome -> case reconcileUsage current previous of
              Left err -> pure (Left err)
              Right (usage, active, unknown, settlement) -> do
                reconciled <- case receipt.rootId of Nothing -> pure (Right Accepted); Just rootId -> Resources.reconcileSettlementTx rootId receipt.request.attemptId settlement
                case reconciled of
                  Left err -> Tx.condemn >> pure (Left (CallResourcesRefused err))
                  Right _ -> do
                    Tx.statement (receipt.assignmentId, current & #usage .~ usage & #active .~ active & #unknown .~ unknown) updateAssignment
                    writeCall (SelectionCall receipt (Just outcome))
                    pure (Right Accepted)
        _ -> pure (Left CallMissing)
  where
    reconcileUsage assignment previous = do
      let fromUnknown = previous.phase == CallTransportUnknown
          refused = outcome.phase == CallRefused
          measured = if refused then Map.fromList [(Tokens, 0), (CostMicroUsd, 0)] else outcome.known
      unless (outcome.phase /= CallTransportUnknown && previous.phase /= CallRefused && (fromUnknown || not (null previous.missing)) && (not refused || (fromUnknown && null outcome.missing && Map.null outcome.known))) (Left CallIdentityConflict)
      unless (all (\(dimension, amount) -> Map.lookup dimension measured == Just amount) (Map.toList previous.known) && preserves previous.reportedModel outcome.reportedModel && preserves previous.providerCallId outcome.providerCallId && preserves previous.compliance outcome.compliance) (Left CallIdentityConflict)
      let settlement = if null outcome.missing then KnownUsage measured else PartialUsage measured outcome.missing "terminal billing facts unavailable"
      unless (fromUnknown || null outcome.missing) (Left CallIdentityConflict)
      let reservation = if fromUnknown then receipt.request.quantities else Map.filterWithKey (\dimension _ -> dimension `elem` previous.missing) receipt.request.quantities
          newlyKnown = if fromUnknown then measured else Map.filterWithKey (\dimension _ -> dimension `elem` previous.missing) measured
      unless (fromUnknown || all (`Map.member` measured) previous.missing) (Left CallIdentityConflict)
      usage <- either (Left . CallResourcesRefused) Right (if fromUnknown then settleAssignment reservation settlement assignment.usage else settleUsage reservation newlyKnown assignment.usage)
      pure (usage, assignment.active - if fromUnknown then 1 else 0, assignment.unknown - if null outcome.missing then 1 else 0, settlement)
    preserves old new = maybe True (\value -> new == Just value) old

assignmentLimits :: CallLimits -> Limits
assignmentLimits limits =
  let unbounded = Map.fromList [(d, ExplicitlyUnbounded) | d <- [minBound .. maxBound]]
   in maybe unbounded (\n -> Map.insert Tokens (Limited n) unbounded) limits.tokens

settleAssignment :: Quantities -> Settlement -> Usage -> Either ResourceError Usage
settleAssignment reservation settlement usage = case settlement of
  UnknownUsage _ -> Right usage
  KnownUsage known -> settleUsage reservation known usage
  PartialUsage known missing _ -> do
    unless (not (null missing) && all (`elem` [Tokens, CostMicroUsd]) missing && all (`Map.notMember` known) missing) (Left (InvalidResourceRequest "invalid partial billing facts"))
    settleUsage (Map.filterWithKey (\d _ -> d `notElem` missing) reservation) known usage

-- | At most 100 facts; the aggregate count also exposes omitted history.
inspectSelection :: (Store :> es) => Text -> Eff es (Maybe (Assignment, [SelectionCall]))
inspectSelection key = runTransaction do
  assignment <- Tx.statement key lockAssignment
  case assignment of
    Nothing -> pure Nothing
    Just value -> Just . (value,) <$> Tx.statement key listCalls

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

jsonRow :: (FromJSON a) => D.Row a
jsonRow = D.column (D.nonNullable (D.refine decode D.jsonb))
  where
    decode value = case Aeson.fromJSON value of Aeson.Error err -> Left (Text.pack err); Aeson.Success v -> Right v

insertAssignment :: Statement (Text, Assignment) ()
insertAssignment = preparable "INSERT INTO shikigami.execution_selections (assignment_id,state) VALUES ($1,$2) ON CONFLICT DO NOTHING" (contrazip2 textParam jsonParam) D.noResult

lockAssignment :: Statement Text (Maybe Assignment)
lockAssignment = preparable "SELECT state FROM shikigami.execution_selections WHERE assignment_id=$1 FOR UPDATE" textParam (D.rowMaybe jsonRow)

updateAssignment :: Statement (Text, Assignment) ()
updateAssignment = preparable "UPDATE shikigami.execution_selections SET state=$2 WHERE assignment_id=$1" (contrazip2 textParam jsonParam) D.noResult

readCall :: AttemptId -> Transaction (Maybe SelectionCall)
readCall (AttemptId key) = Tx.statement key getCall

getCall :: Statement Text (Maybe SelectionCall)
getCall = preparable "SELECT state FROM shikigami.execution_selection_calls WHERE attempt_id=$1 FOR UPDATE" textParam (D.rowMaybe jsonRow)

writeCall :: SelectionCall -> Transaction ()
writeCall call = let AttemptId key = call.receipt.request.attemptId in Tx.statement (call.receipt.assignmentId, key, operationKey call.receipt.request.operationId, fromInteger call.receipt.ordinal, call) putCall

putCall :: Statement (Text, Text, Text, Int64, SelectionCall) ()
putCall = preparable "INSERT INTO shikigami.execution_selection_calls (assignment_id,attempt_id,operation_id,ordinal,state) VALUES ($1,$2,$3,$4,$5) ON CONFLICT (attempt_id) DO UPDATE SET state=EXCLUDED.state" (contrazip5 textParam textParam textParam (E.param (E.nonNullable E.int8)) jsonParam) D.noResult

listCalls :: Statement Text [SelectionCall]
listCalls = preparable "SELECT state FROM shikigami.execution_selection_calls WHERE assignment_id=$1 ORDER BY ordinal LIMIT 100" textParam (D.rowList jsonRow)

operationKey :: OperationId -> Text
operationKey (OperationId key) = key

countOperationCalls :: Statement (Text, Text) Integer
countOperationCalls = preparable "SELECT count(*) FROM shikigami.execution_selection_calls WHERE assignment_id=$1 AND operation_id=$2" (contrazip2 textParam textParam) (D.singleRow (toInteger <$> D.column (D.nonNullable D.int8)))

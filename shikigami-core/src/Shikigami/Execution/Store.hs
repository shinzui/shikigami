{-# LANGUAGE ConstraintKinds #-}

-- | Checked lifecycle events and protected replay data commit together. The
-- generated stream is the lifecycle authority; these rows retain its rich data.
module Shikigami.Execution.Store
  ( ReplayAccess,
    ExecutionBinding (..),
    ExecutionEffects,
    ExecutionReadEffects,
    admitExecution,
    authorizeReplay,
    loadExecution,
    inspectExecution,
    inspectOperation,
    readReplayPayload,
    acceptOperation,
    recordOutcomeAndAdvance,
    recordOutcomeAndAdvanceWith,
    finishExecution,
    payloadReference,
    outcomeReference,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Control.Exception (Exception, fromException, throw)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, tryError)
import Effectful.Exception (catchSync, throwIO)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Keiro.Command (CommandError (CommandRejected, RetryExhausted, StoreFailed), defaultRunCommandOptions)
import Keiro.Projection (ProjectionCommandOutcome (..), runCommandWithCatalogProjections)
import Keiro.ReadModel (runQuery)
import Keiro.Stream qualified as Stream
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Decision.Contract (ModelDescriptor, versionedDigest)
import Shikigami.Execution.Catalog (withLiveExecution)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId (..))
import Shikigami.Execution.Policy (validateTerminalOutput)
import Shikigami.Execution.Policy.Types (HarnessPolicy (..))
import Shikigami.Execution.Resources (Admission (..))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Transcript
import Shikigami.ExecutionLifecycle.Generated.Domain qualified as Generated
import Shikigami.ExecutionLifecycle.Generated.EventStream (executionLifecycleCategory, executionLifecycleEventStream)
import Shikigami.ExecutionLookup.Generated.ReadModel (executionLookupReadModel)
import Shikigami.Prelude
import Shikigami.Store.ExecutionResources qualified as Roots
import Shikigami.Store.ExecutionSelection qualified as Calls

type ExecutionReadEffects es = (IOE :> es, Store :> es, Error StoreError :> es)

type ExecutionEffects es = (ExecutionReadEffects es, KirokuStoreResource :> es)

data ExecutionBinding = ExecutionBinding
  { identity :: !AgentIdentity,
    rootId :: !(Maybe ExecutionRootId),
    assignmentId :: !Text,
    descriptor :: !ModelDescriptor,
    snapshotDigest :: !Text,
    policyDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Constructor is private. The permit is process-local, identity/execution-bound
-- and short-lived; ordinary inspection never obtains one or reads payloads.
data ReplayAccess = ReplayAccess !ExecutionId !AgentIdentity !UTCTime

data PayloadEnvelope = PayloadEnvelope
  { format :: !Int,
    kind :: !Text,
    content :: !Aeson.Value
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype ExecutionAbort = ExecutionAbort ExecutionError
  deriving stock (Show)

instance Exception ExecutionAbort

data PersistenceFailure = EventRejected | CheckFailed !ExecutionError

abort :: ExecutionError -> Transaction a
abort = throw . ExecutionAbort

require :: Either ExecutionError a -> Transaction a
require = either abort pure

payloadReference :: Aeson.Value -> Either ExecutionError PayloadRef
payloadReference body = do
  let bytes = toInteger (Lazy.length (Aeson.encode body))
      digest = versionedDigest "shikigami.execution-payload/1" body
  when (bytes > 1048576) (Left PayloadTooLarge)
  pure (PayloadRef ("payload:" <> digest) digest bytes)

envelope :: (ToJSON a) => Text -> a -> Aeson.Value
envelope kind value = toJSON (PayloadEnvelope 1 kind (toJSON value))

outcomeReference :: OperationOutcome -> Either ExecutionError PayloadRef
outcomeReference = payloadReference . envelope "operation-outcome"

writePayload :: ExecutionId -> Aeson.Value -> Transaction PayloadRef
writePayload execution body = do
  ref <- require (payloadReference body)
  Tx.statement (execution.value, ref.payloadId, ref.digest, fromInteger ref.bytes, body) insertPayload
  stored <- Tx.statement (execution.value, ref.payloadId) selectPayload
  unless (stored == Just (ref.digest, ref.bytes, body)) (abort CorruptReplay)
  pure ref

admitExecution :: (ExecutionEffects es) => ExecutionSnapshot -> Eff es (Either ExecutionError Admission)
admitExecution snapshot
  | Left err <- validateSnapshot snapshot = pure (Left err)
  | otherwise = catchExecutionWith id $ case payloadReference body of
      Left refusal -> pure (Left refusal)
      Right ref -> do
        let execution = snapshot.executionId
            binding = ExecutionBinding snapshot.identity snapshot.selection.rootId snapshot.selection.assignmentId snapshot.selection.descriptor ref.digest (versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy))
            state = ExecutionState 1 execution 0 Active 0 NeedModel ref Nothing Nothing 0 0
        result <- persist execution (Generated.AdmitExecution (Generated.AdmitExecutionData execution.value ref.digest)) do
          lockRoot binding.rootId
          validateAdmissionRoot binding.rootId
          existing <- Tx.statement execution.value lockExecution
          when (isJust existing) (abort ExecutionIdentityConflict)
          Tx.statement (execution.value, state, binding) insertExecution
          actual <- writePayload execution body
          unless (actual == ref) (abort CorruptReplay)
        case result of
          Right () -> pure (Right Accepted)
          Left EventRejected -> do
            existing <- readMetadata (Tx.statement execution.value selectExecution)
            pure case existing of
              Just (previous, previousBinding) | previous.snapshot == ref && previousBinding == binding -> Right AlreadyAccepted
              _ -> Left ExecutionIdentityConflict
          Left (CheckFailed err) -> pure (Left err)
  where
    body = envelope "snapshot" snapshot

authorizeReplay :: (ExecutionEffects es) => ExecutionId -> AgentIdentity -> IO (Either Text ()) -> Eff es (Either ExecutionError ReplayAccess)
authorizeReplay execution identity authority = catchExecutionWith id do
  current <- liftIO authority
  now <- liftIO getCurrentTime
  existing <- readMetadata (Tx.statement execution.value selectExecution)
  pure case (current, existing) of
    (Right (), Just (_, binding)) | identity == binding.identity -> Right (ReplayAccess execution identity (addUTCTime 60 now))
    _ -> Left ReplayReadRefused

checkAccess :: ReplayAccess -> ExecutionBinding -> Transaction ExecutionId
checkAccess (ReplayAccess execution identity expires) binding = do
  now <- Tx.statement () currentTime
  unless (identity == binding.identity && now < expires) (abort ReplayReadRefused)
  pure execution

-- An already accepted operation may record its facts after revocation or a
-- read permit's expiry. This grants no replay read or fresh dispatch authority.
checkOutcomeIdentity :: ReplayAccess -> ExecutionBinding -> Transaction ()
checkOutcomeIdentity (ReplayAccess _ identity _) binding = unless (identity == binding.identity) (abort ReplayReadRefused)

loadExecution :: (ExecutionEffects es) => ReplayAccess -> Eff es (Either ExecutionError (ExecutionSnapshot, ExecutionState))
loadExecution access@(ReplayAccess execution _ _) = protected do
  (state, binding) <- getExecution execution
  _ <- checkAccess access binding
  snapshot <- readPayload access binding "snapshot" state.snapshot
  unless (state.snapshot.digest == binding.snapshotDigest && snapshot.executionId == execution && snapshot.selection.assignmentId == binding.assignmentId && snapshot.identity == binding.identity && snapshot.selection.rootId == binding.rootId && snapshot.selection.descriptor == binding.descriptor && versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy) == binding.policyDigest) (abort CorruptReplay)
  pure (snapshot, state)

-- Bounded metadata only. Protected body columns are never selected here.
inspectExecution :: (ExecutionReadEffects es) => ExecutionId -> Eff es (Either ExecutionError (Maybe (ExecutionState, ExecutionBinding, [Operation])))
inspectExecution execution = protected do
  existing <- Tx.statement execution.value selectExecution
  traverse (\(state, binding) -> (state,binding,) <$> Tx.statement execution.value listOperations) existing

inspectOperation :: (ExecutionReadEffects es) => OperationId -> Eff es (Either ExecutionError (Maybe Operation))
inspectOperation operation = protected (Tx.statement (operationKey operation) selectOperation)

findOperation :: (ExecutionReadEffects es) => OperationId -> Eff es (Maybe Operation)
findOperation operation = readMetadata (Tx.statement (operationKey operation) selectOperation)

readReplayPayload :: forall a es. (ExecutionReadEffects es, FromJSON a, ToJSON a) => ReplayAccess -> Text -> PayloadRef -> Eff es (Either ExecutionError a)
readReplayPayload access@(ReplayAccess execution _ _) kind ref = protected do
  (_, binding) <- getExecution execution
  readPayload access binding kind ref

readPayload :: (FromJSON a) => ReplayAccess -> ExecutionBinding -> Text -> PayloadRef -> Transaction a
readPayload access binding kind ref = do
  execution <- checkAccess access binding
  stored <- Tx.statement (execution.value, ref.payloadId) selectPayload
  case stored of
    Just (digest, bytes, body) | digest == ref.digest && bytes == ref.bytes -> do
      actual <- require (payloadReference body)
      unless (actual == ref) (abort CorruptReplay)
      PayloadEnvelope format actualKind content <- decode body
      unless (format == 1 && actualKind == kind) (abort UnsupportedReplay)
      decode content
    _ -> abort CorruptReplay

acceptOperation :: (ExecutionEffects es) => ReplayAccess -> Integer -> OperationSpec -> Aeson.Value -> Eff es (Either ExecutionError (Admission, Operation))
acceptOperation access@(ReplayAccess execution _ _) expected specification input = catchExecutionWith id do
  stored <- readMetadata (Tx.statement execution.value selectExecution)
  case stored of
    Nothing -> pure (Left ExecutionMissing)
    Just (state, binding) -> case payloadReference body of
      Left err -> pure (Left err)
      Right ref -> do
        let fingerprint = versionedDigest "shikigami.execution-operation-request/1" (toJSON (specification, ref, binding.snapshotDigest))
            operation = Operation 1 execution state.cursor specification fingerprint ref Nothing Nothing False
        old <- findOperation specification.operationId
        case old of
          Just previous -> pure (duplicate fingerprint previous)
          Nothing -> do
            result <- persist execution (advance execution expected) do
              lockRoot binding.rootId
              (current, actualBinding) <- getExecution execution
              _ <- checkAccess access actualBinding
              checkRevision expected current
              unless (current.phase == Active && isNothing current.activeOperation && current.cursor < 10000) (abort ExecutionNotActive)
              unless (specification.operationId == operationIdFor execution current.cursor) (abort OperationConflict)
              require (validateOperation specification)
              unless (specification.policyDigest == actualBinding.policyDigest) (abort OperationConflict)
              snapshot <- readPayload access actualBinding "snapshot" current.snapshot
              when (specification.kind `elem` [ModelTurn, ModelSummary] && current.modelTurns >= (snapshot :: ExecutionSnapshot).policy.maxModelTurns) (abort (ResourceAdmissionRefused "model-turn limit exhausted"))
              validateAdmissionRoot actualBinding.rootId
              actual <- writePayload execution body
              unless (actual == ref) (abort CorruptReplay)
              Tx.statement (operationKey specification.operationId, execution.value, fromInteger current.cursor, operation) insertOperation
              saveExecution (current & #revision .~ (expected + 1) & #activeOperation .~ Just specification.operationId & #modelTurns .~ (current.modelTurns + if specification.kind `elem` [ModelTurn, ModelSummary] then 1 else 0))
            case result of
              Right () -> pure (Right (Accepted, operation))
              Left EventRejected -> do
                replay <- findOperation specification.operationId
                pure (maybe (Left ExecutionRevisionConflict) (duplicate fingerprint) replay)
              Left (CheckFailed err) -> pure (Left err)
  where
    body = envelope "operation-input" input
    duplicate fingerprint operation
      | operation.executionId == execution && operation.fingerprint == fingerprint = Right (AlreadyAccepted, operation)
      | otherwise = Left OperationConflict

recordOutcomeAndAdvance :: (ExecutionEffects es) => ReplayAccess -> Integer -> OperationId -> OperationOutcome -> NextWork -> Maybe (Calls.CallReceipt, Calls.CallOutcome) -> Eff es (Either ExecutionError Admission)
recordOutcomeAndAdvance access revision operation outcome next accounting = recordOutcomeAndAdvanceWith access revision operation outcome next accounting (pure (Right ()))

-- The final transaction hook admits claim/fence checks and deliberate fault
-- injection. A refusal rolls back lifecycle, payload, cursor and accounting.
recordOutcomeAndAdvanceWith :: (ExecutionEffects es) => ReplayAccess -> Integer -> OperationId -> OperationOutcome -> NextWork -> Maybe (Calls.CallReceipt, Calls.CallOutcome) -> Transaction (Either ExecutionError ()) -> Eff es (Either ExecutionError Admission)
recordOutcomeAndAdvanceWith access@(ReplayAccess execution _ _) expected operationId outcome next accounting finalCheck = catchExecutionWith id do
  previous <- findOperation operationId
  case (previous, payloadReference body) of
    (Nothing, _) -> pure (Left OperationMissing)
    (_, Left err) -> pure (Left err)
    (Just operation, Right ref)
      | ModelReturned {} <- outcome, isNothing accounting -> pure (Left OperationConflict)
      | operation.executionId /= execution -> pure (Left OperationConflict)
      | operation.outcome == Just ref && operation.continuation == Just next -> pure (Right AlreadyAccepted)
      | isJust operation.outcome -> pure (Left OperationConflict)
      | otherwise -> do
          stored <- readMetadata (Tx.statement execution.value selectExecution)
          case stored of
            Nothing -> pure (Left ExecutionMissing)
            Just (_, binding) -> do
              let unresolved = case outcome of OperationUnresolved {} -> True; _ -> False
                  command = if unresolved then Generated.MarkExecutionUnresolved (Generated.MarkExecutionUnresolvedData execution.value (fromInteger expected) (fromInteger (expected + 1))) else advance execution expected
              result <- persist execution command do
                lockRoot binding.rootId
                (state, actualBinding) <- getExecution execution
                checkOutcomeIdentity access actualBinding
                checkRevision expected state
                unless (state.activeOperation == Just operationId && state.phase == Active) (abort OperationConflict)
                actualOperation <- Tx.statement (operationKey operationId) lockOperation >>= maybe (abort OperationMissing) pure
                unless (actualOperation == operation) (abort OperationConflict)
                forM_ accounting \(receipt, terminal) -> do
                  unless (receipt.request.operationId == operationId && receipt.rootId == actualBinding.rootId && receipt.assignmentId == actualBinding.assignmentId) (abort OperationConflict)
                  Calls.finishSelectionCallTx receipt terminal >>= either (abort . ResourceAdmissionRefused . Text.pack . show) (const (pure ()))
                actual <- writePayload execution body
                unless (actual == ref) (abort CorruptReplay)
                Tx.statement (operationKey operationId, operation & #outcome .~ Just ref & #continuation .~ Just next & #uncertain .~ unresolved) updateOperation
                saveExecution (state & #revision .~ (expected + 1) & #cursor .~ (state.cursor + if unresolved then 0 else 1) & #phase .~ (if unresolved then Unresolved else Active) & #activeOperation .~ (if unresolved then Just operationId else Nothing) & #next .~ next)
                finalCheck >>= require
              case result of
                Right () -> pure (Right Accepted)
                Left EventRejected -> do
                  recorded <- findOperation operationId
                  pure (if maybe False (\stored -> stored.outcome == Just ref && stored.continuation == Just next) recorded then Right AlreadyAccepted else Left ExecutionRevisionConflict)
                Left (CheckFailed err) -> pure (Left err)
  where
    body = envelope "operation-outcome" outcome

finishExecution :: (ExecutionEffects es) => ReplayAccess -> Integer -> Aeson.Value -> Eff es (Either ExecutionError Admission)
finishExecution access@(ReplayAccess execution _ _) expected result = catchExecutionWith id $ case payloadReference body of
  Left err -> pure (Left err)
  Right ref -> do
    recorded <- readMetadata (Tx.statement execution.value selectExecution)
    case recorded of
      Just (state, _) | state.phase == Succeeded && state.result == Just ref -> pure (Right AlreadyAccepted)
      Nothing -> pure (Left ExecutionMissing)
      Just (_, binding) -> do
        committed <- persist execution (Generated.FinishExecution (Generated.FinishExecutionData execution.value (fromInteger expected) (fromInteger (expected + 1)))) do
          lockRoot binding.rootId
          validateAdmissionRoot binding.rootId
          (state, actualBinding) <- getExecution execution
          _ <- checkAccess access actualBinding
          checkRevision expected state
          unless (isNothing state.activeOperation) (abort OperationConflict)
          case state.next of
            NeedValidation responseRef -> do
              response <- readPayload access actualBinding "operation-outcome" responseRef
              snapshot <- readPayload access actualBinding "snapshot" state.snapshot
              case response of
                ModelReturned assistant _ -> do
                  validated <- require (validateTerminalOutput (snapshot :: ExecutionSnapshot).policy assistant)
                  unless (validated == result) (abort ExecutionOutputInvalid)
                _ -> abort ExecutionOutputInvalid
            _ -> abort ExecutionOutputInvalid
          actual <- writePayload execution body
          unless (actual == ref) (abort CorruptReplay)
          saveExecution (state & #revision .~ (expected + 1) & #phase .~ Succeeded & #result .~ Just ref & #next .~ WorkFinished)
        case committed of
          Right () -> pure (Right Accepted)
          Left (CheckFailed err) -> pure (Left err)
          Left EventRejected -> do
            stored <- readMetadata (Tx.statement execution.value selectExecution)
            pure case stored of
              Just (state, _) | state.phase == Succeeded && state.result == Just ref -> Right AlreadyAccepted
              _ -> Left ExecutionCommandRefused
  where
    body = envelope "execution-result" result

validateOperation :: OperationSpec -> Either ExecutionError ()
validateOperation specification = do
  unless (all (\text -> not (Text.null text) && Text.length text <= 256) [specification.name, specification.policyDigest, specification.scopeDigest]) (Left OperationConflict)
  unless (maybe True (\n -> n >= 0 && n < 256) specification.responsePosition) (Left OperationConflict)

checkRevision :: Integer -> ExecutionState -> Transaction ()
checkRevision expected state = unless (expected >= 0 && expected < toInteger (maxBound :: Int) && state.revision == expected) (abort ExecutionRevisionConflict)

advance :: ExecutionId -> Integer -> Generated.ExecutionLifecycleCommand
advance execution expected = Generated.AdvanceExecution (Generated.AdvanceExecutionData execution.value (fromInteger expected) (fromInteger (expected + 1)))

getExecution :: ExecutionId -> Transaction (ExecutionState, ExecutionBinding)
getExecution execution = Tx.statement execution.value lockExecution >>= maybe (abort ExecutionMissing) pure

lockRoot :: Maybe ExecutionRootId -> Transaction ()
lockRoot = mapM_ (\root -> Roots.inspectRootTx root >>= either (abort . ResourceAdmissionRefused . Text.pack . show) (const (pure ())))

validateAdmissionRoot :: Maybe ExecutionRootId -> Transaction ()
validateAdmissionRoot = mapM_ \root -> do
  state <- Roots.inspectRootTx root >>= either (abort . ResourceAdmissionRefused . Text.pack . show) pure
  now <- Tx.statement () currentTime
  either (abort . ResourceAdmissionRefused . Text.pack . show) pure (Resources.checkRoot now state.revision state)

persist :: (ExecutionEffects es) => ExecutionId -> Generated.ExecutionLifecycleCommand -> Transaction () -> Eff es (Either PersistenceFailure ())
persist execution command action = catchExecutionWith CheckFailed run
  where
    run = do
      let (catalog, projections) = withLiveExecution (\_ _ -> action)
      result <- runCommandWithCatalogProjections defaultRunCommandOptions executionLifecycleEventStream (Stream.entityStream executionLifecycleCategory execution.value) command catalog projections
      pure case result of
        Right (ProjectionCommandApplied _) -> Right ()
        Right _ -> Left (CheckFailed ProjectionUnavailable)
        Left CommandRejected -> Left EventRejected
        Left (StoreFailed _) -> Left (CheckFailed ExecutionStorageUnavailable)
        Left (RetryExhausted _ _) -> Left (CheckFailed ExecutionStorageUnavailable)
        Left _ -> Left (CheckFailed ExecutionCommandRefused)

protected :: (ExecutionReadEffects es, ToJSON a, FromJSON a) => Transaction a -> Eff es (Either ExecutionError a)
protected action = catchExecutionWith id do
  queried <- runQuery Nothing executionLookupReadModel (toJSON <$> action)
  pure case queried of
    Left _ -> Left ProjectionUnavailable
    Right raw -> case Aeson.fromJSON raw of
      Aeson.Success value -> Right value
      Aeson.Error _ -> Left CorruptReplay

readMetadata :: (ExecutionReadEffects es, ToJSON a, FromJSON a) => Transaction a -> Eff es a
readMetadata action = protected action >>= either (throwIO . ExecutionAbort) pure

catchExecutionWith :: (ExecutionReadEffects es) => (ExecutionError -> failure) -> Eff es (Either failure a) -> Eff es (Either failure a)
catchExecutionWith wrap action = do
  attempted <- tryError @StoreError (catchSync action handler)
  pure (either (const (Left (wrap ExecutionStorageUnavailable))) id attempted)
  where
    handler exception = case fromException exception of
      Just (ExecutionAbort err) -> pure (Left (wrap err))
      Nothing -> throwIO exception

decode :: (FromJSON a) => Aeson.Value -> Transaction a
decode value = case Aeson.fromJSON value of Aeson.Success result -> pure result; Aeson.Error _ -> abort CorruptReplay

operationKey :: OperationId -> Text
operationKey (OperationId key) = key

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

jsonRow :: (FromJSON a) => D.Row a
jsonRow = D.column (D.nonNullable (D.refine parse D.jsonb))
  where
    parse value = case Aeson.fromJSON value of Aeson.Success result -> Right result; Aeson.Error _ -> Left "corrupt execution metadata"

executionRow :: D.Row (ExecutionState, ExecutionBinding)
executionRow = (,) <$> jsonRow <*> jsonRow

selectExecution, lockExecution :: Statement Text (Maybe (ExecutionState, ExecutionBinding))
selectExecution = preparable "SELECT state,binding FROM shikigami.executions WHERE execution_id=$1" textParam (D.rowMaybe executionRow)
lockExecution = preparable "SELECT state,binding FROM shikigami.executions WHERE execution_id=$1 FOR UPDATE" textParam (D.rowMaybe executionRow)

insertExecution :: Statement (Text, ExecutionState, ExecutionBinding) ()
insertExecution = preparable "INSERT INTO shikigami.executions(execution_id,state,binding) VALUES ($1,$2,$3)" (contrazip3 textParam jsonParam jsonParam) D.noResult

saveExecution :: ExecutionState -> Transaction ()
saveExecution state = Tx.statement (state.executionId.value, state) updateExecution

updateExecution :: Statement (Text, ExecutionState) ()
updateExecution = preparable "UPDATE shikigami.executions SET state=$2,updated_at=now() WHERE execution_id=$1" (contrazip2 textParam jsonParam) D.noResult

insertPayload :: Statement (Text, Text, Text, Int64, Aeson.Value) ()
insertPayload = preparable "INSERT INTO shikigami.execution_payloads(execution_id,payload_id,digest,bytes,body) VALUES ($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING" (contrazip5 textParam textParam textParam (E.param (E.nonNullable E.int8)) jsonParam) D.noResult

selectPayload :: Statement (Text, Text) (Maybe (Text, Integer, Aeson.Value))
selectPayload = preparable "SELECT digest,bytes,body FROM shikigami.execution_payloads WHERE execution_id=$1 AND payload_id=$2" (contrazip2 textParam textParam) (D.rowMaybe ((,,) <$> D.column (D.nonNullable D.text) <*> (toInteger <$> D.column (D.nonNullable D.int8)) <*> D.column (D.nonNullable D.jsonb)))

insertOperation :: Statement (Text, Text, Int64, Operation) ()
insertOperation = preparable "INSERT INTO shikigami.execution_transcript_operations(operation_id,execution_id,position,state) VALUES ($1,$2,$3,$4)" (contrazip4 textParam textParam (E.param (E.nonNullable E.int8)) jsonParam) D.noResult

selectOperation, lockOperation :: Statement Text (Maybe Operation)
selectOperation = preparable "SELECT state FROM shikigami.execution_transcript_operations WHERE operation_id=$1" textParam (D.rowMaybe jsonRow)
lockOperation = preparable "SELECT state FROM shikigami.execution_transcript_operations WHERE operation_id=$1 FOR UPDATE" textParam (D.rowMaybe jsonRow)

updateOperation :: Statement (Text, Operation) ()
updateOperation = preparable "UPDATE shikigami.execution_transcript_operations SET state=$2 WHERE operation_id=$1" (contrazip2 textParam jsonParam) D.noResult

listOperations :: Statement Text [Operation]
listOperations = preparable "SELECT state FROM shikigami.execution_transcript_operations WHERE execution_id=$1 ORDER BY position LIMIT 100" textParam (D.rowList jsonRow)

currentTime :: Statement () UTCTime
currentTime = preparable "SELECT clock_timestamp()" E.noParams (D.singleRow (D.column (D.nonNullable D.timestamptz)))

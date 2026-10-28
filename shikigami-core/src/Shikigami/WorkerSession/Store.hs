{-# LANGUAGE ConstraintKinds #-}

-- | The checked lifecycle, ordered mailbox and retained result/event rows share
-- a transaction. Queue notifications never own message or result availability.
module Shikigami.WorkerSession.Store
  ( SessionAccess,
    SessionEffects,
    SessionReadEffects,
    openSession,
    authorizeSession,
    inspectSession,
    loadAdmission,
    readInstruction,
    readAssignment,
    readAssignmentContext,
    nextAssignment,
    acceptMessage,
    startAssignment,
    setAssignmentStatus,
    closeSession,
    recordResult,
    readResult,
    readEvents,
    consumeEventsWith,
    prepareCheckpoint,
    readCheckpointIntent,
    acceptCheckpointWith,
    observeSession,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Control.Exception (Exception, fromException, throw)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as Lazy
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int64)
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
import Keiro.Command (CommandError (..), defaultRunCommandOptions)
import Keiro.Projection (ProjectionCommandOutcome (..), runCommandWithCatalogProjections)
import Keiro.ReadModel (runQuery)
import Keiro.Stream qualified as Stream
import Keiro.Workflow (JournalAppendOutcome (..), WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), awakeableStepPrefix, currentGeneration, prepareJournalAppend)
import Keiro.Workflow.Awakeable (awakeableIdText, awakeableIdToUuid)
import Keiro.Workflow.Awakeable.Schema (AwakeableRow (..), AwakeableStatus (Completed), completeAwakeableTx, lookupAwakeable, lookupAwakeableStatusTx)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..))
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId (..))
import Shikigami.Execution.Resources (Admission (..))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.Transcript (PayloadRef (..))
import Shikigami.Prelude
import Shikigami.Store.ExecutionResources qualified as Roots
import Shikigami.WorkerSession.Catalog (withLiveSession)
import Shikigami.WorkerSession.Checkpoint
import Shikigami.WorkerSession.Identity (assignmentChildWorkflowId, sessionWorkflowId, sessionWorkflowName)
import Shikigami.WorkerSession.Types
import Shikigami.WorkerSessionLifecycle.Generated.Domain qualified as Generated
import Shikigami.WorkerSessionLifecycle.Generated.EventStream (workerSessionLifecycleCategory, workerSessionLifecycleEventStream)
import Shikigami.WorkerSessionLookup.Generated.ReadModel (workerSessionLookupReadModel)

type SessionReadEffects es = (IOE :> es, Store :> es, Error StoreError :> es)

type SessionEffects es = (SessionReadEffects es, KirokuStoreResource :> es)

data SessionAccess = SessionAccess !WorkerSessionId !AgentIdentity !UTCTime

newtype SessionAbort = SessionAbort SessionError deriving stock (Show)

instance Exception SessionAbort

abort :: SessionError -> Transaction a
abort = throw . SessionAbort

require :: Either SessionError a -> Transaction a
require = either abort pure

body :: (ToJSON a) => Text -> a -> Aeson.Value
body kind value = Aeson.object ["format" Aeson..= (1 :: Int), "kind" Aeson..= kind, "content" Aeson..= value]

payloadReference :: Aeson.Value -> Either SessionError PayloadRef
payloadReference value = do
  let bytes = toInteger (Lazy.length (Aeson.encode value))
      digest = versionedDigest "shikigami.worker-session-payload/1" value
  when (bytes > 1048576) (Left SessionPayloadTooLarge)
  pure (PayloadRef ("payload:" <> digest) digest bytes)

writePayload :: WorkerSessionId -> Aeson.Value -> Transaction PayloadRef
writePayload session value = do
  ref <- require (payloadReference value)
  Tx.statement (session.value, ref.payloadId, ref.digest, fromInteger ref.bytes, value) insertPayload
  stored <- Tx.statement (session.value, ref.payloadId) selectPayload
  unless (stored == Just (ref.digest, ref.bytes, value)) (abort SessionBindingConflict)
  pure ref

readPayload :: (FromJSON a) => WorkerSessionId -> Text -> PayloadRef -> Transaction a
readPayload session kind ref = do
  stored <- Tx.statement (session.value, ref.payloadId) selectPayload
  case stored of
    Just (digest, bytes, value@(Aeson.Object fields)) -> do
      actual <- require (payloadReference value)
      unless (actual == ref && digest == ref.digest && bytes == ref.bytes) (abort SessionBindingConflict)
      let decoded = do
            version <- fields Aeson..: "format"
            actualKind <- fields Aeson..: "kind"
            unless (version == (1 :: Int) && actualKind == kind) (fail "unsupported session payload")
            fields Aeson..: "content"
      case parseEither (const decoded) value of
        Right result -> pure result
        Left _ -> abort (SessionInputRefused "session payload is unreadable")
    _ -> abort (SessionInputRefused "session payload is unavailable")

openSession :: (SessionEffects es) => SessionAdmission -> Eff es (Either SessionError (Admission, SessionState))
openSession admission = guarded do
  either (throwIO . SessionAbort) pure (validateAdmission admission)
  ref <- either (throwIO . SessionAbort) pure (payloadReference encoded)
  let session = sessionIdFor admission
      root = fromMaybe (error "validated session root missing") admission.context.executionRootId
      binding = SessionBinding session (scopeDigestFor admission) admission.scope admission.objective admission.context.identity admission.identity root ref
      initial = SessionState 1 session 0 Idle admission.identity 0 Nothing 0 0 0 Nothing Nothing
      matching = \case
        Just (state, existing) | existing == binding -> Right (AlreadyAccepted, state)
        Just _ -> Left SessionBindingConflict
        Nothing -> Left SessionRevisionConflict
  existing <- metadata (Tx.statement session.value selectSession)
  case existing of
    Just _ -> pure (matching existing)
    Nothing -> do
      result <- persist session (Generated.AdmitWorkerSession (Generated.AdmitWorkerSessionData session.value ref.digest)) do
        validateRoot True root
        collision <- Tx.statement session.value selectSession
        when (isJust collision) (abort SessionBindingConflict)
        Tx.statement (session.value, scopeDigestFor admission, initial, binding) insertSession
        actual <- writePayload session encoded
        unless (actual == ref) (abort SessionBindingConflict)
      stored <- metadata (Tx.statement session.value selectSession)
      pure $ case (result, stored) of
        (Right (), _) -> fmap (\(_, state) -> (Accepted, state)) (matching stored)
        (_, Just _) -> matching stored
        (Left err, _) -> Left err
  where
    encoded = body "session-admission" admission

authorizeSession :: (SessionReadEffects es) => WorkerSessionId -> AgentIdentity -> IO (Either Text ()) -> Eff es (Either SessionError SessionAccess)
authorizeSession session actor authorize = guarded do
  current <- metadata (Tx.statement session.value selectSession) >>= maybe (throwIO (SessionAbort SessionMissing)) pure
  checked <- liftIO authorize
  now <- liftIO getCurrentTime
  pure $ case checked of
    Right () | actor == (snd current).parentIdentity || actor == (fst current).owner -> Right (SessionAccess session actor (addUTCTime 60 now))
    _ -> Left SessionOwnerRefused

inspectSession :: (SessionReadEffects es) => WorkerSessionId -> Eff es (Either SessionError (Maybe (SessionState, SessionBinding)))
inspectSession session = protected (Tx.statement session.value selectSession)

loadAdmission :: (SessionReadEffects es) => SessionAccess -> Eff es (Either SessionError SessionAdmission)
loadAdmission access@(SessionAccess session _ _) = protected do
  (state, binding) <- getSession session
  checkAccess access state binding
  readPayload session "session-admission" binding.admission

readInstruction :: (SessionReadEffects es) => SessionAccess -> AssignmentId -> Eff es (Either SessionError Instruction)
readInstruction access@(SessionAccess session _ _) assignment = protected do
  (state, binding) <- getSession session
  checkAccess access state binding
  message <- getAssignment session assignment
  readPayload session "session-instruction" message.input

readAssignment :: (SessionReadEffects es) => SessionAccess -> AssignmentId -> Eff es (Either SessionError MessageReceipt)
readAssignment access@(SessionAccess session _ _) assignment = protected do
  (state, binding) <- getSession session
  checkAccess access state binding
  getAssignment session assignment

readAssignmentContext :: (SessionReadEffects es) => SessionAccess -> AssignmentId -> Eff es (Either SessionError [RetainedFinding])
readAssignmentContext access@(SessionAccess session _ _) assignment = protected do
  (state, binding) <- getSession session
  checkAccess access state binding
  message <- getAssignment session assignment
  maybe (pure []) (readPayload session "assignment-context") message.context

nextAssignment :: (SessionReadEffects es) => SessionAccess -> Eff es (Either SessionError (Maybe MessageReceipt))
nextAssignment access@(SessionAccess session _ _) = protected do
  (state, binding) <- getSession session
  checkAccess access state binding
  Tx.statement session.value firstQueued

-- Expected assignment revision is immutable input. Optimistic session revision
-- is not part of the fingerprint, so a refused race can retry the same key.
acceptMessage :: (SessionEffects es) => SessionAccess -> Integer -> Integer -> OperationId -> Instruction -> Eff es (Either SessionError (Admission, MessageReceipt))
acceptMessage access expected epoch operation instruction = guarded do
  either (throwIO . SessionAbort) pure (validateInstruction instruction)
  ref <- either (throwIO . SessionAbort) pure (payloadReference encoded)
  mutate
    access
    expected
    epoch
    operation
    "accept"
    (toJSON (epoch, ref))
    True
    (\session revision -> Generated.AcceptSessionMessage (Generated.AcceptSessionMessageData session revision (revision + 1)))
    \state _ admission -> do
      unless (state.phase `elem` [Idle, Active, Parked, Unresolved]) (abort SessionClosed)
      when (state.nextSequence >= toInteger admission.maximumAssignments) (abort SessionLimitExceeded)
      queued <- Tx.statement state.sessionId.value countQueued
      when (queued >= fromIntegral admission.mailboxLimit) (abort SessionMailboxFull)
      case instruction.kind of
        FollowUp -> pure ()
        Interrupt assignment -> unless (state.activeAssignment == Just assignment) (abort InterruptTargetChanged)
      actual <- writePayload state.sessionId encoded
      unless (actual == ref) (abort SessionBindingConflict)
      let fingerprint = commandFingerprint "accept" (toJSON (epoch, ref))
          message = MessageReceipt 1 state.sessionId state.nextSequence (assignmentIdFor state.sessionId state.nextSequence operation) operation fingerprint instruction.kind ref instruction.assignmentRevision state.epoch Queued Nothing Nothing Nothing
      Tx.statement (state.sessionId.value, fromInteger state.nextSequence, message.assignmentId.value, operationKey operation, message) insertMessage
      appendEvent state (MessageAccepted message)
      pure (message, state & #nextSequence .~ (state.nextSequence + 1) & #eventCursor .~ (state.eventCursor + 1))
  where
    encoded = body "session-instruction" instruction

-- The child mapping is fixed before any spawn. A second assignment receives a
-- distinct deterministic mapping under the same continuing session.
startAssignment :: (SessionEffects es) => SessionAccess -> Integer -> Integer -> OperationId -> AssignmentId -> Eff es (Either SessionError (Admission, MessageReceipt))
startAssignment access expected epoch operation assignment = guarded do
  mutate
    access
    expected
    epoch
    operation
    "start"
    (toJSON (epoch, assignment))
    True
    (\session revision -> Generated.StartSessionAssignment (Generated.StartSessionAssignmentData session revision (revision + 1)))
    \state _ admission -> do
      unless (state.phase == Idle && isNothing state.activeAssignment) (abort AssignmentStillActive)
      message <- getAssignment state.sessionId assignment
      first <- Tx.statement state.sessionId.value firstQueued
      unless (message.phase == Queued && ((.assignmentId) <$> first) == Just assignment) (abort AssignmentConflict)
      prior <- Tx.statement (state.sessionId.value, fromInteger message.sequence) priorResults
      findings <- forM (reverse prior) \receipt -> do
        result <- readPayload state.sessionId "assignment-result" receipt.output
        let bounded = if Lazy.length (Aeson.encode (result :: AssignmentResult).output) <= 8192 then Just result.output else Nothing
        pure (RetainedFinding receipt bounded)
      context <- writePayload state.sessionId (body "assignment-context" findings)
      let child = assignmentChildWorkflowId state.sessionId admission.worker assignment
          started = message & #phase .~ Running & #epoch .~ state.epoch & #childWorkflowId .~ Just child.unWorkflowId & #context .~ Just context
      saveMessage started
      appendEvent state (AssignmentStarted started)
      pure (started, state & #phase .~ Active & #activeAssignment .~ Just assignment & #eventCursor .~ (state.eventCursor + 1))

-- | Trusted runtime observations only. Resuming/reconciling a status does not
-- grant external write authority; the effect owner must independently admit it.
setAssignmentStatus :: (SessionEffects es) => SessionAccess -> Integer -> Integer -> OperationId -> AssignmentId -> AssignmentPhase -> Eff es (Either SessionError (Admission, MessageReceipt))
setAssignmentStatus access expected epoch operation assignment target =
  case target of
    AssignmentParked -> change (\session revision -> Generated.ParkSessionAssignment (Generated.ParkSessionAssignmentData session revision (revision + 1))) [Active] Parked False
    AssignmentUnresolved -> change (\session revision -> Generated.MarkSessionUnresolved (Generated.MarkSessionUnresolvedData session revision (revision + 1))) [Active, Parked] Unresolved False
    Running -> do
      observed <- inspectAccess
      case observed of
        Left err -> pure (Left err)
        Right Parked -> change (\session revision -> Generated.ResumeSessionAssignment (Generated.ResumeSessionAssignmentData session revision (revision + 1))) [Parked] Active True
        Right Unresolved -> change (\session revision -> Generated.ReconcileSessionAssignment (Generated.ReconcileSessionAssignmentData session revision (revision + 1))) [Unresolved] Active True
        Right _ -> change (\session revision -> Generated.ResumeSessionAssignment (Generated.ResumeSessionAssignmentData session revision (revision + 1))) [Parked] Active True
    _ -> pure (Left (SessionInputRefused "unsupported assignment status transition"))
  where
    inspectAccess = protected do
      let SessionAccess session _ _ = access
      (state, binding) <- getSession session
      checkAccess access state binding
      pure state.phase
    change command sources phase fresh = guarded $
      mutate
        access
        expected
        epoch
        operation
        "status"
        (toJSON (epoch, assignment, target))
        fresh
        command
        \state _ _ -> do
          unless (state.phase `elem` sources && state.activeAssignment == Just assignment) (abort AssignmentConflict)
          message <- getAssignment state.sessionId assignment
          unless (message.epoch == epoch && message.phase `elem` [Running, AssignmentParked, AssignmentUnresolved]) (abort AssignmentConflict)
          let next = message & #phase .~ target
          saveMessage next
          appendEvent state (AssignmentStatusChanged assignment target)
          pure (next, state & #phase .~ phase & #eventCursor .~ (state.eventCursor + 1))

-- | Closure cannot silently discard queued or unresolved work. Final retained
-- events may still be acknowledged after logical closure.
closeSession :: (SessionEffects es) => SessionAccess -> Integer -> Integer -> OperationId -> ResultDisposition -> Eff es (Either SessionError (Admission, SessionState))
closeSession access expected epoch operation disposition =
  case disposition of
    AssignmentFailed -> close (\session revision -> Generated.FailWorkerSession (Generated.FailWorkerSessionData session revision (revision + 1))) Failed
    AssignmentCancelled -> close (\session revision -> Generated.CancelWorkerSession (Generated.CancelWorkerSessionData session revision (revision + 1))) Cancelled
    _ -> pure (Left (SessionInputRefused "idle sessions remain available after successful assignments"))
  where
    close command phase = guarded $
      mutate
        access
        expected
        epoch
        operation
        "close"
        (toJSON (epoch, disposition))
        False
        command
        \state _ _ -> do
          queued <- Tx.statement state.sessionId.value countQueued
          unless (state.phase == Idle && isNothing state.activeAssignment && queued == 0) (abort AssignmentStillActive)
          let next = state & #phase .~ phase & #revision .~ (expected + 1)
          pure (next, next)

recordResult :: (SessionEffects es) => SessionAccess -> Integer -> Integer -> OperationId -> AssignmentResult -> Eff es (Either SessionError (Admission, ResultReceipt))
recordResult access expected epoch operation result = guarded do
  unless (result.format == 1 && length result.artifacts <= 128 && all (\ref -> not (Text.null ref) && Text.length ref <= 256) result.artifacts) (throwIO (SessionAbort (SessionInputRefused "invalid assignment result")))
  ref <- either (throwIO . SessionAbort) pure (payloadReference encoded)
  mutate
    access
    expected
    epoch
    operation
    "result"
    (toJSON (epoch, ref))
    False
    (\session revision -> Generated.RecordSessionResult (Generated.RecordSessionResultData session revision (revision + 1)))
    \state _ _ -> do
      unless (state.phase == Active && state.activeAssignment == Just result.assignmentId) (abort AssignmentConflict)
      message <- getAssignment state.sessionId result.assignmentId
      unless (message.phase == Running && message.epoch == epoch) (abort AssignmentConflict)
      existing <- Tx.statement (state.sessionId.value, result.assignmentId.value) selectResult
      when (isJust existing) (abort MessageConflict)
      actual <- writePayload state.sessionId encoded
      unless (actual == ref) (abort SessionBindingConflict)
      let receipt = ResultReceipt 1 state.sessionId result.assignmentId operation (commandFingerprint "result" (toJSON (epoch, ref))) result.disposition ref (state.eventCursor + 1)
      Tx.statement (state.sessionId.value, result.assignmentId.value, receipt) insertResult
      saveMessage (message & #phase .~ AssignmentFinished & #executionId .~ result.executionId)
      appendEvent state (ResultAvailable receipt)
      pure (receipt, state & #phase .~ Idle & #activeAssignment .~ Nothing & #eventCursor .~ (state.eventCursor + 1))
  where
    encoded = body "assignment-result" result

readResult :: (SessionReadEffects es) => SessionAccess -> AssignmentId -> Eff es (Either SessionError (Maybe (ResultReceipt, AssignmentResult)))
readResult access@(SessionAccess session _ _) assignment = protected do
  (state, binding) <- getSession session
  checkAccess access state binding
  stored <- Tx.statement (session.value, assignment.value) selectResult
  traverse (\receipt -> (receipt,) <$> readPayload session "assignment-result" receipt.output) stored

readEvents :: (SessionReadEffects es) => SessionAccess -> Integer -> Int -> Eff es (Either SessionError [EventReceipt])
readEvents access@(SessionAccess session _ _) after limit
  | after < 0 || after > 100000 || limit < 1 || limit > 100 = pure (Left (SessionInputRefused "invalid event cursor or page limit"))
  | otherwise = protected do
      (state, binding) <- getSession session
      checkAccess access state binding
      Tx.statement (session.value, fromInteger after, fromIntegral limit) listEvents

-- The caller's local integration update shares the cursor transaction. A
-- cross-store checkpoint owner must first converge its durable pending intent.
consumeEventsWith :: (SessionEffects es) => SessionAccess -> Integer -> Integer -> OperationId -> Integer -> Integer -> Transaction (Either SessionError ()) -> Eff es (Either SessionError (Admission, Integer))
consumeEventsWith access expected epoch operation previous through integrate = guarded $
  mutate
    access
    expected
    epoch
    operation
    "consume"
    (toJSON (epoch, previous, through))
    False
    (\session revision -> Generated.ConsumeSessionEvents (Generated.ConsumeSessionEventsData session revision (revision + 1)))
    \state _ _ -> do
      when (isJust state.checkpointIntent) (abort AssignmentConflict)
      unless (state.consumedCursor == previous && through >= previous && through <= state.eventCursor) (abort AssignmentConflict)
      integrate >>= require
      pure (through, state & #consumedCursor .~ through)

-- | Persist the exact bounded event batch before contacting a checkpoint owner.
-- One pending intent prevents overlapping batches from racing unknown receipts.
prepareCheckpoint :: (SessionEffects es) => SessionAccess -> Integer -> Integer -> OperationId -> ObjectiveVersion -> Integer -> Integer -> Eff es (Either SessionError (Admission, CheckpointIntent))
prepareCheckpoint access expected epoch operation version previous through = guarded $
  mutate
    access
    expected
    epoch
    operation
    "checkpoint-prepare"
    (toJSON (epoch, version, previous, through))
    False
    (\session revision -> Generated.PrepareSessionCheckpoint (Generated.PrepareSessionCheckpointData session revision (revision + 1)))
    \state binding _ -> do
      unless (isNothing state.checkpointIntent && state.consumedCursor == previous && previous >= 0 && through > previous && through <= state.eventCursor && through - previous <= 100) (abort AssignmentConflict)
      unless (version.rootId == binding.rootId && version.ownerEpoch == epoch && version.owner == state.owner && all (>= 0) [version.revision, version.assignmentRevision, version.criteriaRevision]) (abort SessionBindingConflict)
      events <- Tx.statement (state.sessionId.value, fromInteger previous, fromInteger (through - previous)) listEvents
      unless (map (.cursor) events == [previous + 1 .. through]) (abort SessionBindingConflict)
      let intent = CheckpointIntent 1 state.sessionId binding.objective operation binding.parentIdentity epoch version previous through events
      pure (intent, state & #checkpointIntent .~ Just operation)

readCheckpointIntent :: (SessionReadEffects es) => SessionAccess -> OperationId -> Eff es (Either SessionError CheckpointIntent)
readCheckpointIntent access@(SessionAccess session _ _) operation = protected do
  (state, binding) <- getSession session
  checkAccess access state binding
  getCheckpointIntent session operation

getCheckpointIntent :: WorkerSessionId -> OperationId -> Transaction CheckpointIntent
getCheckpointIntent session operation = do
  stored <- Tx.statement (session.value, operationKey operation) selectCommand
  case stored of
    Just (_, value) -> case Aeson.fromJSON value of
      Aeson.Success intent | intent.format == 1 && intent.sessionId == session && intent.operationId == operation -> pure intent
      _ -> abort SessionBindingConflict
    _ -> abort AssignmentMissing

-- | Only a receipt for this immutable request permits local integration. An
-- exception or refusal in the hook rolls back receipt, cursor and progress.
acceptCheckpointWith :: (SessionEffects es) => SessionAccess -> Integer -> Integer -> OperationId -> OperationId -> CheckpointReceipt -> Transaction (Either SessionError ()) -> Eff es (Either SessionError (Admission, Integer))
acceptCheckpointWith access expected epoch acknowledgement operation receipt integrate = guarded $
  mutate
    access
    expected
    epoch
    acknowledgement
    "checkpoint-accept"
    (toJSON (epoch, operation, receipt))
    False
    (\session revision -> Generated.ConsumeSessionEvents (Generated.ConsumeSessionEventsData session revision (revision + 1)))
    \state binding _ -> do
      intent <- getCheckpointIntent state.sessionId operation
      unless (state.checkpointIntent == Just operation && state.consumedCursor == intent.previousCursor && state.epoch == intent.epoch && binding.objective == intent.objective && matchesReceipt intent receipt) (abort AssignmentConflict)
      integrate >>= require
      pure (intent.throughCursor, state & #consumedCursor .~ intent.throughCursor & #checkpointIntent .~ Nothing)

observeSession :: (SessionEffects es) => SessionAccess -> Integer -> Integer -> OperationId -> SessionWake -> Eff es (Either SessionError (Admission, SessionState))
observeSession access@(SessionAccess session _ _) expected epoch operation wake = guarded do
  _ <- validateWake session wake
  mutate
    access
    expected
    epoch
    operation
    "observe"
    (toJSON (epoch, wake))
    False
    (\key revision -> Generated.ObserveWorkerSession (Generated.ObserveWorkerSessionData key revision (revision + 1)))
    \state _ _ -> do
      ref <- writePayload session (body "session-wake" wake)
      let next = state & #wake .~ Just ref & #revision .~ (expected + 1)
      pure (next, next)

validateWake :: (SessionReadEffects es) => WorkerSessionId -> SessionWake -> Eff es AwakeableRow
validateWake session wake = do
  row <- lookupAwakeable (awakeableIdToUuid wake.token) >>= maybe (throwIO (SessionAbort SessionBindingConflict)) pure
  generation <- currentGeneration sessionWorkflowName (sessionWorkflowId session)
  let WorkflowName name = sessionWorkflowName
  unless (row.ownerWorkflowName == name && row.ownerWorkflowId == session.value && wake.generation >= 0 && generation == wake.generation) (throwIO (SessionAbort SessionBindingConflict))
  pure row

-- Prepared outside the checked writer, completed inside it. A message cannot
-- commit while losing its published wake. Rotation never redirects an old wake.
prepareNotification :: (SessionReadEffects es) => SessionAccess -> Eff es (Maybe PayloadRef, Transaction ())
prepareNotification access@(SessionAccess session _ _) = do
  (reference, wake) <- metadata do
    (state, binding) <- getSession session
    checkAccess access state binding
    decoded <- traverse (readPayload session "session-wake") state.wake
    pure (state.wake, decoded)
  generation <- currentGeneration sessionWorkflowName (sessionWorkflowId session)
  case wake of
    Just published | published.generation == generation -> do
      _ <- validateWake session published
      now <- liftIO getCurrentTime
      append <- prepareJournalAppend sessionWorkflowName (sessionWorkflowId session) published.generation (StepRecorded (awakeableStepPrefix <> awakeableIdText published.token) (toJSON session) now)
      pure
        ( reference,
          do
            transitioned <- completeAwakeableTx (awakeableIdToUuid published.token) (toJSON session) now
            status <- lookupAwakeableStatusTx (awakeableIdToUuid published.token)
            when (transitioned || status == Just Completed) do
              append >>= \case
                JournalAppendConflict {} -> abort SessionStorageUnavailable
                _ -> pure ()
        )
    _ -> pure (reference, pure ())

mutate :: (SessionEffects es, ToJSON a, FromJSON a) => SessionAccess -> Integer -> Integer -> OperationId -> Text -> Aeson.Value -> Bool -> (Text -> Int -> Generated.WorkerSessionLifecycleCommand) -> (SessionState -> SessionBinding -> SessionAdmission -> Transaction (a, SessionState)) -> Eff es (Either SessionError (Admission, a))
mutate access@(SessionAccess session actor _) expected epoch operation kind input fresh command action = do
  requireKey operation
  (_, binding) <- metadata (Tx.statement session.value selectSession) >>= maybe (throwIO (SessionAbort SessionMissing)) pure
  unless (actor == binding.parentIdentity) (throwIO (SessionAbort SessionOwnerRefused))
  let fingerprint = commandFingerprint kind input
      decodeStored = \case
        Just (digest, value) | digest == fingerprint -> case Aeson.fromJSON value of Aeson.Success result -> Right (AlreadyAccepted, result); _ -> Left SessionBindingConflict
        Just _ -> Left MessageConflict
        Nothing -> Left SessionRevisionConflict
  old <- metadata (Tx.statement (session.value, operationKey operation) selectCommand)
  case old of
    Just _ -> pure (decodeStored old)
    Nothing -> do
      notification <- if kind == "observe" then pure Nothing else Just <$> prepareNotification access
      result <- persist session (command session.value (fromInteger expected)) do
        validateRoot fresh binding.rootId
        (state, actualBinding) <- getSession session
        checkAccess access state actualBinding
        unless (actor == actualBinding.parentIdentity && state.epoch == epoch) (abort SessionOwnerRefused)
        unless (state.revision == expected && expected >= 0 && expected < toInteger (maxBound :: Int)) (abort SessionRevisionConflict)
        admission <- readPayload session "session-admission" actualBinding.admission
        (value, next) <- action state actualBinding admission
        forM_ notification \(reference, notify) -> do
          unless (reference == state.wake) (abort SessionRevisionConflict)
          notify
        saveSession (next & #revision .~ (expected + 1))
        Tx.statement (session.value, operationKey operation, fingerprint, toJSON value) insertCommand
      stored <- metadata (Tx.statement (session.value, operationKey operation) selectCommand)
      pure $ case (result, stored) of
        (Right (), _) -> fmap (\(_, value) -> (Accepted, value)) (decodeStored stored)
        (_, Just _) -> decodeStored stored
        (Left err, _) -> Left err

commandFingerprint :: Text -> Aeson.Value -> Text
commandFingerprint kind input = versionedDigest "shikigami.worker-session-command/1" (toJSON (kind, input))

requireKey :: (SessionReadEffects es) => OperationId -> Eff es ()
requireKey operation = unless (either (const False) (const True) (Resources.validateKey (operationKey operation))) (throwIO (SessionAbort MessageConflict))

checkAccess :: SessionAccess -> SessionState -> SessionBinding -> Transaction ()
checkAccess (SessionAccess session actor expiresAt) state binding = do
  now <- Tx.statement () currentTime
  unless (state.sessionId == session && binding.sessionId == session && now < expiresAt && (actor == binding.parentIdentity || actor == state.owner)) (abort SessionOwnerRefused)

validateRoot :: Bool -> ExecutionRootId -> Transaction ()
validateRoot fresh root = do
  current <- Roots.inspectRootTx root >>= either (const (abort SessionOwnerRefused)) pure
  when fresh do
    now <- Tx.statement () currentTime
    either (const (abort SessionOwnerRefused)) pure (Resources.checkRoot now current.revision current)

appendEvent :: SessionState -> SessionEvent -> Transaction ()
appendEvent state event = Tx.statement (state.sessionId.value, fromInteger (state.eventCursor + 1), EventReceipt (state.eventCursor + 1) event) insertEvent

getSession :: WorkerSessionId -> Transaction (SessionState, SessionBinding)
getSession session = Tx.statement session.value lockSession >>= maybe (abort SessionMissing) pure

getAssignment :: WorkerSessionId -> AssignmentId -> Transaction MessageReceipt
getAssignment session assignment = Tx.statement (session.value, assignment.value) selectMessage >>= maybe (abort AssignmentMissing) pure

saveSession :: SessionState -> Transaction ()
saveSession state = Tx.statement (state.sessionId.value, state) updateSession

saveMessage :: MessageReceipt -> Transaction ()
saveMessage message = Tx.statement (message.sessionId.value, message.assignmentId.value, message) updateMessage

operationKey :: OperationId -> Text
operationKey (OperationId key) = key

persist :: (SessionEffects es) => WorkerSessionId -> Generated.WorkerSessionLifecycleCommand -> Transaction () -> Eff es (Either SessionError ())
persist session command action = guarded do
  let (catalog, projections) = withLiveSession (\_ _ -> action)
  result <- runCommandWithCatalogProjections defaultRunCommandOptions workerSessionLifecycleEventStream (Stream.entityStream workerSessionLifecycleCategory session.value) command catalog projections
  pure case result of
    Right (ProjectionCommandApplied _) -> Right ()
    Right _ -> Left SessionProjectionUnavailable
    Left CommandRejected -> Left SessionRevisionConflict
    Left (StoreFailed _) -> Left SessionStorageUnavailable
    Left (RetryExhausted _ _) -> Left SessionStorageUnavailable
    Left _ -> Left SessionCommandRefused

protected :: (SessionReadEffects es, ToJSON a, FromJSON a) => Transaction a -> Eff es (Either SessionError a)
protected action = guarded do
  result <- runQuery Nothing workerSessionLookupReadModel (toJSON <$> action)
  pure case result of
    Left _ -> Left SessionProjectionUnavailable
    Right value -> case Aeson.fromJSON value of Aeson.Success answer -> Right answer; _ -> Left SessionBindingConflict

metadata :: (SessionReadEffects es, ToJSON a, FromJSON a) => Transaction a -> Eff es a
metadata action = protected action >>= either (throwIO . SessionAbort) pure

guarded :: (SessionReadEffects es) => Eff es (Either SessionError a) -> Eff es (Either SessionError a)
guarded action = do
  result <- tryError @StoreError (catchSync action \exception -> case fromException exception of Just (SessionAbort err) -> pure (Left err); Nothing -> throwIO exception)
  pure (either (const (Left SessionStorageUnavailable)) id result)

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

jsonParam :: (ToJSON a) => E.Params a
jsonParam = toJSON >$< E.param (E.nonNullable E.jsonb)

jsonRow :: (FromJSON a) => D.Row a
jsonRow = D.column (D.nonNullable (D.refine (\value -> case Aeson.fromJSON value of Aeson.Success answer -> Right answer; Aeson.Error _ -> Left "unsupported session metadata") D.jsonb))

selectSession, lockSession :: Statement Text (Maybe (SessionState, SessionBinding))
selectSession = preparable "SELECT state,binding FROM shikigami.worker_sessions WHERE session_id=$1" textParam (D.rowMaybe ((,) <$> jsonRow <*> jsonRow))
lockSession = preparable "SELECT state,binding FROM shikigami.worker_sessions WHERE session_id=$1 FOR UPDATE" textParam (D.rowMaybe ((,) <$> jsonRow <*> jsonRow))

insertSession :: Statement (Text, Text, SessionState, SessionBinding) ()
insertSession = preparable "INSERT INTO shikigami.worker_sessions(session_id,scope_digest,state,binding) VALUES ($1,$2,$3,$4)" (contrazip4 textParam textParam jsonParam jsonParam) D.noResult

updateSession :: Statement (Text, SessionState) ()
updateSession = preparable "UPDATE shikigami.worker_sessions SET state=$2,updated_at=clock_timestamp() WHERE session_id=$1" (contrazip2 textParam jsonParam) D.noResult

insertPayload :: Statement (Text, Text, Text, Int64, Aeson.Value) ()
insertPayload = preparable "INSERT INTO shikigami.worker_session_payloads(session_id,payload_id,digest,bytes,body) VALUES ($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING" (contrazip5 textParam textParam textParam (E.param (E.nonNullable E.int8)) jsonParam) D.noResult

selectPayload :: Statement (Text, Text) (Maybe (Text, Integer, Aeson.Value))
selectPayload = preparable "SELECT digest,bytes,body FROM shikigami.worker_session_payloads WHERE session_id=$1 AND payload_id=$2" (contrazip2 textParam textParam) (D.rowMaybe ((,,) <$> D.column (D.nonNullable D.text) <*> (toInteger <$> D.column (D.nonNullable D.int8)) <*> D.column (D.nonNullable D.jsonb)))

insertMessage :: Statement (Text, Int64, Text, Text, MessageReceipt) ()
insertMessage = preparable "INSERT INTO shikigami.worker_session_messages(session_id,sequence,assignment_id,operation_id,state) VALUES ($1,$2,$3,$4,$5)" (contrazip5 textParam (E.param (E.nonNullable E.int8)) textParam textParam jsonParam) D.noResult

selectMessage :: Statement (Text, Text) (Maybe MessageReceipt)
selectMessage = preparable "SELECT state FROM shikigami.worker_session_messages WHERE session_id=$1 AND assignment_id=$2" (contrazip2 textParam textParam) (D.rowMaybe jsonRow)

firstQueued :: Statement Text (Maybe MessageReceipt)
firstQueued = preparable "SELECT state FROM shikigami.worker_session_messages WHERE session_id=$1 AND state->>'phase'='Queued' ORDER BY sequence LIMIT 1" textParam (D.rowMaybe jsonRow)

countQueued :: Statement Text Int64
countQueued = preparable "SELECT count(*) FROM shikigami.worker_session_messages WHERE session_id=$1 AND state->>'phase'='Queued'" textParam (D.singleRow (D.column (D.nonNullable D.int8)))

updateMessage :: Statement (Text, Text, MessageReceipt) ()
updateMessage = preparable "UPDATE shikigami.worker_session_messages SET state=$3 WHERE session_id=$1 AND assignment_id=$2" (contrazip3 textParam textParam jsonParam) D.noResult

insertResult :: Statement (Text, Text, ResultReceipt) ()
insertResult = preparable "INSERT INTO shikigami.worker_session_results(session_id,assignment_id,state) VALUES ($1,$2,$3)" (contrazip3 textParam textParam jsonParam) D.noResult

selectResult :: Statement (Text, Text) (Maybe ResultReceipt)
selectResult = preparable "SELECT state FROM shikigami.worker_session_results WHERE session_id=$1 AND assignment_id=$2" (contrazip2 textParam textParam) (D.rowMaybe jsonRow)

priorResults :: Statement (Text, Int64) [ResultReceipt]
priorResults = preparable "SELECT r.state FROM shikigami.worker_session_results r JOIN shikigami.worker_session_messages m ON m.assignment_id=r.assignment_id AND m.session_id=r.session_id WHERE r.session_id=$1 AND m.sequence<$2 ORDER BY m.sequence DESC LIMIT 3" (contrazip2 textParam (E.param (E.nonNullable E.int8))) (D.rowList jsonRow)

insertEvent :: Statement (Text, Int64, EventReceipt) ()
insertEvent = preparable "INSERT INTO shikigami.worker_session_events(session_id,cursor,state) VALUES ($1,$2,$3)" (contrazip3 textParam (E.param (E.nonNullable E.int8)) jsonParam) D.noResult

listEvents :: Statement (Text, Int64, Int64) [EventReceipt]
listEvents = preparable "SELECT state FROM shikigami.worker_session_events WHERE session_id=$1 AND cursor>$2 ORDER BY cursor LIMIT $3" (contrazip3 textParam (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.int8))) (D.rowList jsonRow)

selectCommand :: Statement (Text, Text) (Maybe (Text, Aeson.Value))
selectCommand = preparable "SELECT fingerprint,state FROM shikigami.worker_session_commands WHERE session_id=$1 AND operation_id=$2" (contrazip2 textParam textParam) (D.rowMaybe ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb)))

insertCommand :: Statement (Text, Text, Text, Aeson.Value) ()
insertCommand = preparable "INSERT INTO shikigami.worker_session_commands(session_id,operation_id,fingerprint,state) VALUES ($1,$2,$3,$4)" (contrazip4 textParam textParam textParam jsonParam) D.noResult

currentTime :: Statement () UTCTime
currentTime = preparable "SELECT clock_timestamp()" E.noParams (D.singleRow (D.column (D.nonNullable D.timestamptz)))

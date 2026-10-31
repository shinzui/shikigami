{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}

-- | The checked lifecycle, ordered mailbox and retained result/event rows share
-- a transaction. Queue notifications never own message or result availability.
module Shikigami.WorkerSession.Store
  ( SessionAccess,
    SessionEffects,
    SessionReadEffects,
    openSession,
    openSessionWithLimit,
    ensureSessionDriver,
    authorizeSession,
    inspectSession,
    rootSessionsTerminalTx,
    inspectSessionPage,
    loadAdmission,
    readInstruction,
    readAssignment,
    readAssignmentContext,
    nextAssignment,
    acceptMessage,
    acceptScopedMessage,
    readMessageAcceptance,
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
    subscribeEvents,
    requestTransfer,
    readTransferIntent,
    readTransferOperation,
    readTransferFence,
    markTransferReconciling,
    retainTransferFence,
    establishOwner,
    assignmentExecutions,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Control.Exception (Exception, fromException, throw)
import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as Lazy
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Maybe (catMaybes, listToMaybe)
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
import Keiro.Command (CommandError (..))
import Keiro.Projection (ProjectionCommandOutcome (..), runCommandWithCatalogProjections)
import Keiro.ReadModel (runQuery)
import Keiro.Stream qualified as Stream
import Keiro.Workflow (JournalAppendOutcome (..), WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), awakeableStepPrefix, currentGeneration, prepareJournalAppend)
import Keiro.Workflow.Awakeable (awakeableIdText, awakeableIdToUuid)
import Keiro.Workflow.Awakeable.Schema (AwakeableRow (..), AwakeableStatus (Completed, Pending), completeAwakeableTx, lookupAwakeable, lookupAwakeableStatusTx)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..), assertMayDelegate, checkCycle, checkDepth)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.App (CommandEffects, commandOptions)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Decision.ModelAlias (ModelAlias, modelAliasText)
import Shikigami.Execution.Identity (ExecutionRootId, OperationId, operationIdText)
import Shikigami.Execution.Payload
import Shikigami.Execution.Resources (Admission (..))
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Transcript (ExecutionId, PayloadRef (..))
import Shikigami.Prelude hiding ((.=))
import Shikigami.StateRevision
import Shikigami.WorkerSession.Catalog (withLiveSession)
import Shikigami.WorkerSession.Checkpoint
import Shikigami.WorkerSession.Identity (assignmentChildWorkflowIdV2, sessionWorkflowId, sessionWorkflowName)
import Shikigami.WorkerSession.Input
import Shikigami.WorkerSession.Position
import Shikigami.WorkerSession.Transfer
import Shikigami.WorkerSession.Types
import Shikigami.WorkerSessionLifecycle.Generated.Domain qualified as Generated
import Shikigami.WorkerSessionLifecycle.Generated.EventStream (workerSessionLifecycleCategory, workerSessionLifecycleEventStream)
import Shikigami.WorkerSessionLookup.Generated.ReadModel (workerSessionLookupReadModel)

type SessionReadEffects es = (IOE :> es, Store :> es, Error StoreError :> es)

type SessionEffects es = (SessionReadEffects es, KirokuStoreResource :> es, CommandEffects es)

data SessionAccess = SessionAccess !WorkerSessionId !AgentIdentity !UTCTime

newtype SessionAbort = SessionAbort SessionError deriving stock (Show)

instance Exception SessionAbort

abort :: SessionError -> Transaction a
abort = throw . SessionAbort

require :: Either SessionError a -> Transaction a
require = either abort pure

body :: (ToJSON a) => Text -> a -> Aeson.Value
body kind value = Aeson.object ["format" .= (1 :: Int), "kind" .= kind, "content" .= value]

payloadReference :: Aeson.Value -> Either SessionError PayloadRef
payloadReference value = do
  let encodedBytes = toInteger (Lazy.length (Aeson.encode value))
  when (encodedBytes > 1048576) (Left SessionPayloadTooLarge)
  first (const (SessionInputRefused "invalid payload reference")) do
    digest <- parsePayloadDigest (versionedDigest "shikigami.worker-session-payload/1" value)
    payloadId <- parsePayloadId ("payload:" <> payloadDigestText digest)
    bytes <- parsePayloadByteCount encodedBytes
    pure (PayloadRef payloadId digest bytes)

writePayload :: WorkerSessionId -> Aeson.Value -> Transaction PayloadRef
writePayload session value = do
  ref <- require (payloadReference value)
  Tx.statement (session.value, ref.payloadId, ref.digest, ref.bytes, value) insertPayload
  stored <- Tx.statement (session.value, ref.payloadId) selectPayload
  unless (stored == Just (Right (ref.digest, ref.bytes, value))) (abort SessionBindingConflict)
  pure ref

readPayload :: (FromJSON a) => WorkerSessionId -> Text -> PayloadRef -> Transaction a
readPayload session kind ref = do
  stored <- Tx.statement (session.value, ref.payloadId) selectPayload
  case stored of
    Just (Right (digest, bytes, value@(Aeson.Object fields))) -> do
      actual <- require (payloadReference value)
      unless (actual == ref && digest == ref.digest && bytes == ref.bytes) (abort SessionBindingConflict)
      let decoded = do
            version <- fields .: "format"
            actualKind <- fields .: "kind"
            unless (version == (1 :: Int) && actualKind == kind) (fail "unsupported session payload")
            fields .: "content"
      case parseEither (const decoded) value of
        Right result -> pure result
        Left _ -> abort (SessionInputRefused "session payload is unreadable")
    Just (Left _) -> abort SessionBindingConflict
    _ -> abort (SessionInputRefused "session payload is unavailable")

openSession :: (SessionEffects es) => SessionAdmission -> Eff es (Either SessionError (Admission, SessionState))
openSession = openSessionWithLimit maximumSessionCapacity

openSessionWithLimit :: (SessionEffects es) => MaximumSessions -> SessionAdmission -> Eff es (Either SessionError (Admission, SessionState))
openSessionWithLimit maximumSessions admission = guarded do
  either (throwIO . SessionAbort) pure (validateAdmission admission)
  ref <- either (throwIO . SessionAbort) pure (payloadReference encoded)
  let session = sessionIdFor admission
      root = fromMaybe (error "validated session root missing") admission.context.executionRootId
      binding = SessionBinding session (scopeDigestFor admission) admission.scope admission.objective admission.context.identity admission.identity root ref
      initial = SessionState 1 session initialRevision Idle admission.identity initialRevision Nothing initialRevision initialRevision initialRevision Nothing Nothing Nothing Nothing []
      matching = \case
        Just (state, existing) | existing == binding -> Right (AlreadyAccepted, state)
        Just _ -> Left SessionBindingConflict
        Nothing -> Left SessionRevisionConflict
  existing <- metadata (readRows session.value selectSession)
  case existing of
    Just _ -> pure (matching existing)
    Nothing -> do
      result <- persist session (Generated.AdmitWorkerSession (Generated.AdmitWorkerSessionData session (payloadDigestText ref.digest))) do
        validateRoot True root
        void (Tx.statement (versionedDigest "shikigami.worker-session-scope-lock/1" (toJSON (admission.scope.parent, admission.context.identity))) lockScope)
        existingScope <- readRows (admission.scope.parent, toJSON admission.context.identity) selectScopeBinding
        when (maybe False ((/= root) . (.rootId)) existingScope) (abort SessionBindingConflict)
        count <- Tx.statement (admission.scope.parent, toJSON admission.context.identity) countScopeSessions
        when (count >= fromIntegral (sessionLimit maximumSessions)) (abort SessionLimitExceeded)
        collision <- readRows session.value selectSession
        when (isJust collision) (abort SessionBindingConflict)
        Tx.statement (session.value, scopeDigestFor admission, initial, binding) insertSession
        actual <- writePayload session encoded
        unless (actual == ref) (abort SessionBindingConflict)
      stored <- metadata (readRows session.value selectSession)
      pure $ case (result, stored) of
        (Right (), _) -> fmap (\(_, state) -> (Accepted, state)) (matching stored)
        (_, Just _) -> matching stored
        (Left err, _) -> Left err
  where
    encoded = body "session-admission" admission

-- | Register only the original input. The public journal API atomically creates
-- the resume instance; an existing generation/input is never reset. A command
-- retry repairs a crash after mailbox acceptance but before this registration.
ensureSessionDriver :: (SessionReadEffects es) => SessionAccess -> Eff es (Either SessionError ())
ensureSessionDriver access@(SessionAccess session _ _) = guarded do
  now <- liftIO getCurrentTime
  let input = Aeson.object ["sessionId" .= session]
  append <- prepareJournalAppend sessionWorkflowName (sessionWorkflowId session) 0 (StepRecorded "ingest-session" input now)
  protected do
    (state, binding) <- getSession session
    checkAccess access state binding
    unless (state.phase `elem` [Failed, Cancelled]) do
      append >>= \case
        JournalAppended {} -> pure ()
        JournalAlreadyPresent original | original == input -> pure ()
        _ -> abort SessionStorageUnavailable

authorizeSession :: (SessionReadEffects es) => WorkerSessionId -> AgentIdentity -> IO (Either Text ()) -> Eff es (Either SessionError SessionAccess)
authorizeSession session actor authorize = guarded do
  current <- metadata (readRows session.value selectSession) >>= maybe (throwIO (SessionAbort SessionMissing)) pure
  checked <- liftIO authorize
  now <- liftIO getCurrentTime
  pure $ case checked of
    Right () | actor == (snd current).parentIdentity || actor == (fst current).owner -> Right (SessionAccess session actor (addUTCTime 60 now))
    _ -> Left SessionOwnerRefused

inspectSession :: (SessionReadEffects es) => WorkerSessionId -> Eff es (Either SessionError (Maybe (SessionState, SessionBinding)))
inspectSession session = protected (readRows session.value selectSession)

-- | Cleanup must not infer absence from fields inside metadata it has not
-- decoded. With no independent relational root index, unreadable attribution
-- refuses this metadata-only scan rather than hiding a possibly live session.
rootSessionsTerminalTx :: ExecutionRootId -> Transaction (Either SessionError Bool)
rootSessionsTerminalTx root = do
  retained <- Tx.statement () statement
  case retained of
    Left () -> Tx.condemn >> pure (Left SessionBindingConflict)
    Right terminal -> pure (Right terminal)
  where
    statement = preparable "SELECT session_id,state,binding FROM shikigami.worker_sessions" E.noParams (D.foldlRows collect (Right True) row)
    row :: D.Row (Text, Either () (SessionState, SessionBinding))
    row = (,) <$> D.column (D.nonNullable D.text) <*> ((\state binding -> (,) <$> state <*> binding) <$> jsonRow <*> jsonRow)
    collect prior (identifier, parsed) = do
      allTerminal <- prior
      (state, binding) <- parsed
      unless (state.sessionId.value == identifier && binding.sessionId == state.sessionId) (Left ())
      let terminal = allTerminal && (binding.rootId /= root || state.phase `elem` [Failed, Cancelled])
      terminal `seq` pure terminal

inspectSessionPage :: (SessionReadEffects es) => WorkerSessionId -> MessagePosition -> Int -> Eff es (Either SessionError (Maybe SessionInspection))
inspectSessionPage session after limit
  | messagePositionNumber after >= 10000 || limit < 1 || limit > 20 = pure (Left (SessionInputRefused "invalid assignment cursor or page limit"))
  | otherwise = protected do
      readRows session.value selectSession >>= traverse \(state, binding) -> do
        messages <- readRows (session.value, fromInteger (messagePositionNumber after), fromIntegral limit) pageMessages
        active <- traverse (getAssignment session) state.activeAssignment
        results <- catMaybes <$> traverse (\message -> readRows (session.value, message.assignmentId.value) selectResult) messages
        let next = maybe after (afterMessage . (.sequence)) (listToMaybe (reverse messages))
        pure (SessionInspection state binding messages active results next (messagePositionNumber next + 1 < revisionNumber state.nextSequence))

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
  readRows session.value firstQueued

-- Expected assignment revision is immutable input. Optimistic session revision
-- is not part of the fingerprint, so a refused race can retry the same key.
acceptMessage :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> Instruction -> Eff es (Either SessionError (Admission, MessageReceipt))
acceptMessage access expected epoch operation instruction = acceptScopedMessage access expected epoch operation Nothing instruction

acceptScopedMessage :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> Maybe [ModelAlias] -> Instruction -> Eff es (Either SessionError (Admission, MessageReceipt))
acceptScopedMessage access expected epoch operation permissions instruction = guarded do
  either (throwIO . SessionAbort) pure (validateInstruction instruction)
  unless (maybe True (\aliases -> not (null aliases) && length aliases <= 128 && all ((<= 256) . Text.length . modelAliasText) aliases) permissions) (throwIO (SessionAbort SessionOwnerRefused))
  ref <- either (throwIO . SessionAbort) pure (payloadReference encoded)
  let commandInput = maybe (toJSON (epoch, ref)) (\aliases -> toJSON (epoch, ref, aliases)) permissions
  mutate
    access
    expected
    epoch
    operation
    "accept"
    commandInput
    True
    (\session revision -> Generated.AcceptSessionMessage (Generated.AcceptSessionMessageData session revision (revision + 1)))
    \state _ admission -> do
      unless (state.phase `elem` [Idle, Active, Parked, Unresolved, Transferring]) (abort SessionClosed)
      when (revisionNumber state.nextSequence >= toInteger (sessionLimit admission.maximumAssignments)) (abort SessionLimitExceeded)
      queued <- Tx.statement state.sessionId.value countQueued
      when (queued >= fromIntegral (sessionLimit admission.mailboxLimit)) (abort SessionMailboxFull)
      case instruction.kind of
        FollowUp -> pure ()
        Interrupt assignment -> unless (state.activeAssignment == Just assignment) (abort InterruptTargetChanged)
      actual <- writePayload state.sessionId encoded
      unless (actual == ref) (abort SessionBindingConflict)
      let fingerprint = commandFingerprint "accept" commandInput
          message = MessageReceipt 1 state.sessionId state.nextSequence (assignmentIdFor state.sessionId state.nextSequence operation) operation fingerprint instruction.kind ref instruction.assignmentRevision state.epoch Queued Nothing Nothing Nothing permissions
      Tx.statement (state.sessionId.value, fromInteger (revisionNumber state.nextSequence), message.assignmentId.value, operationKey operation, message) insertMessage
      appendEvent state (MessageAccepted message)
      pure (message, state & #nextSequence .~ (advanceRevision state.nextSequence) & #eventCursor .~ (advanceRevision state.eventCursor))
  where
    encoded = body "session-instruction" instruction

readMessageAcceptance :: (SessionReadEffects es) => SessionAccess -> OperationId -> Eff es (Either SessionError (Maybe MessageReceipt))
readMessageAcceptance access@(SessionAccess session _ _) operation = protected do
  (state, binding) <- getSession session
  checkAccess access state binding
  stored <- Tx.statement (session.value, operationKey operation) selectCommand
  case stored of
    Nothing -> pure Nothing
    Just (_, value) -> case Aeson.fromJSON value of
      Aeson.Success receipt | receipt.sessionId == session && receipt.operationId == operation -> pure (Just receipt)
      _ -> abort MessageConflict

-- The child mapping is fixed before any spawn. A second assignment receives a
-- distinct deterministic mapping under the same continuing session.
startAssignment :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> AssignmentId -> Eff es (Either SessionError (Admission, MessageReceipt))
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
      first <- readRows state.sessionId.value firstQueued
      unless (message.phase == Queued && ((.assignmentId) <$> first) == Just assignment) (abort AssignmentConflict)
      prior <- readRows (state.sessionId.value, fromInteger (revisionNumber message.sequence)) priorResults
      findings <- forM (reverse prior) \receipt -> do
        result <- readPayload state.sessionId "assignment-result" receipt.output
        let bounded = if Lazy.length (Aeson.encode (result :: AssignmentResult).output) <= 8192 then Just result.output else Nothing
        pure (RetainedFinding receipt bounded)
      context <- writePayload state.sessionId (body "assignment-context" findings)
      let child = assignmentChildWorkflowIdV2 state.sessionId (fromMaybe admission.worker state.worker) assignment
          started = message & #phase .~ Running & #epoch .~ state.epoch & #childWorkflowId .~ Just child.unWorkflowId & #context .~ Just context
      saveMessage started
      appendEvent state (AssignmentStarted started)
      pure (started, state & #phase .~ Active & #activeAssignment .~ Just assignment & #eventCursor .~ (advanceRevision state.eventCursor))

-- | Trusted runtime observations only. Resuming/reconciling a status does not
-- grant external write authority; the effect owner must independently admit it.
setAssignmentStatus :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> AssignmentId -> AssignmentPhase -> Eff es (Either SessionError (Admission, MessageReceipt))
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
          pure (next, state & #phase .~ phase & #eventCursor .~ (advanceRevision state.eventCursor))

-- | Closure cannot silently discard queued or unresolved work. Final retained
-- events may still be acknowledged after logical closure.
closeSession :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> ResultDisposition -> Eff es (Either SessionError (Admission, SessionState))
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
          appendEvent state (SessionClosedEvent phase)
          let next = state & #phase .~ phase & #revision .~ (advanceRevision expected) & #eventCursor .~ (advanceRevision state.eventCursor)
          pure (next, next)

recordResult :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> AssignmentResult -> Eff es (Either SessionError (Admission, ResultReceipt))
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
      unless (state.phase `elem` [Active, Transferring] && state.activeAssignment == Just result.assignmentId) (abort AssignmentConflict)
      message <- getAssignment state.sessionId result.assignmentId
      unless (message.phase == Running && message.epoch == epoch) (abort AssignmentConflict)
      existing <- readRows (state.sessionId.value, result.assignmentId.value) selectResult
      when (isJust existing) (abort MessageConflict)
      actual <- writePayload state.sessionId encoded
      unless (actual == ref) (abort SessionBindingConflict)
      let receipt = ResultReceipt 1 state.sessionId result.assignmentId operation (commandFingerprint "result" (toJSON (epoch, ref))) result.disposition ref (advanceRevision state.eventCursor)
      Tx.statement (state.sessionId.value, result.assignmentId.value, receipt) insertResult
      saveMessage (message & #phase .~ AssignmentFinished & #executionId .~ result.executionId)
      appendEvent state (ResultAvailable receipt)
      pure (receipt, state & #phase .~ (if state.phase == Transferring then Transferring else Idle) & #activeAssignment .~ Nothing & #eventCursor .~ (advanceRevision state.eventCursor))
  where
    encoded = body "assignment-result" result

readResult :: (SessionReadEffects es) => SessionAccess -> AssignmentId -> Eff es (Either SessionError (Maybe (ResultReceipt, AssignmentResult)))
readResult access@(SessionAccess session _ _) assignment = protected do
  (state, binding) <- getSession session
  checkAccess access state binding
  stored <- readRows (session.value, assignment.value) selectResult
  traverse (\receipt -> (receipt,) <$> readPayload session "assignment-result" receipt.output) stored

readEvents :: (SessionReadEffects es) => SessionAccess -> StateRevision "worker-event" -> Int -> Eff es (Either SessionError [EventReceipt])
readEvents access@(SessionAccess session _ _) after limit
  | revisionNumber after > 100000 || limit < 1 || limit > 100 = pure (Left (SessionInputRefused "invalid event cursor or page limit"))
  | otherwise = protected do
      (state, binding) <- getSession session
      checkAccess access state binding
      readRows (session.value, fromInteger (revisionNumber after), fromIntegral limit) listEvents

-- The caller's local integration update shares the cursor transaction. A
-- cross-store checkpoint owner must first converge its durable pending intent.
consumeEventsWith :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> StateRevision "worker-event" -> StateRevision "worker-event" -> Transaction (Either SessionError ()) -> Eff es (Either SessionError (Admission, StateRevision "worker-event"))
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
prepareCheckpoint :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> ObjectiveVersion -> StateRevision "worker-event" -> StateRevision "worker-event" -> Eff es (Either SessionError (Admission, CheckpointIntent))
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
      unless (isNothing state.checkpointIntent && state.consumedCursor == previous && through > previous && through <= state.eventCursor && revisionNumber through - revisionNumber previous <= 100) (abort AssignmentConflict)
      unless (version.rootId == binding.rootId && version.ownerEpoch == epoch && version.owner == state.owner) (abort SessionBindingConflict)
      events <- readRows (state.sessionId.value, fromInteger (revisionNumber previous), fromInteger (revisionNumber through - revisionNumber previous)) listEvents
      unless (map (revisionNumber . (.cursor)) events == [revisionNumber previous + 1 .. revisionNumber through]) (abort SessionBindingConflict)
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
acceptCheckpointWith :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> OperationId -> CheckpointReceipt -> Transaction (Either SessionError ()) -> Eff es (Either SessionError (Admission, StateRevision "worker-event"))
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

observeSession :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> SessionWake -> Eff es (Either SessionError (Admission, SessionState))
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
      let next = state & #wake .~ Just ref & #revision .~ (advanceRevision expected)
      pure (next, next)

subscribeEvents :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> SessionListener -> Eff es (Either SessionError (Admission, StateRevision "worker-event"))
subscribeEvents access@(SessionAccess session _ _) expected epoch operation listener = guarded do
  unless (revisionNumber listener.after <= 100000 && listener.generation >= 0) (throwIO (SessionAbort SessionBindingConflict))
  _ <- validateListener listener
  existing <- metadata do
    (state, binding) <- getSession session
    checkAccess access state binding
    forM state.listeners \ref -> do
      current <- readPayload @SessionListener session "session-listener" ref
      status <- lookupAwakeableStatusTx (awakeableIdToUuid current.token)
      pure (ref, current, status == Just Pending)
  live <- fmap catMaybes $ forM existing \(ref, current, pending) -> do
    generation <- currentGeneration (WorkflowName current.ownerName) (WorkflowId current.ownerId)
    pure (if pending && generation == current.generation then Just ref else Nothing)
  notify <- prepareListenerNotification session listener
  mutate
    access
    expected
    epoch
    operation
    "subscribe"
    (toJSON (epoch, listener))
    False
    (\key revision -> Generated.SubscribeSessionEvents (Generated.SubscribeSessionEventsData key revision (revision + 1)))
    \state _ _ -> do
      ref <- writePayload session (body "session-listener" listener)
      let retained = filter (/= ref) live <> [ref]
      when (length retained > 32) (abort SessionLimitExceeded)
      when (state.eventCursor > listener.after) notify
      pure (state.eventCursor, state & #listeners .~ retained)

validateListener :: (SessionReadEffects es) => SessionListener -> Eff es AwakeableRow
validateListener listener = do
  row <- lookupAwakeable (awakeableIdToUuid listener.token) >>= maybe (throwIO (SessionAbort SessionBindingConflict)) pure
  generation <- currentGeneration (WorkflowName listener.ownerName) (WorkflowId listener.ownerId)
  unless (row.ownerWorkflowName == listener.ownerName && row.ownerWorkflowId == listener.ownerId && listener.generation == generation) (throwIO (SessionAbort SessionBindingConflict))
  pure row

prepareListenerNotification :: (SessionReadEffects es) => WorkerSessionId -> SessionListener -> Eff es (Transaction ())
prepareListenerNotification session listener = do
  generation <- currentGeneration (WorkflowName listener.ownerName) (WorkflowId listener.ownerId)
  row <- lookupAwakeable (awakeableIdToUuid listener.token)
  if generation /= listener.generation || isNothing row
    then pure (pure ())
    else do
      _ <- validateListener listener
      now <- liftIO getCurrentTime
      append <- prepareJournalAppend (WorkflowName listener.ownerName) (WorkflowId listener.ownerId) listener.generation (StepRecorded (awakeableStepPrefix <> awakeableIdText listener.token) (toJSON session) now)
      pure do
        transitioned <- completeAwakeableTx (awakeableIdToUuid listener.token) (toJSON session) now
        status <- lookupAwakeableStatusTx (awakeableIdToUuid listener.token)
        when (transitioned || status == Just Completed) do
          append >>= \case
            JournalAppendConflict {} -> abort SessionStorageUnavailable
            JournalAlreadyPresent stored | stored /= toJSON session -> abort SessionStorageUnavailable
            _ -> pure ()

requestTransfer :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> ObjectiveVersion -> WorkspaceRef -> AgentName -> AgentIdentity -> Eff es (Either SessionError (Admission, TransferIntent))
requestTransfer access expected epoch operation version workspace target successor = guarded $
  mutate
    access
    expected
    epoch
    operation
    "transfer-request"
    (toJSON (epoch, version, workspace, target, successor))
    True
    (\session revision -> Generated.RequestSessionTransfer (Generated.RequestSessionTransferData session revision (revision + 1)))
    \state binding admission -> do
      unless (isNothing state.checkpointIntent && maybe True ((== TransferEstablished) . (.stage)) state.handoff) (abort AssignmentConflict)
      unless (version.active && version.owner == state.owner && version.ownerEpoch == epoch && version.rootId == binding.rootId && successor /= state.owner && successor /= binding.parentIdentity && all (\value -> not (Text.null value) && Text.length value <= 256) [workspace.provider, workspace.resource]) (abort SessionBindingConflict)
      void (require (either (const (Left SessionOwnerRefused)) Right (identityText successor)))
      require (either (const (Left SessionOwnerRefused)) Right (assertMayDelegate admission.delegator target))
      require (either (const (Left SessionOwnerRefused)) Right (checkCycle admission.context target))
      void (require (either (const (Left SessionOwnerRefused)) Right (checkDepth admission.context)))
      let intent = TransferIntent 1 state.sessionId binding.objective binding.parentIdentity operation version state.owner successor target epoch (advanceRevision epoch) binding.rootId workspace
      ref <- writePayload state.sessionId (body "transfer-intent" intent)
      appendEvent state (TransferStatusChanged operation TransferRequested)
      pure (intent, state & #phase .~ Transferring & #handoff .~ Just (HandoffProgress operation ref TransferRequested Nothing Nothing) & #eventCursor .~ (advanceRevision state.eventCursor))

readTransferIntent :: (SessionReadEffects es) => SessionAccess -> Eff es (Either SessionError TransferIntent)
readTransferIntent access@(SessionAccess session _ _) = protected do
  (state, binding) <- getSession session
  checkAccess access state binding
  progress <- maybe (abort AssignmentMissing) pure state.handoff
  readPayload session "transfer-intent" progress.intent

readTransferOperation :: (SessionReadEffects es) => SessionAccess -> OperationId -> Eff es (Either SessionError TransferIntent)
readTransferOperation access@(SessionAccess session _ _) operation = protected do
  (state, binding) <- getSession session
  checkAccess access state binding
  stored <- Tx.statement (session.value, operationKey operation) selectCommand
  case stored of
    Just (_, value) -> case Aeson.fromJSON value of
      Aeson.Success intent | intent.format == 1 && intent.sessionId == session && intent.operationId == operation -> pure intent
      _ -> abort MessageConflict
    Nothing -> abort AssignmentMissing

readTransferFence :: (SessionReadEffects es) => SessionAccess -> Eff es (Either SessionError (Maybe FenceProof))
readTransferFence access@(SessionAccess session _ _) = protected do
  (state, binding) <- getSession session
  checkAccess access state binding
  progress <- maybe (abort AssignmentMissing) pure state.handoff
  traverse (readPayload session "transfer-fence") progress.fence

markTransferReconciling :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> OperationId -> Eff es (Either SessionError (Admission, HandoffProgress))
markTransferReconciling access expected epoch operation transfer = guarded $
  mutate
    access
    expected
    epoch
    operation
    "transfer-reconciling"
    (toJSON (epoch, transfer))
    False
    (\session revision -> Generated.ReconcileSessionTransfer (Generated.ReconcileSessionTransferData session revision (revision + 1)))
    \state _ _ -> do
      progress <- transferProgress state transfer
      unless (progress.stage `elem` [TransferRequested, TransferReconciling, TransferUnresolved]) (abort AssignmentConflict)
      let next = progress & #stage .~ TransferReconciling
      appendEvent state (TransferStatusChanged transfer TransferReconciling)
      pure (next, state & #handoff .~ Just next & #eventCursor .~ (advanceRevision state.eventCursor))

retainTransferFence :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> OperationId -> FenceOutcome -> Eff es (Either SessionError (Admission, HandoffProgress))
retainTransferFence access expected epoch operation transfer outcome = guarded $
  mutate
    access
    expected
    epoch
    operation
    "transfer-fence"
    (toJSON (epoch, transfer, outcome))
    False
    (\session revision -> Generated.ReconcileSessionTransfer (Generated.ReconcileSessionTransferData session revision (revision + 1)))
    \state _ _ -> do
      progress <- transferProgress state transfer
      intent <- readPayload state.sessionId "transfer-intent" progress.intent
      unless (progress.stage /= TransferEstablished) (abort AssignmentConflict)
      next <- case outcome of
        FencedAndSettled proof -> do
          unless (matchesFence intent proof) (abort SessionBindingConflict)
          ref <- writePayload state.sessionId (body "transfer-fence" proof)
          pure (progress & #stage .~ TransferFenced & #fence .~ Just ref)
        _ -> do
          when (isJust progress.fence) (abort AssignmentConflict)
          pure (progress & #stage .~ TransferUnresolved)
      appendEvent state (TransferStatusChanged transfer next.stage)
      pure (next, state & #handoff .~ Just next & #eventCursor .~ (advanceRevision state.eventCursor))

establishOwner :: (SessionEffects es) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> OperationId -> FenceProof -> OwnershipReceipt -> Eff es (Either SessionError (Admission, SessionState))
establishOwner access expected epoch operation transfer proof receipt = guarded $
  mutate
    access
    expected
    epoch
    operation
    "transfer-establish"
    (toJSON (epoch, transfer, proof, receipt))
    False
    (\session revision -> Generated.EstablishSessionOwner (Generated.EstablishSessionOwnerData session revision (revision + 1)))
    \state binding _ -> do
      progress <- transferProgress state transfer
      intent <- readPayload state.sessionId "transfer-intent" progress.intent
      unless (isNothing state.activeAssignment && isNothing state.checkpointIntent && progress.stage == TransferFenced && state.owner == intent.oldOwner && epoch == intent.oldEpoch && intent.newEpoch == advanceRevision epoch && binding.rootId == intent.rootId && matchesOwnership intent proof receipt) (abort AssignmentConflict)
      storedProof <- maybe (abort AssignmentMissing) (readPayload state.sessionId "transfer-fence") progress.fence
      unless (storedProof == proof) (abort SessionBindingConflict)
      ref <- writePayload state.sessionId (body "transfer-checkpoint" receipt)
      let established = progress & #stage .~ TransferEstablished & #checkpoint .~ Just ref
          next = state & #phase .~ Idle & #owner .~ intent.newOwner & #worker .~ Just intent.newWorker & #epoch .~ intent.newEpoch & #handoff .~ Just established & #eventCursor .~ (advanceRevision state.eventCursor) & #revision .~ (advanceRevision expected)
      appendEvent state (TransferStatusChanged transfer TransferEstablished)
      pure (next, next)

transferProgress :: SessionState -> OperationId -> Transaction HandoffProgress
transferProgress state operation = do
  progress <- maybe (abort AssignmentMissing) pure state.handoff
  unless (state.phase == Transferring && progress.operationId == operation) (abort AssignmentConflict)
  pure progress

assignmentExecutions :: (SessionReadEffects es) => SessionAccess -> Eff es (Either SessionError [ExecutionId])
assignmentExecutions access@(SessionAccess session _ _) = protected do
  (state, binding) <- getSession session
  checkAccess access state binding
  messages <- readRows session.value completedAssignments
  pure (mapMaybe (.executionId) messages)

validateWake :: (SessionReadEffects es) => WorkerSessionId -> SessionWake -> Eff es AwakeableRow
validateWake session wake = do
  row <- lookupAwakeable (awakeableIdToUuid wake.token) >>= maybe (throwIO (SessionAbort SessionBindingConflict)) pure
  generation <- currentGeneration sessionWorkflowName (sessionWorkflowId session)
  let WorkflowName name = sessionWorkflowName
  unless (row.ownerWorkflowName == name && row.ownerWorkflowId == session.value && wake.generation >= 0 && generation == wake.generation) (throwIO (SessionAbort SessionBindingConflict))
  pure row

-- Prepared outside the checked writer, completed inside it. A message cannot
-- commit while losing its published wake. Rotation never redirects an old wake.
prepareNotification :: (SessionReadEffects es) => SessionAccess -> Eff es (Maybe PayloadRef, [PayloadRef], SessionState -> Transaction ())
prepareNotification access@(SessionAccess session _ _) = do
  (reference, wake, references, listeners) <- metadata do
    (state, binding) <- getSession session
    checkAccess access state binding
    decoded <- traverse (readPayload session "session-wake") state.wake
    listeners <- traverse (readPayload session "session-listener") state.listeners
    pure (state.wake, decoded, state.listeners, listeners)
  notifications <- forM listeners \listener -> (listener.after,) <$> prepareListenerNotification session listener
  generation <- currentGeneration sessionWorkflowName (sessionWorkflowId session)
  driver <- case wake of
    Just published | published.generation == generation -> do
      row <- lookupAwakeable (awakeableIdToUuid published.token)
      case row of
        Nothing -> pure (pure ()) -- A retained session can outlive journal GC.
        Just _ -> do
          _ <- validateWake session published
          now <- liftIO getCurrentTime
          append <- prepareJournalAppend sessionWorkflowName (sessionWorkflowId session) published.generation (StepRecorded (awakeableStepPrefix <> awakeableIdText published.token) (toJSON session) now)
          pure do
            transitioned <- completeAwakeableTx (awakeableIdToUuid published.token) (toJSON session) now
            status <- lookupAwakeableStatusTx (awakeableIdToUuid published.token)
            when (transitioned || status == Just Completed) do
              append >>= \case
                JournalAppendConflict {} -> abort SessionStorageUnavailable
                JournalAlreadyPresent stored | stored /= toJSON session -> abort SessionStorageUnavailable
                _ -> pure ()
    _ -> pure (pure ())
  pure
    ( reference,
      references,
      \state -> do
        driver
        forM_ notifications \(after, notify) -> when (state.eventCursor > after) notify
    )

mutate :: (SessionEffects es, ToJSON a, FromJSON a) => SessionAccess -> StateRevision "worker-session" -> StateRevision "worker-owner" -> OperationId -> Text -> Aeson.Value -> Bool -> (WorkerSessionId -> Int -> Generated.WorkerSessionLifecycleCommand) -> (SessionState -> SessionBinding -> SessionAdmission -> Transaction (a, SessionState)) -> Eff es (Either SessionError (Admission, a))
mutate access@(SessionAccess session actor _) expected epoch operation kind input fresh command action = do
  requireKey operation
  (_, binding) <- metadata (readRows session.value selectSession) >>= maybe (throwIO (SessionAbort SessionMissing)) pure
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
      notification <- if kind `elem` ["observe", "subscribe"] then pure Nothing else Just <$> prepareNotification access
      result <- persist session (command session (fromInteger (revisionNumber expected))) do
        validateRoot fresh binding.rootId
        (state, actualBinding) <- getSession session
        checkAccess access state actualBinding
        unless (actor == actualBinding.parentIdentity && state.epoch == epoch) (abort SessionOwnerRefused)
        unless (state.revision == expected && revisionNumber expected < toInteger (maxBound :: Int)) (abort SessionRevisionConflict)
        admission <- readPayload session "session-admission" actualBinding.admission
        (value, next) <- action state actualBinding admission
        forM_ notification \(reference, listeners, notify) -> do
          unless (reference == state.wake && listeners == state.listeners) (abort SessionRevisionConflict)
          notify next
        saveSession (next & #revision .~ (advanceRevision expected))
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
appendEvent state event = do
  when (revisionNumber state.eventCursor >= 100000) (abort SessionLimitExceeded)
  Tx.statement (state.sessionId.value, fromInteger (revisionNumber (advanceRevision state.eventCursor)), EventReceipt (advanceRevision state.eventCursor) event) insertEvent

getSession :: WorkerSessionId -> Transaction (SessionState, SessionBinding)
getSession session = readRows session.value lockSession >>= maybe (abort SessionMissing) pure

getAssignment :: WorkerSessionId -> AssignmentId -> Transaction MessageReceipt
getAssignment session assignment = readRows (session.value, assignment.value) selectMessage >>= maybe (abort AssignmentMissing) pure

saveSession :: SessionState -> Transaction ()
saveSession state = Tx.statement (state.sessionId.value, state) updateSession

saveMessage :: MessageReceipt -> Transaction ()
saveMessage message = Tx.statement (message.sessionId.value, message.assignmentId.value, message) updateMessage

operationKey :: OperationId -> Text
operationKey = operationIdText

persist :: (SessionEffects es) => WorkerSessionId -> Generated.WorkerSessionLifecycleCommand -> Transaction () -> Eff es (Either SessionError ())
persist session command action = guarded do
  let (catalog, projections) = withLiveSession (\_ _ -> action)
  options <- commandOptions
  result <- runCommandWithCatalogProjections options workerSessionLifecycleEventStream (Stream.entityStream workerSessionLifecycleCategory session.value) command catalog projections
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

jsonRow :: (FromJSON a) => D.Row (Either () a)
jsonRow = capture <$> D.column (D.nonNullable D.jsonb)
  where
    capture value = case Aeson.fromJSON value of
      Aeson.Success result -> Right result
      Aeson.Error _ -> Left ()

selectSession, lockSession :: Statement Text (Maybe (Either () (SessionState, SessionBinding)))
selectSession = preparable "SELECT state,binding FROM shikigami.worker_sessions WHERE session_id=$1" textParam (D.rowMaybe ((\state binding -> (,) <$> state <*> binding) <$> jsonRow <*> jsonRow))
lockSession = preparable "SELECT state,binding FROM shikigami.worker_sessions WHERE session_id=$1 FOR UPDATE" textParam (D.rowMaybe ((\state binding -> (,) <$> state <*> binding) <$> jsonRow <*> jsonRow))

countScopeSessions :: Statement (Text, Aeson.Value) Int64
countScopeSessions = preparable "SELECT count(*) FROM shikigami.worker_sessions WHERE binding->'scope'->>'parent'=$1 AND binding->'parentIdentity'=$2" (contrazip2 textParam jsonParam) (D.singleRow (D.column (D.nonNullable D.int8)))

lockScope :: Statement Text Int
lockScope = preparable "SELECT 1::int4 FROM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended($1,0))" textParam (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int4)))

selectScopeBinding :: Statement (Text, Aeson.Value) (Maybe (Either () SessionBinding))
selectScopeBinding = preparable "SELECT binding FROM shikigami.worker_sessions WHERE binding->'scope'->>'parent'=$1 AND binding->'parentIdentity'=$2 ORDER BY session_id LIMIT 1" (contrazip2 textParam jsonParam) (D.rowMaybe jsonRow)

pageMessages :: Statement (Text, Int64, Int64) [Either () MessageReceipt]
pageMessages = preparable "SELECT state FROM shikigami.worker_session_messages WHERE session_id=$1 AND sequence>$2 ORDER BY sequence LIMIT $3" (contrazip3 textParam (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.int8))) (D.rowList jsonRow)

insertSession :: Statement (Text, Text, SessionState, SessionBinding) ()
insertSession = preparable "INSERT INTO shikigami.worker_sessions(session_id,scope_digest,state,binding) VALUES ($1,$2,$3,$4)" (contrazip4 textParam textParam jsonParam jsonParam) D.noResult

updateSession :: Statement (Text, SessionState) ()
updateSession = preparable "UPDATE shikigami.worker_sessions SET state=$2,updated_at=clock_timestamp() WHERE session_id=$1" (contrazip2 textParam jsonParam) D.noResult

insertPayload :: Statement (Text, PayloadId, PayloadDigest, PayloadByteCount, Aeson.Value) ()
insertPayload = preparable "INSERT INTO shikigami.worker_session_payloads(session_id,payload_id,digest,bytes,body) VALUES ($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING" (contrazip5 textParam (payloadIdText >$< textParam) (payloadDigestText >$< textParam) (payloadByteCountInt64 >$< E.param (E.nonNullable E.int8)) jsonParam) D.noResult

selectPayload :: Statement (Text, PayloadId) (Maybe (Either Text (PayloadDigest, PayloadByteCount, Aeson.Value)))
selectPayload = preparable "SELECT digest,bytes,body FROM shikigami.worker_session_payloads WHERE session_id=$1 AND payload_id=$2" (contrazip2 textParam (payloadIdText >$< textParam)) (D.rowMaybe payloadRow)

-- Decode owned payload metadata as data, so malformed values remain corruption
-- refusals rather than being reported as database transport unavailability.
payloadRow :: D.Row (Either Text (PayloadDigest, PayloadByteCount, Aeson.Value))
payloadRow = capture <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.jsonb)
  where
    capture rawDigest rawBytes body = do
      digest <- parsePayloadDigest rawDigest
      bytes <- parsePayloadByteCount (toInteger rawBytes)
      pure (digest, bytes, body)

insertMessage :: Statement (Text, Int64, Text, Text, MessageReceipt) ()
insertMessage = preparable "INSERT INTO shikigami.worker_session_messages(session_id,sequence,assignment_id,operation_id,state) VALUES ($1,$2,$3,$4,$5)" (contrazip5 textParam (E.param (E.nonNullable E.int8)) textParam textParam jsonParam) D.noResult

selectMessage :: Statement (Text, Text) (Maybe (Either () MessageReceipt))
selectMessage = preparable "SELECT state FROM shikigami.worker_session_messages WHERE session_id=$1 AND assignment_id=$2" (contrazip2 textParam textParam) (D.rowMaybe jsonRow)

firstQueued :: Statement Text (Maybe (Either () MessageReceipt))
firstQueued = preparable "SELECT state FROM shikigami.worker_session_messages WHERE session_id=$1 AND state->>'phase'='Queued' ORDER BY sequence LIMIT 1" textParam (D.rowMaybe jsonRow)

completedAssignments :: Statement Text [Either () MessageReceipt]
completedAssignments = preparable "SELECT state FROM shikigami.worker_session_messages WHERE session_id=$1 AND state->>'phase'='AssignmentFinished' ORDER BY sequence LIMIT 1000" textParam (D.rowList jsonRow)

countQueued :: Statement Text Int64
countQueued = preparable "SELECT count(*) FROM shikigami.worker_session_messages WHERE session_id=$1 AND state->>'phase'='Queued'" textParam (D.singleRow (D.column (D.nonNullable D.int8)))

updateMessage :: Statement (Text, Text, MessageReceipt) ()
updateMessage = preparable "UPDATE shikigami.worker_session_messages SET state=$3 WHERE session_id=$1 AND assignment_id=$2" (contrazip3 textParam textParam jsonParam) D.noResult

insertResult :: Statement (Text, Text, ResultReceipt) ()
insertResult = preparable "INSERT INTO shikigami.worker_session_results(session_id,assignment_id,state) VALUES ($1,$2,$3)" (contrazip3 textParam textParam jsonParam) D.noResult

selectResult :: Statement (Text, Text) (Maybe (Either () ResultReceipt))
selectResult = preparable "SELECT state FROM shikigami.worker_session_results WHERE session_id=$1 AND assignment_id=$2" (contrazip2 textParam textParam) (D.rowMaybe jsonRow)

priorResults :: Statement (Text, Int64) [Either () ResultReceipt]
priorResults = preparable "SELECT r.state FROM shikigami.worker_session_results r JOIN shikigami.worker_session_messages m ON m.assignment_id=r.assignment_id AND m.session_id=r.session_id WHERE r.session_id=$1 AND m.sequence<$2 ORDER BY m.sequence DESC LIMIT 3" (contrazip2 textParam (E.param (E.nonNullable E.int8))) (D.rowList jsonRow)

insertEvent :: Statement (Text, Int64, EventReceipt) ()
insertEvent = preparable "INSERT INTO shikigami.worker_session_events(session_id,cursor,state) VALUES ($1,$2,$3)" (contrazip3 textParam (E.param (E.nonNullable E.int8)) jsonParam) D.noResult

listEvents :: Statement (Text, Int64, Int64) [Either () EventReceipt]
listEvents = preparable "SELECT state FROM shikigami.worker_session_events WHERE session_id=$1 AND cursor>$2 ORDER BY cursor LIMIT $3" (contrazip3 textParam (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.int8))) (D.rowList jsonRow)

selectCommand :: Statement (Text, Text) (Maybe (Text, Aeson.Value))
selectCommand = preparable "SELECT fingerprint,state FROM shikigami.worker_session_commands WHERE session_id=$1 AND operation_id=$2" (contrazip2 textParam textParam) (D.rowMaybe ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb)))

insertCommand :: Statement (Text, Text, Text, Aeson.Value) ()
insertCommand = preparable "INSERT INTO shikigami.worker_session_commands(session_id,operation_id,fingerprint,state) VALUES ($1,$2,$3,$4)" (contrazip4 textParam textParam textParam jsonParam) D.noResult

currentTime :: Statement () UTCTime
currentTime = preparable "SELECT clock_timestamp()" E.noParams (D.singleRow (D.column (D.nonNullable D.timestamptz)))

-- Decode owned JSON inside the transaction. Invalid domain values abort before
-- commit; Hasql transport errors retain their separate store classification.
readRows :: (Traversable rows) => parameters -> Statement parameters (rows (Either () a)) -> Transaction (rows a)
readRows parameters statement = Tx.statement parameters statement >>= traverse (either (const (abort SessionBindingConflict)) pure)

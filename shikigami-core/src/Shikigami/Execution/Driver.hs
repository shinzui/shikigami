-- | A bounded generation decides/submits work; the queue executor performs IO
-- outside the workflow lease. Durable rows, rather than a replay-local counter,
-- determine which operation and actual attempt may run next.
module Shikigami.Execution.Driver
  ( ExecutionStart (..),
    ExecutionSeed (..),
    ExecutionDriverResult (..),
    ExecutionAction (..),
    executionWorkflow,
    executionRegistry,
    requestExecution,
    advanceExecution,
  )
where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Time (diffUTCTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError, tryError)
import Effectful.Exception (throwIO)
import Keiro.Workflow (StepName (..), Workflow, WorkflowJournalEvent (..), appendJournalEntry, continueAsNew, currentRunGeneration, restoreSeed, step)
import Keiro.Workflow.Awakeable (cancelAwakeable)
import Keiro.Workflow.Child (awaitChild, spawnChild)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Kioku.Id (SessionId)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Approval (ApprovalChannel (ViaDanwa), ApprovalDecision (..), ApprovalRequest (..))
import Shikigami.Agent.Approval.Workflow qualified as Approval
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Agent.Run.Key (RunKey (..))
import Shikigami.Agent.RunJob (RunRouteKind (ExecutionOperationRoute))
import Shikigami.App (AppEffects)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Executor (ExecutionRuntime (..), modelContext, runExecutionStore)
import Shikigami.Execution.Identity (AttemptId (..))
import Shikigami.Execution.Policy
import Shikigami.Execution.Policy.Limits (policyNumber)
import Shikigami.Execution.Progress (repairLimitReached)
import Shikigami.Execution.Resources (AttemptRequest (..), Envelope (..), Root (..))
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.SelectionRuntime (preparePinnedExecutionCall)
import Shikigami.Execution.Store qualified as Store
import Shikigami.Execution.Timer (armObservation)
import Shikigami.Execution.Transcript
import Shikigami.ExecutionDriver.Generated.WorkflowRuntime qualified as Generated
import Shikigami.Prelude hiding ((.=))
import Shikigami.Trigger.Enqueue (addressedRunJob, enqueueRunJobTx)

newtype ExecutionStart = ExecutionStart {executionId :: ExecutionId}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype ExecutionSeed = ExecutionSeed {start :: Maybe ExecutionStart}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ExecutionDriverResult = ExecutionDriverResult
  { executionId :: !ExecutionId,
    phase :: !ExecutionPhase,
    result :: !(Maybe PayloadRef),
    failure :: !(Maybe ExecutionError)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ExecutionAction
  = ExecutionDone !ExecutionDriverResult
  | ObserveExecution !Attempt.JobReference
  | ReviewTool !SessionId !Text !PermissionBinding
  | RotateExecution
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

executionRegistry :: ExecutionRuntime -> WorkflowRegistry AppEffects
executionRegistry runtime = Map.singleton Generated.workflowName (WorkflowDef \_ -> executionWorkflow runtime Nothing)

requestExecution :: ExecutionRuntime -> ExecutionStart -> Eff (Workflow : AppEffects) ExecutionDriverResult
requestExecution _runtime start = do
  let workflowId = executionWorkflowId start.executionId
  child <- spawnChild Generated.workflowName workflowId (pure (ExecutionDriverResult start.executionId Failed Nothing (Just ExecutionMissing)))
  now <- liftIO getCurrentTime
  appendJournalEntry Generated.workflowName workflowId (StepRecorded "ingest-execution" (toJSON start) now)
  awaitChild child

executionWorkflow :: ExecutionRuntime -> Maybe ExecutionStart -> Eff (Workflow : AppEffects) ExecutionDriverResult
executionWorkflow runtime initial = do
  seed <- restoreSeed (ExecutionSeed Nothing)
  start <- step (StepName "ingest-execution") (maybe (throwIO (userError "execution resumed without its admitted start")) pure (seed.start <|> initial))
  (token, awaitObservation) <- Generated.allocateDeclaredAwait Generated.observationAwait
  generation <- currentRunGeneration
  let wake = Attempt.ExecutionWake token generation
  action <- step (StepName "advance-execution") (liftIO (advanceExecution runtime start wake) >>= require)
  case action of
    ExecutionDone result -> void (cancelAwakeable token) >> pure result
    RotateExecution -> void (cancelAwakeable token) >> continueAsNew (ExecutionSeed (Just start))
    ObserveExecution reference -> do
      armObservation wake reference
      _ <- awaitObservation :: Eff (Workflow : AppEffects) Attempt.JobReference
      continueAsNew (ExecutionSeed (Just start))
    ReviewTool session tool permission -> do
      void (cancelAwakeable token)
      now <- liftIO getCurrentTime
      decision <-
        Approval.requestBoundApproval
          permission.reviewRequestId
          session
          (ApprovalRequest ("Allow tool " <> tool <> "?") (Aeson.object ["executionId" .= start.executionId, "fingerprint" .= permission.fingerprint, "scopeDigest" .= permission.scopeDigest]) ViaDanwa)
          (max 0 (diffUTCTime permission.expiresAt now))
      _ <- step (StepName "resolve-tool-permission") do
        metadata <- liftIO (runExecutionStore runtime (Store.inspectExecution start.executionId)) >>= require
        (state, binding, _) <- maybe (throwIO (userError "execution disappeared during permission review")) pure metadata
        operation <- maybe (throwIO (userError "permission operation disappeared")) pure state.activeOperation
        resolvedAt <- liftIO getCurrentTime
        let resolution =
              if resolvedAt >= permission.expiresAt
                then TimedOut
                else case decision of
                  Approval.ApprovalResolved value -> value
                  Approval.ApprovalNotificationFailed _ -> Rejected "permission notification failed"
        liftIO (runExecutionStore runtime (Store.resolveOperationControlPermission binding.identity start.executionId state.revision operation permission.reviewRequestId resolution)) >>= require
      continueAsNew (ExecutionSeed (Just start))
  where
    require :: Either ExecutionError a -> Eff (Workflow : AppEffects) a
    require = either (throwIO . userError . show) pure

type DecisionEffects = '[Error ExecutionError, IOE]

checked :: IO (Either ExecutionError a) -> Eff DecisionEffects a
checked action = liftIO action >>= either throwError pure

advanceExecution :: ExecutionRuntime -> ExecutionStart -> Attempt.ExecutionWake -> IO (Either ExecutionError ExecutionAction)
advanceExecution runtime start wake = do
  decision <- runEff (runErrorNoCallStack (decide runtime start wake))
  case decision of
    Left err | err `notElem` [ExecutionRevisionConflict, ExecutionStorageUnavailable, ProjectionUnavailable] -> do
      metadata <- runExecutionStore runtime (Store.inspectExecution start.executionId)
      case metadata of
        Right (Just (state, binding, _)) | state.phase `elem` [Active, Parked] -> do
          stopped <- runExecutionStore runtime (Store.stopExecution binding.identity start.executionId state.revision False err)
          case stopped of
            Right _ -> pure (Right RotateExecution)
            Left UnresolvedOperation -> pure decision
            Left failure -> pure (Left failure)
        _ -> pure decision
    _ -> pure decision

decide :: ExecutionRuntime -> ExecutionStart -> Attempt.ExecutionWake -> Eff DecisionEffects ExecutionAction
decide runtime start wake = do
  (state, binding, _) <- metadata
  if state.phase `elem` [Succeeded, Failed, Cancelled]
    then pure (ExecutionDone (ExecutionDriverResult start.executionId state.phase state.result state.failure))
    else do
      now <- liftIO getCurrentTime
      root <- traverse (\rootId -> checked (owned (Roots.inspectRoot rootId <&> either (const (Left (ResourceAdmissionRefused "execution root unavailable"))) Right))) binding.rootId
      let stopped = maybe False (.cancelled) root
          cutoff = maybe False (\value -> now >= value.envelope.cutoff) root
      stoppedResult <-
        if stopped || cutoff
          then do
            result <- liftIO (owned (Store.stopExecution binding.identity start.executionId state.revision stopped (ExecutionPolicyRefused (if stopped then "execution root cancelled" else "execution cutoff reached"))))
            case result of
              Right _ -> pure True
              Left UnresolvedOperation -> case state.activeOperation of
                Nothing -> pure False
                Just operationId -> do
                  attempts <- checked (owned (Store.inspectOperationAttempts operationId))
                  case find (\attempt -> attempt.phase `elem` [Attempt.AwaitingDispatch, Attempt.Claimed]) attempts of
                    Nothing -> pure False
                    Just attempt -> do
                      _ <- checked (owned (Store.refuseUndispatchedExecutionAttempt binding.identity state.revision (Attempt.JobReference 1 start.executionId operationId attempt.request.attemptId)))
                      pure True
              Left err -> throwError err
          else pure False
      if stoppedResult
        then pure RotateExecution
        else do
          when (state.phase `elem` [Active, Unresolved]) do
            _ <- checked (owned (Store.refreshExecutionControlWake binding.identity start.executionId state.revision wake))
            pure ()
          (current, _, _) <- metadata
          case current.activeOperation of
            Just operationId -> do
              operation <- checked (owned (Store.inspectOperation operationId)) >>= maybe (throwError OperationMissing) pure
              attempts <- checked (owned (Store.inspectOperationAttempts operationId))
              case find Attempt.logicalAttempt attempts of
                Just attempt -> observe binding.identity current attempt
                Nothing -> do
                  (access, snapshot, fresh) <- replay binding.identity
                  authority <- liftIO (runtime.authorize snapshot)
                  either (const (throwError (ExecutionPolicyRefused "fresh execution authority refused"))) pure authority
                  if fresh.phase == Parked then permissionAction snapshot operation else submit Nothing access snapshot fresh operation
            Nothing -> do
              (access, snapshot, fresh) <- replay binding.identity
              authority <- liftIO (runtime.authorize snapshot)
              either (const (throwError (ExecutionPolicyRefused "fresh execution authority refused"))) pure authority
              case fresh.next of
                NeedValidation ref -> do
                  outcome <- checked (owned (Store.readReplayPayload @OperationOutcome access "operation-outcome" ref))
                  case outcome of
                    ModelReturned assistant _ -> case validateTerminalOutput snapshot.policy assistant of
                      Right value -> checked (owned (Store.finishExecution access fresh.revision value)) >> pure RotateExecution
                      Left _ | not (repairLimitReached fresh.repairs snapshot.policy.outputRepairs) -> admitModel access snapshot fresh ModelRepair
                      _ -> throwError ExecutionOutputInvalid
                    _ -> throwError ExecutionOutputInvalid
                NeedModel -> admitModel access snapshot fresh ModelTurn
                NeedTool ref position -> do
                  outcome <- checked (owned (Store.readReplayPayload @OperationOutcome access "operation-outcome" ref))
                  assistant <- case outcome of ModelReturned value _ -> pure value; _ -> throwError CorruptReplay
                  admission <- either throwError pure (validateToolInvocation snapshot.policy snapshot.toolBindings snapshot.toolBindings assistant position)
                  let binding = case admission of ToolAdmitted value -> value; ToolNeedsPermission value -> value
                  invocation <- maybe (throwError OperationConflict) pure (listToMaybe (drop position (toolInvocations assistant)))
                  let input = ToolOperationInput ref position invocation binding
                      spec = OperationSpec (operationIdFor start.executionId fresh.cursor) ToolOperation binding.recovery binding.name (policyDigest snapshot) (toolScopeDigest binding) (Just position)
                  _ <- checked (owned (Store.acceptOperation access fresh.revision spec (toJSON input)))
                  pure RotateExecution
                WorkFinished -> throwError (ExecutionPolicyRefused "accepted operation refused further execution")
  where
    owned :: Eff AppEffects (Either ExecutionError a) -> IO (Either ExecutionError a)
    owned = runExecutionStore runtime
    metadata = checked (owned (Store.inspectExecution start.executionId)) >>= maybe (throwError ExecutionMissing) pure
    replay identity = do
      access <- checked (owned (Store.authorizeReplay start.executionId identity (runtime.replayAuthority identity)))
      (snapshot, state) <- checked (owned (Store.loadExecution access))
      pure (access, snapshot, state)
    observe identity state attempt = do
      let reference = Attempt.JobReference 1 start.executionId attempt.operationId attempt.request.attemptId
      now <- liftIO getCurrentTime
      case attempt.phase of
        Attempt.AttemptUncertain ->
          if isJust attempt.lateReceipt
            then do
              _ <- checked (owned (Store.reconcileExecutionControlAttempt identity start.executionId state.revision attempt.request.attemptId))
              pure RotateExecution
            else recover reference identity attempt
        Attempt.DispatchStarted | maybe False (now >=) attempt.expiresAt -> do
          _ <- checked (owned (Store.markExpiredExecutionAttemptUncertain identity state.revision reference))
          pure RotateExecution
        Attempt.AttemptCommitted -> pure RotateExecution
        _ -> do
          -- At-least-once repair of a missing/expired queue delivery keeps the
          -- admitted actual attempt; executor claim/start supplies deduplication.
          when (attempt.phase == Attempt.AwaitingDispatch || maybe False (now >=) attempt.expiresAt) do
            (_, binding, _) <- metadata
            checked (owned (Right <$> runTransaction (enqueue now binding.identity "execution" reference)))
          pure (ObserveExecution reference)
    recover reference identity attempt = do
      proposed <- tryError @ExecutionError do
        (access, snapshot, state) <- replay identity
        operation <- checked (owned (Store.inspectOperation attempt.operationId)) >>= maybe (throwError OperationMissing) pure
        unless (operation.specification.recovery `elem` [RepeatableObservation, IdempotentEffect] && policyNumber snapshot.policy.recoveryAttempts > 0) (throwError UnresolvedOperation)
        authority <- liftIO (runtime.authorize snapshot)
        either (const (throwError (ExecutionPolicyRefused "fresh recovery authority refused"))) pure authority
        submit (Just attempt.request.attemptId) access snapshot state operation
      case proposed of
        Right action -> pure action
        Left (_, err) | err `elem` [ExecutionStorageUnavailable, ProjectionUnavailable, ExecutionRevisionConflict] -> throwError err
        -- Refused recovery preserves the original unknown effect and hold.
        -- Observation remains available for a later real receipt or authority.
        Left _ -> pure (ObserveExecution reference)
    permissionAction snapshot operation = case operation.permission of
      Just permission -> pure (ReviewTool snapshot.sessionId operation.specification.name permission)
      Nothing -> throwError OperationConflict
    admitModel access snapshot state kind = do
      (source, predecessor, summary) <- checked (owned (Store.loadModelReplayWindow access))
      (acceptedKind, input) <- either throwError pure (prepareModelOperationInput snapshot.policy kind source predecessor summary)
      let spec = OperationSpec (operationIdFor start.executionId state.cursor) acceptedKind RepeatableObservation (if acceptedKind == ModelSummary then "summary" else "model") (policyDigest snapshot) (versionedDigest "shikigami.execution-model-scope/1" (toJSON snapshot.selection)) Nothing
      _ <- checked (owned (Store.acceptOperation access state.revision spec (toJSON input)))
      pure RotateExecution
    submit retired access snapshot state operation
      | operation.specification.kind == ToolOperation && operation.specification.name `elem` snapshot.policy.humanTools && isNothing operation.permission = do
          permission <- checked (owned (Store.parkOperationPermission access state.revision operation.specification.operationId))
          pure (ReviewTool snapshot.sessionId operation.specification.name permission)
      | otherwise = do
          attemptId <- AttemptId . ("attempt:" <>) . UUID.toText <$> liftIO UUID.nextRandom
          (request, prepared) <-
            if operation.specification.kind == ToolOperation
              then do
                input <- checked (owned (Store.readReplayPayload @ToolOperationInput access "operation-input" operation.input))
                pure (Store.toolAttemptRequest attemptId operation.specification.operationId input.binding, Nothing)
              else do
                input <- checked (owned (Store.readReplayPayload @ModelOperationInput access "operation-input" operation.input))
                context <- either throwError pure (modelContext snapshot operation input)
                result <- liftIO (preparePinnedExecutionCall (runtime.selectionRuntime snapshot) snapshot.selection operation.specification.operationId attemptId context input.maxOutputTokens)
                (request, prepared) <- either (throwError . ExecutionPolicyRefused) pure result
                pure (request, Just prepared)
          now <- liftIO getCurrentTime
          (_, accepted) <- checked (owned ((case retired of Nothing -> Store.submitExecutionAttemptWith; Just old -> \permit revision -> Store.recoverExecutionAttemptWith permit revision old) access state.revision (Attempt.AttemptSubmission request prepared wake) (enqueue now snapshot.identity (agentNameText snapshot.agent))))
          pure (ObserveExecution (Attempt.JobReference 1 start.executionId accepted.operationId accepted.request.attemptId))
    enqueue now identity agent reference = void (enqueueRunJobTx (addressedRunJob now identity agent ExecutionOperationRoute (toJSON reference) (RunKey ("execution:" <> versionedDigest "shikigami.execution-job/1" (toJSON reference)))))
    policyDigest snapshot = versionedDigest "shikigami.harness-policy/1" (toJSON snapshot.policy)

{-# LANGUAGE RankNTypes #-}

-- | One queue delivery observes or executes an already prepared attempt.
-- Claims and dispatch-start are conditional database facts; queue visibility
-- and process ownership never substitute for those facts.
module Shikigami.Execution.Executor
  ( ExecutionRuntime (..),
    BoundTool (..),
    ExecutorResult (..),
    executeAcceptedAttempt,
    runExecutionStore,
    modelContext,
  )
where

import Baikai.Context qualified as Context
import Baikai.Provider.Registry (newProviderRegistryFrom)
import Baikai.Response (Response (..))
import Baikai.StopReason (StopReason (ToolUse))
import Baikai.Tool qualified as Tool
import Control.Exception qualified as Exception
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.List (find, sort)
import Data.Time (diffUTCTime)
import Data.UUID.V4 qualified as UUID
import Data.Vector qualified as Vector
import Effectful (Eff, runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.App (AppEffects, AppEnv, runAppIO)
import Shikigami.Behavior.Compatibility (validateResponseRequest)
import Shikigami.Behavior.Run (BehaviorEnv (..), completeBehaviorRequest)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Claim
import Shikigami.Execution.Identity (OperationId, operationIdText)
import Shikigami.Execution.Policy
import Shikigami.Execution.Policy.Limits (policyNumber)
import Shikigami.Execution.Resources (Admission (..))
import Shikigami.Execution.Runner qualified as Runner
import Shikigami.Execution.SelectionRuntime
import Shikigami.Execution.SelectionRuntime qualified as SelectionRuntime
import Shikigami.Execution.SelectionStore qualified as Calls
import Shikigami.Execution.Store qualified as Store
import Shikigami.Execution.ToolPosition
import Shikigami.Execution.Transcript
import Shikigami.Prelude
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (runLLMWith)
import Shikumi.Tool (SomeTool, renderToolError, runErasedOutput, someToolName, someToolSchema)
import System.Timeout (timeout)

data BoundTool = BoundTool
  { binding :: !ToolBinding,
    tool :: !SomeTool
  }

data ExecutionRuntime = ExecutionRuntime
  { appEnv :: !AppEnv,
    replayAuthority :: !(AgentIdentity -> IO (Either Text ())),
    authorize :: !(ExecutionSnapshot -> IO (Either Text ())),
    selectionRuntime :: !(ExecutionSnapshot -> SelectionRuntime),
    withTools :: !(forall a. ExecutionSnapshot -> Runner.DispatchContext -> Maybe Text -> ([BoundTool] -> IO a) -> IO (Either ExecutionError a)),
    timeoutSeconds :: !Int
  }

data ExecutorResult = ExecutorDone | ExecutorRetry | ExecutorWait !Int | ExecutorInvalidReference
  deriving stock (Eq, Show)

runExecutionStore :: ExecutionRuntime -> Eff AppEffects (Either ExecutionError a) -> IO (Either ExecutionError a)
runExecutionStore env action = runAppIO env.appEnv action <&> either (const (Left ExecutionStorageUnavailable)) id

executeAcceptedAttempt :: ExecutionRuntime -> AgentIdentity -> Attempt.JobReference -> IO (Either ExecutionError ExecutorResult)
executeAcceptedAttempt env@ExecutionRuntime {withTools} identity reference = do
  now <- getCurrentTime
  metadata <- runExecutionStore env (Store.inspectExecution reference.executionId)
  attempt <- runExecutionStore env (Store.inspectExecutionAttempt reference.attemptId)
  case (metadata, attempt) of
    (Right (Just (state, binding, _)), Right (Just current))
      | binding.identity /= identity -> pure (Right ExecutorInvalidReference)
      | current.executionId /= reference.executionId || current.operationId /= reference.operationId || reference.format /= 1 -> pure (Right ExecutorInvalidReference)
      | current.phase `elem` [Attempt.AttemptCommitted, Attempt.AttemptAbandoned, Attempt.AttemptUncertain, Attempt.AttemptSuperseded] -> publish
      | current.phase == Attempt.DispatchStarted ->
          if maybe False (now >=) current.expiresAt
            then runExecutionStore env (Store.markExpiredExecutionAttemptUncertain identity state.revision reference) >>= \case Right _ -> publish; Left err -> pure (Left err)
            else waitFor current.expiresAt
      | otherwise -> do
          access <- runExecutionStore env (Store.authorizeReplay reference.executionId identity (env.replayAuthority identity))
          case access of
            Left ReplayReadRefused | current.phase `elem` [Attempt.AwaitingDispatch, Attempt.Claimed] -> do
              refused <- runExecutionStore env (Store.refuseUndispatchedExecutionAttempt identity state.revision reference)
              case refused of Right _ -> publish; Left err -> pure (Left err)
            Left err -> pure (Left err)
            Right permit -> do
              loaded <- runExecutionStore env (Store.loadExecution permit)
              case loaded of
                Left err -> pure (Left err)
                Right (snapshot, freshState) -> do
                  owner <- claimOwnerFor <$> UUID.nextRandom
                  claim <- runExecutionStore env (Store.claimExecutionAttempt permit freshState.revision reference owner (max 1 (min 3500 env.timeoutSeconds) + 30))
                  case claim of
                    Right Attempt.AttemptFinished -> publish
                    Right Attempt.AttemptBusy -> waitFor current.expiresAt
                    Right Attempt.AttemptNeedsReconciliation -> case current.owner of
                      Nothing -> pure (Left AttemptClaimLost)
                      Just formerOwner -> do
                        let oldClaim = Attempt.AttemptClaim reference formerOwner current.generation
                        result <- runExecutionStore env (Store.markExecutionAttemptUncertain permit freshState.revision oldClaim)
                        case result of Right _ -> publish; Left err -> pure (Left err)
                    Left ResourceAdmissionRefused {} -> owned (Store.refuseUndispatchedExecutionAttempt identity freshState.revision reference) >>= \case Right _ -> publish; Left err -> pure (Left err)
                    Left err -> pure (Left err)
                    Right (Attempt.ClaimGranted lease) -> runClaim permit snapshot lease
    (Left err, _) -> pure (Left err)
    (_, Left err) -> pure (Left err)
    _ -> pure (Right ExecutorInvalidReference)
  where
    waitFor expiry = do
      now <- getCurrentTime
      let seconds = maybe 60 (\deadline -> max 1 (min 3600 (ceiling (diffUTCTime deadline now) + 1))) expiry
      pure (Right (ExecutorWait seconds))
    owned :: Eff AppEffects (Either ExecutionError a) -> IO (Either ExecutionError a)
    owned = runExecutionStore env
    publish = owned (Store.publishExecutionWake reference) <&> fmap (const ExecutorDone)
    currentState _access = owned (Store.inspectExecution reference.executionId) <&> (>>= maybe (Left ExecutionMissing) (\(state, binding, _) -> Right (binding, state)))
    runClaim access snapshot lease = do
      fresh <- env.authorize snapshot
      before <- currentState access
      case (fresh, before) of
        (Left _, Right (_, state)) -> owned (Store.abandonExecutionAttempt access state.revision reference) >>= \case Right _ -> publish; Left err -> pure (Left err)
        (_, Left err) -> pure (Left err)
        (Right (), Right (_, state)) -> do
          started <- owned (Store.startExecutionAttempt access state.revision lease)
          case started of
            Right AlreadyAccepted -> pure (Right ExecutorRetry)
            Left ResourceAdmissionRefused {} -> owned (Store.abandonExecutionAttempt access state.revision reference) >>= \case Right _ -> publish; Left err -> pure (Left err)
            Left ExecutionPolicyRefused {} -> owned (Store.abandonExecutionAttempt access state.revision reference) >>= \case Right _ -> publish; Left err -> pure (Left err)
            Left err -> pure (Left err)
            Right Accepted -> Exception.mask \restore -> do
              dispatched <- Exception.try @Exception.SomeException (restore (timeout (max 1 (min 3500 env.timeoutSeconds) * 1000000) (dispatch access snapshot lease)))
              result <- case dispatched of
                Right (Just value) -> pure value
                _ -> markUnknown access lease
              case dispatched of
                Left exception | Just (_ :: Exception.SomeAsyncException) <- Exception.fromException exception -> Exception.throwIO exception
                _ -> case result of Right () -> publish; Left err -> pure (Left err)
    markUnknown access lease =
      currentState access >>= \case
        Right (_, state) -> do
          result <- owned (Store.inspectExecutionAttempt reference.attemptId)
          case result of
            Right (Just current) | current.phase `elem` [Attempt.AttemptCommitted, Attempt.AttemptUncertain, Attempt.AttemptSuperseded] -> pure (Right ())
            Right _ -> owned (Store.markExecutionAttemptUncertain access state.revision lease) <&> fmap (const ())
            Left err -> pure (Left err)
        Left err -> pure (Left err)
    commit access lease result =
      currentState access >>= \case
        Left err -> pure (Left err)
        Right (_, state) ->
          owned (Store.completeExecutionAttempt access state.revision lease result) >>= \case
            Right _ -> pure (Right ())
            Left AttemptClaimLost -> do
              unknown <- markUnknown access lease
              case unknown of
                Left err -> pure (Left err)
                Right () ->
                  currentState access >>= \case
                    Left err -> pure (Left err)
                    Right (_, pending) -> owned (Store.recordLateExecutionReceipt access pending.revision lease result) <&> fmap (const ())
            Left err -> pure (Left err)
    dispatch access snapshot lease =
      owned (Store.inspectOperation reference.operationId) >>= \case
        Left err -> pure (Left err)
        Right Nothing -> pure (Left OperationMissing)
        Right (Just operation) -> case operation.specification.kind of
          ToolOperation -> dispatchTool access snapshot lease operation
          _ -> dispatchModel access snapshot lease operation
    dispatchModel access snapshot lease operation = do
      input <- owned (Store.readReplayPayload @ModelOperationInput access "operation-input" operation.input)
      attempt <- owned (Store.inspectExecutionAttempt reference.attemptId)
      case (input, attempt) of
        (Right request, Right (Just current)) -> case (modelContext snapshot operation request, current.call) of
          (Right context, Just receipt) -> do
            let terminal _ accounting response = case response of
                  Nothing -> markUnknown access lease >>= requireIO
                  Just actual -> do
                    let outcome = ModelReturned (captureAssistant actual) (toJSON <$> actual.evidence)
                    responseRef <- either (Exception.throwIO . userError . show) pure (Store.outcomeReference outcome)
                    let next = if operation.specification.kind == ModelSummary then NeedModel else if not (null (toolInvocations (captureAssistant actual))) && (captureAssistant actual).stopReason == ToolUse then NeedTool responseRef firstToolPosition else NeedValidation responseRef
                    commit access lease (Attempt.AttemptResult outcome next (Just accounting)) >>= requireIO
            let selectedRuntime = (env.selectionRuntime snapshot) {SelectionRuntime.authorize = dispatchAuthority access snapshot lease}
            built <- buildPreparedExecutionEnv selectedRuntime snapshot.selection (PreparedSelectionCall receipt terminal)
            case built of
              Left _ -> denied access lease "pinned model binding is unavailable"
              Right selected -> case narrowOutput selected.options request.maxOutputTokens of
                Left _ -> denied access lease "requested model output is outside the pinned ceiling"
                Right options | Left _ <- validateResponseRequest selected.model options context -> denied access lease "model request is incompatible with the pinned API"
                Right options -> completeBehaviorRequest selected selected.model context options >> pure (Right ())
          _ -> denied access lease "model replay or prepared receipt is unavailable"
        (Left _, _) -> denied access lease "model replay is unsupported"
        (_, Left err) -> pure (Left err)
        _ -> pure (Left AttemptMissing)
    dispatchTool access snapshot lease operation = do
      let context = Runner.OperationContext snapshot.executionId operation.specification.operationId (operationKey operation.specification.operationId) operation.fingerprint operation.specification.scopeDigest
      let dispatchContext = Runner.DispatchContext context lease.reference.attemptId lease.owner lease.generation
      handled <- withTools snapshot dispatchContext (Just operation.specification.name) \tools -> do
        now <- getCurrentTime
        prepared <- owned (Runner.prepareAcceptedTool now False Nothing access operation.specification.operationId (map (.binding) tools) (const (dispatchAuthority access snapshot lease)))
        case prepared of
          Left _ -> denied access lease "tool preparation or fresh authorization refused"
          Right Runner.ToolPermissionNeeded -> denied access lease "tool permission is unavailable"
          Right (Runner.ToolReady request) -> case find (\bound -> bound.binding == request.input.binding) tools of
            Nothing -> denied access lease "pinned tool binding is unavailable"
            Just bound | someToolName bound.tool == bound.binding.name && versionedDigest "shikigami.tool-schema/1" (someToolSchema bound.tool) == bound.binding.schemaDigest -> do
              -- Nested LLM operations cannot escape root admission through the
              -- process-global provider registry. They require their own work.
              emptyRegistry <- newProviderRegistryFrom []
              source <- owned (Store.readReplayPayload @OperationOutcome access "operation-outcome" request.input.response)
              case source of
                Right (ModelReturned assistant _) -> do
                  let next = toolContinuation request.input assistant
                  result <- runEff . runErrorNoCallStack @ShikumiError . runLLMWith emptyRegistry $ runErasedOutput bound.tool request.input.invocation.arguments
                  case result of
                    Left _ -> markUnknown access lease
                    Right (Left err) -> commit access lease (Attempt.AttemptResult (ToolReturned [TextBlock (renderToolError err)] True) next Nothing)
                    Right (Right output) -> commit access lease (Attempt.AttemptResult (RichToolReturned (captureToolOutput output)) next Nothing)
                _ -> denied access lease "accepted tool response is unavailable"
            _ -> denied access lease "live tool schema differs from its immutable binding"
      case handled of
        Right result -> pure result
        -- Release happens after the callback's accepted commit. Preserve that
        -- result even when a provider reports a cleanup failure.
        Left _ ->
          owned (Store.inspectExecutionAttempt reference.attemptId) >>= \case
            Right (Just current) | current.phase == Attempt.AttemptCommitted -> pure (Right ())
            _ -> denied access lease "tool lease is unavailable"
    dispatchAuthority access snapshot lease = do
      authority <- env.authorize snapshot
      case authority of
        Left _ -> pure (Left "fresh execution authority refused")
        Right () -> owned (Store.checkStartedExecutionAttempt access lease) <&> either (const (Left "execution attempt is no longer dispatchable")) (const (Right ()))
    denied access lease reason =
      owned (Store.inspectExecutionAttempt reference.attemptId) >>= \case
        Right (Just current) -> commit access lease (Attempt.AttemptResult (OperationDenied reason) WorkFinished ((const (Calls.CallOutcome Calls.CallRefused mempty [] Nothing Nothing Nothing)) <$> current.call))
        Left err -> pure (Left err)
        _ -> pure (Left AttemptMissing)
    requireIO = either (Exception.throwIO . userError . show) pure
    operationKey = operationIdText

modelContext :: ExecutionSnapshot -> Operation -> ModelOperationInput -> Either ExecutionError Context.Context
modelContext snapshot operation input = do
  unless (input.format == 1 && input.view.context.systemPrompt == snapshot.initialContext.systemPrompt) (Left CorruptReplay)
  unless (Lazy.length (Aeson.encode input.view.context) <= fromIntegral (policyNumber snapshot.policy.contextBytes)) (Left (ExecutionPolicyRefused "model context exceeds the pinned byte ceiling"))
  unless (contextRequest input.view.context.messages == contextRequest snapshot.initialContext.messages) (Left CorruptReplay)
  context <- restoreContext input.view.context
  tools <- case Aeson.fromJSON snapshot.offeredTools of Aeson.Success value -> Right (value :: [Tool.Tool]); _ -> Left UnsupportedReplay
  unless (length tools <= 128 && sort (map (\(tool :: Tool.Tool) -> tool.name) tools) == sort (map (\(binding :: ToolBinding) -> binding.name) snapshot.toolBindings) && all (\(tool :: Tool.Tool) -> any (\(binding :: ToolBinding) -> binding.name == tool.name && binding.schemaDigest == versionedDigest "shikigami.tool-schema/1" tool.parameters) snapshot.toolBindings) tools) (Left UnsupportedReplay)
  when (operation.specification.kind == ModelSummary && (isNothing snapshot.policy.summaryTokens || maybe True (\requested -> maybe True (\cap -> requested > policyNumber cap) snapshot.policy.summaryTokens) input.maxOutputTokens)) (Left (ExecutionPolicyRefused "summary output exceeds the pinned ceiling"))
  pure (context & #tools .~ if operation.specification.kind == ModelSummary then Vector.empty else Vector.fromList tools)

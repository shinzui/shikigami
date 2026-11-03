{-# LANGUAGE DataKinds #-}

-- | Submit/observe adapter for typed decisions. The existing accepted driver
-- owns queue repair, claims, fences, capacity and generation-owned wakes.
module Shikigami.Decision.Execution
  ( decisionExecutionId,
    admitDecisionExecution,
    executeDecisionWork,
  )
where

import Data.Aeson (Value)
import Data.Bifunctor (first)
import Data.IORef (newIORef, readIORef, writeIORef)
import Effectful (Eff)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.App (AppEffects)
import Shikigami.Decision.Accounting
import Shikigami.Decision.Contract
import Shikigami.Decision.Evidence
import Shikigami.Execution.AssignmentKey (assignmentIdFor)
import Shikigami.Execution.Driver (ExecutionStart (..))
import Shikigami.Execution.Executor (ExecutionRuntime (..), runExecutionStore)
import Shikigami.Execution.Policy.Types (RecoveryClass (RepeatableObservation))
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Store qualified as Store
import Shikigami.Execution.Transcript
import Shikigami.Prelude
import Shikigami.Program.Decision
import Shikigami.Program.DecisionRunner
import Shikigami.StateRevision (initialRevision)

decisionExecutionId :: PreparedDecision -> ExecutionId
decisionExecutionId = executionIdFor . assignmentIdFor . ("typed-decision:" <>) . decisionPreparationIdText . (.identity)

-- | Accepted state wins before consulting mutable program/catalog bindings.
-- The trusted loader is reached only for an unaccepted snapshot.
admitDecisionExecution :: ExecutionRuntime -> AgentIdentity -> PreparedDecision -> (IO (Either ExecutionError (ExecutionSnapshot, Value))) -> IO (Either ExecutionError ExecutionStart)
admitDecisionExecution runtime identity prepared load = do
  existing <- owned (Store.inspectExecution execution)
  case existing of
    Left err -> pure (Left err)
    Right (Just (_, binding, _)) | binding.identity /= identity -> pure (Left ExecutionIdentityConflict)
    Right (Just (_, binding, _)) -> do
      access <- owned (Store.authorizeReplay execution binding.identity (runtime.replayAuthority binding.identity))
      case access of
        Left err -> pure (Left err)
        Right permit -> do
          loaded <- owned (Store.loadExecution permit)
          case loaded of
            Left err -> pure (Left err)
            Right (snapshot, state) -> do
              operation <- owned (Store.inspectOperation (operationIdFor execution initialRevision))
              case operation of
                Right (Just operation) -> do
                  work <- owned (Store.readReplayPayload @DecisionWork permit "operation-input" operation.input)
                  pure do
                    actual <- work
                    unless (actual.prepared == prepared) (Left OperationConflict)
                    pure (ExecutionStart execution)
                Right Nothing | state.cursor == initialRevision -> load >>= either (pure . Left) (\(_, parameters) -> accept permit snapshot state parameters)
                Right Nothing -> pure (Left OperationMissing)
                Left err -> pure (Left err)
    Right Nothing ->
      load >>= \case
        Left err -> pure (Left err)
        Right (snapshot, parameters)
          | snapshot.identity /= identity || snapshot.executionId /= execution || snapshot.selection.descriptor /= prepared.model || snapshot.runId /= prepared.workflowId -> pure (Left ExecutionIdentityConflict)
          | otherwise -> do
              fresh <- runtime.authorize snapshot
              admitted <- case fresh of
                Left _ -> pure (Left (ExecutionPolicyRefused "fresh typed decision authority refused"))
                Right () -> owned (Store.admitExecution snapshot)
              case admitted of
                Left ExecutionIdentityConflict -> admitDecisionExecution runtime identity prepared load
                Left err -> pure (Left err)
                Right _ -> do
                  access <- owned (Store.authorizeReplay execution snapshot.identity (runtime.replayAuthority snapshot.identity))
                  case access of
                    Left err -> pure (Left err)
                    Right permit -> owned (Store.loadExecution permit) >>= either (pure . Left) (\(actual, state) -> accept permit actual state parameters)
  where
    execution = decisionExecutionId prepared
    owned :: Eff AppEffects (Either ExecutionError a) -> IO (Either ExecutionError a)
    owned = runExecutionStore runtime
    accept access snapshot state parameters = do
      let spec = OperationSpec (operationIdFor execution initialRevision) TypedDecision RepeatableObservation (executionCoordinate "typed-decision") (executionDigestFor "shikigami.harness-policy/1" (toJSON snapshot.policy)) (executionDigestFor "shikigami.typed-decision-scope/1" (toJSON prepared)) Nothing
      accepted <- owned (Store.acceptOperation access state.revision spec (toJSON (DecisionWork prepared parameters)))
      pure (ExecutionStart execution <$ accepted)

-- | Invoked exclusively inside an admitted executor claim. Every real call,
-- including Shikumi retries and internal nodes, passes both authority and root
-- admission. Parallel nodes serialize under the wrapper's single permit.
executeDecisionWork :: DecisionEvidenceStore -> (ExecutionSnapshot -> DecisionRuntime) -> ExecutionSnapshot -> DecisionWork -> IO (Either Text ()) -> IO (Either ExecutionError DecisionOutcome)
executeDecisionWork evidence runtimeFor snapshot work authorize = do
  let runtime = runtimeFor snapshot
      failure = decisionFailure ContractMismatch "accepted typed decision contract differs"
  if work.prepared.model /= snapshot.selection.descriptor || work.prepared.policy /= snapshot.selection.profile
    then pure (Left OperationConflict)
    else do
      answers <- newIORef []
      result <- withPreparedProgram runtime.programs work.prepared \registered input ->
        if registeredParameterState registered /= work.parameterState
          then pure (Left failure)
          else do
            let factory = accountedDecisionHooks evidence snapshot.sanctionedProfile snapshot.selection (first (const (decisionFailure ForbiddenModel "fresh typed decision authority refused")) <$> authorize)
            (output, observed) <- runDecisionProgramWithAccounting factory runtime work.prepared (programRef registered) input
            writeIORef answers observed
            pure (encodeResult (registeredCodec registered) <$> output)
      report <- readDecisionReport evidence work.prepared.runId
      observations <- readIORef answers
      pure do
        retained <- first (const ExecutionStorageUnavailable) report
        let calls = maybe [] (filter (\call -> call.invocationId == work.prepared.identity) . (.calls)) retained
        unless (all (isJust . (.terminal)) calls) (Left UnresolvedOperation)
        pure (decisionOutcome work.prepared.identity work.prepared.program result (map (.callId) calls) observations)

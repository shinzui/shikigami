-- | Bounded local driving of one already admitted child. Queue acceptance and
-- fenced execution are identical to background delivery; no queue is drained.
module Shikigami.Execution.Foreground (driveExecutionForeground) where

import Keiro.Workflow (WorkflowOutcome (..))
import Keiro.Workflow.Child (runChildWorkflow)
import Kioku.App (runAppIO)
import Shikigami.Execution.Attempt qualified as Attempt
import Shikigami.Execution.Driver
import Shikigami.Execution.Executor
import Shikigami.Execution.Resources (AttemptRequest (..))
import Shikigami.Execution.Store qualified as Store
import Shikigami.Execution.Transcript
import Shikigami.ExecutionDriver.Generated.WorkflowRuntime qualified as Generated
import Shikigami.Prelude
import Shikigami.Workflow.Versioning (shikigamiWorkflowRunOptions)

-- Nothing means that a human, live claim or unresolved operation must wake the
-- accepted child later. Exhausting the local advance allowance also parks; it
-- never creates another attempt merely to keep this command running.
driveExecutionForeground :: ExecutionRuntime -> ExecutionStart -> Int -> IO (Either ExecutionError (Maybe ExecutionDriverResult))
driveExecutionForeground runtime start allowance = drive (max 0 (min 10000 allowance))
  where
    drive 0 = pure (Right Nothing)
    drive remaining = do
      outcome <- runAppIO runtime.appEnv (runChildWorkflow (shikigamiWorkflowRunOptions runtime.appEnv) Generated.workflowName (executionWorkflowId start.executionId) (executionWorkflow runtime Nothing))
      case outcome of
        Left _ -> pure (Left ExecutionStorageUnavailable)
        Right (Completed result) -> pure (Right (Just result))
        Right ContinuedAsNew -> drive (remaining - 1)
        Right Suspended -> do
          metadata <- runExecutionStore runtime (Store.inspectExecution start.executionId)
          case metadata of
            Right (Just (state, binding, _)) -> case state.activeOperation of
              Nothing -> pure (Right Nothing)
              Just operation -> do
                attempts <- runExecutionStore runtime (Store.inspectOperationAttempts operation)
                case attempts of
                  Left err -> pure (Left err)
                  Right values -> case filter (\attempt -> attempt.phase /= Attempt.AttemptAbandoned) values of
                    [attempt] | attempt.phase /= Attempt.AttemptUncertain -> do
                      result <- executeAcceptedAttempt runtime binding.identity (Attempt.JobReference 1 start.executionId operation attempt.request.attemptId)
                      case result of
                        Right ExecutorDone -> drive (remaining - 1)
                        Right ExecutorRetry -> pure (Right Nothing)
                        Right ExecutorWait {} -> pure (Right Nothing)
                        Right ExecutorInvalidReference -> pure (Left AttemptConflict)
                        Left err -> pure (Left err)
                    _ -> pure (Right Nothing)
            Left err -> pure (Left err)
            _ -> pure (Left ExecutionMissing)
        Right _ -> pure (Left ExecutionNotActive)

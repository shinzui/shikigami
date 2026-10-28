-- | Preparation is separate from dispatch. An executor must also acquire and
-- start a fenced attempt before using this prepared request. Preparation alone
-- never authorizes external IO or claims that an uncertain effect is absent.
module Shikigami.Execution.Runner
  ( OperationContext (..),
    PreparedTool (..),
    ToolPreparation (..),
    prepareAcceptedTool,
    validatePreparedTool,
  )
where

import Effectful (Eff)
import Shikigami.Execution.Identity (OperationId (..))
import Shikigami.Execution.Policy
import Shikigami.Execution.Store qualified as Store
import Shikigami.Execution.Transcript
import Shikigami.Prelude

-- A trusted callback receives the logical key outside the model arguments.
-- Actual transport attempts and owner generations are separate coordinates.
data OperationContext = OperationContext
  { executionId :: !ExecutionId,
    operationId :: !OperationId,
    idempotencyKey :: !Text,
    fingerprint :: !Text,
    scopeDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data PreparedTool = PreparedTool
  { context :: !OperationContext,
    expectedRevision :: !Integer,
    input :: !ToolOperationInput
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show PreparedTool where show _ = "PreparedTool <protected>"

data ToolPreparation = ToolReady !PreparedTool | ToolPermissionNeeded
  deriving stock (Eq, Show)

prepareAcceptedTool ::
  (Store.ExecutionEffects es) =>
  UTCTime ->
  Bool ->
  Maybe UTCTime ->
  Store.ReplayAccess ->
  OperationId ->
  [ToolBinding] ->
  (OperationContext -> IO (Either Text ())) ->
  Eff es (Either ExecutionError ToolPreparation)
prepareAcceptedTool now stopped cutoff access operationId offered authorize = do
  loaded <- Store.loadExecution access
  inspected <- Store.inspectOperation operationId
  case (loaded, inspected) of
    (Right (snapshot, state), Right (Just operation)) -> do
      input <- Store.readReplayPayload @ToolOperationInput access "operation-input" operation.input
      case input of
        Left err -> pure (Left err)
        Right tool -> do
          outcome <- Store.readReplayPayload @OperationOutcome access "operation-outcome" tool.response
          case outcome of
            Right (ModelReturned assistant _) -> case validatePreparedTool now stopped cutoff snapshot state operation tool assistant offered of
              Left err -> pure (Left err)
              Right ToolPermissionNeeded -> pure (Right ToolPermissionNeeded)
              Right ready@(ToolReady prepared) -> do
                -- The live authorizer sees only trusted operation coordinates.
                -- Its bounded detail is intentionally not copied into replay.
                checked <- liftIO (authorize prepared.context)
                pure (case checked of Right () -> Right ready; Left _ -> Left (ExecutionPolicyRefused "fresh tool authorization refused"))
            Left err -> pure (Left err)
            _ -> pure (Left CorruptReplay)
    (Left err, _) -> pure (Left err)
    (_, Left err) -> pure (Left err)
    _ -> pure (Left OperationMissing)

validatePreparedTool :: UTCTime -> Bool -> Maybe UTCTime -> ExecutionSnapshot -> ExecutionState -> Operation -> ToolOperationInput -> ReplayAssistant -> [ToolBinding] -> Either ExecutionError ToolPreparation
validatePreparedTool now stopped cutoff snapshot state operation tool assistant offered = do
  validateExecutionGate now stopped cutoff state
  let specification = operation.specification
  unless (snapshot.executionId == state.executionId && operation.executionId == state.executionId && state.activeOperation == Just specification.operationId && operation.position == state.cursor && isNothing operation.outcome && not operation.uncertain && specification.kind == ToolOperation && specification.operationId == operationIdFor state.executionId state.cursor && state.next == NeedTool tool.response tool.position && specification.responsePosition == Just tool.position && specification.name == tool.invocation.name && specification.recovery == tool.binding.recovery && specification.scopeDigest == toolScopeDigest tool.binding) (Left OperationConflict)
  admission <- validateToolInvocation snapshot.policy snapshot.toolBindings offered assistant tool.position
  unless (take 1 (drop tool.position (toolInvocations assistant)) == [tool.invocation]) (Left OperationConflict)
  let ready binding = do
        unless (binding == tool.binding) (Left OperationConflict)
        let OperationId key = specification.operationId
            context = OperationContext state.executionId specification.operationId key operation.fingerprint specification.scopeDigest
        pure (ToolReady (PreparedTool context state.revision tool))
  case admission of
    ToolAdmitted binding -> ready binding
    ToolNeedsPermission binding -> case operation.permission of
      Nothing -> Right ToolPermissionNeeded
      Just permission -> do
        unless (permission.fingerprint == operation.fingerprint && permission.scopeDigest == specification.scopeDigest && permission.policyDigest == specification.policyDigest) (Left OperationConflict)
        when (now >= permission.expiresAt) (Left (ExecutionPolicyRefused "tool permission expired"))
        case permission.resolution of
          Nothing -> Right ToolPermissionNeeded
          Just PermissionApproved -> ready binding
          _ -> Left (ExecutionPolicyRefused "tool permission was not approved")

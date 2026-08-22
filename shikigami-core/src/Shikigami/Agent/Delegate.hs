-- | Imperative delegation from one durable agent run to another.
module Shikigami.Agent.Delegate
  ( Delegated (..),
    delegate,
    awaitDelegated,
    delegatedWorkflowId,
  )
where

import Control.Exception (fromException)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (catchSync, throwIO)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowJournalEvent (..), appendJournalEntry, currentWorkflow)
import Keiro.Workflow.Child (ChildHandle, WorkflowChildCancelled (..), WorkflowChildFailed (..), awaitChild, spawnChild)
import Kiroku.Store.Effect (Store)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..), DelegationError (..), assertMayDelegate, checkCycle, checkDepth)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), TriggerKind (TriggeredByDelegation))
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName, ingestJobStepName)
import Shikigami.Id.Name (nameBytes)
import Shikigami.Prelude
import Shikigami.Store.DelegationBudget
  ( BudgetReservationError (..),
    ReservationResult (..),
    delegationBudgetIdFor,
    reserveDelegationSlot,
  )

-- | A pending delegated child run. The phantom @a@ is the value expected from
-- the child's behavior output.
newtype Delegated a = Delegated (ChildHandle (Either Text AgentRunResult))

-- | Start @childAgent@ as a child agent-run workflow without blocking.
delegate ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  AgentDecl ->
  DelegateCtx ->
  Text ->
  Text ->
  Aeson.Value ->
  Eff es (Delegated Aeson.Value)
delegate decl ctx delegationKey childAgent payload = do
  either throwIO pure (assertMayDelegate decl childAgent)
  either throwIO pure (checkCycle ctx childAgent)
  childCtx <- either throwIO pure (checkDepth ctx)
  let DelegateCtx
        { sessionId = currentCtxSessionId,
          lineage = currentLineage,
          delegationBudgetId = existingBudgetId,
          budgetLimit = currentBudgetLimit
        } = ctx
      DelegateCtx {delegateDepth = childDepth} = childCtx
  currentSession <-
    case currentCtxSessionId of
      Just sid -> pure sid
      Nothing -> throwIO DelegationMissingSessionId
  (_, parentWorkflowId) <- currentWorkflow
  let childWorkflowId = delegatedWorkflowId parentWorkflowId childAgent delegationKey
      WorkflowId childWorkflowIdText = childWorkflowId
      WorkflowId parentWorkflowIdText = parentWorkflowId
      (budgetId, seed) =
        case existingBudgetId of
          Just existing -> (existing, Nothing)
          Nothing ->
            let created = delegationBudgetIdFor parentWorkflowId
             in (created, Just (parentWorkflowId, currentBudgetLimit))
  now <- liftIO getCurrentTime
  reserved <- reserveDelegationSlot budgetId seed childWorkflowId now
  case reserved of
    Left (DelegationBudgetLedgerMissing missing) ->
      throwIO (DelegationBudgetUnavailable (Text.pack (show missing)))
    Right DelegationSlotsExhausted -> throwIO DelegationBudgetExhausted
    Right DelegationSlotReserved -> pure ()
    Right DelegationSlotAlreadyReserved -> pure ()
  let childJob =
        RunJob
          { agentName = childAgent,
            triggerKind = TriggeredByDelegation,
            routeKind = AgentWorkflowRoute,
            occurredAt = now,
            triggerPayload = payload,
            idempotencyKey = childWorkflowIdText,
            parentSessionId = Just currentSession,
            parentRunWorkflowId = Just parentWorkflowIdText,
            delegationDepth = Just childDepth,
            lineage = currentLineage <> [childAgent],
            delegationBudgetId = Just budgetId
          }
  handle <- spawnChild agentRunWorkflowName childWorkflowId (pure (Left "delegated child is driven from the agent-run registry"))
  appendJournalEntry
    agentRunWorkflowName
    childWorkflowId
    StepRecorded
      { stepName = unStepName ingestJobStepName,
        result = Aeson.toJSON childJob,
        recordedAt = now
      }
  pure (Delegated handle)

-- | Suspend until the delegated child completes and decode its behavior output.
awaitDelegated ::
  (Workflow :> es, Store :> es, IOE :> es, Aeson.FromJSON a) =>
  Delegated a ->
  Eff es a
awaitDelegated (Delegated handle) =
  awaitSucceededChild `catchSync` mapChildException
  where
    awaitSucceededChild = do
      awaitChild handle >>= \case
        Left err -> throwIO (DelegatedChildFailed err)
        Right AgentRunResult {behaviorOutput} ->
          case parseEither Aeson.parseJSON behaviorOutput of
            Right decoded -> pure decoded
            Left err -> throwIO (DelegatedResultDecodeFailed (Text.pack err))

    mapChildException err
      | Just (WorkflowChildCancelled _ _) <- fromException err =
          throwIO DelegatedChildCancelled
      | Just (WorkflowChildFailed _ _ reason) <- fromException err =
          throwIO (DelegatedChildFailed reason)
      | otherwise = throwIO err

delegatedWorkflowId :: WorkflowId -> Text -> Text -> WorkflowId
delegatedWorkflowId (WorkflowId parentWorkflowId) childAgent delegationKey =
  WorkflowId $
    Text.pack $
      UUID.toString $
        UUID.V5.generateNamed UUID.V5.namespaceURL $
          nameBytes $
            Text.intercalate
              ":"
              ["shikigami", "delegate", parentWorkflowId, childAgent, delegationKey]

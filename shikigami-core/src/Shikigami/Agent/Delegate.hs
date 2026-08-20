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
import Keiro.Workflow (Workflow, WorkflowId (..), WorkflowJournalEvent (..), appendJournalEntry, currentWorkflow, freshOrdinal)
import Keiro.Workflow.Child (ChildHandle, WorkflowChildCancelled (..), WorkflowChildFailed (..), awaitChild, spawnChild)
import Kiroku.Store.Effect (Store)
import Shikigami.Agent.Delegate.Context (DelegateCtx (..), DelegationError (..), checkDepth)
import Shikigami.Agent.Run (AgentRunResult (..))
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), TriggerKind (TriggeredByDelegation))
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.Id.Name (nameBytes)
import Shikigami.Prelude

-- | A pending delegated child run. The phantom @a@ is the value expected from
-- the child's behavior output.
newtype Delegated a = Delegated (ChildHandle (Either Text AgentRunResult))

-- | Start @childAgent@ as a child agent-run workflow without blocking.
delegate ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  DelegateCtx ->
  Text ->
  Aeson.Value ->
  Eff es (Delegated Aeson.Value)
delegate ctx childAgent payload = do
  childCtx <- either throwIO pure (checkDepth ctx)
  let DelegateCtx {sessionId = currentCtxSessionId} = ctx
      DelegateCtx {delegateDepth = childDepth} = childCtx
  currentSession <-
    case currentCtxSessionId of
      Just sid -> pure sid
      Nothing -> throwIO DelegationMissingSessionId
  (_, parentWorkflowId) <- currentWorkflow
  ordinal <- freshOrdinal "delegate"
  let childWorkflowId = delegatedWorkflowId parentWorkflowId childAgent ordinal
      WorkflowId childWorkflowIdText = childWorkflowId
      WorkflowId parentWorkflowIdText = parentWorkflowId
  now <- liftIO getCurrentTime
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
            delegationDepth = Just childDepth
          }
  handle <- spawnChild agentRunWorkflowName childWorkflowId (pure (Left "delegated child is driven from the agent-run registry"))
  appendJournalEntry
    agentRunWorkflowName
    childWorkflowId
    StepRecorded
      { stepName = "ingest-job",
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

delegatedWorkflowId :: WorkflowId -> Text -> Int -> WorkflowId
delegatedWorkflowId (WorkflowId parentWorkflowId) childAgent ordinal =
  WorkflowId $
    Text.pack $
      UUID.toString $
        UUID.V5.generateNamed UUID.V5.namespaceURL $
          nameBytes $
            Text.intercalate
              ":"
              ["shikigami", "delegate", parentWorkflowId, childAgent, Text.pack (show ordinal)]

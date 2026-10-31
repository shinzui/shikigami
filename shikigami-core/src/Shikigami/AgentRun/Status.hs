-- | Compose acceptance, owning-library workflow/session reads, and drain receipts.
-- A read failure stays an error; it is never evidence that an agent failed.
module Shikigami.AgentRun.Status
  ( RunLifecycle (..),
    RunFailureKind (..),
    RunFailure (..),
    RunStatusView (..),
    RunFacts (..),
    RunStatusFailure (..),
    runStatusFailureText,
    gatherRunFacts,
    classifyRun,
    deriveRunStatus,
    lifecycleText,
    failureKindText,
  )
where

import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Keiro.Workflow (WorkflowId (..), WorkflowInstanceRow (..), loadStepIndex)
import Keiro.Workflow.Instance (WorkflowStatus (..), lookupInstance)
import Kioku.Id (parseId)
import Kioku.Session (SessionRow (..))
import Kioku.Session qualified as Session
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Effect (runStoreIO)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.RunJob (RunJob (..), TriggerKind (..))
import Shikigami.Agent.Workflow (StepResult (..))
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.AgentRun.Ledger (RunDisposition (..), RunRequestRow (..), lookupRunRequest, refreshRunDisposition)
import Shikigami.Behavior.Error (boundedBehaviorDetail)
import Shikigami.Directory.Store (RunSkip (..), lookupDrainSkip)
import Shikigami.Memory.Access (shikigamiMemorySpace)
import Shikigami.Prelude

data RunLifecycle = Accepted | Running | Succeeded | Failed | Cancelled
  deriving stock (Eq, Show, Enum, Bounded)

data RunFailureKind = Refused | DeadLettered | BehaviorFailed | WorkflowFailed
  deriving stock (Eq, Show)

data RunFailure = RunFailure {kind :: !RunFailureKind, reason :: !Text}
  deriving stock (Generic, Eq, Show)

data RunStatusView = RunStatusView
  { runId :: !Text,
    agentName :: !Text,
    lifecycle :: !RunLifecycle,
    trigger :: !(Maybe Text),
    acceptedAt :: !(Maybe UTCTime),
    startedAt :: !(Maybe UTCTime),
    completedAt :: !(Maybe UTCTime),
    sessionId :: !(Maybe Text),
    summary :: !(Maybe Text),
    failure :: !(Maybe RunFailure)
  }
  deriving stock (Generic, Eq, Show)

data RunFacts = RunFacts
  { request :: !(Maybe RunRequestRow),
    instance_ :: !(Maybe WorkflowInstanceRow),
    steps :: !(Map Text Aeson.Value),
    session :: !(Maybe SessionRow),
    skip :: !(Maybe RunSkip)
  }
  deriving stock (Generic, Eq, Show)

data RunStatusFailure = RunStatusStoreUnavailable | RunStatusHistoryInvalid
  deriving stock (Eq, Show)

runStatusFailureText :: RunStatusFailure -> Text
runStatusFailureText = \case
  RunStatusStoreUnavailable -> "The run status store is unavailable."
  RunStatusHistoryInvalid -> "The stored run history cannot be interpreted."

gatherRunFacts :: KirokuStore -> AgentName -> Text -> IO (Either RunStatusFailure (Maybe RunFacts))
gatherRunFacts store agent runId = do
  request <- lookupRunRequest store.pool agent runId
  case request of
    Left _ -> pure (Left unavailable)
    Right accepted -> do
      stored <- runStoreIO store do
        instance_ <- lookupInstance agentRunWorkflowName (WorkflowId runId)
        steps <- maybe (pure Map.empty) (\row -> loadStepIndex agentRunWorkflowName (WorkflowId runId) (fromIntegral row.generation)) instance_
        let job = recordedJob steps
            owned = maybe False (const True) accepted || maybe False ((== agent) . (.agentName)) job
        if not owned || (isNothing accepted && isNothing instance_)
          then pure (Right Nothing)
          else case sessionLink steps of
            Left err -> pure (Left err)
            Right Nothing -> pure (Right (Just (RunFacts accepted instance_ steps Nothing Nothing)))
            Right (Just sid) ->
              Session.getById shikigamiMemorySpace sid >>= \case
                Left _ -> pure (Left unavailable)
                Right session -> pure (Right (Just (RunFacts accepted instance_ steps session Nothing)))
      case stored of
        Left _ -> pure (Left unavailable)
        Right (Left err) -> pure (Left err)
        Right (Right Nothing) -> pure (Right Nothing)
        Right (Right (Just facts)) -> do
          let key = (.runKey) <$> facts.request <|> ((.idempotencyKey) <$> recordedJob facts.steps)
          skipped <- maybe (pure (Right Nothing)) (lookupDrainSkip store.pool agent) key
          -- Only requests with no workflow/refusal need queue reconciliation.
          -- Existing terminal receipts avoid touching the queue on repeated reads.
          refreshed <- case (facts.instance_, skipped, facts.request) of
            (Nothing, Right Nothing, Just row) -> fmap Just <$> refreshRunDisposition store.pool row
            _ -> pure (Right facts.request)
          pure $ case (skipped, refreshed) of
            (Right skip, Right accepted') -> Right (Just (RunFacts accepted' facts.instance_ facts.steps facts.session skip))
            _ -> Left unavailable
  where
    unavailable = RunStatusStoreUnavailable
    sessionLink steps
      | Just value <- Map.lookup "ingest-job" steps,
        Aeson.Error _ <- (Aeson.fromJSON value :: Aeson.Result RunJob) =
          Left RunStatusHistoryInvalid
      | Just value <- Map.lookup "complete" steps,
        Aeson.Error _ <- (Aeson.fromJSON value :: Aeson.Result (StepResult ())) =
          Left RunStatusHistoryInvalid
      | otherwise = case Map.lookup "open-session" steps of
          Nothing -> Right Nothing
          Just value -> case Aeson.fromJSON value :: Aeson.Result (StepResult Text) of
            Aeson.Success (StepProduced raw) -> either (const (Left RunStatusHistoryInvalid)) (Right . Just) (parseId raw)
            Aeson.Success (StepRefused _) -> Right Nothing
            Aeson.Error _ -> Left RunStatusHistoryInvalid

recordedJob :: Map Text Aeson.Value -> Maybe RunJob
recordedJob steps =
  Map.lookup "ingest-job" steps >>= \value -> case Aeson.fromJSON value of
    Aeson.Success job -> Just job
    Aeson.Error _ -> Nothing

classifyRun :: AgentName -> Text -> RunFacts -> RunStatusView
classifyRun agent runId facts =
  RunStatusView
    { runId,
      agentName = agentNameText agent,
      lifecycle,
      trigger = triggerText . (.triggerKind) <$> recordedJob facts.steps,
      acceptedAt = (.acceptedAt) <$> facts.request,
      startedAt = (.createdAt) <$> facts.instance_,
      completedAt = ((.completedAt) =<< facts.instance_) <|> ((.completedAt) =<< facts.session) <|> terminalDisposition,
      sessionId = (.sessionId) <$> facts.session,
      summary = if lifecycle == Succeeded then Text.take 2000 <$> ((.summary) =<< facts.session) else Nothing,
      failure
    }
  where
    (lifecycle, failure) = case facts.instance_ of
      Just row -> case row.status of
        WfCancelled -> (Cancelled, Nothing)
        WfFailed -> failed WorkflowFailed (fromMaybe "workflow failed" row.lastError)
        WfRunning -> (Running, Nothing)
        WfSuspended -> (Running, Nothing)
        WfCompleted ->
          if completedSuccessfully
            then (Succeeded, Nothing)
            else failed BehaviorFailed (fromMaybe "run completed without a successful session" behaviorReason)
      Nothing -> case facts.request of
        Just row | row.disposition == RunDeadLettered -> failed DeadLettered (fromMaybe "run job dead-lettered" row.dispositionDetail)
        _ -> case facts.skip of
          Just skip -> failed Refused skip.reason
          Nothing -> (Accepted, Nothing)
    failed kind reason = (Failed, Just (RunFailure kind (boundedBehaviorDetail reason)))
    completedSuccessfully = case Map.lookup "complete" facts.steps of
      Just value -> case Aeson.fromJSON value :: Aeson.Result (StepResult ()) of Aeson.Success (StepProduced ()) -> True; _ -> False
      Nothing -> False
    behaviorReason =
      ((.errorMessage) =<< facts.session)
        <|> listToMaybe
          [reason | name <- ["open-session", "record", "complete"], Just value <- [Map.lookup name facts.steps], Aeson.Success (StepRefused reason) <- [Aeson.fromJSON value :: Aeson.Result (StepResult ())]]
        <|> ((.lastError) =<< facts.instance_)
    terminalDisposition = case facts.request of
      Just row | row.disposition == RunDeadLettered -> row.dispositionAt
      _ -> Nothing

deriveRunStatus :: KirokuStore -> AgentName -> Text -> IO (Either RunStatusFailure (Maybe RunStatusView))
deriveRunStatus store agent runId = fmap (fmap (classifyRun agent runId)) <$> gatherRunFacts store agent runId

lifecycleText :: RunLifecycle -> Text
lifecycleText = \case Accepted -> "accepted"; Running -> "running"; Succeeded -> "succeeded"; Failed -> "failed"; Cancelled -> "cancelled"

failureKindText :: RunFailureKind -> Text
failureKindText = \case Refused -> "refused"; DeadLettered -> "dead_lettered"; BehaviorFailed -> "behavior_failed"; WorkflowFailed -> "workflow_failed"

triggerText :: TriggerKind -> Text
triggerText = \case TriggeredByEvent -> "event"; TriggeredByStream -> "stream"; TriggeredBySchedule -> "schedule"; TriggeredByDelegation -> "delegation"

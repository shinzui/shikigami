module Shikigami.Agent.Approval
  ( ApprovalRequest (..),
    ApprovalChannel (..),
    ApprovalDecision (..),
    ApprovalRequirement (..),
    ApprovalEnv (..),
    defaultApprovalEnv,
    awaitApproval,
    awaitInput,
    deliverInput,
    resolveApproval,
    approvalTimeoutFireAction,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Foldable (traverse_)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, addUTCTime)
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow (..), scheduleTimerOnceTx)
import Keiro.Workflow
  ( StepName (..),
    Workflow,
    WorkflowId (..),
    WorkflowJournalEvent (StepRecorded),
    WorkflowName (..),
    appendJournalEntryReturningId,
    awakeableAllocStepPrefix,
    awakeableStepPrefix,
    currentRunGeneration,
    currentWorkflow,
    loadStepIndex,
    step,
  )
import Keiro.Workflow.Awakeable (AwakeableId, awakeableIdText, awakeableIdToUuid, awakeableNamed, signalAwakeable)
import Keiro.Workflow.Awakeable.Schema (AwakeableRow (..), lookupAwakeable)
import Kioku.App (AppEffects, AppEnv (..))
import Kioku.Id (SessionId)
import Kiroku.Store.Effect (Store, runStorePool)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId)
import Shibuya.Telemetry.Effect (runTracing)
import Shikigami.Prelude
import Shikigami.Sink.Permission (AgentIdentity, SinkKind)

data ApprovalRequest = ApprovalRequest
  { prompt :: !Text,
    context :: !Value,
    channel :: !ApprovalChannel
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ApprovalChannel
  = ViaKizashi
  | ViaDanwa
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ApprovalDecision
  = Approved !Value
  | Rejected !Text
  | TimedOut
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ApprovalRequirement
  = ApprovalNotRequired
  | ApprovalRequired !ApprovalRequest
  deriving stock (Eq, Show, Generic)

data ApprovalTimeoutPayload = ApprovalTimeoutPayload
  { kind :: !Text,
    awakeableId :: !AwakeableId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ApprovalEnv = ApprovalEnv
  { currentSession :: !SessionId,
    requiresApproval :: !(AgentIdentity -> SinkKind -> Value -> IO ApprovalRequirement),
    recordPark :: !(SessionId -> AwakeableId -> ApprovalRequest -> IO ()),
    postAsk :: !(ApprovalChannel -> ApprovalRequest -> AwakeableId -> IO ())
  }

defaultApprovalEnv :: SessionId -> ApprovalEnv
defaultApprovalEnv currentSession =
  ApprovalEnv
    { currentSession,
      requiresApproval = \_ _ _ -> pure ApprovalNotRequired,
      recordPark = \_ _ _ -> pure (),
      postAsk = \_ _ _ -> pure ()
    }

awaitApproval ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  ApprovalEnv ->
  StepName ->
  ApprovalRequest ->
  Maybe NominalDiffTime ->
  Eff es ApprovalDecision
awaitApproval env stepName req deadline = do
  (aid, awaitAnswer) <- awakeableNamed stepName
  _ <-
    step (notifyStepName stepName) $
      liftIO do
        recordPark env (currentSession env) aid req
        postAsk env (channel req) req aid
  traverse_ (armApprovalDeadline stepName aid) deadline
  awaitAnswer

awaitInput ::
  (Workflow :> es, Store :> es, IOE :> es, FromJSON a) =>
  StepName ->
  Eff es a
awaitInput stepName = do
  (_aid, awaitAnswer) <- awakeableNamed stepName
  awaitAnswer

deliverInput ::
  (Store :> es, IOE :> es, ToJSON a) =>
  WorkflowId ->
  StepName ->
  a ->
  Eff es Bool
deliverInput workflowId stepName value = do
  stepIndex <- loadStepIndex agentRunWorkflowName workflowId 0
  case Map.lookup (awakeableAllocStepPrefix <> unStepName stepName) stepIndex >>= parseMaybe Aeson.parseJSON of
    Nothing -> pure False
    Just aid -> signalAwakeable aid value

resolveApproval :: AppEnv -> AwakeableId -> ApprovalDecision -> IO Bool
resolveApproval appEnv aid decision = do
  result <- runApp appEnv (signalAwakeable aid decision)
  case result of
    Right resolved -> pure resolved
    Left err -> ioError (userError (show err))

approvalTimeoutFireAction ::
  (Store :> es, IOE :> es) =>
  TimerRow ->
  Eff es (Maybe EventId)
approvalTimeoutFireAction TimerRow {payload = timerPayload} =
  case parseApprovalTimeoutPayload timerPayload of
    Nothing -> pure Nothing
    Just aid -> do
      _ <- signalAwakeable aid TimedOut
      lookupAwakeable (awakeableIdToUuid aid) >>= \case
        Nothing -> pure Nothing
        Just AwakeableRow {ownerWorkflowName, ownerWorkflowId, payload = storedPayload} -> do
          now <- liftIO getCurrentTime
          let eventPayload = fromMaybe (toJSON TimedOut) storedPayload
          Just
            <$> appendJournalEntryReturningId
              (WorkflowName ownerWorkflowName)
              (WorkflowId ownerWorkflowId)
              (StepRecorded (awakeableStepPrefix <> awakeableIdText aid) eventPayload now)

runApp :: AppEnv -> Eff AppEffects a -> IO (Either StoreError a)
runApp env =
  runEff
    . runTracing (tracer env)
    . runErrorNoCallStack
    . runStorePool (store env)

notifyStepName :: StepName -> StepName
notifyStepName (StepName name) = StepName (name <> ":notify")

armApprovalDeadline ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  StepName ->
  AwakeableId ->
  NominalDiffTime ->
  Eff es ()
armApprovalDeadline stepName aid deadline = do
  (workflowName, workflowId) <- currentWorkflow
  generation <- currentRunGeneration
  now <- liftIO getCurrentTime
  let request =
        TimerRequest
          { timerId = approvalTimeoutTimerId workflowName workflowId generation stepName,
            processManagerName = unWorkflowName workflowName,
            correlationId = unWorkflowId workflowId,
            fireAt = addUTCTime deadline now,
            payload = Aeson.toJSON (approvalTimeoutPayload aid)
          }
  runTransaction (scheduleTimerOnceTx request)

approvalTimeoutTimerId :: WorkflowName -> WorkflowId -> Int -> StepName -> TimerId
approvalTimeoutTimerId (WorkflowName workflowName) (WorkflowId workflowId) generation (StepName stepName) =
  TimerId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      fmap (fromIntegral . fromEnum) $
        Text.unpack $
          Text.intercalate ":" ["shikigami", "approval-timeout", workflowName, workflowId, Text.pack (show generation), stepName]

approvalTimeoutPayload :: AwakeableId -> ApprovalTimeoutPayload
approvalTimeoutPayload aid =
  ApprovalTimeoutPayload
    { kind = approvalTimeoutKind,
      awakeableId = aid
    }

parseApprovalTimeoutPayload :: Value -> Maybe AwakeableId
parseApprovalTimeoutPayload value = do
  ApprovalTimeoutPayload {kind, awakeableId} <- parseMaybe Aeson.parseJSON value
  if kind == approvalTimeoutKind
    then Just awakeableId
    else Nothing

approvalTimeoutKind :: Text
approvalTimeoutKind = "shikigami.approval-timeout"

agentRunWorkflowName :: WorkflowName
agentRunWorkflowName = WorkflowName "shikigami.agent-run"

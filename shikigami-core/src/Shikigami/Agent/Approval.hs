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
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Map.Strict qualified as Map
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowName (..), awakeableAllocStepPrefix, loadStepIndex, step)
import Keiro.Workflow.Awakeable (AwakeableId, awakeableNamed, signalAwakeable)
import Kioku.App (AppEffects, AppEnv (..))
import Kioku.Id (SessionId)
import Kiroku.Store.Effect (Store, runStorePool)
import Kiroku.Store.Error (StoreError)
import Shibuya.Telemetry.Effect (runTracing)
import Shikigami.Prelude
import Shikigami.Sink.Permission (AgentIdentity, SinkKind)

data ApprovalRequest = ApprovalRequest
  { approvalPrompt :: !Text,
    approvalContext :: !Value,
    approvalChannel :: !ApprovalChannel
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
awaitApproval env stepName req _deadline = do
  (aid, awaitAnswer) <- awakeableNamed stepName
  _ <-
    step (notifyStepName stepName) $
      liftIO do
        recordPark env (currentSession env) aid req
        postAsk env (approvalChannel req) req aid
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

runApp :: AppEnv -> Eff AppEffects a -> IO (Either StoreError a)
runApp env =
  runEff
    . runTracing (tracer env)
    . runErrorNoCallStack
    . runStorePool (store env)

notifyStepName :: StepName -> StepName
notifyStepName (StepName name) = StepName (name <> ":notify")

agentRunWorkflowName :: WorkflowName
agentRunWorkflowName = WorkflowName "shikigami.agent-run"

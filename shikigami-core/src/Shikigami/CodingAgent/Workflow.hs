{-# LANGUAGE DataKinds #-}

-- | The durable child workflow of one coding-agent step,
-- @shikigami.coding-agent-step@ (@domain/shikigami/coding-agent.keiro@).
--
-- A parent spawns one keyed child per call site and awaits it. The child's
-- body has static steps: ingest the input, @admit@ (decide the launch, fix the
-- deadline, prepare the attempt directory), @attempt@ (launch or reattach,
-- restart-safely) and @settle@ (map the result to an outcome and commit a
-- completed change). Each step calls the tier's 'CodingAgentRunner'; the
-- kernel spawns no process itself.
module Shikigami.CodingAgent.Workflow
  ( CodingAgentStepInput (..),
    CodingAgentAdmission (..),
    CodingAgentRunner (..),
    refusingCodingAgentRunner,
    codingAgentStepWorkflowId,
    codingAgentChildId,
    codingAgentStepWorkflowName,
    codingAgentStepWorkflow,
    codingAgentStepRegistry,
    runCodingAgentChild,
  )
where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Effectful (Eff, IOE, liftIO, (:>))
import GHC.Generics (Generic)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow
  ( JournalAppendOutcome (..),
    StepName (..),
    Workflow,
    WorkflowId (..),
    WorkflowJournalEvent (..),
    WorkflowName,
    currentRunGeneration,
    currentWorkflow,
    prepareJournalAppend,
    step,
  )
import Keiro.Workflow.Child (awaitChild, spawnChild)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, declarationCoordinateText)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.App (AppEffects)
import Shikigami.CodingAgent.Types
import Shikigami.CodingAgentStep.Generated.WorkflowRuntime qualified as Generated
import Shikigami.Process.Attempt (AttemptResult)

-- | What a parent asks one child to do. Journaled as the child's first step.
data CodingAgentStepInput = CodingAgentStepInput
  { -- | The parent workflow's id.
    parent :: !Text,
    generation :: !Int,
    key :: !(DeclarationCoordinate "coding-agent-key"),
    agent :: !AgentName,
    identity :: !AgentIdentity,
    step :: !CodingAgentStep,
    -- | The trigger payload, quoted to the agent as evidence (ADR-112).
    payload :: !Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | What admission froze: the full input of the attempt and the settlement.
data CodingAgentAdmission = CodingAgentAdmission
  { step :: !CodingAgentStep,
    -- | The child workflow's id, which also labels Baikai's evidence.
    child :: !Text,
    repository :: !Text,
    -- | The worktree the agent works in, its branch and its base commit.
    root :: !FilePath,
    branch :: !Text,
    base :: !Text,
    deadline :: !UTCTime,
    -- | Outside the worktree; it is the attempt's recovery state.
    attemptDirectory :: !FilePath,
    -- | Copies of the attached skills, by name, inside the attempt directory.
    skills :: ![(Text, FilePath)]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The tier's runner. Each field is the body of one journaled step;
-- 'attempt' must be safe to re-execute (it reattaches, never relaunches).
data CodingAgentRunner = CodingAgentRunner
  { admit :: !(CodingAgentStepInput -> IO (Either FailureReason CodingAgentAdmission)),
    attempt :: !(CodingAgentAdmission -> IO (AttemptResult Value)),
    settle :: !(CodingAgentAdmission -> AttemptResult Value -> IO CodingAgentOutcome)
  }

-- | The runner of tiers that do not admit coding agents (ADR-40's
-- qualification gate still applies to @contained@ and @multi-tenant@).
refusingCodingAgentRunner :: Text -> CodingAgentRunner
refusingCodingAgentRunner detail =
  CodingAgentRunner
    { admit = \_ -> pure (Left (TierRefused detail)),
      attempt = \_ -> error "a refused coding-agent step has no attempt",
      settle = \_ _ -> pure (Failed (TierRefused detail))
    }

codingAgentStepWorkflowName :: WorkflowName
codingAgentStepWorkflowName = Generated.workflowName

-- | The child's id: the parent, its generation and the call-site key.
codingAgentStepWorkflowId :: CodingAgentStepInput -> WorkflowId
codingAgentStepWorkflowId CodingAgentStepInput {parent, generation, key} = codingAgentChildId parent generation key

-- | The same id from its parts, for a driver that knows the parent.
codingAgentChildId :: Text -> Int -> DeclarationCoordinate "coding-agent-key" -> WorkflowId
codingAgentChildId parent generation key =
  WorkflowId (parent <> ":coding-agent:" <> Text.pack (show generation) <> ":" <> declarationCoordinateText key)

codingAgentStepWorkflow :: CodingAgentRunner -> Maybe CodingAgentStepInput -> Eff (Workflow : AppEffects) CodingAgentOutcome
codingAgentStepWorkflow runner supplied = do
  input <- step (StepName "ingest-coding-agent-step") (ingest supplied)
  admitted <- step (StepName "admit") (liftIO (runner.admit input))
  case admitted of
    Left reason -> pure (Failed reason)
    Right admission -> do
      attempted <- step (StepName "attempt") (liftIO (runner.attempt admission))
      step (StepName "settle") (liftIO (runner.settle admission attempted))
  where
    ingest = \case
      Just value -> pure value
      Nothing -> liftIO (ioError (userError "coding-agent step resumed before ingest-coding-agent-step was journaled"))

codingAgentStepRegistry :: CodingAgentRunner -> WorkflowRegistry AppEffects
codingAgentStepRegistry runner =
  Map.singleton codingAgentStepWorkflowName (WorkflowDef \_workflowId -> codingAgentStepWorkflow runner Nothing)

-- | Spawn (or, on replay, find) the keyed child and await its outcome. The
-- child is driven by whoever drives the registry: the resume worker, or the
-- one-off command in the foreground.
runCodingAgentChild ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  AgentName ->
  AgentIdentity ->
  DeclarationCoordinate "coding-agent-key" ->
  CodingAgentStep ->
  Value ->
  Eff es CodingAgentOutcome
runCodingAgentChild agent identity key requested payload = do
  (_, parentId) <- currentWorkflow
  generation <- currentRunGeneration
  let input = CodingAgentStepInput {parent = parentId.unWorkflowId, generation, key, agent, identity, step = requested, payload}
      childId = codingAgentStepWorkflowId input
  child <- spawnChild codingAgentStepWorkflowName childId (pure (Failed (TierRefused "the coding-agent child is driven from the workflow registry")))
  now <- liftIO getCurrentTime
  appendTx <- prepareJournalAppend codingAgentStepWorkflowName childId 0 StepRecorded {stepName = "ingest-coding-agent-step", result = Aeson.toJSON input, recordedAt = now}
  admitted <-
    runTransaction
      ( appendTx >>= \case
          JournalAppended {} -> pure (Right ())
          JournalAlreadyPresent _ -> pure (Right ())
          other -> Tx.condemn >> pure (Left (show other))
      )
  either (liftIO . ioError . userError) pure admitted
  awaitChild child

{-# LANGUAGE DataKinds #-}

-- | A declared tool run as a durable step (EP-3 M4 of MasterPlan 22): the
-- child workflow @shikigami.declared-tool-step@
-- (@domain/shikigami/declared-tool.keiro@).
--
-- A flow body or a playbook step runs one declared command to completion,
-- possibly for hours and possibly changing the repository. Each call site is
-- a keyed child whose body has the static steps @admit@ (decide the call
-- against the declaration and the grant, fix the deadline, prepare the
-- attempt directory), @attempt@ (launch or reattach through the restart-safe
-- attempt machinery of EP-2) and @settle@. A step is launched at most once:
-- a call whose fate is unknown after a restart ends 'ToolUncertain'.
module Shikigami.DeclaredTool.Workflow
  ( ToolStep (..),
    mkToolStep,
    ToolRun (..),
    ToolStepOutcome (..),
    toolStepOutcomeLabel,
    renderToolStepOutcome,
    DeclaredToolStepInput (..),
    DeclaredToolAdmission (..),
    DeclaredToolRunner (..),
    DeclaredToolRunners,
    noDeclaredTools,
    declaredToolStepWorkflowId,
    declaredToolChildId,
    declaredToolStepWorkflowName,
    declaredToolStepWorkflow,
    declaredToolStepRegistry,
    runDeclaredToolChild,
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
import Numeric.Natural (Natural)
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, declarationCoordinateText)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.App (AppEffects)
import Shikigami.Capability.Declared (ToolDecl, ToolName)
import Shikigami.DeclaredToolStep.Generated.WorkflowRuntime qualified as Generated
import Shikigami.Process.Attempt (AttemptResult, UncertainReason)

-- | One call of a declared CLI tool, by name, with its arguments and a
-- deadline of 1 to 720 minutes.
data ToolStep = ToolStep
  { tool :: !ToolName,
    arguments :: ![Text],
    deadlineMinutes :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

mkToolStep :: ToolName -> [Text] -> Natural -> Either Text ToolStep
mkToolStep tool arguments deadlineMinutes
  | deadlineMinutes < 1 || deadlineMinutes > 720 = Left "a declared-tool step deadline is 1 to 720 minutes"
  | otherwise = Right ToolStep {tool, arguments, deadlineMinutes}

data ToolRun = ToolRun
  { exit :: !Int,
    stdout :: !Text,
    stderr :: !Text,
    droppedBytes :: !Natural,
    elapsedMs :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ToolStepOutcome
  = -- | The command ran to an end, with any exit code.
    ToolCompleted !ToolRun
  | -- | The call does not match the declaration or the grant; nothing ran.
    ToolRefused !Text
  | -- | The command could not be started.
    ToolFailed !Text
  | ToolTimedOut !ToolRun
  | -- | The launcher was lost without a result; never retried.
    ToolUncertain !UncertainReason
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

toolStepOutcomeLabel :: ToolStepOutcome -> Text
toolStepOutcomeLabel = \case
  ToolCompleted {} -> "completed"
  ToolRefused {} -> "refused"
  ToolFailed {} -> "failed"
  ToolTimedOut {} -> "timed_out"
  ToolUncertain {} -> "uncertain"

renderToolStepOutcome :: ToolStepOutcome -> Text
renderToolStepOutcome = \case
  ToolCompleted ToolRun {exit, elapsedMs} -> "declared tool completed with exit " <> Text.pack (show exit) <> " in " <> Text.pack (show (elapsedMs `div` 1000)) <> "s"
  ToolRefused reason -> "declared tool refused: " <> reason
  ToolFailed reason -> "declared tool failed: " <> reason
  ToolTimedOut ToolRun {elapsedMs} -> "declared tool timed out after " <> Text.pack (show (elapsedMs `div` 1000)) <> "s"
  ToolUncertain reason -> "declared tool outcome is uncertain (" <> Text.pack (show reason) <> "); inspect the attempt, it is never retried"

-- | What a parent asks one child to do. Journaled as the child's first step.
data DeclaredToolStepInput = DeclaredToolStepInput
  { parent :: !Text,
    generation :: !Int,
    key :: !(DeclarationCoordinate "tool-step-key"),
    agent :: !AgentName,
    identity :: !AgentIdentity,
    step :: !ToolStep,
    -- | The declaration's tools; the step's tool must be one of them.
    tools :: ![ToolDecl],
    repository :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | What admission froze for the attempt and the settlement.
data DeclaredToolAdmission = DeclaredToolAdmission
  { child :: !Text,
    tool :: !Text,
    -- | The located executable and the admitted arguments.
    program :: !FilePath,
    arguments :: ![Text],
    root :: !FilePath,
    deadline :: !UTCTime,
    outputLimit :: !Natural,
    attemptDirectory :: !FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data DeclaredToolRunner = DeclaredToolRunner
  { admit :: !(DeclaredToolStepInput -> IO (Either ToolStepOutcome DeclaredToolAdmission)),
    attempt :: !(DeclaredToolAdmission -> IO (AttemptResult Value)),
    settle :: !(DeclaredToolAdmission -> AttemptResult Value -> IO ToolStepOutcome)
  }

-- | Resolved per step from its input, as coding-agent runners are.
type DeclaredToolRunners = DeclaredToolStepInput -> IO (Either Text DeclaredToolRunner)

noDeclaredTools :: DeclaredToolRunners
noDeclaredTools _ = pure (Left "declared-tool steps run only under the local-operator trust tier")

declaredToolStepWorkflowName :: WorkflowName
declaredToolStepWorkflowName = Generated.workflowName

declaredToolStepWorkflowId :: DeclaredToolStepInput -> WorkflowId
declaredToolStepWorkflowId DeclaredToolStepInput {parent, generation, key} = declaredToolChildId parent generation key

declaredToolChildId :: Text -> Int -> DeclarationCoordinate "tool-step-key" -> WorkflowId
declaredToolChildId parent generation key =
  WorkflowId (parent <> ":declared-tool:" <> Text.pack (show generation) <> ":" <> declarationCoordinateText key)

declaredToolStepWorkflow :: DeclaredToolRunners -> Maybe DeclaredToolStepInput -> Eff (Workflow : AppEffects) ToolStepOutcome
declaredToolStepWorkflow runners supplied = do
  input <- step (StepName "ingest-declared-tool-step") (ingest supplied)
  -- Not a step: the composition's runner, resolved again on replay.
  resolved <- liftIO (runners input)
  case resolved of
    Left reason -> pure (ToolFailed reason)
    Right runner -> do
      admitted <- step (StepName "admit") (liftIO (runner.admit input))
      case admitted of
        Left outcome -> pure outcome
        Right admission -> do
          attempted <- step (StepName "attempt") (liftIO (runner.attempt admission))
          step (StepName "settle") (liftIO (runner.settle admission attempted))
  where
    ingest = \case
      Just value -> pure value
      Nothing -> liftIO (ioError (userError "declared-tool step resumed before ingest-declared-tool-step was journaled"))

declaredToolStepRegistry :: DeclaredToolRunners -> WorkflowRegistry AppEffects
declaredToolStepRegistry runners =
  Map.singleton declaredToolStepWorkflowName (WorkflowDef \_workflowId -> declaredToolStepWorkflow runners Nothing)

-- | Spawn (or, on replay, find) the keyed child and await its outcome.
runDeclaredToolChild ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  AgentName ->
  AgentIdentity ->
  DeclarationCoordinate "tool-step-key" ->
  ToolStep ->
  [ToolDecl] ->
  Maybe Text ->
  Eff es ToolStepOutcome
runDeclaredToolChild agent identity key requested tools repository = do
  (_, parentId) <- currentWorkflow
  generation <- currentRunGeneration
  let input = DeclaredToolStepInput {parent = parentId.unWorkflowId, generation, key, agent, identity, step = requested, tools, repository}
      childId = declaredToolStepWorkflowId input
  child <- spawnChild declaredToolStepWorkflowName childId (pure (ToolFailed "the declared-tool child is driven from the workflow registry"))
  now <- liftIO getCurrentTime
  appendTx <- prepareJournalAppend declaredToolStepWorkflowName childId 0 StepRecorded {stepName = "ingest-declared-tool-step", result = Aeson.toJSON input, recordedAt = now}
  admitted <-
    runTransaction
      ( appendTx >>= \case
          JournalAppended {} -> pure (Right ())
          JournalAlreadyPresent _ -> pure (Right ())
          other -> Tx.condemn >> pure (Left (show other))
      )
  either (liftIO . ioError . userError) pure admitted
  awaitChild child

-- | Read the native run owner's accepted inputs. This is a source lookup, not
-- a workflow step or a decoder for model-provided coordination context.
module Shikigami.Agent.CoordinationSource (AcceptedCoordinator (..), loadAcceptedCoordinator, acceptsCoordination) where

import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Effectful (Eff)
import Keiro.Workflow (loadStepIndex)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.App (AppEffects)
import Shikigami.Execution.Request (ExecutionPolicy (..), ExecutionRequest (..))
import Shikigami.Execution.Selection (ExecutionSelection (..), ExecutionSelectionFailure)
import Shikigami.Prelude
import Shikigami.WorkerSession.Capability (CoordinatorRun (..))

data AcceptedCoordinator = AcceptedCoordinator
  { run :: !CoordinatorRun,
    job :: !RunJob,
    agent :: !AgentDecl
  }
  deriving stock (Eq, Generic)

-- Ordinary associated Skills consume their assignment directly. They do not
-- acquire coordinator grants merely because the production factory is installed.
acceptsCoordination :: CoordinatorRun -> Eff AppEffects (Either Text Bool)
acceptsCoordination run = do
  recorded <- loadStepIndex agentRunWorkflowName run.runId 0
  pure do
    job <- decode recorded "ingest-job"
    declaration <- (decode recorded "lookup-agent" :: Either Text (Maybe AgentDecl)) >>= maybe (Left "accepted agent declaration is absent") Right
    session <- decode recorded "open-session"
    unless (runJobWorkflowId job == run.runId && job.identity == run.identity && declaration.name == job.agentName && session == run.sessionId) (Left "accepted coordinator identity disagrees")
    pure case declaration.behavior of
      CoordinatingSkill {} -> True
      Flow {} -> True
      _ -> False
  where
    decode :: (FromJSON a) => Map.Map Text Aeson.Value -> Text -> Either Text a
    decode values label = case Map.lookup label values of
      Just value -> case Aeson.fromJSON value of
        Aeson.Success result -> Right result
        Aeson.Error _ -> Left "unreadable accepted agent input"
      Nothing -> Left "missing accepted agent input"

loadAcceptedCoordinator :: CoordinatorRun -> Eff AppEffects (Either Text AcceptedCoordinator)
loadAcceptedCoordinator run = do
  recorded <- loadStepIndex agentRunWorkflowName run.runId 0
  pure do
    job <- required recorded "ingest-job"
    declaration <- required recorded "lookup-agent" >>= maybe (Left "accepted agent declaration is absent") Right
    session <- required recorded "open-session"
    selected <- required recorded "resolve-execution-selection" :: Either Text (Either ExecutionSelectionFailure (Maybe ExecutionSelection))
    selection <- either (const (Left "accepted execution selection was refused")) Right selected
    unless (runJobWorkflowId job == run.runId && job.identity == run.identity && declaration.name == job.agentName && session == run.sessionId && isJust run.rootId && job.executionRootId == run.rootId) (Left "accepted coordinator coordinates disagree")
    let restrictions = catMaybes [job.executionPermissions, job.executionRequest >>= (.permittedAliases), (.permittedAliases) <$> declaration.execution, (.permittedAliases) <$> selection]
    unless (case run.permittedAliases of Nothing -> null restrictions; Just allowed -> not (null allowed) && all (\bound -> all (`elem` bound) allowed) restrictions) (Left "coordination permissions exceed the accepted run")
    pure (AcceptedCoordinator run job declaration)
  where
    required :: (FromJSON a) => Map.Map Text Aeson.Value -> Text -> Either Text a
    required values label = do
      value <- maybe (Left ("accepted run has no " <> label)) Right (Map.lookup label values)
      case Aeson.fromJSON value of
        Aeson.Success result -> Right result
        Aeson.Error _ -> Left ("accepted run has unreadable " <> label)

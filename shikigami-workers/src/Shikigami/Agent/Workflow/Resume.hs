-- | Resuming durable workflows that stopped part-way.
--
-- A Keiro workflow can suspend — waiting for an approval, a timer, or a child —
-- and a process can crash mid-run. Neither case is a failure: the workflow's
-- journal records every step that already completed, and resuming replays that
-- journal and continues from the first step that did not.
--
-- The resume worker needs a /registry/: a map from workflow name to the code
-- that runs it. Both workflow families are registered here — agent runs and
-- conversations — because a resume worker that knows only one of them would
-- silently leave the other suspended forever.
module Shikigami.Agent.Workflow.Resume
  ( runResumeWorker,
    workflowRegistry,
  )
where

import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Keiro.Workflow.Resume (WorkflowRegistry, runWorkflowResumeWorkerWith)
import Kioku.App (AppEffects, runAppIO)
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Log qualified as Log
import Shikigami.Workers.Config (WorkerEnv (..), agentRunDeps, conversationEnv, envLogger)
import Shikigami.Workflow.Versioning (shikigamiWorkflowResumeOptions)

-- | Every workflow this process knows how to resume.
workflowRegistry :: WorkerEnv -> WorkflowRegistry AppEffects
workflowRegistry env =
  AgentWorkflow.agentRunRegistry (agentRunDeps env)
    `Map.union` Conversation.conversationRegistry (conversationEnv env)

-- | Run the resume loop until the process stops.
runResumeWorker :: WorkerEnv -> IO ()
runResumeWorker env@WorkerEnv {runTimeout} = do
  Log.logInfo (envLogger env) "worker.resume.started" []
  result <- runAppIO (appEnv env) (runWorkflowResumeWorkerWith (shikigamiWorkflowResumeOptions runTimeout) (workflowRegistry env))
  case result of
    Left err -> Log.logError (envLogger env) "worker.resume.failed" ["error" Aeson..= Text.pack (show err)]
    Right () -> pure ()

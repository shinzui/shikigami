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

import Data.Map.Strict qualified as Map
import Keiro.Workflow.Resume (WorkflowRegistry, runWorkflowResumeWorker)
import Kioku.App (AppEffects, runAppIO)
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Workers.Config (WorkerEnv (..), agentRunDeps, conversationEnv)
import System.IO (hPutStrLn, stderr)

-- | Every workflow this process knows how to resume.
workflowRegistry :: WorkerEnv -> WorkflowRegistry AppEffects
workflowRegistry env =
  AgentWorkflow.agentRunRegistry (agentRunDeps env)
    `Map.union` Conversation.conversationRegistry (conversationEnv env)

-- | Run the resume loop until the process stops.
runResumeWorker :: WorkerEnv -> IO ()
runResumeWorker env = do
  hPutStrLn stderr "[shikigami.worker] starting keiro workflow resume worker"
  result <- runAppIO (appEnv env) (runWorkflowResumeWorker (workflowRegistry env))
  case result of
    Left err -> hPutStrLn stderr ("[shikigami.worker] resume worker store error: " <> show err)
    Right () -> pure ()

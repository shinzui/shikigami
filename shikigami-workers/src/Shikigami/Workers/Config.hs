-- | What every worker loop needs, and how each loop's own environment is derived
-- from it.
--
-- The worker process runs four loops — draining the run-job queue, resuming
-- suspended workflows, publishing the sink outbox, and firing timers — and they
-- share a database pool, a kioku application environment, the loaded agent
-- declarations, the behavior runner, and the downstream sink configurations.
-- Building that once and deriving each loop's view of it here is what keeps
-- 'Shikigami.Workers.Registry' a composition root rather than a place where
-- behavior accumulates.
--
-- Resolution of these values — connection strings, base URLs, participant ids —
-- is owned by
-- @docs\/plans\/37-adopt-settei-configuration-across-shikigami-binaries.md@. This
-- module only says what the loops need, not where it comes from.
module Shikigami.Workers.Config
  ( WorkerEnv (..),
    envLogger,
    envGrants,
    envCatchUpPolicy,
    agentRunDeps,
    conversationEnv,
    schedulerEnv,
  )
where

import Data.Map.Strict qualified as Map
import Data.Time (NominalDiffTime)
import Hasql.Pool (Pool)
import Kioku.App (AppEnv (..))
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Decl (AgentDecl (..), Trigger (..))
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Attestation.Resolve qualified as Profile
import Shikigami.Behavior.Run (BehaviorEnv)
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Sink (DanwaConfig, GrantSource, KawaConfig, KizashiConfig, ReiConfig)
import Shikigami.Trigger.Schedule (CatchUpPolicy, parseCron)
import Shikigami.Trigger.Scheduler qualified as Scheduler

-- | Everything the worker loops need.
data WorkerEnv = WorkerEnv
  { pool :: !Pool,
    appEnv :: !AppEnv,
    agents :: ![AgentDecl],
    behaviorEnv :: !BehaviorEnv,
    runTimeout :: !NominalDiffTime,
    approvalDeadline :: !NominalDiffTime,
    -- | What the timer loop does about cron minutes that passed while the
    -- process was down. Resolved from @scheduler.catch_up@.
    catchUpPolicy :: !CatchUpPolicy,
    kizashi :: !KizashiConfig,
    kawa :: !KawaConfig,
    danwa :: !DanwaConfig,
    rei :: !ReiConfig,
    -- | Which grant source every C11 check in this process consults. Built once
    -- at boot as 'DbGrants' over the store pool, so a grant or revocation takes
    -- effect on the next dispatch with no restart.
    grants :: !GrantSource,
    -- | Where every loop's log lines go. Built once by the command that boots
    -- the process and shared by all four loops, so that one worker's output is
    -- one stream of JSON objects rather than four.
    logger :: !Log.Logger
  }

-- | The process-wide logger. Named rather than used as a bare selector
-- because several of the records below also carry a @logger@ field, which makes
-- the unqualified use ambiguous under @DuplicateRecordFields@.
envLogger :: WorkerEnv -> Log.Logger
envLogger WorkerEnv {logger = l} = l

-- | Named for the same reason as 'envLogger': several of the records below also
-- carry a @grants@ field.
envGrants :: WorkerEnv -> GrantSource
envGrants WorkerEnv {grants = g} = g

envRunTimeout :: WorkerEnv -> NominalDiffTime
envRunTimeout WorkerEnv {runTimeout = timeout} = timeout

-- | Named for the same reason as 'envLogger': 'Scheduler.SchedulerEnv' also
-- carries a @catchUpPolicy@ field.
envCatchUpPolicy :: WorkerEnv -> CatchUpPolicy
envCatchUpPolicy WorkerEnv {catchUpPolicy = policy} = policy

envApprovalDeadline :: WorkerEnv -> NominalDiffTime
envApprovalDeadline WorkerEnv {approvalDeadline = deadline} = deadline

-- | The agent-run workflow's dependencies.
agentRunDeps :: WorkerEnv -> AgentWorkflow.AgentRunDeps
agentRunDeps env =
  AgentWorkflow.AgentRunDeps
    { AgentWorkflow.appEnv = appEnv env,
      AgentWorkflow.behaviorEnv = behaviorEnv env,
      AgentWorkflow.agents = agents env,
      AgentWorkflow.kizashi = kizashi env,
      AgentWorkflow.kawa = kawa env,
      AgentWorkflow.danwa = danwa env,
      AgentWorkflow.rei = rei env,
      AgentWorkflow.hooks = AgentWorkflow.defaultAgentRunHooks,
      AgentWorkflow.approval = Approval.defaultApprovalEnv,
      AgentWorkflow.deadline = Just (envApprovalDeadline env),
      AgentWorkflow.runTimeout = envRunTimeout env,
      AgentWorkflow.logger = envLogger env,
      AgentWorkflow.grants = envGrants env,
      AgentWorkflow.resolveRunProfile = \profileId version -> do
        now <- getCurrentTime
        Profile.resolveProfile (Profile.postgresProfileStore (envPool env)) now profileId version
    }

envPool :: WorkerEnv -> Pool
envPool WorkerEnv {pool = p} = p

-- | The conversation workflow's environment.
conversationEnv :: WorkerEnv -> Conversation.ConversationEnv
conversationEnv env =
  Conversation.ConversationEnv
    { Conversation.appEnv = appEnv env,
      Conversation.behaviorEnv = behaviorEnv env,
      Conversation.runTimeout = envRunTimeout env,
      Conversation.danwa = danwa env,
      Conversation.agents = agents env,
      Conversation.grants = envGrants env
    }

-- | The scheduler's view: the pool plus every agent whose trigger is a parseable
-- cron schedule.
--
-- An unparseable cron is dropped rather than failing the process. That is the
-- behavior this refactor preserves, not endorses; making a bad declaration loud
-- belongs to
-- @docs\/plans\/20-explicit-trigger-routing-scheduler-catch-up-policy-and-loud-failures.md@.
schedulerEnv :: WorkerEnv -> Scheduler.SchedulerEnv
schedulerEnv env =
  Scheduler.SchedulerEnv
    { Scheduler.pool = pool env,
      Scheduler.schedules = Map.fromList (mapMaybe scheduleFor (agents env)),
      Scheduler.catchUpPolicy = envCatchUpPolicy env,
      Scheduler.logger = envLogger env
    }
  where
    scheduleFor AgentDecl {name = agentName, trigger = Schedule {cron}} =
      case parseCron cron of
        Right parsed -> Just (agentName, parsed)
        Left _ -> Nothing
    scheduleFor _ = Nothing

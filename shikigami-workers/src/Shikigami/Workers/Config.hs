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
    envHeartbeats,
    agentRunDeps,
    conversationEnv,
    schedulerSchedules,
    schedulerEnv,
  )
where

import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
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
import Shikigami.Health.Worker (Heartbeats)
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Sink (DanwaConfig, GrantSource, KawaConfig, KizashiConfig, ReiConfig)
import Shikigami.Trigger.Schedule (CatchUpPolicy, CronSchedule, parseCron)
import Shikigami.Trigger.Scheduler qualified as Scheduler
import System.Exit (exitFailure)

-- | Everything the worker loops need.
data WorkerEnv = WorkerEnv
  { pool :: !Pool,
    appEnv :: !AppEnv,
    agents :: ![AgentDecl],
    behaviorEnv :: !BehaviorEnv,
    runTimeout :: !NominalDiffTime,
    approvalDeadline :: !NominalDiffTime,
    -- | How long a parked conversation waits for its next message before its
    -- epoch ends and its kioku session is completed. Resolved from
    -- @conversation.idle_timeout_seconds@.
    conversationIdleTimeout :: !NominalDiffTime,
    -- | What the timer loop does about cron minutes that passed while the
    -- process was down. Resolved from @scheduler.catch_up@.
    catchUpPolicy :: !CatchUpPolicy,
    -- | Every scheduled agent whose declared cron parsed, resolved once at boot
    -- by 'schedulerSchedules' so that an unparseable cron is reported there
    -- rather than dropped silently on every timer pass.
    schedules :: !(Map Text CronSchedule),
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
    logger :: !Log.Logger,
    -- | What each loop last said about its own progress, read by this process's
    -- @\/health\/live@ probe. Shared by all four loops for the same reason the
    -- logger is: one process answers with one registry, or the probe reports on
    -- whichever copy it happens to hold.
    heartbeats :: !Heartbeats
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

-- | Named for the same reason as 'envLogger': field access through a bare
-- selector is ambiguous under @DuplicateRecordFields@.
envHeartbeats :: WorkerEnv -> Heartbeats
envHeartbeats WorkerEnv {heartbeats = h} = h

envRunTimeout :: WorkerEnv -> NominalDiffTime
envRunTimeout WorkerEnv {runTimeout = timeout} = timeout

-- | Named for the same reason as 'envLogger': 'Scheduler.SchedulerEnv' also
-- carries a @catchUpPolicy@ field.
envCatchUpPolicy :: WorkerEnv -> CatchUpPolicy
envCatchUpPolicy WorkerEnv {catchUpPolicy = policy} = policy

envApprovalDeadline :: WorkerEnv -> NominalDiffTime
envApprovalDeadline WorkerEnv {approvalDeadline = deadline} = deadline

-- | Named for the same reason as 'envLogger': 'Conversation.ConversationEnv'
-- also carries a @conversationIdleTimeout@-shaped field.
envConversationIdleTimeout :: WorkerEnv -> NominalDiffTime
envConversationIdleTimeout WorkerEnv {conversationIdleTimeout = timeout} = timeout

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
      Conversation.idleTimeout = envConversationIdleTimeout env,
      Conversation.danwa = danwa env,
      Conversation.agents = agents env,
      Conversation.grants = envGrants env
    }

-- | Resolve every scheduled agent's declared cron, once, at boot.
--
-- This used to be a pure @mapMaybe@ inside 'schedulerEnv', which is why it could
-- only drop: an agent whose @cron@ did not parse was silently removed from the
-- timer loop's map, so it loaded fine, logged nothing, and never fired. A
-- declaration this process cannot act on is a misconfiguration, and it belongs
-- where a deploy can see it, so each offender is named and — under
-- @agents.strict@, the same switch that governs a manifest that will not load —
-- the process refuses to start after reporting all of them.
schedulerSchedules :: Log.Logger -> Bool -> [AgentDecl] -> IO (Map Text CronSchedule)
schedulerSchedules logger strictMode declarations = do
  let scheduled =
        [ (agentName, cron)
        | AgentDecl {name = agentName, trigger = Schedule {cron}} <- declarations
        ]
      parsed = [(agentName, parseCron cron) | (agentName, cron) <- scheduled]
      invalid = [(agentName, err) | (agentName, Left err) <- parsed]
  traverse_ reportInvalid invalid
  unless (null invalid) do
    when strictMode do
      Log.logError
        logger
        "scheduler.cron.strict_refused"
        ["invalid" Aeson..= length invalid]
      exitFailure
  pure (Map.fromList [(agentName, schedule) | (agentName, Right schedule) <- parsed])
  where
    reportInvalid (agentName, err) =
      Log.logError
        logger
        "scheduler.cron.invalid"
        ["agent" Aeson..= agentName, "error" Aeson..= err]

-- | The scheduler's view: the pool, the schedules resolved at boot, the catch-up
-- policy, and the logger the timer loop reports through.
schedulerEnv :: WorkerEnv -> Scheduler.SchedulerEnv
schedulerEnv env =
  Scheduler.SchedulerEnv
    { Scheduler.pool = pool env,
      Scheduler.schedules = envSchedules env,
      Scheduler.catchUpPolicy = envCatchUpPolicy env,
      Scheduler.logger = envLogger env
    }

-- | Named for the same reason as 'envLogger': 'Scheduler.SchedulerEnv' also
-- carries a @schedules@ field.
envSchedules :: WorkerEnv -> Map Text CronSchedule
envSchedules WorkerEnv {schedules = s} = s

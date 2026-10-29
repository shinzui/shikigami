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
    envMetrics,
    envKeiroMetrics,
    envGrants,
    envCatchUpPolicy,
    envHeartbeats,
    envDirectory,
    envDirectoryRefresher,
    agentRunDeps,
    conversationEnv,
    persistAgentLoadReport,
    schedulerSchedules,
    principalIdsByAgent,
    schedulerEnv,
    directoryLoopRegistration,
    startProcessDirectory,
  )
where

import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Time (NominalDiffTime)
import Hasql.Pool (Pool)
import Keiro.Telemetry (KeiroMetrics)
import Kioku.App (AppEnv (..))
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.Agent.Approval qualified as Approval
import Shikigami.Agent.Approval.Workflow qualified as ApprovalWorkflow
import Shikigami.Agent.Conversation qualified as Conversation
import Shikigami.Agent.Decl (AgentDecl (..), DelegationBudget, IdentityDecl (..), Trigger (..))
import Shikigami.Agent.Loader (AgentLoadReport)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Attestation.Resolve qualified as Profile
import Shikigami.Behavior.Run (BehaviorEnv)
import Shikigami.Capability.Provider (emptyCapabilityRuntime)
import Shikigami.Directory (DirectoryHandle, DirectoryRuntime (..), DirectorySettings (..), startDirectoryWithHeartbeat)
import Shikigami.Directory.Store (recordLoadStates)
import Shikigami.Execution.Policy.Types (HarnessPolicy)
import Shikigami.Flow.Decision qualified as FlowDecision
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Health.Worker (Heartbeats, LoopName (DirectoryLoop), beat)
import Shikigami.Log qualified as Log
import Shikigami.PracticeReview.Capability qualified as PracticeReviewCapability
import Shikigami.Prelude
import Shikigami.Sink (DanwaConfig, GrantSource, KanmonConfig, KawaConfig, KizashiConfig, ReiConfig)
import Shikigami.Sink.GrantStore (withActionAuthorizer)
import Shikigami.Sink.Http (SinkHttp)
import Shikigami.Telemetry.Metrics (ShikigamiMetrics)
import Shikigami.Trigger.Schedule (CatchUpPolicy, CronSchedule, parseCron)
import Shikigami.Trigger.Scheduler qualified as Scheduler
import Shikigami.Workspace.Admission (WorkspaceHost (..))
import System.Exit (exitFailure)

-- | Persist the one completed loader report before strict mode may refuse boot.
--
-- A failure is fatal and structured: continuing would recreate the invisible
-- manifest failure that durable load state exists to eliminate.
persistAgentLoadReport :: Log.Logger -> Pool -> FilePath -> AgentLoadReport -> IO ()
persistAgentLoadReport logger pool directory report =
  recordLoadStates pool directory report >>= \case
    Right () -> pure ()
    Left problem -> do
      Log.logError
        logger
        "agents.manifest.persistence_failed"
        [ "directory" Aeson..= directory,
          "error" Aeson..= problem
        ]
      exitFailure

-- | Everything the worker loops need.
data WorkerEnv = WorkerEnv
  { pool :: !Pool,
    appEnv :: !AppEnv,
    agents :: ![AgentDecl],
    -- | The exact completed startup report, retained because routing catalogs
    -- must include disabled declarations and the bounded failure count rather
    -- than reconstructing a less truthful view from enabled agents.
    agentReport :: !AgentLoadReport,
    behaviorEnv :: !BehaviorEnv,
    decisions :: !FlowDecision.DecisionServices,
    actionAuthorizer :: !ActionAuthorizer,
    workspace :: !(Maybe WorkspaceHost),
    runTimeout :: !NominalDiffTime,
    harness :: !HarnessPolicy,
    delegationBudget :: !DelegationBudget,
    approvalDeadline :: !NominalDiffTime,
    approvalPolicy :: !Approval.ApprovalPolicySnapshot,
    approvalNotifier :: !ApprovalWorkflow.ApprovalNotifier,
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
    kanmon :: !KanmonConfig,
    danwa :: !DanwaConfig,
    rei :: !ReiConfig,
    http :: !SinkHttp,
    -- | Shikigami-owned process metrics. The provider may be real or no-op;
    -- recording sites never branch on telemetry configuration.
    metrics :: !ShikigamiMetrics,
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
    heartbeats :: !Heartbeats,
    directory :: !DirectoryHandle,
    directoryRefresher :: !(Maybe (IO ())),
    practiceReviewAttentionRecipients :: !PracticeReviewCapability.AttentionRecipientMap
  }

-- | The process-wide logger. Named rather than used as a bare selector
-- because several of the records below also carry a @logger@ field, which makes
-- the unqualified use ambiguous under @DuplicateRecordFields@.
envLogger :: WorkerEnv -> Log.Logger
envLogger WorkerEnv {logger = l} = l

-- | Named because both 'WorkerEnv' and Kioku's 'AppEnv' carry a @metrics@
-- field under @DuplicateRecordFields@.
envMetrics :: WorkerEnv -> ShikigamiMetrics
envMetrics WorkerEnv {metrics = value} = value

envKeiroMetrics :: WorkerEnv -> Maybe KeiroMetrics
envKeiroMetrics WorkerEnv {appEnv = AppEnv {metrics = value}} = value

-- | Named for the same reason as 'envLogger': several of the records below also
-- carry a @grants@ field.
envGrants :: WorkerEnv -> GrantSource
envGrants WorkerEnv {grants = g, actionAuthorizer} = withActionAuthorizer actionAuthorizer g

-- | Named for the same reason as 'envLogger': field access through a bare
-- selector is ambiguous under @DuplicateRecordFields@.
envHeartbeats :: WorkerEnv -> Heartbeats
envHeartbeats WorkerEnv {heartbeats = h} = h

envDirectory :: WorkerEnv -> DirectoryHandle
envDirectory WorkerEnv {directory = value} = value

envDirectoryRefresher :: WorkerEnv -> Maybe (IO ())
envDirectoryRefresher WorkerEnv {directoryRefresher = value} = value

envRunTimeout :: WorkerEnv -> NominalDiffTime
envRunTimeout WorkerEnv {runTimeout = timeout} = timeout

envDelegationBudget :: WorkerEnv -> DelegationBudget
envDelegationBudget WorkerEnv {delegationBudget = limit} = limit

-- | Named for the same reason as 'envLogger': 'Scheduler.SchedulerEnv' also
-- carries a @catchUpPolicy@ field.
envCatchUpPolicy :: WorkerEnv -> CatchUpPolicy
envCatchUpPolicy WorkerEnv {catchUpPolicy = policy} = policy

envApprovalDeadline :: WorkerEnv -> NominalDiffTime
envApprovalDeadline WorkerEnv {approvalDeadline = deadline} = deadline

envApprovalPolicy :: WorkerEnv -> Approval.ApprovalPolicySnapshot
envApprovalPolicy WorkerEnv {approvalPolicy = policy} = policy

envApprovalNotifier :: WorkerEnv -> ApprovalWorkflow.ApprovalNotifier
envApprovalNotifier WorkerEnv {approvalNotifier = notifier} = notifier

-- | Named for the same reason as 'envLogger': 'Conversation.ConversationEnv'
-- also carries a @conversationIdleTimeout@-shaped field.
envConversationIdleTimeout :: WorkerEnv -> NominalDiffTime
envConversationIdleTimeout WorkerEnv {conversationIdleTimeout = timeout} = timeout

-- | The agent-run workflow's dependencies.
agentRunDeps :: WorkerEnv -> AgentWorkflow.AgentRunDeps
agentRunDeps env =
  AgentWorkflow.AgentRunDeps
    { AgentWorkflow.appEnv = (.appEnv) env,
      AgentWorkflow.behaviorEnv = (.behaviorEnv) env,
      AgentWorkflow.decisions = (.decisions) env,
      AgentWorkflow.actionAuthorizer = (.actionAuthorizer) env,
      AgentWorkflow.capabilities = maybe emptyCapabilityRuntime (.capabilities) env.workspace,
      AgentWorkflow.workspace = env.workspace,
      AgentWorkflow.coordination = Nothing,
      AgentWorkflow.agents = (.agents) env,
      AgentWorkflow.kizashi = (.kizashi) env,
      AgentWorkflow.kawa = (.kawa) env,
      AgentWorkflow.kanmon = (.kanmon) env,
      AgentWorkflow.danwa = (.danwa) env,
      AgentWorkflow.rei = (.rei) env,
      AgentWorkflow.http = (.http) env,
      AgentWorkflow.hooks = AgentWorkflow.defaultAgentRunHooks,
      AgentWorkflow.approvalPolicy = envApprovalPolicy env,
      AgentWorkflow.approvalWorkflow = ApprovalWorkflow.ApprovalWorkflowEnv {ApprovalWorkflow.notifier = envApprovalNotifier env},
      AgentWorkflow.runTimeout = envRunTimeout env,
      AgentWorkflow.harness = (.harness) env,
      AgentWorkflow.delegationBudget = envDelegationBudget env,
      AgentWorkflow.logger = envLogger env,
      AgentWorkflow.grants = envGrants env,
      AgentWorkflow.directory = envDirectory env,
      AgentWorkflow.routing = Routing.routingRuntime ((.agentReport) env) (envDirectory env),
      AgentWorkflow.practiceReview = PracticeReviewCapability.failClosedPracticeReviewRuntime ((.practiceReviewAttentionRecipients) env),
      AgentWorkflow.deliveryPool = Just (envPool env),
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
    { Conversation.appEnv = (.appEnv) env,
      Conversation.behaviorEnv = (.behaviorEnv) env,
      Conversation.decisions = env.decisions,
      Conversation.deliveryPool = Just (envPool env),
      Conversation.resolveRunProfile = (agentRunDeps env).resolveRunProfile,
      Conversation.runTimeout = envRunTimeout env,
      Conversation.harness = (.harness) env,
      Conversation.idleTimeout = envConversationIdleTimeout env,
      Conversation.danwa = (.danwa) env,
      Conversation.agents = (.agents) env,
      Conversation.grants = envGrants env,
      Conversation.directory = envDirectory env
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
    { Scheduler.pool = (.pool) env,
      Scheduler.schedules = envSchedules env,
      Scheduler.principalIds = principalIdsByAgent ((.agents) env),
      Scheduler.directory = envDirectory env,
      Scheduler.catchUpPolicy = envCatchUpPolicy env,
      Scheduler.logger = envLogger env
    }

-- | Named for the same reason as 'envLogger': 'Scheduler.SchedulerEnv' also
-- carries a @schedules@ field.
envSchedules :: WorkerEnv -> Map Text CronSchedule
envSchedules WorkerEnv {schedules = s} = s

principalIdsByAgent :: [AgentDecl] -> Map Text (Maybe Text)
principalIdsByAgent =
  Map.fromList . fmap (\AgentDecl {name, identity} -> (name, declaredPrincipal <$> identity))
  where
    declaredPrincipal IdentityDecl {principal} = principal

-- | Register the directory loop only when lifecycle enforcement is enabled.
-- Its liveness deadline scales with the configured cadence: three missed
-- attempts, with the same ten-second floor as the one-second worker loops.
directoryLoopRegistration :: DirectorySettings -> [(LoopName, NominalDiffTime)]
directoryLoopRegistration = \case
  DirectoryDisabled -> []
  DirectoryFile {refreshInterval} -> [(DirectoryLoop, max 10 (refreshInterval * 3))]

-- | Cold-start the process directory and bind refresh attempts to liveness.
-- A configured source without an initial valid snapshot is fail-closed and
-- therefore fatal before any trigger or drain loop starts.
startProcessDirectory :: Log.Logger -> Heartbeats -> DirectorySettings -> IO DirectoryRuntime
startProcessDirectory logger registry settings =
  startDirectoryWithHeartbeat logger (beat registry DirectoryLoop) settings >>= \case
    Left problem -> do
      Log.logError logger "directory.start_failed" ["reason" Aeson..= problem]
      exitFailure
    Right runtime -> pure runtime

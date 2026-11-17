module Shikigami.Workers.Command.Worker
  ( runWorkerCmd,
    runResumeCmd,
    workerTierAdmission,
  )
where

import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import Control.Monad (void)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Either (rights)
import Data.Foldable (traverse_)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (nominalDiffTimeToSeconds)
import Hasql.Pool (Pool)
import Kiroku.Store.Connection qualified as StoreConnection
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Approval (ApprovalPolicySnapshot (..), renderApprovalChannel)
import Shikigami.Agent.Approval.LocalInbox (localInboxDirectory, localInboxNotifier)
import Shikigami.Agent.Approval.Workflow (ApprovalNotifier (..))
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (enabledAgentsFromReport, loadAgentsLoud)
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Agent.Workflow.Resume (runBoundedResumeWorker)
import Shikigami.App (AppEnv (..), runAppIO)
import Shikigami.App.Config (ActionAuthorizationConfig (ActionAuthorizationDisabled), AppConfig (..), Role (WorkerRole))
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Approval.Channel (ApprovalChannelAdapter (..), buildApprovalChannels, chooseApprovalChannel, composeApprovalNotifier)
import Shikigami.Authority (Authority, mkOutputKind, recordedIn)
import Shikigami.Authority.Configured (buildConfiguredAuthority)
import Shikigami.Behavior.Provider (newBehaviorEnvFor)
import Shikigami.Behavior.Run (withProgramTasks)
import Shikigami.CodingAgent.Workflow (CodingAgentRunners)
import Shikigami.Directory (DirectoryRuntime (..))
import Shikigami.Duration
import Shikigami.Execution.Capacity qualified as Capacity
import Shikigami.Flow.Builtin (builtinPack)
import Shikigami.Flow.Pack (FlowPack (..), FlowRegistry, PackMetrics (..), composeFlowRegistryOrExit, decisionServices, flowDeclarationErrors, flowPackNameText, lookupTask)
import Shikigami.Health.Worker (LoopName (OutboxLoop, QueueLoop, TelemetryLoop, TimerLoop), loopStaleAfter, loopStaleness, newHeartbeatsWithStaleness, serveProbesWith)
import Shikigami.Inspection.Consumer (consumerInspection)
import Shikigami.Inspection.Store (withObservedStore)
import Shikigami.Log qualified as Log
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Objective.Tracker.Config (TrackerEnablement (..), TrackerSettings (..))
import Shikigami.Objective.Tracker.Runtime qualified as TrackerRuntime
import Shikigami.Objective.Tracker.Store qualified as Tracker
import Shikigami.Objective.Tracker.Worker (trackerLoopRegistration)
import Shikigami.Output (outputKindText, registeredKinds, renderDefaultOutputChoice)
import Shikigami.Output.Registration (AdapterContext (..), buildOutputRegistry)
import Shikigami.Prelude (Text)
import Shikigami.Record (observedRecord, postgresRecord)
import Shikigami.Runtime (registerRuntimeCatalog, runtimeConnectionSettings)
import Shikigami.Sink (GrantSource (DbGrants))
import Shikigami.Sink.Http (HttpLimits (..))
import Shikigami.Telemetry (withRunTelemetry)
import Shikigami.Telemetry.Metrics (ShikigamiMetrics, recordPackEvent)
import Shikigami.Trust.LocalOperator.Approvals (defaultApprovalsPath)
import Shikigami.Trust.LocalOperator.Grant (defaultStateDirectory)
import Shikigami.Trust.LocalOperator.Host (LocalOperatorPaths (..), queuedCodingAgents)
import Shikigami.Trust.Tier (TrustTier (..))
import Shikigami.Workers.Config (WorkerEnv (..), directoryLoopRegistration, persistAgentLoadReport, schedulerSchedules, startProcessDirectory)
import Shikigami.Workers.Registry (runWorkers)
import Shikigami.Workspace.ConfiguredHost (configuredWorkspaceHostWithTransfers, configuredWorkspaceTransfers)
import Shikigami.Workspace.Settings (WorkspaceRepository (..), WorkspaceSettings (..))
import System.Exit qualified as Exit

-- | Boot the supervised worker that drains @shikigami_run_jobs@, runs each agent
-- end to end, and dispatches its sinks.
--
-- Every value it needs comes from the one resolved configuration: the manifest
-- directory from @agents.directory@, the connection string from
-- @database.connection_string@, the model provider from @behavior.provider@ and
-- its branch, and each downstream from its @sinks.*@ keys. The @--agents@,
-- @--kawa-url@, @--kizashi-url@, @--kanmon-url@, @--danwa-url@ and
-- @--danwa-agent@ flags are
-- command-line sources for exactly those keys.
--
-- The logger is built first, before anything that could want to log, and every
-- line this process writes goes through it as one JSON object per line.
runWorkerCmd :: [FlowPack] -> AppConfig -> IO ()
runWorkerCmd packs = runWorkerCmdWith packs Nothing

-- | Bounded operational resume owns the same dependencies as the worker.
-- Without force this reports the budgets and performs no workflow advancement.
runResumeCmd :: [FlowPack] -> Int -> Int -> Bool -> AppConfig -> IO ()
runResumeCmd packs passes candidates force config
  | force = runWorkerCmdWith packs (Just (passes, candidates)) config
  | otherwise = do
      logger <- Log.newStderrLogger Log.Info
      Log.logInfo
        logger
        "worker.resume.preview"
        ["passes" .= passes, "candidates_per_pass" .= candidates, "force_required" .= True]

runWorkerCmdWith :: [FlowPack] -> Maybe (Int, Int) -> AppConfig -> IO ()
runWorkerCmdWith packs resumeBudget config = do
  logger <- Log.newStderrLogger Log.Info
  flows <- composeFlowRegistryOrExit logger "shikigami-worker" (builtinPack : packs)
  either Exit.die pure (workerTierAdmission config)
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "shikigami-worker" config
  verifyShikigamiMigrations connStr
  withRunTelemetry "shikigami.worker" \tr keiroMetrics shikigamiMetrics -> do
    behEnv <- withProgramTasks (lookupTask flows) <$> newBehaviorEnvFor logger ((.behaviorProvider) config) (Just (otelSink tr))
    let settings = runtimeConnectionSettings logger keiroMetrics connStr
    withObservedStore tr settings $ \st storeMetrics -> do
      registerRuntimeCatalog st
      let manifestDirectory = (.agentsDirectory) config
          storePool = StoreConnection.pool st
      report <-
        loadAgentsLoud
          logger
          manifestDirectory
          ((.agentsStrict) config)
          (persistAgentLoadReport logger storePool manifestDirectory)
      agents <- enabledAgentsFromReport logger report
      Log.logInfo logger "worker.agents.loaded" ["count" .= length agents]
      refuseUndeployableAgents flows logger agents
      let httpLimits =
            HttpLimits
              { requestBytes = (.httpRequestMaxBytes) config,
                responseBytes = (.httpResponseMaxBytes) config
              }
          adapterContext = AdapterContext {logger, settings = config.packSettings, httpLimits}
          channelRegistrations = concatMap (.approvalChannels) packs
      -- Approval asks go through the channels the composed packs register,
      -- or the kernel's local inbox (plan 135, M3).
      approvalChannel <- either (\problem -> Exit.die ("shikigami-worker: refusing to start; " <> Text.unpack problem)) pure (chooseApprovalChannel channelRegistrations config.approvalChannel)
      channels <- buildApprovalChannels adapterContext channelRegistrations >>= either (\problem -> Exit.die ("shikigami-worker: refusing to start; " <> Text.unpack problem)) pure
      inboxDirectory <- localInboxDirectory <$> maybe defaultStateDirectory pure config.localOperatorStateDirectory
      actionAuthority <- recordedIn logger (Just shikigamiMetrics) storePool <$> buildActionAuthorizer packs logger config
      codingAgents <- workerCodingAgents logger shikigamiMetrics storePool config agents
      let policy =
            ApprovalPolicySnapshot
              { requireFor = requiredOutputs,
                channel = approvalChannel,
                deadline = (.approvalDeadline) config
              }
          notifier = composeApprovalNotifier logger approvalChannel (Just (ApprovalChannelAdapter (localInboxNotifier inboxDirectory).postAsk)) channels
          requiredOutputs = (.approvalRequiredSinks) config <> Set.fromList (rights (mkOutputKind <$> config.approvalRequiredOutputs))
          requiredKinds = outputKindText <$> Set.toAscList requiredOutputs
      Log.logInfo
        logger
        "worker.approval.policy"
        [ "mode" .= if null requiredKinds then ("auto_approve" :: Text) else "required",
          "required_sink_kinds" .= requiredKinds,
          "channel" .= renderApprovalChannel approvalChannel,
          "deadline_seconds" .= (floor (nominalDiffTimeToSeconds (durationTime ((.approvalDeadline) config))) :: Integer)
        ]
      -- Resolved here, at the composition root, so an unparseable cron is
      -- reported (and under agents.strict refused) once at boot rather than
      -- dropped silently on every pass of the timer loop.
      schedules <- schedulerSchedules logger ((.agentsStrict) config) agents
      -- Registered before the loops start, so a loop that never gets going is a
      -- stale heartbeat rather than an absent one the probe would skip.
      --
      -- Resume and GC use upstream continuous runners with failure callbacks,
      -- but no success heartbeat. Supervision detects their unexpected exit.
      registry <-
        newHeartbeatsWithStaleness
          ( [(loop, if loop == OutboxLoop && config.trackerSettings.enabled == TrackersEnabled then loopStaleness 45 else loopStaleAfter loop) | loop <- [QueueLoop, OutboxLoop, TimerLoop, TelemetryLoop]]
              <> directoryLoopRegistration ((.directorySettings) config)
              <> trackerLoopRegistration config.trackerSettings
          )
      DirectoryRuntime {handle = directory, refresher = directoryRefresher} <-
        startProcessDirectory logger registry ((.directorySettings) config)
      let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = keiroMetrics, store = Just st}
      workspace <- case traverse (configuredWorkspaceHostWithTransfers appEnv storePool directory actionAuthority) config.workspaceSettings of
        Left _ -> do
          Log.logError logger "worker.workspace.invalid" []
          Exit.exitFailure
        Right host -> pure host
      TrackerRuntime.withTrackerProviders (concatMap (.trackerProviders) packs) httpLimits config.trackerSettings \available -> do
        providers <- either (const (Exit.die "shikigami-worker: invalid objective tracker provider configuration")) pure available
        trackers <-
          if config.trackerSettings.enabled == TrackersDisabled
            then pure Nothing
            else do
              objective <- either (const (Exit.die "shikigami-worker: objective tracker operator is required")) pure (TrackerRuntime.operatorHost config.objectiveSettings actionAuthority)
              pure (Just (Tracker.TrackerHost objective config.trackerSettings (TrackerRuntime.providerFor providers config.trackerSettings)))
        either (Exit.die . Text.unpack) pure (Capacity.validateHeadroom settings.poolSize config.capacity)
        configured <- runAppIO appEnv (runTransaction (Capacity.configureTx config.capacity))
        case configured of
          Right (Right ()) -> pure ()
          _ -> Exit.die "shikigami-worker: shared execution capacity is unavailable"
        outputs <- buildOutputRegistry adapterContext [] (concatMap (.outputs) packs) config.defaultOutputKind >>= either (\problem -> Exit.die ("shikigami-worker: invalid outputs: " <> Text.unpack problem)) pure
        Log.logInfo
          logger
          "worker.outputs"
          [ "registered" .= (outputKindText <$> registeredKinds outputs),
            "default" .= renderDefaultOutputChoice config.defaultOutputKind
          ]
        let env =
              WorkerEnv
                { pool = storePool,
                  outputs,
                  appEnv,
                  inspection = consumerInspection (durationTime config.runTimeout + 30) config.inspection logger settings st storeMetrics,
                  agents,
                  agentReport = report,
                  behaviorEnv = behEnv,
                  decisions = decisionServices flows (either (error . show) id config.decisionModelCatalog),
                  flows,
                  actionAuthority,
                  workspace,
                  codingAgents,
                  workspaceTransfers = config.workspaceSettings >>= configuredWorkspaceTransfers,
                  runTimeout = (.runTimeout) config,
                  harness = (.harness) config,
                  capacity = config.capacity,
                  delegationBudget = (.delegationBudget) config,
                  approvalDeadline = (.approvalDeadline) config,
                  approvalPolicy = policy,
                  approvalNotifier = notifier,
                  conversationIdleTimeout = (.conversationIdleTimeout) config,
                  catchUpPolicy = (.schedulerCatchUp) config,
                  schedules,
                  metrics = shikigamiMetrics,
                  logger,
                  -- The C11 gate reads shikigami.sink_grants over the same pool
                  -- the rest of the process uses, so a grant change is visible on
                  -- the next dispatch without a restart.
                  grants = DbGrants storePool,
                  heartbeats = registry,
                  directory,
                  directoryRefresher,
                  objectiveSettings = config.objectiveSettings,
                  packMetrics = \pack -> PackMetrics (recordPackEvent shikigamiMetrics (flowPackNameText pack)),
                  -- Identity only: a repository's source is a private locator
                  -- and must not reach a model provider.
                  workspaceCatalog = [entry.identity | entry <- maybe [] (.repositories) config.workspaceSettings],
                  trackers,
                  packSettings = config.packSettings
                }
        case resumeBudget of
          Just (passes, candidates) -> void (runBoundedResumeWorker passes candidates env)
          Nothing ->
            serveProbesWith
              logger
              ((.httpHost) config)
              (Config.healthPortFor WorkerRole config)
              storePool
              registry
              (runWorkers env)

-- | The worker composes every tier. Under @local-operator@ it runs queued
-- coding-agent steps on the operator's machine, resolving each step's grant,
-- repository and worktree from the step (EP-2 M2b of MasterPlan 22); it
-- refuses @multi-tenant@ without a configured service authority.
workerTierAdmission :: AppConfig -> Either String ()
workerTierAdmission config = case (config.trustTier, config.actionAuthorization) of
  (MultiTenant, ActionAuthorizationDisabled) ->
    Left "shikigami-worker: refusing to start; trust.tier=multi-tenant requires an authority (authorization.actions.mode other than disabled, such as kikan under the Kikan distribution)"
  _ -> Right ()

-- | The coding-agent runners of this worker's tier.
workerCodingAgents :: Log.Logger -> ShikigamiMetrics -> Pool -> AppConfig -> [AgentDecl] -> IO CodingAgentRunners
workerCodingAgents logger metrics pool config agents = case config.trustTier of
  LocalOperator -> do
    approvalsFile <- maybe defaultApprovalsPath pure config.localOperatorApprovalsFile
    stateDirectory <- maybe defaultStateDirectory pure config.localOperatorStateDirectory
    Log.logInfo logger "worker.local_operator.enabled" ["approvals" .= approvalsFile, "state" .= stateDirectory]
    pure (queuedCodingAgents LocalOperatorPaths {approvalsFile, stateDirectory} (observedRecord logger (Just metrics) (postgresRecord pool)) agents)
  _ -> pure AgentWorkflow.noCodingAgents

-- | The authority @authorization.actions.mode@ selects from the composed
-- packs; a mode no pack registers refuses to start.
buildActionAuthorizer :: [FlowPack] -> Log.Logger -> AppConfig -> IO Authority
buildActionAuthorizer packs logger config =
  buildConfiguredAuthority (concatMap (.authorities) packs) logger config >>= either (Exit.die . ("shikigami-worker: refusing to start; " <>) . Text.unpack) pure

-- | Refuse to boot when a loaded manifest declares a behavior this build cannot
-- run, naming every offender.
--
-- The only such check today is a @Behavior.Flow { name }@ with no registered
-- flow behind it. Without this, the process starts happily and the mistake
-- surfaces as a failed agent run every time that agent's trigger fires — once
-- per matching activity, indefinitely, with nothing said at boot. A worker that
-- cannot run one of its agents is misconfigured, and the loud failure belongs
-- where a deploy can see it.
--
-- This is deliberately fatal rather than a skip: silently dropping the agent is
-- what 'Shikigami.Agent.Loader.loadAgentsIn' already does to an unparseable
-- manifest, and that behavior is documented there as preserved-not-endorsed.
refuseUndeployableAgents :: FlowRegistry -> Log.Logger -> [AgentDecl] -> IO ()
refuseUndeployableAgents flows logger agents =
  case [(name, err) | decl@AgentDecl {name} <- agents, err <- flowDeclarationErrors flows decl] of
    [] -> pure ()
    problems -> do
      traverse_
        ( \(agent, err) ->
            Log.logError logger "worker.agents.undeployable" ["agent" .= agent, "error" .= err]
        )
        problems
      Exit.die
        ( "shikigami-worker: refusing to start; "
            <> show (length problems)
            <> " agent declaration(s) name a behavior this build cannot run"
        )

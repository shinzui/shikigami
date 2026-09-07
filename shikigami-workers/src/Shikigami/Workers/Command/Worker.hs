module Shikigami.Workers.Command.Worker
  ( runWorkerCmd,
  )
where

import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (nominalDiffTimeToSeconds)
import Kikan.En.Client (newActionProofVerifier, newKikanEnClient)
import Kioku.App (AppEnv (..))
import Kiroku.Store.Connection qualified as StoreConnection
import Network.HTTP.Client.TLS (newTlsManager)
import Servant.Client (mkClientEnv, parseBaseUrl)
import Shikigami.Action.Authorization (ActionAuthorizer, denyAllActionAuthorizer, newKikanActionAuthorizer, shomeiClientCredentialsToken)
import Shikigami.Agent.Approval (ApprovalPolicySnapshot (..), renderApprovalChannel)
import Shikigami.Agent.Approval.Notification qualified as ApprovalNotification
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (enabledAgentsFromReport, loadAgentsLoud)
import Shikigami.App.Config (AppConfig, Role (WorkerRole))
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Behavior.Provider (newBehaviorEnvFor)
import Shikigami.Directory (DirectoryRuntime (..))
import Shikigami.Flow (flowDeclarationErrors)
import Shikigami.Health.Worker (LoopName (OutboxLoop, QueueLoop, TelemetryLoop, TimerLoop), loopStaleAfter, newHeartbeatsWithStaleness, serveProbesWith)
import Shikigami.Log qualified as Log
import Shikigami.Prelude (Text)
import Shikigami.Sink (DanwaConfig (..), GrantSource (DbGrants), KanmonConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Sink.Http (HttpLimits (..), SinkHttp, SinkHttpError, credentialsFromConfig, newSinkHttp)
import Shikigami.Sink.Permission (sinkKindText)
import Shikigami.Telemetry (withRunTelemetry)
import Shikigami.Workers.Config (WorkerEnv (..), directoryLoopRegistration, persistAgentLoadReport, schedulerSchedules, startProcessDirectory)
import Shikigami.Workers.Registry (runWorkers)
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
runWorkerCmd :: AppConfig -> IO ()
runWorkerCmd config = do
  logger <- Log.newStderrLogger Log.Info
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "shikigami-worker" config
  withRunTelemetry "shikigami.worker" \tr keiroMetrics shikigamiMetrics -> do
    behEnv <- newBehaviorEnvFor logger ((.behaviorProvider) config) (Just (otelSink tr))
    let settings = StoreConnection.defaultConnectionSettings connStr
    StoreConnection.withStore settings $ \st -> do
      let manifestDirectory = (.agentsDirectory) config
          storePool = StoreConnection.pool st
      report <-
        loadAgentsLoud
          logger
          manifestDirectory
          ((.agentsStrict) config)
          (persistAgentLoadReport logger storePool manifestDirectory)
      agents <- enabledAgentsFromReport logger report
      Log.logInfo logger "worker.agents.loaded" ["count" Aeson..= length agents]
      refuseUndeployableAgents logger agents
      let kizashiConfig =
            KizashiConfig
              { baseUrl = (.kizashiBaseUrl) config,
                defaultRecipient = (.kizashiDefaultRecipient) config
              }
          kawaConfig =
            KawaConfig
              { baseUrl = (.kawaBaseUrl) config,
                sourceSegment = (.kawaSourceSegment) config
              }
          kanmonConfig = KanmonConfig {baseUrl = (.kanmonBaseUrl) config}
          danwaConfig =
            DanwaConfig
              { baseUrl = (.danwaBaseUrl) config,
                agentParticipant = (.danwaAgentParticipant) config
              }
          httpLimits =
            HttpLimits
              { requestBytes = (.httpRequestMaxBytes) config,
                responseBytes = (.httpResponseMaxBytes) config
              }
      sinkHttp <-
        newSinkHttp httpLimits (credentialsFromConfig config) danwaConfig >>= \case
          Left failure -> refuseInvalidSinkHttp logger failure
          Right clients -> pure clients
      actionAuthorizer <- buildActionAuthorizer logger config
      let policy =
            ApprovalPolicySnapshot
              { requireFor = (.approvalRequiredSinks) config,
                channel = (.approvalChannel) config,
                deadline = (.approvalDeadline) config
              }
          notifier = ApprovalNotification.approvalNotifier logger sinkHttp danwaConfig kizashiConfig
          requiredKinds = sinkKindText <$> Set.toAscList ((.approvalRequiredSinks) config)
      Log.logInfo
        logger
        "worker.approval.policy"
        [ "mode" Aeson..= if null requiredKinds then ("auto_approve" :: Text) else "required",
          "required_sink_kinds" Aeson..= requiredKinds,
          "channel" Aeson..= renderApprovalChannel ((.approvalChannel) config),
          "deadline_seconds" Aeson..= (floor (nominalDiffTimeToSeconds ((.approvalDeadline) config)) :: Integer)
        ]
      Log.logInfo
        logger
        "worker.sink_credentials.configured"
        [ "kawa" Aeson..= credentialPresence ((.kawaToken) config),
          "kizashi" Aeson..= credentialPresence ((.kizashiToken) config),
          "kanmon" Aeson..= credentialPresence ((.kanmonToken) config),
          "danwa" Aeson..= credentialPresence ((.danwaToken) config)
        ]
      -- Resolved here, at the composition root, so an unparseable cron is
      -- reported (and under agents.strict refused) once at boot rather than
      -- dropped silently on every pass of the timer loop.
      schedules <- schedulerSchedules logger ((.agentsStrict) config) agents
      -- Registered before the loops start, so a loop that never gets going is a
      -- stale heartbeat rather than an absent one the probe would skip.
      --
      -- The resume loop is deliberately absent: it is still a run-once action
      -- rather than a loop, so it has no cadence to be stale against. It joins
      -- this list when it becomes a loop.
      registry <-
        newHeartbeatsWithStaleness
          ( [(loop, loopStaleAfter loop) | loop <- [QueueLoop, OutboxLoop, TimerLoop, TelemetryLoop]]
              <> directoryLoopRegistration ((.directorySettings) config)
          )
      DirectoryRuntime {handle = directory, refresher = directoryRefresher} <-
        startProcessDirectory logger registry ((.directorySettings) config)
      let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = keiroMetrics}
          env =
            WorkerEnv
              { pool = storePool,
                appEnv,
                agents,
                agentReport = report,
                behaviorEnv = behEnv,
                actionAuthorizer,
                runTimeout = (.runTimeout) config,
                delegationBudget = (.delegationBudget) config,
                approvalDeadline = (.approvalDeadline) config,
                approvalPolicy = policy,
                approvalNotifier = notifier,
                conversationIdleTimeout = (.conversationIdleTimeout) config,
                catchUpPolicy = (.schedulerCatchUp) config,
                schedules,
                kizashi = kizashiConfig,
                kawa = kawaConfig,
                kanmon = kanmonConfig,
                danwa = danwaConfig,
                rei = ReiConfig {baseUrl = (.reiBaseUrl) config},
                http = sinkHttp,
                metrics = shikigamiMetrics,
                logger,
                -- The C11 gate reads shikigami.sink_grants over the same pool
                -- the rest of the process uses, so a grant change is visible on
                -- the next dispatch without a restart.
                grants = DbGrants storePool,
                heartbeats = registry,
                directory,
                directoryRefresher,
                practiceReviewAttentionRecipients = (.practiceReviewAttentionRecipients) config
              }
      serveProbesWith
        logger
        ((.httpHost) config)
        (Config.healthPortFor WorkerRole config)
        storePool
        registry
        (runWorkers env)

credentialPresence :: Maybe a -> Text
credentialPresence = maybe "none" (const "token")

refuseInvalidSinkHttp :: Log.Logger -> SinkHttpError -> IO SinkHttp
refuseInvalidSinkHttp logger failure = do
  Log.logError logger "worker.sink_http.invalid" ["error" Aeson..= show failure]
  Exit.die "shikigami-worker: refusing to start; invalid sink HTTP configuration"

buildActionAuthorizer :: Log.Logger -> AppConfig -> IO ActionAuthorizer
buildActionAuthorizer logger config =
  case (.actionAuthorization) config of
    Config.ActionAuthorizationDisabled -> pure denyAllActionAuthorizer
    Config.KikanActionAuthorization {kikanBaseUrl, shomeiBaseUrl, shomeiClientId, shomeiClientSecret, issuerPublicKeys, acceptedSchemaHashes, callerId} -> do
      kikanBase <- either (refuse "Kikan-En" kikanBaseUrl) pure (parseBaseUrl (Text.unpack kikanBaseUrl))
      shomeiBase <- either (refuse "Shomei" shomeiBaseUrl) pure (parseBaseUrl (Text.unpack shomeiBaseUrl))
      manager <- newTlsManager
      let verifier = newActionProofVerifier issuerPublicKeys acceptedSchemaHashes (const (pure False))
          client = newKikanEnClient (mkClientEnv manager kikanBase) verifier
          tokenSource = shomeiClientCredentialsToken (mkClientEnv manager shomeiBase) shomeiClientId (Config.revealSecretText shomeiClientSecret)
      pure (newKikanActionAuthorizer logger callerId ((.kawaSourceSegment) config) client tokenSource)
  where
    refuse serviceName baseUrl _ =
      Exit.die ("shikigami-worker: invalid " <> Text.unpack serviceName <> " authorization base URL: " <> Text.unpack baseUrl)

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
refuseUndeployableAgents :: Log.Logger -> [AgentDecl] -> IO ()
refuseUndeployableAgents logger agents =
  case [(name, err) | decl@AgentDecl {name} <- agents, err <- flowDeclarationErrors decl] of
    [] -> pure ()
    problems -> do
      traverse_
        ( \(agent, err) ->
            Log.logError logger "worker.agents.undeployable" ["agent" Aeson..= agent, "error" Aeson..= err]
        )
        problems
      Exit.die
        ( "shikigami-worker: refusing to start; "
            <> show (length problems)
            <> " agent declaration(s) name a behavior this build cannot run"
        )

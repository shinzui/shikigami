-- | The Kikan distribution's two consumer roles (plan 135, M5):
-- @kikan-shikigami-consume-stream@ matches declared stream agents against the
-- Kawa activity stream, and @kikan-shikigami-consume-events@ matches declared
-- event agents against a public integration-event topic, such as Danwa's
-- addressed messages. Both enqueue run jobs that any worker drains.
--
-- The stock role set has no consumer: a stock composition still runs a
-- stream or event agent addressed by @enqueue-run@, but nothing there reads a
-- broker.
module Kikan.Shikigami.Binding.Intake.Role
  ( consumeStreamRoleInfo,
    consumeEventsRoleInfo,
    runConsumeStream,
    runConsumeEvents,
  )
where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Maybe (catMaybes)
import Kikan.Shikigami.Binding.Intake (OnSupervisor, StreamConfig (..), subscribeActivityStream, subscribeIntegrationEventStream)
import Kiroku.Store.Connection (KirokuStore (..))
import Options.Applicative
import Settei.Optparse (cliOverride, cliSources, namedOption)
import Settei.Source (Source)
import Shikigami.Agent.Loader (enabledAgentsFromReport, loadAgentsLoud)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.App (AppEnv (..))
import Shikigami.App.Config
  ( AppConfig,
    Role (EventConsumerRole, StreamConsumerRole),
    agentsDirectoryKey,
    kafkaActivityTopicKey,
    kafkaBrokerKey,
    kafkaEventsGroupKey,
    kafkaEventsTopicKey,
    kafkaIncludeAgentActorsKey,
    kafkaStreamGroupKey,
  )
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl, withConfigOptions)
import Shikigami.App.Role (RoleInfo (..))
import Shikigami.Directory (DirectoryRuntime (..))
import Shikigami.Flow.Builtin (builtinPack)
import Shikigami.Flow.Pack (FlowPack (..), composeFlowRegistryOrExit, streamIntakeOf)
import Shikigami.Health.Supervision (superviseLoops)
import Shikigami.Health.Worker
  ( Heartbeats,
    LoopName (ConsumerLoop, DirectoryLoop),
    beat,
    clearReport,
    loopStaleAfter,
    loopStalenessTime,
    newHeartbeatsWithStaleness,
    registerReport,
    serveProbesWith,
    supervisedLoopVerdict,
  )
import Shikigami.Inspection.Consumer (consumerInspection)
import Shikigami.Inspection.Store (withObservedStore)
import Shikigami.Log qualified as Log
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Runtime (registerRuntimeCatalog, runtimeConnectionSettings)
import Shikigami.Telemetry (withRunTelemetry)
import Shikigami.Trigger.Enqueue (ensureRunQueue)
import Shikigami.Trigger.Intake (EventHit (..), StreamHit (..), ensureDeadLetterQueue)
import Shikigami.Workers.Config (directoryLoopRegistration, persistAgentLoadReport, startProcessDirectory)

-- ── The roles ───────────────────────────────────────────────────────────────

-- | @kikan-shikigami-consume-stream@, composed with the distribution's packs
-- so a pack's stream hook has its say over the records that match its flows.
consumeStreamRoleInfo :: [FlowPack] -> RoleInfo
consumeStreamRoleInfo packs =
  RoleInfo
    { binaryName = "kikan-shikigami-consume-stream",
      role = StreamConsumerRole,
      packSettings = concatMap (.settings) packs,
      parserInfo =
        withConfigOptions
          "kikan-shikigami-consume-stream"
          "Consume the activity.v1 stream, match declared stream agents, enqueue run jobs"
          (pure (runConsumeStream packs))
          streamConsumerSources
    }

-- | @kikan-shikigami-consume-events@. Event agents have no pack hook, so the
-- packs contribute only their settings, which the shared configuration file
-- may carry.
consumeEventsRoleInfo :: [FlowPack] -> RoleInfo
consumeEventsRoleInfo packs =
  RoleInfo
    { binaryName = "kikan-shikigami-consume-events",
      role = EventConsumerRole,
      packSettings = concatMap (.settings) packs,
      parserInfo =
        withConfigOptions
          "kikan-shikigami-consume-events"
          "Consume public integration events, match Event triggers, and enqueue run jobs"
          (pure runConsumeEvents)
          (sourcesOf [agentsOption, brokerOption, eventsTopicOption, eventsGroupOption])
    }

-- | Run the @activity.v1@ stream consumer; for each declared stream agent that
-- matches an incoming envelope, log the match and enqueue a run job (the
-- stream→queue path).
--
-- Broker, topic, consumer group, manifest directory and the feedback guard all
-- come from the resolved configuration under @kafka.*@ and @agents.directory@;
-- the @--broker@, @--topic@, @--group@, @--agents@ and
-- @--include-agent-actors@ flags are command-line sources for those keys.
--
-- The packs are composed beside the builtin pack. A pack's stream hook has a
-- say over the records that match its flows' agents (docs/adr/0129).
runConsumeStream :: [FlowPack] -> AppConfig -> IO ()
runConsumeStream packs config = do
  logger <- Log.newStderrLogger Log.Info
  let include = (.kafkaIncludeAgentActors) config
      broker = (.kafkaBroker) config
      topic = (.kafkaActivityTopic) config
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "kikan-shikigami-consume-stream" config
  verifyShikigamiMigrations connStr
  withRunTelemetry "kikan-shikigami.consume-stream" \tr keiroMetrics shikigamiMetrics -> do
    let settings = runtimeConnectionSettings logger keiroMetrics connStr
    withObservedStore tr settings $ \st storeMetrics -> do
      registerRuntimeCatalog st
      let manifestDirectory = (.agentsDirectory) config
          storePool = pool st
      report <-
        loadAgentsLoud
          logger
          manifestDirectory
          ((.agentsStrict) config)
          (persistAgentLoadReport logger storePool manifestDirectory)
      agents <- enabledAgentsFromReport logger report
      Log.logInfo
        logger
        "stream.consumer.started"
        ["count" .= length agents, "topic" .= topic, "broker" .= broker]
      queueResult <- ensureRunQueue storePool
      case queueResult of
        Left err -> fail ("run-job queue reconciliation failed: " <> show err)
        Right () -> pure ()
      deadLetterResult <- ensureDeadLetterQueue storePool ((.kafkaDeadLetterQueue) config)
      case deadLetterResult of
        Left err -> fail ("stream dead-letter queue reconciliation failed: " <> show err)
        Right () -> pure ()
      let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = keiroMetrics, store = Just st}
          cfg =
            StreamConfig
              { broker = broker,
                topic = topic,
                consumerGroupId = (.kafkaStreamGroup) config,
                deadLetterQueue = (.kafkaDeadLetterQueue) config,
                inspection = consumerInspection (loopStalenessTime (loopStaleAfter ConsumerLoop)) config.inspection logger settings st storeMetrics
              }
          onHit StreamHit {agentName} = do
            let matched = ["agent" .= agentName, "topic" .= topic]
            Log.logInfo logger "stream.record.matched" matched
      registry <-
        newHeartbeatsWithStaleness
          ((ConsumerLoop, loopStaleAfter ConsumerLoop) : directoryLoopRegistration ((.directorySettings) config))
      DirectoryRuntime {handle = directory, refresher = directoryRefresher} <-
        startProcessDirectory logger registry ((.directorySettings) config)
      flows <- composeFlowRegistryOrExit logger "kikan-shikigami-consume-stream" (builtinPack : packs)
      let intake = streamIntakeOf flows config.packSettings
          consumerLoop = subscribeActivityStream logger (consumerSupervisor registry) shikigamiMetrics appEnv directory intake cfg include agents onHit
          directoryLoops = maybe [] (pure . (DirectoryLoop,)) directoryRefresher
      serveProbesWith
        logger
        ((.httpHost) config)
        (Config.healthPortFor StreamConsumerRole config)
        storePool
        registry
        (superviseLoops logger ((ConsumerLoop, consumerLoop) : directoryLoops))

-- | Consume public integration events and enqueue matching @Trigger.Event@
-- agents. Use this for danwa's @danwa.message-addressed.v1@ topic.
--
-- Broker, topic, consumer group and manifest directory come from
-- @kafka.broker@, @kafka.events.topic@, @kafka.groups.events@ and
-- @agents.directory@.
runConsumeEvents :: AppConfig -> IO ()
runConsumeEvents config = do
  logger <- Log.newStderrLogger Log.Info
  let broker = (.kafkaBroker) config
      topic = (.kafkaEventsTopic) config
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "kikan-shikigami-consume-events" config
  verifyShikigamiMigrations connStr
  withRunTelemetry "kikan-shikigami.consume-events" \tr keiroMetrics shikigamiMetrics -> do
    let settings = runtimeConnectionSettings logger keiroMetrics connStr
    withObservedStore tr settings $ \st storeMetrics -> do
      registerRuntimeCatalog st
      let manifestDirectory = (.agentsDirectory) config
          storePool = pool st
      report <-
        loadAgentsLoud
          logger
          manifestDirectory
          ((.agentsStrict) config)
          (persistAgentLoadReport logger storePool manifestDirectory)
      agents <- enabledAgentsFromReport logger report
      Log.logInfo
        logger
        "events.consumer.started"
        ["count" .= length agents, "topic" .= topic, "broker" .= broker]
      queueResult <- ensureRunQueue storePool
      case queueResult of
        Left err -> fail ("run-job queue reconciliation failed: " <> show err)
        Right () -> pure ()
      deadLetterResult <- ensureDeadLetterQueue storePool ((.kafkaDeadLetterQueue) config)
      case deadLetterResult of
        Left err -> fail ("stream dead-letter queue reconciliation failed: " <> show err)
        Right () -> pure ()
      let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = keiroMetrics, store = Just st}
          cfg =
            StreamConfig
              { broker = broker,
                topic = topic,
                consumerGroupId = (.kafkaEventsGroup) config,
                deadLetterQueue = (.kafkaDeadLetterQueue) config,
                inspection = consumerInspection (loopStalenessTime (loopStaleAfter ConsumerLoop)) config.inspection logger settings st storeMetrics
              }
          onHit EventHit {agentName, eventType, integrationMessageId} = do
            let matched =
                  [ "agent" .= agentName,
                    "event_type" .= eventType,
                    "topic" .= topic
                  ]
            Log.logInfo logger "events.record.matched" matched
            Log.logDebug logger "events.job.enqueued" (matched <> [Log.runIdKey .= (agentNameText agentName <> ":" <> integrationMessageId)])
      registry <-
        newHeartbeatsWithStaleness
          ((ConsumerLoop, loopStaleAfter ConsumerLoop) : directoryLoopRegistration ((.directorySettings) config))
      DirectoryRuntime {handle = directory, refresher = directoryRefresher} <-
        startProcessDirectory logger registry ((.directorySettings) config)
      let consumerLoop = subscribeIntegrationEventStream logger (consumerSupervisor registry) shikigamiMetrics appEnv directory cfg agents onHit
          directoryLoops = maybe [] (pure . (DirectoryLoop,)) directoryRefresher
      serveProbesWith
        logger
        ((.httpHost) config)
        (Config.healthPortFor EventConsumerRole config)
        storePool
        registry
        (superviseLoops logger ((ConsumerLoop, consumerLoop) : directoryLoops))

-- | Turn the consumer's report of its own supervisor into a liveness verdict.
--
-- While a supervisor is running, its processor state is the honest answer, and
-- it is the only one that distinguishes a consumer idling on a quiet topic from
-- one wedged on a record it will never finish. A heartbeat cannot: there is
-- nothing to beat about when no record arrives, so an idle consumer would look
-- dead.
--
-- Between connections there is no supervisor to ask, so the loop falls back to
-- its heartbeat. Beating on each attempt is what keeps a broker outage looking
-- like a loop retrying rather than a loop wedged — and Kafka being unreachable
-- is deliberately not a reason to fail this process's probes, since restarting
-- it would not bring the broker back.
consumerSupervisor :: Heartbeats -> OnSupervisor
consumerSupervisor registry = \case
  Nothing -> do
    beat registry ConsumerLoop
    clearReport registry ConsumerLoop
  Just (master, processorId) ->
    registerReport registry ConsumerLoop (supervisedLoopVerdict ConsumerLoop master processorId)

-- ── Command-line configuration sources ──────────────────────────────────────

-- | Collect the flags that were actually given. An absent flag contributes no
-- source, which leaves a configuration file, the environment, or the declared
-- default in place.
sourcesOf :: [Parser (Maybe Source)] -> Parser [Source]
sourcesOf parsers = catMaybes <$> sequenceA parsers

-- | The stream consumer's flags.
streamConsumerSources :: Parser [Source]
streamConsumerSources =
  (<>)
    <$> sourcesOf [agentsOption, brokerOption, activityTopicOption, streamGroupOption]
    <*> includeAgentActorsSwitch

-- | @--include-agent-actors@ takes no value, so it cannot be a 'namedOption'.
-- Passing it contributes the same source a @--set@ override would, carrying the
-- literal @true@; not passing it contributes nothing, which leaves the
-- feedback-guard default in place.
includeAgentActorsSwitch :: Parser [Source]
includeAgentActorsSwitch =
  toSources
    <$> switch
      ( long "include-agent-actors"
          <> help "Match agent-produced activities too (meta-detectors; sets kafka.include_agent_actors)"
      )
  where
    toSources False = []
    toSources True = cliSources "--include-agent-actors" [cliOverride kafkaIncludeAgentActorsKey "true"]

agentsOption :: Parser (Maybe Source)
agentsOption =
  namedOption
    "--agents"
    agentsDirectoryKey
    (long "agents" <> metavar "DIR" <> help "Agents manifest directory (sets agents.directory)")

brokerOption :: Parser (Maybe Source)
brokerOption =
  namedOption
    "--broker"
    kafkaBrokerKey
    (long "broker" <> metavar "HOST:PORT" <> help "Kafka broker (sets kafka.broker)")

activityTopicOption :: Parser (Maybe Source)
activityTopicOption =
  namedOption
    "--topic"
    kafkaActivityTopicKey
    (long "topic" <> metavar "TOPIC" <> help "Activity topic (sets kafka.activity.topic)")

eventsTopicOption :: Parser (Maybe Source)
eventsTopicOption =
  namedOption
    "--topic"
    kafkaEventsTopicKey
    (long "topic" <> metavar "TOPIC" <> help "Integration-event topic (sets kafka.events.topic)")

streamGroupOption :: Parser (Maybe Source)
streamGroupOption =
  namedOption
    "--group"
    kafkaStreamGroupKey
    (long "group" <> metavar "GROUP" <> help "Consumer group id (sets kafka.groups.stream)")

eventsGroupOption :: Parser (Maybe Source)
eventsGroupOption =
  namedOption
    "--group"
    kafkaEventsGroupKey
    (long "group" <> metavar "GROUP" <> help "Consumer group id (sets kafka.groups.events)")

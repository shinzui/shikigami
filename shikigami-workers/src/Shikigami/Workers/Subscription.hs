module Shikigami.Workers.Subscription
  ( runConsumeStream,
    runConsumeEvents,
  )
where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Kiroku.Store.Connection (KirokuStore (..))
import Shikigami.Agent.Loader (enabledAgentsFromReport, loadAgentsLoud)
import Shikigami.App (AppEnv (..))
import Shikigami.App.Config (AppConfig, Role (EventConsumerRole, StreamConsumerRole))
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Directory (DirectoryRuntime (..))
import Shikigami.Health.Supervision (superviseLoops)
import Shikigami.Health.Worker
  ( Heartbeats,
    LoopName (ConsumerLoop, DirectoryLoop),
    beat,
    clearReport,
    loopStaleAfter,
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
import Shikigami.Trigger.Consumer (EventHit (..), OnSupervisor, StreamConfig (..), StreamHit (..), ensureDeadLetterQueue, subscribeActivityStream, subscribeIntegrationEventStream)
import Shikigami.Trigger.Enqueue (ensureRunQueue)
import Shikigami.Trigger.Stream (IncludeAgentActors (ExcludeAgentActors, IncludeAgentActors))
import Shikigami.Workers.Config (directoryLoopRegistration, persistAgentLoadReport, startProcessDirectory)

-- | Run the @activity.v1@ stream consumer; for each declared stream agent that
-- matches an incoming envelope, log the match and enqueue a run job (the
-- stream→queue path).
--
-- Broker, topic, consumer group, manifest directory and the feedback guard all
-- come from the resolved configuration under @kafka.*@ and @agents.directory@;
-- the @--broker@, @--topic@, @--group@, @--agents@ and
-- @--include-agent-actors@ flags are command-line sources for those keys.
runConsumeStream :: AppConfig -> IO ()
runConsumeStream config = do
  logger <- Log.newStderrLogger Log.Info
  let include = if (.kafkaIncludeAgentActors) config then IncludeAgentActors else ExcludeAgentActors
      broker = (.kafkaBroker) config
      topic = (.kafkaActivityTopic) config
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "shikigami-consume-stream" config
  verifyShikigamiMigrations connStr
  withRunTelemetry "shikigami.consume-stream" \tr keiroMetrics shikigamiMetrics -> do
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
                inspection = consumerInspection (loopStaleAfter ConsumerLoop) config.inspection logger settings st storeMetrics
              }
          onHit StreamHit {agentName} = do
            let matched = ["agent" .= agentName, "topic" .= topic]
            Log.logInfo logger "stream.record.matched" matched
      registry <-
        newHeartbeatsWithStaleness
          ((ConsumerLoop, loopStaleAfter ConsumerLoop) : directoryLoopRegistration ((.directorySettings) config))
      DirectoryRuntime {handle = directory, refresher = directoryRefresher} <-
        startProcessDirectory logger registry ((.directorySettings) config)
      let consumerLoop = subscribeActivityStream logger (consumerSupervisor registry) shikigamiMetrics appEnv directory cfg include agents onHit
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
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "shikigami-consume-events" config
  verifyShikigamiMigrations connStr
  withRunTelemetry "shikigami.consume-events" \tr keiroMetrics shikigamiMetrics -> do
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
                inspection = consumerInspection (loopStaleAfter ConsumerLoop) config.inspection logger settings st storeMetrics
              }
          onHit EventHit {agentName, eventType, integrationMessageId} = do
            let matched =
                  [ "agent" .= agentName,
                    "event_type" .= eventType,
                    "topic" .= topic
                  ]
            Log.logInfo logger "events.record.matched" matched
            Log.logDebug logger "events.job.enqueued" (matched <> [Log.runIdKey .= (agentName <> ":" <> integrationMessageId)])
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

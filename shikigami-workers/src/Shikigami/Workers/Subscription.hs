module Shikigami.Workers.Subscription
  ( runConsumeStream,
    runConsumeEvents,
  )
where

import Data.Aeson qualified as Aeson
import Kioku.App (AppEnv (..), noopTracer)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Loader (loadAgentsIn)
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Log qualified as Log
import Shikigami.Trigger.Consumer (EventHit (..), StreamConfig (..), StreamHit (..), subscribeActivityStream, subscribeIntegrationEventStream)
import Shikigami.Trigger.Enqueue (ensureRunQueue)
import Shikigami.Trigger.Stream (IncludeAgentActors (ExcludeAgentActors, IncludeAgentActors))

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
  let include = if Config.kafkaIncludeAgentActors config then IncludeAgentActors else ExcludeAgentActors
      broker = Config.kafkaBroker config
      topic = Config.kafkaActivityTopic config
  agents <- loadAgentsIn (Config.agentsDirectory config)
  Log.logInfo
    logger
    "stream.consumer.started"
    ["count" Aeson..= length agents, "topic" Aeson..= topic, "broker" Aeson..= broker]
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "shikigami-consume-stream" config
  let settings = defaultConnectionSettings connStr
  withStore settings $ \st -> do
    queueResult <- ensureRunQueue (pool st)
    case queueResult of
      Left err -> fail ("run-job queue reconciliation failed: " <> show err)
      Right () -> pure ()
    tr <- noopTracer
    let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = Nothing}
        cfg = StreamConfig {broker = broker, topic = topic, consumerGroupId = Config.kafkaStreamGroup config}
        onHit StreamHit {agentName} = do
          let matched = ["agent" Aeson..= agentName, "topic" Aeson..= topic]
          Log.logInfo logger "stream.record.matched" matched
    subscribeActivityStream logger appEnv cfg include agents onHit

-- | Consume public integration events and enqueue matching @Trigger.Event@
-- agents. Use this for danwa's @danwa.message-addressed.v1@ topic.
--
-- Broker, topic, consumer group and manifest directory come from
-- @kafka.broker@, @kafka.events.topic@, @kafka.groups.events@ and
-- @agents.directory@.
runConsumeEvents :: AppConfig -> IO ()
runConsumeEvents config = do
  logger <- Log.newStderrLogger Log.Info
  let broker = Config.kafkaBroker config
      topic = Config.kafkaEventsTopic config
  agents <- loadAgentsIn (Config.agentsDirectory config)
  Log.logInfo
    logger
    "events.consumer.started"
    ["count" Aeson..= length agents, "topic" Aeson..= topic, "broker" Aeson..= broker]
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "shikigami-consume-events" config
  let settings = defaultConnectionSettings connStr
  withStore settings $ \st -> do
    queueResult <- ensureRunQueue (pool st)
    case queueResult of
      Left err -> fail ("run-job queue reconciliation failed: " <> show err)
      Right () -> pure ()
    tr <- noopTracer
    let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = Nothing}
        cfg = StreamConfig {broker = broker, topic = topic, consumerGroupId = Config.kafkaEventsGroup config}
        onHit EventHit {agentName, eventType, integrationMessageId} = do
          let matched =
                [ "agent" Aeson..= agentName,
                  "event_type" Aeson..= eventType,
                  "topic" Aeson..= topic
                ]
          Log.logInfo logger "events.record.matched" matched
          Log.logDebug logger "events.job.enqueued" (matched <> [Log.runIdKey Aeson..= (agentName <> ":" <> integrationMessageId)])
    subscribeIntegrationEventStream logger appEnv cfg agents onHit

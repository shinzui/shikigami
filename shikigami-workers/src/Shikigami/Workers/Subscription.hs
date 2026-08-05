module Shikigami.Workers.Subscription
  ( runConsumeStream,
    runConsumeEvents,
  )
where

import Data.Aeson qualified as Aeson
import Data.List (find)
import Data.Text qualified as Text
import Kioku.App (AppEnv (..), noopTracer)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgentsIn)
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Log qualified as Log
import Shikigami.Trigger.Consumer (StreamConfig (..), subscribeActivityStream, subscribeIntegrationEventStream)
import Shikigami.Trigger.Consumer qualified as Consumer
import Shikigami.Trigger.Enqueue (enqueueAddressedRunWithKey, enqueueRunJob, runJobFromEnvelope)
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
    tr <- noopTracer
    let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = Nothing}
        cfg = StreamConfig {broker = broker, topic = topic, consumerGroupId = Config.kafkaStreamGroup config}
        onHit hit = do
          let matched = ["agent" Aeson..= Consumer.streamAgentName hit, "topic" Aeson..= topic]
          Log.logInfo logger "stream.record.matched" matched
          case find ((== Consumer.streamAgentName hit) . name) agents of
            Just decl -> do
              r <- enqueueRunJob (pool st) (runJobFromEnvelope decl (Consumer.envelope hit))
              case r of
                Right mid ->
                  Log.logInfo logger "stream.job.enqueued" (matched <> ["message_id" Aeson..= Text.pack (show mid)])
                Left e ->
                  Log.logError logger "stream.job.enqueue_failed" (matched <> ["error" Aeson..= Text.pack (show e)])
            Nothing -> pure ()
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
    tr <- noopTracer
    let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = Nothing}
        cfg = StreamConfig {broker = broker, topic = topic, consumerGroupId = Config.kafkaEventsGroup config}
        onHit hit = do
          let matched =
                [ "agent" Aeson..= Consumer.eventAgentName hit,
                  "event_type" Aeson..= Consumer.eventType hit,
                  "topic" Aeson..= topic
                ]
          Log.logInfo logger "events.record.matched" matched
          let key = Consumer.eventAgentName hit <> ":" <> Consumer.integrationMessageId hit
          r <- enqueueAddressedRunWithKey (pool st) (Consumer.eventAgentName hit) (Consumer.payload hit) key
          case r of
            Right mid ->
              Log.logInfo logger "events.job.enqueued" (matched <> [Log.runIdKey Aeson..= key, "message_id" Aeson..= Text.pack (show mid)])
            Left e ->
              Log.logError logger "events.job.enqueue_failed" (matched <> [Log.runIdKey Aeson..= key, "error" Aeson..= Text.pack (show e)])
    subscribeIntegrationEventStream logger appEnv cfg agents onHit

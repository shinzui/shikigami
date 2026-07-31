module Shikigami.Workers.Subscription
  ( runConsumeStream,
    runConsumeEvents,
  )
where

import Data.List (find)
import Data.Text qualified as Text
import Kioku.App (AppEnv (..), noopTracer)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgentsIn)
import Shikigami.App.Config (AppConfig)
import Shikigami.App.Config qualified as Config
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Trigger.Consumer (StreamConfig (..), subscribeActivityStream, subscribeIntegrationEventStream)
import Shikigami.Trigger.Consumer qualified as Consumer
import Shikigami.Trigger.Enqueue (enqueueAddressedRunWithKey, enqueueRunJob, runJobFromEnvelope)
import Shikigami.Trigger.Stream (IncludeAgentActors (ExcludeAgentActors, IncludeAgentActors))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

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
  hSetBuffering stdout LineBuffering
  let include = if Config.kafkaIncludeAgentActors config then IncludeAgentActors else ExcludeAgentActors
      broker = Config.kafkaBroker config
      topic = Config.kafkaActivityTopic config
  agents <- loadAgentsIn (Config.agentsDirectory config)
  putStrLn
    ( "[stream] loaded "
        <> show (length agents)
        <> " agents; consuming "
        <> Text.unpack topic
        <> " on "
        <> Text.unpack broker
    )
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "shikigami-consume-stream" config
  let settings = defaultConnectionSettings connStr
  withStore settings $ \st -> do
    tr <- noopTracer
    let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = Nothing}
        cfg = StreamConfig {broker = broker, topic = topic, consumerGroupId = Config.kafkaStreamGroup config}
        onHit hit = do
          putStrLn ("[stream] MATCH agent=" <> Text.unpack (Consumer.streamAgentName hit))
          case find ((== Consumer.streamAgentName hit) . name) agents of
            Just decl -> do
              r <- enqueueRunJob (pool st) (runJobFromEnvelope decl (Consumer.envelope hit))
              case r of
                Right mid -> putStrLn ("[stream]   enqueued run job " <> show mid)
                Left e -> putStrLn ("[stream]   enqueue failed: " <> show e)
            Nothing -> pure ()
    subscribeActivityStream appEnv cfg include agents onHit

-- | Consume public integration events and enqueue matching @Trigger.Event@
-- agents. Use this for danwa's @danwa.message-addressed.v1@ topic.
--
-- Broker, topic, consumer group and manifest directory come from
-- @kafka.broker@, @kafka.events.topic@, @kafka.groups.events@ and
-- @agents.directory@.
runConsumeEvents :: AppConfig -> IO ()
runConsumeEvents config = do
  hSetBuffering stdout LineBuffering
  let broker = Config.kafkaBroker config
      topic = Config.kafkaEventsTopic config
  agents <- loadAgentsIn (Config.agentsDirectory config)
  putStrLn
    ( "[events] loaded "
        <> show (length agents)
        <> " agents; consuming "
        <> Text.unpack topic
        <> " on "
        <> Text.unpack broker
    )
  connStr <- Config.revealSecretText <$> requireDatabaseUrl "shikigami-consume-events" config
  let settings = defaultConnectionSettings connStr
  withStore settings $ \st -> do
    tr <- noopTracer
    let appEnv = AppEnv {connectionSettings = settings, tracer = tr, metrics = Nothing}
        cfg = StreamConfig {broker = broker, topic = topic, consumerGroupId = Config.kafkaEventsGroup config}
        onHit hit = do
          putStrLn
            ( "[events] MATCH agent="
                <> Text.unpack (Consumer.eventAgentName hit)
                <> " eventType="
                <> Text.unpack (Consumer.eventType hit)
            )
          let key = Consumer.eventAgentName hit <> ":" <> Consumer.integrationMessageId hit
          r <- enqueueAddressedRunWithKey (pool st) (Consumer.eventAgentName hit) (Consumer.payload hit) key
          case r of
            Right mid -> putStrLn ("[events]   enqueued run job " <> show mid)
            Left e -> putStrLn ("[events]   enqueue failed: " <> show e)
    subscribeIntegrationEventStream appEnv cfg agents onHit

-- | Command-line surfaces of the worker-role executables.
--
-- Each worker role is its own binary — @shikigami-worker@,
-- @shikigami-scheduler@, @shikigami-consume-stream@, @shikigami-consume-events@,
-- @shikigami-run-behavior@, @shikigami-agent-run@ — because an operator scales,
-- restarts, and rolls them out independently, and because a single umbrella
-- process could not honestly import both server and worker implementations
-- without violating the package dependency graph.
--
-- == How configuration reaches a role
--
-- Every role's parser produces a pair: the action to run, which takes the
-- resolved 'Shikigami.App.Config.AppConfig', and the command-line configuration
-- sources its own flags supplied. The flags an operator already knows —
-- @--agents@, @--broker@, @--topic@, @--group@, @--kawa-url@ and the rest —
-- survive, but as ordinary Settei sources aimed at declared keys rather than as
-- private parsers. @--broker 10.0.0.1:9092@ and
-- @--set kafka.broker=10.0.0.1:9092@ are the same thing, both appear in
-- @--explain-config@ with their spelling, and neither can disagree with the
-- other about what the default is.
--
-- 'runRole' is the whole of each executable's @main@: parse, resolve, act. That
-- ordering is what makes @--check-config@ honest — configuration is fully
-- resolved and the role's required keys are checked before the action opens a
-- database, joins a consumer group, or registers a processor.
--
-- Every parser has the same result type, which is exactly why a dropped or
-- misrouted flag is invisible to the type checker; 'workerRoles' exists so a
-- test can drive all six parsers without listing them a second time.
module Shikigami.Workers.Command
  ( -- * Roles
    WorkerRoleInfo (..),
    workerRoles,
    runRole,

    -- * The individual roles
    workerRoleInfo,
    schedulerRoleInfo,
    consumeStreamRoleInfo,
    consumeEventsRoleInfo,
    runBehaviorRoleInfo,
    agentRunRoleInfo,
  )
where

import Data.Maybe (catMaybes)
import Options.Applicative
import Settei.Optparse (cliOverride, cliSources, namedOption)
import Settei.Source (Source)
import Shikigami.App.Config
  ( AppConfig,
    Role (..),
    agentsDirectoryKey,
    kafkaActivityTopicKey,
    kafkaBrokerKey,
    kafkaEventsGroupKey,
    kafkaEventsTopicKey,
    kafkaIncludeAgentActorsKey,
    kafkaStreamGroupKey,
    sinksDanwaAgentParticipantKey,
    sinksDanwaBaseUrlKey,
    sinksKawaBaseUrlKey,
    sinksKizashiBaseUrlKey,
  )
import Shikigami.App.Config.Load
  ( ConfigOptions,
    runAppConfig,
    withConfigOptions,
  )
import Shikigami.Workers.Command.AgentRun (runAgentRun)
import Shikigami.Workers.Command.RunBehavior (runRunBehavior)
import Shikigami.Workers.Command.Scheduler (runSchedulerCmd)
import Shikigami.Workers.Command.Worker (runWorkerCmd)
import Shikigami.Workers.Subscription (runConsumeEvents, runConsumeStream)

-- | One worker executable: what it is installed as, which role it plays for the
-- purpose of required-key checking, and how its command line parses.
data WorkerRoleInfo = WorkerRoleInfo
  { binaryName :: !String,
    role :: !Role,
    parserInfo :: !(ParserInfo (AppConfig -> IO (), ConfigOptions))
  }

-- | Every worker executable, in the order they are documented.
--
-- Exists so a test can assert that each one's @--help@ works and keeps its
-- flags, and so adding a role forces a decision about its name.
workerRoles :: [WorkerRoleInfo]
workerRoles =
  [ workerRoleInfo,
    schedulerRoleInfo,
    consumeStreamRoleInfo,
    consumeEventsRoleInfo,
    runBehaviorRoleInfo,
    agentRunRoleInfo
  ]

-- | A worker executable's @main@: parse the command line, resolve configuration,
-- then act.
runRole :: WorkerRoleInfo -> IO ()
runRole info = do
  (action, options) <- execParser (parserInfo info)
  config <- runAppConfig (role info) options
  action config

-- ── The roles ───────────────────────────────────────────────────────────────

-- | @shikigami-worker@: drain the run-job queue and run agents end to end.
workerRoleInfo :: WorkerRoleInfo
workerRoleInfo =
  WorkerRoleInfo
    { binaryName = "shikigami-worker",
      role = WorkerRole,
      parserInfo =
        withConfigOptions
          "Drain shikigami_run_jobs: run each agent, dispatch its sinks, record the session"
          (pure runWorkerCmd)
          ( sourcesOf
              [ agentsOption,
                kawaUrlOption,
                kizashiUrlOption,
                danwaUrlOption,
                danwaAgentOption
              ]
          )
    }

-- | @shikigami-scheduler@: arm Schedule triggers and drive timer firing.
schedulerRoleInfo :: WorkerRoleInfo
schedulerRoleInfo =
  WorkerRoleInfo
    { binaryName = "shikigami-scheduler",
      role = SchedulerRole,
      parserInfo =
        withConfigOptions
          "Arm Schedule triggers and drive keiro timer firing"
          (pure runSchedulerCmd)
          (sourcesOf [agentsOption])
    }

-- | @shikigami-consume-stream@: match declared stream agents against @activity.v1@.
consumeStreamRoleInfo :: WorkerRoleInfo
consumeStreamRoleInfo =
  WorkerRoleInfo
    { binaryName = "shikigami-consume-stream",
      role = StreamConsumerRole,
      parserInfo =
        withConfigOptions
          "Consume the activity.v1 stream, match declared stream agents, enqueue run jobs"
          (pure runConsumeStream)
          streamConsumerSources
    }

-- | @shikigami-consume-events@: match declared event agents against a public topic.
consumeEventsRoleInfo :: WorkerRoleInfo
consumeEventsRoleInfo =
  WorkerRoleInfo
    { binaryName = "shikigami-consume-events",
      role = EventConsumerRole,
      parserInfo =
        withConfigOptions
          "Consume public integration events, match Event triggers, and enqueue run jobs"
          (pure runConsumeEvents)
          ( sourcesOf
              [ agentsOption,
                brokerOption,
                eventsTopicOption,
                eventsGroupOption
              ]
          )
    }

-- | @shikigami-run-behavior@: run one agent's behavior, with no database.
--
-- The manifest path and the payload are per-invocation arguments; the only
-- configuration it reads is which model provider to run. That makes it both the
-- offline default (stubs, no key, no database) and the cheapest live check of a
-- real provider, depending on nothing but @behavior.provider@.
runBehaviorRoleInfo :: WorkerRoleInfo
runBehaviorRoleInfo =
  WorkerRoleInfo
    { binaryName = "shikigami-run-behavior",
      role = RunBehaviorRole,
      parserInfo =
        withConfigOptions
          "Run an agent's behavior once, with no database and no recalled memory"
          ( runRunBehavior
              <$> strOption (long "agent" <> metavar "FILE" <> help "Agent manifest (.dhall)")
              <*> optional (strOption (long "payload" <> metavar "JSON" <> help "Trigger payload as JSON"))
          )
          (pure [])
    }

-- | @shikigami-agent-run@: run one agent through the kioku session lifecycle.
agentRunRoleInfo :: WorkerRoleInfo
agentRunRoleInfo =
  WorkerRoleInfo
    { binaryName = "shikigami-agent-run",
      role = AgentRunRole,
      parserInfo =
        withConfigOptions
          "Run an agent with the kioku session/memory lifecycle"
          ( runAgentRun
              <$> strOption (long "agent" <> metavar "NAME|FILE" <> help "Agent name (agents/<name>.dhall) or manifest path")
              <*> optional (strOption (long "from-activity" <> metavar "FILE" <> help "Record an activity.v1 envelope as a memory instead of running"))
          )
          (pure [])
    }

-- ── Command-line configuration sources ──────────────────────────────────────

-- | Collect the flags that were actually given. An absent flag contributes no
-- source, which is what leaves a configuration file, the environment, or the
-- declared default in place.
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

kawaUrlOption :: Parser (Maybe Source)
kawaUrlOption =
  namedOption
    "--kawa-url"
    sinksKawaBaseUrlKey
    (long "kawa-url" <> metavar "URL" <> help "kawa (or stub-kawa) base URL (sets sinks.kawa.base_url)")

kizashiUrlOption :: Parser (Maybe Source)
kizashiUrlOption =
  namedOption
    "--kizashi-url"
    sinksKizashiBaseUrlKey
    (long "kizashi-url" <> metavar "URL" <> help "kizashi base URL (sets sinks.kizashi.base_url)")

danwaUrlOption :: Parser (Maybe Source)
danwaUrlOption =
  namedOption
    "--danwa-url"
    sinksDanwaBaseUrlKey
    (long "danwa-url" <> metavar "URL" <> help "danwa base URL (sets sinks.danwa.base_url)")

danwaAgentOption :: Parser (Maybe Source)
danwaAgentOption =
  namedOption
    "--danwa-agent"
    sinksDanwaAgentParticipantKey
    (long "danwa-agent" <> metavar "PARTICIPANT" <> help "danwa agent participant id (sets sinks.danwa.agent_participant)")

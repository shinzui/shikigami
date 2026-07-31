-- | Command-line surfaces of the worker-role executables.
--
-- Each worker role is its own binary — @shikigami-worker@,
-- @shikigami-scheduler@, @shikigami-consume-stream@, @shikigami-consume-events@,
-- @shikigami-run-behavior@, @shikigami-agent-run@ — because an operator scales,
-- restarts, and rolls them out independently, and because a single umbrella
-- process could not honestly import both server and worker implementations
-- without violating the package dependency graph.
--
-- Every parser here produces an @IO ()@: the action to run once the options
-- parse. That shape is what lets @main@ be @join (execParser info)@ and, more
-- importantly, lets a test drive the parser purely with
-- @optparse-applicative@'s @execParserPure@ instead of shelling out to a built
-- binary to check that @--help@ works.
--
-- Where the values come from is still the command line plus
-- @PG_CONNECTION_STRING@; making that a resolved, validated configuration is
-- owned by
-- @docs\/plans\/37-adopt-settei-configuration-across-shikigami-binaries.md@.
module Shikigami.Workers.Command
  ( workerInfo,
    schedulerInfo,
    consumeStreamInfo,
    consumeEventsInfo,
    runBehaviorInfo,
    agentRunInfo,
    workerCommands,
  )
where

import Data.Text (Text)
import Options.Applicative
import Shikigami.Workers.Command.AgentRun (runAgentRun)
import Shikigami.Workers.Command.RunBehavior (runRunBehavior)
import Shikigami.Workers.Command.Scheduler (runSchedulerCmd)
import Shikigami.Workers.Command.Worker (runWorkerCmd)
import Shikigami.Workers.Subscription (runConsumeEvents, runConsumeStream)

-- | Every worker executable, paired with the name it is installed under.
--
-- Exists so a test can assert that each one's @--help@ works without listing
-- them a second time, and so adding a role forces a decision about its name.
workerCommands :: [(String, ParserInfo (IO ()))]
workerCommands =
  [ ("shikigami-worker", workerInfo),
    ("shikigami-scheduler", schedulerInfo),
    ("shikigami-consume-stream", consumeStreamInfo),
    ("shikigami-consume-events", consumeEventsInfo),
    ("shikigami-run-behavior", runBehaviorInfo),
    ("shikigami-agent-run", agentRunInfo)
  ]

agentsDirOption :: Parser FilePath
agentsDirOption =
  strOption
    ( long "agents"
        <> metavar "DIR"
        <> value "agents"
        <> showDefault
        <> help "Agents manifest directory"
    )

brokerOption :: Parser Text
brokerOption =
  strOption
    ( long "broker"
        <> metavar "HOST:PORT"
        <> value "127.0.0.1:9092"
        <> showDefault
        <> help "Kafka broker"
    )

-- | @shikigami-worker@: drain the run-job queue and run agents end to end.
workerInfo :: ParserInfo (IO ())
workerInfo =
  info
    (parser <**> helper)
    ( fullDesc
        <> progDesc "Drain shikigami_run_jobs: run each agent, dispatch its sinks, record the session"
    )
  where
    parser =
      runWorkerCmd
        <$> agentsDirOption
        <*> strOption (long "kawa-url" <> metavar "URL" <> value "http://localhost:8088" <> showDefault <> help "kawa (or stub-kawa) base URL")
        <*> strOption (long "kizashi-url" <> metavar "URL" <> value "http://localhost:8089" <> showDefault <> help "kizashi base URL")
        <*> strOption (long "danwa-url" <> metavar "URL" <> value "http://localhost:8080" <> showDefault <> help "danwa base URL")
        <*> strOption (long "danwa-agent" <> metavar "PARTICIPANT" <> value "part_shikigami" <> showDefault <> help "danwa agent participant id used as message author")

-- | @shikigami-scheduler@: arm Schedule triggers and drive timer firing.
schedulerInfo :: ParserInfo (IO ())
schedulerInfo =
  info
    ((runSchedulerCmd <$> agentsDirOption) <**> helper)
    (fullDesc <> progDesc "Arm Schedule triggers and drive keiro timer firing")

-- | @shikigami-consume-stream@: match declared stream agents against @activity.v1@.
consumeStreamInfo :: ParserInfo (IO ())
consumeStreamInfo =
  info
    (parser <**> helper)
    (fullDesc <> progDesc "Consume the activity.v1 stream, match declared stream agents, enqueue run jobs")
  where
    parser =
      runConsumeStream
        <$> agentsDirOption
        <*> brokerOption
        <*> strOption (long "topic" <> metavar "TOPIC" <> value "activity.v1" <> showDefault <> help "Topic")
        <*> strOption (long "group" <> metavar "GROUP" <> value "shikigami-stream" <> showDefault <> help "Consumer group id")
        <*> switch (long "include-agent-actors" <> help "Match agent-produced activities too (meta-detectors; off by default = feedback guard)")

-- | @shikigami-consume-events@: match declared event agents against a public topic.
consumeEventsInfo :: ParserInfo (IO ())
consumeEventsInfo =
  info
    (parser <**> helper)
    (fullDesc <> progDesc "Consume public integration events, match Event triggers, and enqueue run jobs")
  where
    parser =
      runConsumeEvents
        <$> agentsDirOption
        <*> brokerOption
        <*> strOption (long "topic" <> metavar "TOPIC" <> value "danwa.message-addressed.v1" <> showDefault <> help "Integration-event topic")
        <*> strOption (long "group" <> metavar "GROUP" <> value "shikigami-events" <> showDefault <> help "Consumer group id")

-- | @shikigami-run-behavior@: run one behavior with deterministic stubs.
runBehaviorInfo :: ParserInfo (IO ())
runBehaviorInfo =
  info
    (parser <**> helper)
    (fullDesc <> progDesc "Run an agent's behavior with deterministic stubs (no DB, no key)")
  where
    parser =
      runRunBehavior
        <$> strOption (long "agent" <> metavar "FILE" <> help "Agent manifest (.dhall)")
        <*> optional (strOption (long "payload" <> metavar "JSON" <> help "Trigger payload as JSON"))

-- | @shikigami-agent-run@: run one agent through the kioku session lifecycle.
agentRunInfo :: ParserInfo (IO ())
agentRunInfo =
  info
    (parser <**> helper)
    (fullDesc <> progDesc "Run an agent with the kioku session/memory lifecycle")
  where
    parser =
      runAgentRun
        <$> strOption (long "agent" <> metavar "NAME|FILE" <> help "Agent name (agents/<name>.dhall) or manifest path")
        <*> optional (strOption (long "from-activity" <> metavar "FILE" <> help "Record an activity.v1 envelope as a memory instead of running"))

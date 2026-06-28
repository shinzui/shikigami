module Shikigami.Cli (main) where

import Data.Text (Text)
import Options.Applicative
import Shikigami.Cli.Commands.AgentRun (runAgentRun)
import Shikigami.Cli.Commands.ConsumeStream (runConsumeEvents, runConsumeStream)
import Shikigami.Cli.Commands.DanwaSpike (runDanwaSpike)
import Shikigami.Cli.Commands.EnqueueRun (runEnqueueRun)
import Shikigami.Cli.Commands.PublishFixture (runPublishFixture)
import Shikigami.Cli.Commands.RunBehavior (runRunBehavior)
import Shikigami.Cli.Commands.Scheduler (runSchedulerCmd)
import Shikigami.Cli.Commands.StubKawa (runStubKawaCmd)
import Shikigami.Cli.Commands.Validate (runValidate)
import Shikigami.Cli.Commands.Worker (runWorkerCmd)

data Command
  = Validate FilePath
  | RunBehavior FilePath (Maybe String)
  | AgentRun String (Maybe FilePath)
  | StubKawa Int (Maybe String) (Maybe String)
  | EnqueueRun String (Maybe String)
  | PublishFixture FilePath Text Text
  | ConsumeStream FilePath Text Text Text Bool
  | ConsumeEvents FilePath Text Text Text
  | Scheduler FilePath
  | Worker FilePath Text Text Text Text
  | DanwaSpike String String String

main :: IO ()
main = run =<< execParser opts
  where
    opts = info (parser <**> helper) (fullDesc <> progDesc "shikigami declared-agent runtime")

parser :: Parser Command
parser =
  subparser
    ( command
        "validate"
        ( info
            (Validate <$> argument str (metavar "FILE"))
            (progDesc "Parse and validate an agent manifest (.dhall)")
        )
        <> command
          "run-behavior"
          ( info
              ( RunBehavior
                  <$> strOption (long "agent" <> metavar "FILE" <> help "Agent manifest (.dhall)")
                  <*> optional (strOption (long "payload" <> metavar "JSON" <> help "Trigger payload as JSON"))
              )
              (progDesc "Run an agent's behavior with deterministic stubs (no DB, no key)")
          )
        <> command
          "agent-run"
          ( info
              ( AgentRun
                  <$> strOption (long "agent" <> metavar "NAME|FILE" <> help "Agent name (agents/<name>.dhall) or manifest path")
                  <*> optional (strOption (long "from-activity" <> metavar "FILE" <> help "Record an activity.v1 envelope as a memory instead of running"))
              )
              (progDesc "Run an agent with the kioku session/memory lifecycle")
          )
        <> command
          "stub-kawa"
          ( info
              ( StubKawa
                  <$> option auto (long "port" <> metavar "PORT" <> help "Port to listen on")
                  <*> optional (strOption (long "republish-topic" <> metavar "TOPIC" <> help "Re-publish accepted envelopes onto this Kafka topic"))
                  <*> optional (strOption (long "broker" <> metavar "HOST:PORT" <> help "Kafka broker for --republish-topic"))
              )
              (progDesc "Run the kawa ingest doorway stub (C2), optionally republishing to a topic")
          )
        <> command
          "enqueue-run"
          ( info
              ( EnqueueRun
                  <$> argument str (metavar "AGENT")
                  <*> optional (strOption (long "payload" <> metavar "JSON" <> help "Addressed run payload as JSON"))
              )
              (progDesc "Enqueue an addressed run job for a named agent (IP-7)")
          )
        <> command
          "danwa-spike"
          ( info
              ( DanwaSpike
                  <$> strOption (long "danwa-url" <> metavar "URL" <> help "danwa server base URL")
                  <*> strOption (long "human" <> metavar "PARTICIPANT" <> help "Human participant id, e.g. part_...")
                  <*> strOption (long "agent" <> metavar "PARTICIPANT" <> help "Agent participant id, e.g. part_...")
              )
              (progDesc "Spike the danwa HTTP client by posting a human message and agent reply")
          )
        <> command
          "consume-events"
          ( info
              ( ConsumeEvents
                  <$> strOption (long "agents" <> metavar "DIR" <> value "agents" <> help "Agents manifest directory")
                  <*> strOption (long "broker" <> metavar "HOST:PORT" <> value "127.0.0.1:9092" <> help "Kafka broker")
                  <*> strOption (long "topic" <> metavar "TOPIC" <> value "danwa.message-addressed.v1" <> help "Integration-event topic")
                  <*> strOption (long "group" <> metavar "GROUP" <> value "shikigami-events" <> help "Consumer group id")
              )
              (progDesc "Consume public integration events, match Event triggers, and enqueue run jobs")
          )
        <> command
          "publish-fixture"
          ( info
              ( PublishFixture
                  <$> argument str (metavar "FILE")
                  <*> strOption (long "broker" <> metavar "HOST:PORT" <> value "127.0.0.1:9092" <> help "Kafka broker")
                  <*> strOption (long "topic" <> metavar "TOPIC" <> value "activity.v1" <> help "Topic")
              )
              (progDesc "Publish one Activity Envelope (JSON) onto the activity stream with keiro-* headers")
          )
        <> command
          "consume-stream"
          ( info
              ( ConsumeStream
                  <$> strOption (long "agents" <> metavar "DIR" <> value "agents" <> help "Agents manifest directory")
                  <*> strOption (long "broker" <> metavar "HOST:PORT" <> value "127.0.0.1:9092" <> help "Kafka broker")
                  <*> strOption (long "topic" <> metavar "TOPIC" <> value "activity.v1" <> help "Topic")
                  <*> strOption (long "group" <> metavar "GROUP" <> value "shikigami-stream" <> help "Consumer group id")
                  <*> switch (long "include-agent-actors" <> help "Match agent-produced activities too (meta-detectors; off by default = feedback guard)")
              )
              (progDesc "Consume the activity.v1 stream, match declared stream agents, enqueue run jobs")
          )
        <> command
          "scheduler"
          ( info
              ( Scheduler
                  <$> strOption (long "agents" <> metavar "DIR" <> value "agents" <> help "Agents manifest directory")
              )
              (progDesc "Arm Schedule triggers and drive keiro timer firing")
          )
        <> command
          "worker"
          ( info
              ( Worker
                  <$> strOption (long "agents" <> metavar "DIR" <> value "agents" <> help "Agents manifest directory")
                  <*> strOption (long "kawa-url" <> metavar "URL" <> value "http://localhost:8088" <> help "kawa (or stub-kawa) base URL")
                  <*> strOption (long "kizashi-url" <> metavar "URL" <> value "http://localhost:8089" <> help "kizashi base URL")
                  <*> strOption (long "danwa-url" <> metavar "URL" <> value "http://localhost:8080" <> help "danwa base URL")
                  <*> strOption (long "danwa-agent" <> metavar "PARTICIPANT" <> value "part_shikigami" <> help "danwa agent participant id used as message author")
              )
              (progDesc "Drain shikigami_run_jobs: run each agent, dispatch its sinks, record the session")
          )
    )

run :: Command -> IO ()
run (Validate file) = runValidate file
run (RunBehavior file payload) = runRunBehavior file payload
run (AgentRun agentArg fromActivity) = runAgentRun agentArg fromActivity
run (StubKawa port topic broker) = runStubKawaCmd port topic broker
run (EnqueueRun agent payload) = runEnqueueRun agent payload
run (PublishFixture file broker topic) = runPublishFixture broker topic file
run (ConsumeStream agentsDir broker topic grp inclAgents) = runConsumeStream agentsDir broker topic grp inclAgents
run (ConsumeEvents agentsDir broker topic grp) = runConsumeEvents agentsDir broker topic grp
run (Scheduler agentsDir) = runSchedulerCmd agentsDir
run (Worker agentsDir kawaUrl kizashiUrl danwaUrl danwaAgent) = runWorkerCmd agentsDir kawaUrl kizashiUrl danwaUrl danwaAgent
run (DanwaSpike danwaUrl human agent) = runDanwaSpike danwaUrl human agent

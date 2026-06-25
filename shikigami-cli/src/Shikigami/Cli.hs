module Shikigami.Cli (main) where

import Options.Applicative
import Shikigami.Cli.Commands.AgentRun (runAgentRun)
import Shikigami.Cli.Commands.EnqueueRun (runEnqueueRun)
import Shikigami.Cli.Commands.RunBehavior (runRunBehavior)
import Shikigami.Cli.Commands.StubKawa (runStubKawaCmd)
import Shikigami.Cli.Commands.Validate (runValidate)

data Command
  = Validate FilePath
  | RunBehavior FilePath (Maybe String)
  | AgentRun String (Maybe FilePath)
  | StubKawa Int (Maybe String) (Maybe String)
  | EnqueueRun String (Maybe String)

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
    )

run :: Command -> IO ()
run (Validate file) = runValidate file
run (RunBehavior file payload) = runRunBehavior file payload
run (AgentRun agentArg fromActivity) = runAgentRun agentArg fromActivity
run (StubKawa port topic broker) = runStubKawaCmd port topic broker
run (EnqueueRun agent payload) = runEnqueueRun agent payload

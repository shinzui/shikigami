-- | The @shikigami@ administrative command line.
--
-- One binary with subcommands, rather than one binary per command, because these
-- are short-lived operator actions rather than long-running roles: validating a
-- manifest, rendering a lifecycle diagram, enqueuing a run, publishing a fixture
-- envelope, or standing up a downstream stub for a local end-to-end run. Nothing
-- here supervises anything, and none of it is what @shikigami-server@ serves.
--
-- It lives in @shikigami-server@ because these commands reach downstream HTTP and
-- Kafka surfaces the server package already owns, and because the package
-- dependency graph gives them nowhere else to live: @shikigami-workers@ may not
-- be imported by the server, and core may hold no listener.
--
-- The parser produces an @IO ()@, so @main@ is @join (execParser info)@ and a
-- test can drive @--help@ for every subcommand purely with
-- @optparse-applicative@'s @execParserPure@.
module Shikigami.Server.Command
  ( adminInfo,
    adminSubcommands,
  )
where

import Options.Applicative
import Shikigami.Server.Command.DanwaSpike (runDanwaSpike)
import Shikigami.Server.Command.EnqueueRun (runEnqueueRun)
import Shikigami.Server.Command.PublishFixture (runPublishFixture)
import Shikigami.Server.Command.RenderLifecycle (runRenderLifecycle)
import Shikigami.Server.Command.StubKawa (runStubKawaCmd)
import Shikigami.Server.Command.Validate (runValidate)

-- | The whole @shikigami@ command line.
adminInfo :: ParserInfo (IO ())
adminInfo =
  info
    (subparser (foldMap snd adminSubcommands) <**> helper)
    (fullDesc <> progDesc "shikigami declared-agent runtime: administrative commands")

-- | Every subcommand, paired with its name.
--
-- Exists so a test can assert each one parses and renders help without listing
-- them a second time.
adminSubcommands :: [(String, Mod CommandFields (IO ()))]
adminSubcommands =
  [ ("validate", command "validate" validateInfo),
    ("render-lifecycle", command "render-lifecycle" renderLifecycleInfo),
    ("enqueue-run", command "enqueue-run" enqueueRunInfo),
    ("publish-fixture", command "publish-fixture" publishFixtureInfo),
    ("stub-kawa", command "stub-kawa" stubKawaInfo),
    ("danwa-spike", command "danwa-spike" danwaSpikeInfo)
  ]

validateInfo :: ParserInfo (IO ())
validateInfo =
  info
    ((runValidate <$> argument str (metavar "FILE")) <**> helper)
    (progDesc "Parse and validate an agent manifest (.dhall)")

renderLifecycleInfo :: ParserInfo (IO ())
renderLifecycleInfo =
  info
    ((runRenderLifecycle <$> argument str (metavar "FILE")) <**> helper)
    (progDesc "Render a Flow agent lifecycle as Mermaid")

enqueueRunInfo :: ParserInfo (IO ())
enqueueRunInfo =
  info
    (parser <**> helper)
    (progDesc "Enqueue an addressed run job for a named agent")
  where
    parser =
      runEnqueueRun
        <$> argument str (metavar "AGENT")
        <*> optional (strOption (long "payload" <> metavar "JSON" <> help "Addressed run payload as JSON"))

publishFixtureInfo :: ParserInfo (IO ())
publishFixtureInfo =
  info
    (parser <**> helper)
    (progDesc "Publish one Activity Envelope (JSON) onto the activity stream with keiro-* headers")
  where
    parser =
      (\file broker topic -> runPublishFixture broker topic file)
        <$> argument str (metavar "FILE")
        <*> strOption (long "broker" <> metavar "HOST:PORT" <> value "127.0.0.1:9092" <> showDefault <> help "Kafka broker")
        <*> strOption (long "topic" <> metavar "TOPIC" <> value "activity.v1" <> showDefault <> help "Topic")

stubKawaInfo :: ParserInfo (IO ())
stubKawaInfo =
  info
    (parser <**> helper)
    (progDesc "Run the kawa ingest doorway stub, optionally republishing to a topic")
  where
    parser =
      runStubKawaCmd
        <$> option auto (long "port" <> metavar "PORT" <> help "Port to listen on")
        <*> optional (strOption (long "republish-topic" <> metavar "TOPIC" <> help "Re-publish accepted envelopes onto this Kafka topic"))
        <*> optional (strOption (long "broker" <> metavar "HOST:PORT" <> help "Kafka broker for --republish-topic"))

danwaSpikeInfo :: ParserInfo (IO ())
danwaSpikeInfo =
  info
    (parser <**> helper)
    (progDesc "Spike the danwa HTTP client by posting a human message and agent reply")
  where
    parser =
      runDanwaSpike
        <$> strOption (long "danwa-url" <> metavar "URL" <> help "danwa server base URL")
        <*> strOption (long "human" <> metavar "PARTICIPANT" <> help "Human participant id, e.g. part_...")
        <*> strOption (long "agent" <> metavar "PARTICIPANT" <> help "Agent participant id, e.g. part_...")

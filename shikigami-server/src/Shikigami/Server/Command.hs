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
-- == How configuration reaches a subcommand
--
-- Each subcommand parser produces a pair: the action to run, which takes the
-- resolved 'Shikigami.App.Config.AppConfig', and any command-line configuration
-- sources the subcommand itself contributes. Sources are how a flag like
-- @--broker@ survives the move to typed configuration: it is not a private
-- parser feeding a private value, it is an ordinary Settei source aimed at the
-- declared @kafka.broker@ key. So @--broker@ and @--set kafka.broker=…@ mean the
-- same thing, both appear in @--explain-config@ with their spelling, and neither
-- can disagree with the other about defaults.
--
-- The subcommand is optional so that @shikigami --describe-config@ works with no
-- command at all. Invoking the binary with neither a command nor a diagnostic
-- prints a pointer to @--help@ and exits with the reserved usage status.
--
-- The parser produces this pair rather than a bare @IO ()@, so a test can drive
-- @--help@ for every subcommand purely with @optparse-applicative@'s
-- @execParserPure@.
module Shikigami.Server.Command
  ( adminInfo,
    adminSubcommands,
    AdminAction,
    runAdmin,
  )
where

import Data.Maybe (catMaybes)
import Options.Applicative
import Settei.Optparse (namedOption)
import Settei.Source (Source)
import Shikigami.App.Config (AppConfig, Role (AdminRole), kafkaActivityTopicKey, kafkaBrokerKey, sinksDanwaBaseUrlKey)
import Shikigami.App.Config.Load
  ( ConfigOptions (..),
    configOptions,
    runAppConfig,
    usageExitCode,
  )
import Shikigami.Server.Command.DanwaSpike (runDanwaSpike)
import Shikigami.Server.Command.EnqueueRun (runEnqueueRun)
import Shikigami.Server.Command.Grants (runGrantsGrant, runGrantsList, runGrantsRevoke)
import Shikigami.Server.Command.PublishFixture (runPublishFixture)
import Shikigami.Server.Command.RenderLifecycle (runRenderLifecycle)
import Shikigami.Server.Command.StubKawa (runStubKawaCmd)
import Shikigami.Server.Command.Validate (runValidate)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

-- | What a subcommand contributes: the work to do once configuration is
-- resolved, plus the configuration sources its own flags supplied.
type AdminAction = (AppConfig -> IO (), [Source])

-- | The whole @shikigami@ command line.
adminInfo :: ParserInfo (Maybe AdminAction, ConfigOptions)
adminInfo =
  info
    (((,) <$> optional (subparser (foldMap snd adminSubcommands)) <*> configOptions) <**> helper)
    ( fullDesc
        <> progDesc "shikigami declared-agent runtime: administrative commands"
        <> failureCode usageExitCode
    )

-- | Parse the command line, resolve configuration, and run the chosen command.
--
-- Resolution happens after parsing and before the action, so every diagnostic
-- mode completes without a subcommand opening a database, a socket, or a Kafka
-- producer.
runAdmin :: IO ()
runAdmin = do
  (chosen, options) <- execParser adminInfo
  case chosen of
    -- A diagnostic with no subcommand is legitimate, and 'runAppConfig' exits
    -- inside it. Reaching the next line therefore means no command was given.
    Nothing -> do
      _ <- runAppConfig AdminRole options
      hPutStrLn stderr "shikigami: no command given; run 'shikigami --help' for the list"
      exitWith (ExitFailure usageExitCode)
    Just (action, sources) -> do
      config <- runAppConfig AdminRole options {namedSources = namedSources options <> sources}
      action config

-- | Every subcommand, paired with its name.
--
-- Exists so a test can assert each one parses and renders help without listing
-- them a second time.
adminSubcommands :: [(String, Mod CommandFields AdminAction)]
adminSubcommands =
  [ ("validate", command "validate" validateInfo),
    ("render-lifecycle", command "render-lifecycle" renderLifecycleInfo),
    ("enqueue-run", command "enqueue-run" enqueueRunInfo),
    ("publish-fixture", command "publish-fixture" publishFixtureInfo),
    ("stub-kawa", command "stub-kawa" stubKawaInfo),
    ("danwa-spike", command "danwa-spike" danwaSpikeInfo),
    ("grants", command "grants" grantsInfo)
  ]

-- | @grants@ is a group rather than a flat command: list, grant, and revoke
-- share the table but take different arguments, and a flat @grant-sink@ /
-- @revoke-sink@ pair would scatter the C11 surface across the top-level help.
grantsInfo :: ParserInfo AdminAction
grantsInfo =
  info
    (subparser (foldMap snd grantsSubcommands) <**> helper)
    (progDesc "Inspect and change per-agent sink permission grants (C11)")

grantsSubcommands :: [(String, Mod CommandFields AdminAction)]
grantsSubcommands =
  [ ("list", command "list" grantsListInfo),
    ("grant", command "grant" grantsGrantInfo),
    ("revoke", command "revoke" grantsRevokeInfo)
  ]

grantsListInfo :: ParserInfo AdminAction
grantsListInfo =
  info
    (parser <**> helper)
    (progDesc "List sink grants, most-significant page first")
  where
    parser =
      (\limit after -> (runGrantsList limit after, []))
        <$> optional (option auto (long "limit" <> metavar "N" <> help "rows per page (1-200, default 50)"))
        <*> optional (strOption (long "after" <> metavar "AGENT:KIND" <> help "resume after this row"))

grantsGrantInfo :: ParserInfo AdminAction
grantsGrantInfo =
  info
    (parser <**> helper)
    (progDesc "Grant an agent a sink kind")
  where
    parser =
      (\agent kind by -> (runGrantsGrant agent kind by, []))
        <$> argument str (metavar "AGENT")
        <*> argument str (metavar "KIND")
        <*> optional (strOption (long "by" <> metavar "WHO" <> help "recorded in granted_by"))

grantsRevokeInfo :: ParserInfo AdminAction
grantsRevokeInfo =
  info
    (parser <**> helper)
    (progDesc "Revoke an agent's sink kind")
  where
    parser =
      (\agent kind by -> (runGrantsRevoke agent kind by, []))
        <$> argument str (metavar "AGENT")
        <*> argument str (metavar "KIND")
        <*> optional (strOption (long "by" <> metavar "WHO" <> help "recorded in revoked_by"))

-- | A subcommand that reads no configuration at all.
offline :: IO () -> AdminAction
offline action = (const action, [])

validateInfo :: ParserInfo AdminAction
validateInfo =
  info
    ((offline . runValidate <$> argument str (metavar "FILE")) <**> helper)
    (progDesc "Parse and validate an agent manifest (.dhall)")

renderLifecycleInfo :: ParserInfo AdminAction
renderLifecycleInfo =
  info
    ((offline . runRenderLifecycle <$> argument str (metavar "FILE")) <**> helper)
    (progDesc "Render a Flow agent lifecycle as Mermaid")

enqueueRunInfo :: ParserInfo AdminAction
enqueueRunInfo =
  info
    (parser <**> helper)
    (progDesc "Enqueue an addressed run job for a named agent")
  where
    parser =
      (\agent payload conversation -> (runEnqueueRun agent payload conversation, []))
        <$> argument str (metavar "AGENT")
        <*> optional (strOption (long "payload" <> metavar "JSON" <> help "Addressed run payload as JSON"))
        <*> switch (long "conversation" <> help "Route the job as a danwa conversation turn instead of an agent run")

publishFixtureInfo :: ParserInfo AdminAction
publishFixtureInfo =
  info
    (parser <**> helper)
    (progDesc "Publish one Activity Envelope (JSON) onto the activity stream with keiro-* headers")
  where
    parser =
      (\file sources -> (runPublishFixture file, sources))
        <$> argument str (metavar "FILE")
        <*> sourcesOf [brokerOption, topicOption]

stubKawaInfo :: ParserInfo AdminAction
stubKawaInfo =
  info
    (parser <**> helper)
    (progDesc "Run the kawa ingest doorway stub, optionally republishing to a topic")
  where
    parser =
      (\port topic sources -> (runStubKawaCmd port topic, sources))
        <$> option auto (long "port" <> metavar "PORT" <> help "Port to listen on")
        <*> optional (strOption (long "republish-topic" <> metavar "TOPIC" <> help "Re-publish accepted envelopes onto this Kafka topic"))
        <*> sourcesOf [brokerOption]

danwaSpikeInfo :: ParserInfo AdminAction
danwaSpikeInfo =
  info
    (parser <**> helper)
    (progDesc "Spike the danwa HTTP client by posting a human message and agent reply")
  where
    parser =
      (\human agent sources -> (runDanwaSpike human agent, sources))
        <$> strOption (long "human" <> metavar "PARTICIPANT" <> help "Human participant id, e.g. part_...")
        <*> strOption (long "agent" <> metavar "PARTICIPANT" <> help "Agent participant id, e.g. part_...")
        <*> sourcesOf [danwaUrlOption]

-- ── Command-line configuration sources ──────────────────────────────────────

-- | Collect the flags that were actually given. An absent flag contributes no
-- source, which is what leaves the environment or the declared default in place.
sourcesOf :: [Parser (Maybe Source)] -> Parser [Source]
sourcesOf parsers = catMaybes <$> sequenceA parsers

brokerOption :: Parser (Maybe Source)
brokerOption =
  namedOption
    "--broker"
    kafkaBrokerKey
    (long "broker" <> metavar "HOST:PORT" <> help "Kafka broker (sets kafka.broker)")

topicOption :: Parser (Maybe Source)
topicOption =
  namedOption
    "--topic"
    kafkaActivityTopicKey
    (long "topic" <> metavar "TOPIC" <> help "Activity topic (sets kafka.activity.topic)")

danwaUrlOption :: Parser (Maybe Source)
danwaUrlOption =
  namedOption
    "--danwa-url"
    sinksDanwaBaseUrlKey
    (long "danwa-url" <> metavar "URL" <> help "danwa base URL (sets sinks.danwa.base_url)")

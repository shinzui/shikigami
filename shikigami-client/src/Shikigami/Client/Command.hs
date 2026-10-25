-- | The @shikigami-client@ command line.
--
-- A thin operator tool for asking a running server a question over the typed
-- client, so that \"is the deployed server healthy, and does it speak the
-- contract this build expects?\" can be answered without curl and without
-- guessing at paths.
--
-- The parser produces an @IO ()@, so @main@ is @join (execParser info)@ and a
-- test can drive @--help@ purely with @optparse-applicative@'s
-- @execParserPure@.
module Shikigami.Client.Command
  ( clientInfo,
    clientSubcommands,
    runHealthCommand,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Options.Applicative
import Relay.Pagination (Connection (..), Edge (..), PageInfo (..), cursorFromText, cursorToText)
import Relay.Pagination.Servant (forwardPage)
import Servant.API (parseUrlPiece)
import Servant.Health (ProbeResult (..), ProbeStatus (..))
import Shikigami.Agent.Api qualified as Agent
import Shikigami.Client (agentsClient, callServer, healthClient)
import Shikigami.Health.Api (HealthApi (..))
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | The whole @shikigami-client@ command line.
clientInfo :: ParserInfo (IO ())
clientInfo =
  info
    (subparser (foldMap snd clientSubcommands) <**> helper)
    (fullDesc <> progDesc "Call a running shikigami server through the typed client")

-- | Every subcommand, paired with its name, so a test can cover them all.
clientSubcommands :: [(String, Mod CommandFields (IO ()))]
clientSubcommands =
  [ ("health", command "health" healthInfo),
    ("agents", command "agents" agentsInfo)
  ]

healthInfo :: ParserInfo (IO ())
healthInfo =
  info
    (parser <**> helper)
    (progDesc "Report the server's liveness and readiness probes")
  where
    parser =
      runHealthCommand
        <$> strOption
          ( long "server"
              <> metavar "URL"
              <> value "http://localhost:8080"
              <> showDefault
              <> help "Base URL of the shikigami server"
          )

-- | Ask both probes and print what they said.
--
-- Exits non-zero when either probe fails or the call itself fails, so the
-- command is usable directly in a deployment check.
runHealthCommand :: Text -> IO ()
runHealthCommand serverUrl = do
  liveResult <- callServer serverUrl (live healthClient)
  readyResult <- callServer serverUrl (ready healthClient)
  liveOk <- report "live" liveResult
  readyOk <- report "ready" readyResult
  if liveOk && readyOk then pure () else exitFailure
  where
    report label = \case
      Left err -> do
        hPutStrLn stderr ("shikigami-client: " <> label <> ": " <> show err)
        pure False
      Right (ProbePassed body) -> do
        putStrLn (label <> ": ok (" <> Text.unpack (check body) <> ")")
        pure True
      Right (ProbeFailed body) -> do
        putStrLn (label <> ": FAILED (" <> Text.unpack (check body) <> ")")
        pure False

serverOption :: Parser Text
serverOption = strOption (long "server" <> metavar "URL" <> value "http://localhost:8080" <> showDefault)

agentsInfo :: ParserInfo (IO ())
agentsInfo =
  info
    ( subparser
        ( command "list" (info (listParser <**> helper) (progDesc "List declared agents"))
            <> command "show" (info (showParser <**> helper) (progDesc "Show a declared agent"))
        )
        <**> helper
    )
    (progDesc "Inspect declared agents")
  where
    listParser =
      ( \url size cursor -> do
          boundary <- traverse (either (fail . Text.unpack) pure . cursorFromText) cursor
          callServer url ((.list) agentsClient (forwardPage size boundary)) >>= \case
            Right (Agent.AgentPage page) -> do
              mapM_ (\edge -> let view = edge.node in putStrLn (Text.unpack (Text.unwords [view.name, boolText view.enabled, view.lifecycle, boolText view.runnable]))) page.edges
              mapM_ (putStrLn . ("endCursor " <>) . Text.unpack . cursorToText) page.pageInfo.endCursor
            result -> hPutStrLn stderr (show result) >> exitFailure
      )
        <$> serverOption
        <*> option auto (long "first" <> value 50)
        <*> optional (strOption (long "after" <> metavar "CURSOR"))
    showParser =
      ( \url name -> do
          agentName <- either (fail . Text.unpack) pure (parseUrlPiece name)
          callServer url ((.show) agentsClient agentName) >>= \case
            Right (Agent.AgentFound view) ->
              mapM_ (putStrLn . Text.unpack) ["name         " <> view.name, "enabled      " <> boolText view.enabled, "trigger      " <> view.trigger, "behavior     " <> view.behavior, "sinks        " <> Text.intercalate "," view.sinks, "lifecycle    " <> view.lifecycle, "runnable     " <> boolText view.runnable]
            result -> hPutStrLn stderr (show result) >> exitFailure
      )
        <$> serverOption
        <*> strArgument (metavar "NAME")

boolText :: Bool -> Text
boolText True = "true"
boolText False = "false"

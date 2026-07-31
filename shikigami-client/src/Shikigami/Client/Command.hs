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
import Servant.Health (ProbeResult (..), ProbeStatus (..))
import Shikigami.Client (callServer, healthClient)
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
  [ ("health", command "health" healthInfo)
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

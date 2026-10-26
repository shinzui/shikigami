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

import Control.Concurrent (threadDelay)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Clock (getMonotonicTimeNSec)
import Options.Applicative
import Relay.Pagination (Connection (..), Edge (..), PageInfo (..), cursorFromText, cursorToText)
import Relay.Pagination.Servant (forwardPage)
import Servant.API (parseUrlPiece)
import Servant.Health (ProbeResult (..), ProbeStatus (..))
import Shikigami.Agent.Api qualified as Agent
import Shikigami.AgentRun.Api qualified as Run
import Shikigami.Client (Credential, agentsClient, callServer, credentialFor, healthClient)
import Shikigami.Health.Api (HealthApi (..))
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitFailure), exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)

-- | The whole @shikigami-client@ command line.
clientInfo :: ParserInfo (IO ())
clientInfo =
  info
    ((\token commandAction -> commandAction token) <$> optional (strOption (long "token" <> metavar "TOKEN")) <*> subparser (foldMap snd clientSubcommands) <**> helper)
    (fullDesc <> progDesc "Call a running shikigami server through the typed client")

-- | Every subcommand, paired with its name, so a test can cover them all.
clientSubcommands :: [(String, Mod CommandFields (Maybe Text -> IO ()))]
clientSubcommands =
  [ ("health", command "health" (fmap const healthInfo)),
    ("agents", command "agents" agentsInfo),
    ("runs", command "runs" runsInfo)
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

agentsInfo :: ParserInfo (Maybe Text -> IO ())
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
      ( \url size cursor token -> do
          credential <- resolveCredential token
          boundary <- traverse (either (fail . Text.unpack) pure . cursorFromText) cursor
          callServer url ((.list) (agentsClient credential) (forwardPage size boundary)) >>= \case
            Right (Agent.AgentPage page) -> do
              mapM_ (\edge -> let view = edge.node in putStrLn (Text.unpack (Text.unwords [view.name, boolText view.enabled, view.lifecycle, boolText view.runnable]))) page.edges
              mapM_ (putStrLn . ("endCursor " <>) . Text.unpack . cursorToText) page.pageInfo.endCursor
            Right result -> hPutStrLn stderr (show result) >> exitFailure
            Left _ -> hPutStrLn stderr "shikigami-client: request failed" >> exitFailure
      )
        <$> serverOption
        <*> option auto (long "first" <> value 50)
        <*> optional (strOption (long "after" <> metavar "CURSOR"))
    showParser =
      ( \url name token -> do
          credential <- resolveCredential token
          agentName <- either (fail . Text.unpack) pure (parseUrlPiece name)
          callServer url ((.show) (agentsClient credential) agentName) >>= \case
            Right (Agent.AgentFound view) ->
              mapM_ (putStrLn . Text.unpack) ["name         " <> view.name, "enabled      " <> boolText view.enabled, "trigger      " <> view.trigger, "behavior     " <> view.behavior, "sinks        " <> Text.intercalate "," view.sinks, "lifecycle    " <> view.lifecycle, "runnable     " <> boolText view.runnable]
            Right result -> hPutStrLn stderr (show result) >> exitFailure
            Left _ -> hPutStrLn stderr "shikigami-client: request failed" >> exitFailure
      )
        <$> serverOption
        <*> strArgument (metavar "NAME")

boolText :: Bool -> Text
boolText True = "true"
boolText False = "false"

resolveCredential :: Maybe Text -> IO Credential
resolveCredential token = credentialFor <$> maybe (fmap (fmap Text.pack) (lookupEnv "SHIKIGAMI_API_TOKEN")) (pure . Just) token

runsInfo :: ParserInfo (Maybe Text -> IO ())
runsInfo =
  info
    ( subparser
        ( command "request" (info (requestParser <**> helper) (progDesc "Request an addressed agent run"))
            <> command "show" (info (showParser <**> helper) (progDesc "Read one run lifecycle"))
            <> command "list" (info (listParser <**> helper) (progDesc "List accepted run requests"))
            <> command "wait" (info (waitParser <**> helper) (progDesc "Wait for a terminal run lifecycle"))
        )
        <**> helper
    )
    (progDesc "Request and inspect agent runs")
  where
    requestParser =
      ( \url agent key payload token -> do
          credential <- resolveCredential token
          name <- either (fail . Text.unpack) pure (parseUrlPiece agent)
          body <- either fail pure (Aeson.eitherDecode (LBS.fromStrict (TextEncoding.encodeUtf8 (Text.pack payload))))
          callServer url ((.request) ((.runs) (agentsClient credential) name) (Run.AgentRunRequest key body)) >>= \case
            Right (Run.RunAccepted (accepted, location)) -> reportRun "accepted" accepted location
            Right (Run.RunReplayed (accepted, location)) -> reportRun "replayed" accepted location
            Right result -> hPutStrLn stderr (show result) >> exitFailure
            Left _ -> hPutStrLn stderr "shikigami-client: run request failed" >> exitFailure
      )
        <$> serverOption
        <*> strArgument (metavar "AGENT")
        <*> strOption (long "key" <> metavar "KEY")
        <*> strOption (long "payload" <> metavar "JSON" <> value "{}")
    showParser =
      ( \url agent runId token -> do
          credential <- resolveCredential token
          name <- either (fail . Text.unpack) pure (parseUrlPiece agent)
          callServer url ((.show) ((.runs) (agentsClient credential) name) runId) >>= \case
            Right (Run.RunFound view) -> printStatus view
            Right result -> hPutStrLn stderr (show result) >> exitFailure
            Left _ -> hPutStrLn stderr "shikigami-client: run status request failed" >> exitFailure
      )
        <$> serverOption
        <*> strArgument (metavar "AGENT")
        <*> strArgument (metavar "RUN_ID")
    listParser =
      ( \url agent size after token -> do
          credential <- resolveCredential token
          name <- either (fail . Text.unpack) pure (parseUrlPiece agent)
          cursor <- traverse (either (fail . Text.unpack) pure . cursorFromText) after
          callServer url ((.list) ((.runs) (agentsClient credential) name) (forwardPage size cursor)) >>= \case
            Right (Run.RunPage page) -> do
              mapM_ (\edge -> putStrLn (Text.unpack (Text.unwords [edge.node.runId, edge.node.idempotencyKey, edge.node.disposition]))) page.edges
              mapM_ (putStrLn . ("endCursor " <>) . Text.unpack . cursorToText) page.pageInfo.endCursor
            Right result -> hPutStrLn stderr (show result) >> exitFailure
            Left _ -> hPutStrLn stderr "shikigami-client: run list request failed" >> exitFailure
      )
        <$> serverOption
        <*> strArgument (metavar "AGENT")
        <*> option auto (long "first" <> value 50)
        <*> optional (strOption (long "after" <> metavar "CURSOR"))
    waitParser =
      ( \url agent runId timeout interval token -> do
          whenInvalid (timeout < 0 || interval <= 0) "Timeout must be nonnegative and interval positive."
          credential <- resolveCredential token
          name <- either (fail . Text.unpack) pure (parseUrlPiece agent)
          started <- getMonotonicTimeNSec
          let deadline = toInteger started + toInteger timeout * 1000000000
              poll previous = do
                result <- callServer url ((.show) ((.runs) (agentsClient credential) name) runId)
                case result of
                  Right (Run.RunFound view) -> do
                    if Just view.status /= previous then putStrLn (Text.unpack view.status) else pure ()
                    case view.status of
                      "succeeded" -> pure ()
                      "failed" -> exitWith (ExitFailure 1)
                      "cancelled" -> exitWith (ExitFailure 1)
                      _ -> do
                        now <- getMonotonicTimeNSec
                        if toInteger now >= deadline
                          then exitWith (ExitFailure 2)
                          else do
                            threadDelay (fromInteger (min (toInteger interval * 1000000) ((deadline - toInteger now) `div` 1000)))
                            poll (Just view.status)
                  _ -> hPutStrLn stderr "shikigami-client: run status request failed" >> exitWith (ExitFailure 3)
          poll Nothing
      )
        <$> serverOption
        <*> strArgument (metavar "AGENT")
        <*> strArgument (metavar "RUN_ID")
        <*> option auto (long "timeout" <> value (600 :: Int))
        <*> option auto (long "interval" <> value (5 :: Int))
    reportRun label accepted location = putStrLn (label <> " " <> Text.unpack accepted.runId) >> putStrLn ("Location " <> Text.unpack location)

printStatus :: Run.AgentRunStatus -> IO ()
printStatus view =
  mapM_
    (putStrLn . Text.unpack)
    ( ["runId        " <> view.runId, "agent        " <> view.agentName, "status       " <> view.status]
        <> maybe [] (\session -> ["session      " <> session]) view.sessionId
        <> maybe [] (\summary -> ["summary      " <> summary]) view.summary
        <> maybe [] (\failure -> ["failure      " <> failure.kind <> ": " <> failure.reason]) view.failure
    )

whenInvalid :: Bool -> String -> IO ()
whenInvalid condition message = if condition then hPutStrLn stderr message >> exitFailure else pure ()

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
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Options.Applicative
import Relay.Pagination (Connection (..), Edge (..), PageInfo (..), cursorFromText, cursorToText)
import Relay.Pagination.Servant (forwardPage)
import Servant.API (parseUrlPiece)
import Servant.Health (ProbeResult (..), ProbeStatus (..))
import Settei.Optparse (namedOption, setteiOptions)
import Settei.Source (Source)
import Shikigami.Agent.Api qualified as Agent
import Shikigami.AgentRun.Api qualified as Run
import Shikigami.Client (agentsClient, callServer, healthClient)
import Shikigami.Client.Config (ClientConfig (..), runClientConfig, serverKey, tokenKey)
import Shikigami.Client.Payload (payloadArgument, readPayload)
import Shikigami.Client.Version (versionOption)
import Shikigami.Health.Api (HealthApi (..))
import System.Exit (ExitCode (ExitFailure), exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)

-- | The whole @shikigami-client@ command line.
clientInfo :: ParserInfo (IO ())
clientInfo =
  info
    (run <$> namedOption "--token" tokenKey (long "token" <> metavar "TOKEN") <*> optional (subparser (foldMap snd clientSubcommands)) <*> setteiOptions <**> helper <**> versionOption)
    (fullDesc <> progDesc "Call a running shikigami server through the typed client" <> failureCode 2)
  where
    run token chosen options = do
      let (action, named) = maybe (const (hPutStrLn stderr "shikigami-client: choose a command; see --help" >> exitWith (ExitFailure 2)), []) id chosen
      config <- runClientConfig options (catMaybes [token] <> named)
      action config

type ClientAction = (ClientConfig -> IO (), [Source])

-- | Every subcommand, paired with its name, so a test can cover them all.
clientSubcommands :: [(String, Mod CommandFields ClientAction)]
clientSubcommands =
  [ ("health", command "health" healthInfo),
    ("agents", command "agents" agentsInfo),
    ("runs", command "runs" runsInfo)
  ]

healthInfo :: ParserInfo ClientAction
healthInfo =
  info
    (parser <**> helper)
    (progDesc "Report the server's liveness and readiness probes")
  where
    parser = (\named -> (runHealthCommand . (.server), named)) <$> serverOption

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

serverOption :: Parser [Source]
serverOption = catMaybes . pure <$> namedOption "--server" serverKey (long "server" <> metavar "URL" <> help "Server base URL (default http://localhost:8080)")

agentsInfo :: ParserInfo ClientAction
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
      ( \named size cursor ->
          ( \config -> do
              let credential = config.credential
                  url = config.server
              boundary <- traverse (either (fail . Text.unpack) pure . cursorFromText) cursor
              callServer url ((.list) (agentsClient credential) (forwardPage size boundary)) >>= \case
                Right (Agent.AgentPage page) -> do
                  mapM_ (\edge -> let view = edge.node in putStrLn (Text.unpack (Text.unwords [view.name, boolText view.enabled, view.lifecycle, boolText view.runnable]))) page.edges
                  mapM_ (putStrLn . ("endCursor " <>) . Text.unpack . cursorToText) page.pageInfo.endCursor
                Right result -> hPutStrLn stderr (show result) >> exitFailure
                Left _ -> hPutStrLn stderr "shikigami-client: request failed" >> exitFailure,
            named
          )
      )
        <$> serverOption
        <*> option auto (long "first" <> value 50)
        <*> optional (strOption (long "after" <> metavar "CURSOR"))
    showParser =
      ( \named name ->
          ( \config -> do
              let credential = config.credential
                  url = config.server
              agentName <- either (fail . Text.unpack) pure (parseUrlPiece name)
              callServer url ((.show) (agentsClient credential) agentName) >>= \case
                Right (Agent.AgentFound view) ->
                  mapM_ (putStrLn . Text.unpack) ["name         " <> view.name, "enabled      " <> boolText view.enabled, "trigger      " <> view.trigger, "behavior     " <> view.behavior, "sinks        " <> Text.intercalate "," view.sinks, "lifecycle    " <> view.lifecycle, "runnable     " <> boolText view.runnable]
                Right result -> hPutStrLn stderr (show result) >> exitFailure
                Left _ -> hPutStrLn stderr "shikigami-client: request failed" >> exitFailure,
            named
          )
      )
        <$> serverOption
        <*> strArgument (metavar "NAME")

boolText :: Bool -> Text
boolText True = "true"
boolText False = "false"

runsInfo :: ParserInfo ClientAction
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
      ( \named agent key payload ->
          ( \config -> do
              let credential = config.credential
                  url = config.server
              name <- either (fail . Text.unpack) pure (parseUrlPiece agent)
              body <- readPayload payload
              callServer url ((.request) ((.runs) (agentsClient credential) name) (Run.AgentRunRequest key body)) >>= \case
                Right (Run.RunAccepted (accepted, location)) -> reportRun "accepted" accepted location
                Right (Run.RunReplayed (accepted, location)) -> reportRun "replayed" accepted location
                Right result -> hPutStrLn stderr (show result) >> exitFailure
                Left _ -> hPutStrLn stderr "shikigami-client: run request failed" >> exitFailure,
            named
          )
      )
        <$> serverOption
        <*> strArgument (metavar "AGENT")
        <*> option (eitherReader (either (Left . Text.unpack) Right . Run.parseRequestKey . Text.pack)) (long "key" <> metavar "KEY")
        <*> payloadArgument
    showParser =
      ( \named agent runId ->
          ( \config -> do
              let credential = config.credential
                  url = config.server
              name <- either (fail . Text.unpack) pure (parseUrlPiece agent)
              callServer url ((.show) ((.runs) (agentsClient credential) name) runId) >>= \case
                Right (Run.RunFound view) -> printStatus view
                Right result -> hPutStrLn stderr (show result) >> exitFailure
                Left _ -> hPutStrLn stderr "shikigami-client: run status request failed" >> exitFailure,
            named
          )
      )
        <$> serverOption
        <*> strArgument (metavar "AGENT")
        <*> strArgument (metavar "RUN_ID")
    listParser =
      ( \named agent size after ->
          ( \config -> do
              let credential = config.credential
                  url = config.server
              name <- either (fail . Text.unpack) pure (parseUrlPiece agent)
              cursor <- traverse (either (fail . Text.unpack) pure . cursorFromText) after
              callServer url ((.list) ((.runs) (agentsClient credential) name) (forwardPage size cursor)) >>= \case
                Right (Run.RunPage page) -> do
                  mapM_ (\edge -> putStrLn (Text.unpack (Text.unwords [edge.node.runId, edge.node.idempotencyKey, edge.node.disposition]))) page.edges
                  mapM_ (putStrLn . ("endCursor " <>) . Text.unpack . cursorToText) page.pageInfo.endCursor
                Right result -> hPutStrLn stderr (show result) >> exitFailure
                Left _ -> hPutStrLn stderr "shikigami-client: run list request failed" >> exitFailure,
            named
          )
      )
        <$> serverOption
        <*> strArgument (metavar "AGENT")
        <*> option auto (long "first" <> value 50)
        <*> optional (strOption (long "after" <> metavar "CURSOR"))
    waitParser =
      ( \named agent runId timeout interval ->
          ( \config -> do
              whenInvalid (timeout < 0 || interval <= 0) "Timeout must be nonnegative and interval positive."
              let credential = config.credential
                  url = config.server
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
              poll Nothing,
            named
          )
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

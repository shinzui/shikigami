module Shikigami.Cli.Commands.DanwaBridge
  ( runDanwaBridgeCmd,
  )
where

import Data.List (isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.App (AppEnv (..), noopTracer)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Conversation (deliverConversationInputFromApp)
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Api.Agent (AgentDecl)
import Shikigami.Trigger.Danwa (DanwaBridgeConfig (..), runDanwaBridge)
import System.Directory (listDirectory)
import System.Environment (getEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hPutStrLn, hSetBuffering, stderr, stdout)

runDanwaBridgeCmd :: FilePath -> Text -> [Text] -> IO ()
runDanwaBridgeCmd agentsDir danwaConn mappingsRaw = do
  hSetBuffering stdout LineBuffering
  mappings <- either die pure (traverse parseMapping mappingsRaw)
  agents <- loadAgents agentsDir
  putStrLn ("[danwa-bridge] loaded " <> show (length agents) <> " agents")
  putStrLn ("[danwa-bridge] configured " <> show (length mappings) <> " participant mappings")
  shikigamiConn <- Text.pack <$> getEnv "PG_CONNECTION_STRING"
  withStore (defaultConnectionSettings shikigamiConn) \shikigamiStore -> do
    tracer <- noopTracer
    let appEnv = AppEnv {store = shikigamiStore, tracer, metrics = Nothing}
    withStore (defaultConnectionSettings danwaConn) \danwaStore ->
      runDanwaBridge
        DanwaBridgeConfig
          { agentMap = mappings,
            pollIntervalMicros = 1_000_000,
            deliverAddressed = deliverConversationInputFromApp appEnv
          }
        (pool shikigamiStore)
        (pool danwaStore)
        agents
  where
    die err = do
      hPutStrLn stderr ("danwa-bridge: " <> Text.unpack err)
      exitFailure

parseMapping :: Text -> Either Text (Text, Text)
parseMapping raw =
  case Text.breakOn "=" raw of
    (participant, rest)
      | Text.null participant || Text.null rest ->
          Left ("--map must be PARTICIPANT=AGENT, got: " <> raw)
      | otherwise ->
          Right (participant, Text.drop 1 rest)

loadAgents :: FilePath -> IO [AgentDecl]
loadAgents dir = do
  entries <- listDirectory dir
  loaded <- mapM loadAgent [dir </> e | e <- entries, ".dhall" `isSuffixOf` e]
  pure [a | Right a <- loaded]

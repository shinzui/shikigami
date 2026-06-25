module Shikigami.Cli.Commands.ConsumeStream
  ( runConsumeStream,
  )
where

import Data.List (find, isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.App (AppEnv (..), noopTracer)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Api.Agent (AgentDecl (..))
import Shikigami.Trigger.Consumer (StreamConfig (..), StreamHit (..), subscribeActivityStream)
import Shikigami.Trigger.Enqueue (enqueueRunJob, runJobFromEnvelope)
import System.Directory (listDirectory)
import System.Environment (getEnv)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

-- | @consume-stream --agents <dir> [--broker B --topic T --group G]@: run the
-- activity.v1 stream consumer; for each declared stream agent that matches an incoming
-- envelope, log the match and enqueue a run job (the stream→queue path). EP-5 folds
-- this into the full @worker@.
runConsumeStream :: FilePath -> Text -> Text -> Text -> IO ()
runConsumeStream agentsDir broker topic grp = do
  hSetBuffering stdout LineBuffering
  agents <- loadAgents agentsDir
  putStrLn
    ( "[stream] loaded "
        <> show (length agents)
        <> " agents; consuming "
        <> Text.unpack topic
        <> " on "
        <> Text.unpack broker
    )
  connStr <- Text.pack <$> getEnv "PG_CONNECTION_STRING"
  withStore (defaultConnectionSettings connStr) $ \st -> do
    tr <- noopTracer
    let appEnv = AppEnv {store = st, tracer = tr, metrics = Nothing}
        cfg = StreamConfig {streamBroker = broker, streamTopic = topic, streamGroupId = grp}
        onHit hit = do
          putStrLn ("[stream] MATCH agent=" <> Text.unpack (hitAgentName hit))
          case find ((== hitAgentName hit) . name) agents of
            Just decl -> do
              r <- enqueueRunJob (pool st) (runJobFromEnvelope decl (hitEnvelope hit))
              case r of
                Right mid -> putStrLn ("[stream]   enqueued run job " <> show mid)
                Left e -> putStrLn ("[stream]   enqueue failed: " <> show e)
            Nothing -> pure ()
    subscribeActivityStream appEnv cfg agents onHit

-- | Load every @*.dhall@ manifest in a directory (skipping ones that fail to parse).
loadAgents :: FilePath -> IO [AgentDecl]
loadAgents dir = do
  entries <- listDirectory dir
  loaded <- mapM loadAgent [dir </> e | e <- entries, ".dhall" `isSuffixOf` e]
  pure [a | Right a <- loaded]

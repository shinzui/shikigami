module Shikigami.Cli.Commands.AgentRun
  ( runAgentRun,
  )
where

import Data.Aeson qualified as Aeson
import Data.List (isInfixOf, isSuffixOf)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Kioku.App (AppEnv (..), noopTracer)
import Kioku.Id (idText)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Shikigami.Activity (ActivityEnvelope)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Run (AgentRunResult (..), recordActivityAsMemory, renderMemoryRecord, runAgentWithMemory)
import Shikigami.Behavior.Run (newBehaviorEnv)
import System.Environment (getEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | @agent-run --agent <name|path> [--from-activity <file>]@: open the kioku store and
-- either run the agent end to end with memory (open session → recall → run behavior →
-- record learning → complete) and print the across-run report, or — with
-- @--from-activity@ — map an @activity.v1@ envelope into a memory under the agent
-- scope. The connection string comes from the dev shell's @PG_CONNECTION_STRING@.
runAgentRun :: String -> Maybe FilePath -> IO ()
runAgentRun agentArg mActivity = do
  let path = resolvePath agentArg
  declE <- loadAgent path
  case declE of
    Left err -> do
      hPutStrLn stderr ("agent-run: load error in " <> path <> ": " <> show err)
      exitFailure
    Right decl -> do
      connStr <- Text.pack <$> getEnv "PG_CONNECTION_STRING"
      behEnv <- newBehaviorEnv
      withStore (defaultConnectionSettings connStr) $ \st -> do
        tr <- noopTracer
        let appEnv = AppEnv {store = st, tracer = tr, metrics = Nothing}
        case mActivity of
          Just actPath -> do
            decoded <- Aeson.eitherDecodeFileStrict' actPath
            case decoded :: Either String ActivityEnvelope of
              Left e -> do
                hPutStrLn stderr ("agent-run: cannot decode activity " <> actPath <> ": " <> e)
                exitFailure
              Right env -> do
                recE <- recordActivityAsMemory appEnv decl env
                case recE of
                  Left e -> hPutStrLn stderr ("agent-run: " <> Text.unpack e) >> exitFailure
                  Right m -> putStrLn ("recorded activity memory " <> Text.unpack (idText m))
          Nothing -> do
            resultE <- runAgentWithMemory appEnv behEnv decl Aeson.Null
            case resultE of
              Left e -> do
                hPutStrLn stderr ("agent-run: " <> Text.unpack e)
                exitFailure
              Right r -> do
                putStrLn ("agent " <> show (name decl) <> " run " <> Text.unpack (idText (sessionId r)))
                putStrLn ("recalled " <> show (length (recalledPrior r)) <> " prior memories:")
                mapM_ (TIO.putStrLn . ("  - " <>) . renderMemoryRecord) (recalledPrior r)
                maybe
                  (pure ())
                  (\m -> putStrLn ("recorded learning " <> Text.unpack (idText m)))
                  (recordedMemId r)

-- | A bare agent name resolves to @agents/<name>.dhall@; anything that already looks
-- like a path (contains @/@ or ends in @.dhall@) is used as-is.
resolvePath :: String -> FilePath
resolvePath arg
  | ".dhall" `isSuffixOf` arg = arg
  | "/" `isInfixOf` arg = arg
  | otherwise = "agents/" <> arg <> ".dhall"

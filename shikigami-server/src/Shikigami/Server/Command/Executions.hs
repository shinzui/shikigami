-- | Operator metadata has no replay-body or token access.
module Shikigami.Server.Command.Executions (runExecutionsInspect) where

import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Text (Text)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config (AppConfig, revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Execution.Store (inspectExecutionPage)
import Shikigami.Execution.Transcript (ExecutionId (..))
import Shikigami.Migrations (verifyShikigamiMigrations)
import System.Exit (die)

runExecutionsInspect :: Text -> Integer -> Int -> Bool -> AppConfig -> IO ()
runExecutionsInspect key after limit _asJson config = do
  connection <- revealSecretText <$> requireDatabaseUrl "executions inspect" config
  verifyShikigamiMigrations connection
  tracer <- noopTracer
  result <- runAppIO (AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing) (inspectExecutionPage (ExecutionId key) after limit)
  case result of
    Left _ -> die "execution store is unavailable"
    Right (Left _) -> die "execution inspection was refused; verify the catalog and page bounds"
    Right (Right Nothing) -> die "execution was not found"
    Right (Right (Just metadata)) -> Lazy.putStrLn (encode metadata)

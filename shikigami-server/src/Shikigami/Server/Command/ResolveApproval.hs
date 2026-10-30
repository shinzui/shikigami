-- | Resolve one pending human approval through Shikigami's owning library API.
module Shikigami.Server.Command.ResolveApproval
  ( resolveApprovalOptionsParser,
    runResolveApproval,
    resolutionResult,
  )
where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.UUID qualified as UUID
import Keiro.Workflow.Awakeable (AwakeableId (..), awakeableIdText)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Options.Applicative
import Shikigami.Agent.Approval (ApprovalDecision (..), resolveApproval)
import Shikigami.App (AppEnv (..))
import Shikigami.App.Config (AppConfig, revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Server.Telemetry (ServerTelemetry (..), withServerTelemetry)
import System.Exit (ExitCode (..), exitWith)

resolveApprovalOptionsParser :: Parser (AwakeableId, ApprovalDecision)
resolveApprovalOptionsParser =
  (,)
    <$> argument awakeableReader (metavar "TOKEN" <> help "Opaque approval token from the human-visible ask")
    <*> decisionParser

decisionParser :: Parser ApprovalDecision
decisionParser =
  flag'
    (Approved (object ["source" .= ("shikigami-cli" :: Text)]))
    (long "approve" <> help "Approve the pending request")
    <|> (Rejected . Text.pack <$> strOption (long "reject" <> metavar "REASON" <> help "Reject the pending request with a reason"))

awakeableReader :: ReadM AwakeableId
awakeableReader = eitherReader \raw ->
  maybe
    (Left "TOKEN must be a UUID")
    (Right . AwakeableId)
    (UUID.fromText (Text.pack raw))

runResolveApproval :: AwakeableId -> ApprovalDecision -> AppConfig -> IO ()
runResolveApproval awakeableId decision config = do
  connectionString <- revealSecretText <$> requireDatabaseUrl "resolve-approval" config
  withServerTelemetry \ServerTelemetry {tracer} -> do
    let appEnv =
          AppEnv
            { connectionSettings = defaultConnectionSettings connectionString,
              tracer,
              metrics = Nothing,
              store = Nothing
            }
    resolved <- resolveApproval appEnv awakeableId decision
    let (message, status) = resolutionResult awakeableId resolved
    TextIO.putStrLn message
    case status of
      ExitSuccess -> pure ()
      failure -> exitWith failure

resolutionResult :: AwakeableId -> Bool -> (Text, ExitCode)
resolutionResult awakeableId resolved
  | resolved = (prefix <> " resolved: true", ExitSuccess)
  | otherwise = (prefix <> " resolved: false (unknown or already resolved)", ExitFailure 1)
  where
    prefix = "approval " <> awakeableIdText awakeableId

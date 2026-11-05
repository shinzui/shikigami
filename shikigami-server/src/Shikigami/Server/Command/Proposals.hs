{-# LANGUAGE DataKinds #-}

-- | Operator verbs over unrequested work. Reads need the database and reveal no
-- excerpt, because the ledger stores none. Installing or revoking a standing
-- policy and pruning act as the configured local operator.
module Shikigami.Server.Command.Proposals
  ( runPolicyInstall,
    runPolicyRevoke,
    runPolicyList,
    runProposalsList,
    runProposalsInspect,
    runProposalsCandidates,
    runProposalsAdmissions,
    runProposalsPrune,
  )
where

import Control.Exception (finally)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.ByteString.Lazy.Char8 qualified as Char8
import Data.Text qualified as Text
import Effectful (Eff)
import Hasql.Transaction (Transaction)
import Kiroku.Store.Connection (withStore)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Activity.Coordinate (activityCoordinate)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Loader (loadAgentsReport, loadedAgents)
import Shikigami.Agent.Principal (mkAgentPrincipal, principalText)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.App.Config (AppConfig (..), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Directory qualified as Directory
import Shikigami.Initiative.Inspection (anyExhausted, inspect)
import Shikigami.Initiative.Ledger (listCandidates, listProposals, pruneCandidatesBefore)
import Shikigami.Initiative.Policy
import Shikigami.Initiative.Settings (InitiativeSettings (..), defaultMaximumPolicyLifetime)
import Shikigami.Initiative.Types (parseProposalId, parseStandingPolicyId)
import Shikigami.Log qualified as Log
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Objective.Types (ObjectiveSettings (..), OperatorId)
import Shikigami.Prelude hiding ((.=))
import Shikigami.Runtime (registerRuntimeCatalog, runtimeConnectionSettings)
import Shikigami.StateRevision (parseRevision)
import Shikigami.Workspace.Settings (WorkspaceRepository (..), WorkspaceSettings (..))
import System.Exit (die, exitFailure)
import System.IO (IOMode (ReadMode), withBinaryFile)

runPolicyInstall :: FilePath -> Bool -> AppConfig -> IO ()
runPolicyInstall path _json config = do
  input <- readPolicyDocument path
  operator <- requireOperator config
  instant <- getCurrentTime
  report <- loadAgentsReport config.agentsDirectory
  directoryRuntime <- Directory.startDirectory Log.silentLogger config.directorySettings >>= either (die . Text.unpack) pure
  let principalCoordinate = declarationCoordinate (principalText input.principal)
  active <-
    ( \case
        Directory.AllowRun (Just _) -> True
        _ -> False
    )
      <$> Directory.consultLifecycle directoryRuntime.handle (Just principalCoordinate) (principalText input.principal)
        `finally` maybe (pure ()) id directoryRuntime.refresher
  let context =
        PolicyContext
          { principalActive = const active,
            objectives = config.objectiveSettings,
            catalog = maybe [] (map (.identity) . (.repositories)) config.workspaceSettings,
            declarations = loadedAgents report,
            now = instant,
            maximumLifetime = maybe defaultMaximumPolicyLifetime (.maximumPolicyLifetime) config.initiativeSettings
          }
  withLedger config (installPolicy operator context input) >>= \case
    Left refusal -> die ("proposals policy install refused: " <> Text.unpack (policyRefusalText refusal))
    Right policy -> emit (policyView instant policy)

runPolicyRevoke :: Text -> Integer -> Bool -> AppConfig -> IO ()
runPolicyRevoke raw expected _json config = do
  policy <- checked (parseStandingPolicyId raw)
  revision <- checked (parseRevision expected)
  operator <- requireOperator config
  instant <- getCurrentTime
  withLedger config (revokePolicy operator policy revision instant) >>= \case
    Left refusal -> die ("proposals policy revoke refused: " <> Text.unpack (policyRefusalText refusal))
    Right view -> emit view

runPolicyList :: Maybe Text -> Maybe Text -> Int -> Bool -> AppConfig -> IO ()
runPolicyList claimed after limit _json config = do
  observer <- traverse (checked . mkAgentPrincipal) claimed
  cursor <- traverse (checked . parseStandingPolicyId) after
  instant <- getCurrentTime
  reading config (listPolicies instant observer cursor limit) >>= \case
    Left refusal -> die ("proposals policy list refused: " <> Text.unpack (policyRefusalText refusal))
    Right views -> emit views

runProposalsList :: Maybe Text -> Maybe Text -> Maybe Text -> Int -> Bool -> AppConfig -> IO ()
runProposalsList claimed status after limit _json config = do
  observer <- traverse (checked . mkAgentPrincipal) claimed
  cursor <- traverse (checked . parseProposalId) after
  forM_ status \wanted -> unless (wanted `elem` ["pending", "accepted", "admitted", "rejected", "expired", "refused"]) (die "unknown proposal status")
  reading config (listProposals observer status cursor limit) >>= \case
    Left problem -> die ("proposals list refused: " <> show problem)
    Right views -> emit views

runProposalsInspect :: Bool -> Bool -> AppConfig -> IO ()
runProposalsInspect _json failWhenExhausted config = do
  instant <- getCurrentTime
  reading config (inspect config.initiativeSettings instant) >>= \case
    Left refusal -> die ("proposals inspect refused: " <> Text.unpack (policyRefusalText refusal))
    Right view -> do
      emit view
      when (failWhenExhausted && anyExhausted view) exitFailure

runProposalsCandidates :: Text -> Maybe UTCTime -> Maybe Text -> Int -> Bool -> AppConfig -> IO ()
runProposalsCandidates claimed since after limit _json config = do
  observer <- checked (mkAgentPrincipal claimed)
  reading config (listCandidates observer since (activityCoordinate <$> after) limit) >>= emit

runProposalsAdmissions :: Maybe Text -> Maybe Text -> Int -> Bool -> AppConfig -> IO ()
runProposalsAdmissions policy after limit _json config = do
  named <- traverse (checked . parseStandingPolicyId) policy
  cursor <- traverse (checked . parseProposalId) after
  reading config (listAdmissions named cursor limit) >>= emit

runProposalsPrune :: UTCTime -> Int -> Bool -> AppConfig -> IO ()
runProposalsPrune before batch _json config = do
  _ <- requireOperator config
  removed <- reading config (pruneCandidatesBefore before batch)
  emit (object ["removed" .= removed])

requireOperator :: AppConfig -> IO OperatorId
requireOperator config =
  maybe (die "this command requires a configured local operator identity") pure config.objectiveSettings.operator

reading :: AppConfig -> Transaction value -> IO value
reading config transaction = withLedger config (runTransaction transaction)

withLedger :: AppConfig -> Eff AppEffects value -> IO value
withLedger config action = do
  connection <- revealSecretText <$> requireDatabaseUrl "proposals" config
  verifyShikigamiMigrations connection
  tracer <- noopTracer
  let settings = runtimeConnectionSettings Log.silentLogger Nothing connection
  withStore settings \store -> do
    registerRuntimeCatalog store
    runAppIO (AppEnv settings tracer Nothing (Just store)) action >>= either (const (die "the proposal ledger is unavailable")) pure

readPolicyDocument :: FilePath -> IO PolicyInput
readPolicyDocument path = withBinaryFile path ReadMode \handle -> do
  bytes <- Lazy.hGet handle 1048577
  when (Lazy.length bytes > 1048576) (die "policy document exceeds 1 MiB")
  either (\problem -> die ("invalid standing policy document: " <> problem)) pure (Aeson.eitherDecode bytes)

emit :: (ToJSON value) => value -> IO ()
emit = Char8.putStrLn . Aeson.encode

checked :: Either Text value -> IO value
checked = either (die . Text.unpack) pure

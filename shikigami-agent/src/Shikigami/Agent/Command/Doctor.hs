-- | @shikigami-local doctor@: every prerequisite of a routine agent, one line
-- per check, each failure with the command that fixes it (EP-9 M2 of
-- MasterPlan 22). @--agent@ adds a declaration outside the routine agents'
-- directory, such as a playbook campaign, and @--workspace@ also checks that
-- each declaration is granted on that repository (FRIC-100, FRIC-101).
module Shikigami.Agent.Command.Doctor
  ( DoctorOptions (..),
    runDoctor,
  )
where

import Control.Exception (SomeException, try)
import Control.Monad (forM, unless)
import Data.List (isSuffixOf, sort)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Shikigami.Agent.Command.Routine (defaultAgentsDirectory)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Agent.Preflight (Check (..), Problem (..), grantCheck, localRunChecks, passed, renderCheck)
import Shikigami.App.Config (AppConfig (..), ProviderSelection (..), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Capability.Declared (cliTools, mcpRequests)
import Shikigami.Capability.Declared.Catalog (checkDeclaredTools, checkMcpRequests, defaultToolCatalogPath, loadToolCatalog, renderToolResolutionError)
import Shikigami.Capability.Declared.Local (locateCliTools)
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Trust.LocalOperator.Approvals (defaultApprovalsPath, loadLocalApprovals, renderApprovalsError)
import Shikigami.Trust.LocalOperator.Grant (defaultStateDirectory, openGrantStore)
import Shikigami.Trust.LocalOperator.Host (repositorySelectorText)
import Shikigami.Workspace.Local.Checkout (processCheckoutResolver)
import System.Directory (doesDirectoryExist, listDirectory)
import System.Exit (exitFailure)
import System.FilePath ((</>))

data DoctorOptions = DoctorOptions
  { -- | Declarations to check beside the routine agents.
    agents :: ![FilePath],
    -- | The repository whose grants to check: a checkout path or a Mori
    -- identity. Absent, no grant is checked.
    workspace :: !(Maybe Text.Text)
  }

runDoctor :: DoctorOptions -> AppConfig -> IO ()
runDoctor options config = do
  database <- try @SomeException do
    connection <- revealSecretText <$> requireDatabaseUrl "shikigami-local doctor" config
    verifyShikigamiMigrations connection
  let databaseCheck = Check "database reachable and migrated" (either (\failure -> Just (Problem (Text.take 200 (Text.pack (show failure))) "start PostgreSQL, set PG_CONNECTION_STRING, then run: just migrate")) (const Nothing) database)
      providerCheck = case config.behaviorProvider of
        UseStub -> Check "model provider" (Just (Problem "behavior.provider is the stub; no model will be called" "set behavior.provider and its API key, for example --set behavior.provider=openai --set behavior.model=…"))
        _ -> Check "model provider configured" Nothing
  agentsDirectory <- defaultAgentsDirectory
  exists <- doesDirectoryExist agentsDirectory
  routine <-
    if exists
      then fmap (agentsDirectory </>) . sort . filter (".dhall" `isSuffixOf`) <$> listDirectory agentsDirectory
      else pure []
  loaded <- forM (routine <> options.agents) \path -> (path,) <$> loadAgent path
  grants <- grantChecker
  catalog <- loadToolCatalog =<< defaultToolCatalogPath
  agentChecks <- forM loaded \(path, result) -> case result of
    Left failure -> pure [Check (Text.pack path <> " loads") (Just (Problem (Text.take 300 (Text.pack (show failure))) "fix the declaration, or recreate it with: shikigami-local new NAME"))]
    Right decl -> do
      let name = agentNameText decl.name
      located <- locateCliTools (cliTools decl.tools)
      let toolCheck = case (catalog, located) of
            (Left failure, _) -> Just (Problem failure "fix ~/.config/shikigami/tools.dhall")
            (_, Left failure) -> Just (Problem (renderToolResolutionError failure) "install the executable or correct the declaration's tools")
            (Right tools, Right _) -> case (checkDeclaredTools tools (cliTools decl.tools), checkMcpRequests tools (mcpRequests decl.tools)) of
              (Left failure, _) -> Just (Problem (renderToolResolutionError failure) "widen the ceiling in ~/.config/shikigami/tools.dhall or narrow the declaration")
              (_, Left failure) -> Just (Problem (renderToolResolutionError failure) "bind the server in ~/.config/shikigami/tools.dhall; shikigami-local mcp SERVER lists its tools")
              _ -> Nothing
      machine <- localRunChecks decl
      granted <- grants decl
      pure (Check (name <> " loads") Nothing : [Check (name <> ": declared tools resolve") toolCheck | not (null decl.tools)] <> machine <> granted)
  let directoryCheck = Check ("agents directory " <> Text.pack agentsDirectory) (if exists then Nothing else Just (Problem "missing" "create a routine agent: shikigami-local new NAME"))
      checks = databaseCheck : providerCheck : directoryCheck : concat agentChecks
  mapM_ (TextIO.putStrLn . renderCheck) checks
  unless (all passed checks) exitFailure
  where
    grantChecker = case options.workspace of
      Nothing -> pure (\_ -> pure [])
      Just named -> do
        approvalsPath <- maybe defaultApprovalsPath pure config.localOperatorApprovalsFile
        stateDirectory <- maybe defaultStateDirectory pure config.localOperatorStateDirectory
        approvals <- loadLocalApprovals processCheckoutResolver approvalsPath
        store <- openGrantStore stateDirectory
        pure case (approvals, store) of
          (Left problem, _) -> \_ -> pure [Check ("approvals file " <> Text.pack approvalsPath) (Just (Problem (renderApprovalsError problem) "fix the approvals file"))]
          (_, Left problem) -> \_ -> pure [Check "grant store" (Just (Problem (Text.pack (show problem)) ("check the permissions of " <> Text.pack stateDirectory)))]
          (Right loadedApprovals, Right grantStore) -> \decl -> (: []) <$> grantCheck loadedApprovals grantStore decl (repositorySelectorText named)

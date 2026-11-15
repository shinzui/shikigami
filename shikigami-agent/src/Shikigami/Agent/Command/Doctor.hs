-- | @shikigami-local doctor@: every prerequisite of a routine agent, one line
-- per check, each failure with the command that fixes it (EP-9 M2 of
-- MasterPlan 22).
module Shikigami.Agent.Command.Doctor
  ( runDoctor,
  )
where

import Control.Exception (SomeException, try)
import Control.Monad (forM, unless)
import Data.List (isSuffixOf, sort)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Shikigami.Agent.Command.Routine (defaultAgentsDirectory)
import Shikigami.Agent.Decl (AgentDecl (..), codingAgentStepOf)
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.App.Config (AppConfig (..), ProviderSelection (..), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Capability.Declared (cliTools, mcpRequests)
import Shikigami.Capability.Declared.Catalog (checkDeclaredTools, checkMcpRequests, defaultToolCatalogPath, loadToolCatalog, renderToolResolutionError)
import Shikigami.Capability.Declared.Local (locateCliTools)
import Shikigami.CodingAgent.Types (CodingAgentProvider (..), CodingAgentStep (..))
import Shikigami.Migrations (verifyShikigamiMigrations)
import System.Directory (doesDirectoryExist, findExecutable, listDirectory)
import System.Exit (exitFailure)
import System.FilePath ((</>))

data Check = Check {label :: !Text, problem :: !(Maybe (Text, Text))}

runDoctor :: AppConfig -> IO ()
runDoctor config = do
  database <- try @SomeException do
    connection <- revealSecretText <$> requireDatabaseUrl "shikigami-local doctor" config
    verifyShikigamiMigrations connection
  let databaseCheck = Check "database reachable and migrated" (either (\failure -> Just (Text.take 200 (Text.pack (show failure)), "start PostgreSQL, set PG_CONNECTION_STRING, then run: just migrate")) (const Nothing) database)
      providerCheck = case config.behaviorProvider of
        UseStub -> Check "model provider" (Just ("behavior.provider is the stub; no model will be called", "set behavior.provider and its API key, for example --set behavior.provider=openai --set behavior.model=…"))
        _ -> Check "model provider configured" Nothing
  agents <- defaultAgentsDirectory
  exists <- doesDirectoryExist agents
  declarations <-
    if exists
      then fmap (agents </>) . sort . filter (".dhall" `isSuffixOf`) <$> listDirectory agents
      else pure []
  loaded <- forM declarations \path -> (path,) <$> loadAgent path
  catalog <- loadToolCatalog =<< defaultToolCatalogPath
  agentChecks <- forM loaded \(path, result) -> case result of
    Left failure -> pure [Check (Text.pack path <> " loads") (Just (Text.take 300 (Text.pack (show failure)), "fix the declaration, or recreate it with: shikigami-local new NAME"))]
    Right decl -> do
      let name = agentNameText decl.name
      located <- locateCliTools (cliTools decl.tools)
      vendor <- case codingAgentStepOf decl.behavior of
        Nothing -> pure []
        Just step -> do
          let executable = case step.provider of ClaudeCode -> "claude"; Codex -> "codex"
          found <- findExecutable executable
          pure [Check (name <> ": " <> Text.pack executable <> " on PATH") (if isJust found then Nothing else Just ("not found", "install " <> Text.pack executable <> " and log in"))]
      let toolCheck = case (catalog, located) of
            (Left failure, _) -> Just (failure, "fix ~/.config/shikigami/tools.dhall")
            (_, Left failure) -> Just (renderToolResolutionError failure, "install the executable or correct the declaration's tools")
            (Right tools, Right _) -> case (checkDeclaredTools tools (cliTools decl.tools), checkMcpRequests tools (mcpRequests decl.tools)) of
              (Left failure, _) -> Just (renderToolResolutionError failure, "widen the ceiling in ~/.config/shikigami/tools.dhall or narrow the declaration")
              (_, Left failure) -> Just (renderToolResolutionError failure, "bind the server in ~/.config/shikigami/tools.dhall; shikigami-local mcp SERVER lists its tools")
              _ -> Nothing
      pure (Check (name <> " loads") Nothing : [Check (name <> ": declared tools resolve") toolCheck | not (null decl.tools)] <> vendor)
  let directoryCheck = Check ("agents directory " <> Text.pack agents) (if exists then Nothing else Just ("missing", "create a routine agent: shikigami-local new NAME"))
      checks = databaseCheck : providerCheck : directoryCheck : concat agentChecks
  mapM_ render checks
  unless (all (\check -> case check.problem of Nothing -> True; Just _ -> False) checks) exitFailure
  where
    render Check {label, problem} = case problem of
      Nothing -> TextIO.putStrLn ("ok    " <> label)
      Just (detail, fix) -> TextIO.putStrLn ("FAIL  " <> label <> ": " <> detail <> "\n      fix: " <> fix)

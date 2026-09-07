module Shikigami.Server.AgentsSpec (tests) where

import Data.List (find)
import Data.Set qualified as Set
import Data.Text (Text)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgentsReport)
import Shikigami.Agent.Principal (mkAgentPrincipal)
import Shikigami.Directory
  ( Lifecycle (..),
    PrincipalRecord (..),
    disabledDirectoryHandle,
    newDirectoryHandle,
    refreshDirectory,
    staticDirectorySource,
  )
import Shikigami.Directory qualified as Directory
import Shikigami.Memory.AliasStore (AliasReconciliation (..))
import Shikigami.Memory.AliasStore qualified as AliasStore
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.Server.Command.Agents
  ( AgentInventoryEntry (..),
    AliasSyncEntry (..),
    AliasSyncOutcome (..),
    buildAgentInventory,
    reconcileAgentAliases,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "agent inventory"
    [ testCase "lists joined, declared-only, principal-only, and failed states" do
        report <- loadAgentsReport "../agents"
        directoryHandle <-
          newDirectoryHandle
            ( staticDirectorySource
                [ PrincipalRecord
                    { principalId = "agent_heartbeat",
                      handle = "heartbeat",
                      lifecycle = Paused
                    },
                  PrincipalRecord
                    { principalId = "agent_directory_only",
                      handle = "directory-only",
                      lifecycle = Active
                    }
                ]
            )
        refreshDirectory directoryHandle >>= either (assertFailure . show) pure
        inventory <- buildAgentInventory True directoryHandle report
        heartbeat <- findDeclared "heartbeat" inventory
        assertEqual
          "joined principal"
          (Just "agent_heartbeat")
          ((.principalId) <$> (.principal) heartbeat)
        triage <- findDeclared "triage-note" inventory
        assertEqual "declared-only principal" Nothing ((.principal) triage)
        assertBool "broken manifest missing" (any isFailure inventory)
        assertBool "directory-only principal missing" (any isDirectoryOnly inventory),
      testCase "disabled mode labels declarations without inventing principals" do
        report <- loadAgentsReport "../agents"
        inventory <- buildAgentInventory False disabledDirectoryHandle report
        heartbeat <- findDeclared "heartbeat" inventory
        assertEqual "disabled join" Nothing ((.principal) heartbeat)
        assertBool "disabled marker" (not ((.directoryConfigured) heartbeat))
        assertBool "disabled mode invented a principal-only row" (not (any isDirectoryOnly inventory)),
      testCase "explicit rename aliases are idempotent and missing mappings remain untouched" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \store -> do
            report <- loadAgentsReport "../agents"
            directoryHandle <- directoryWithPrincipals [heartbeatPrincipal]
            inventory <- buildAgentInventory True directoryHandle report
            first <-
              reconcileAgentAliases (pool store) (Set.singleton "old-heartbeat") [] inventory ["old-heartbeat=agent_heartbeat"]
                >>= either (assertFailure . show) pure
            case first of
              [AliasSyncEntry {legacyName = "old-heartbeat", outcome = AliasReconciled AliasInserted {}}] -> pure ()
              other -> assertFailure ("expected one inserted alias, got " <> show other)
            second <-
              reconcileAgentAliases (pool store) (Set.singleton "old-heartbeat") [] inventory ["old-heartbeat=agent_heartbeat"]
                >>= either (assertFailure . show) pure
            case second of
              [AliasSyncEntry {outcome = AliasReconciled AliasAlreadyPresent {}}] -> pure ()
              other -> assertFailure ("expected an idempotent alias, got " <> show other)
            missing <-
              reconcileAgentAliases (pool store) (Set.singleton "orphan") [] inventory []
                >>= either (assertFailure . show) pure
            case missing of
              [AliasSyncEntry {legacyName = "orphan", outcome = AliasMissingMapping}] -> pure ()
              other -> assertFailure ("expected an untouched missing mapping, got " <> show other),
      testCase "multiply claimed explicit aliases are reported without insertion" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \store -> do
            report <- loadAgentsReport "../agents"
            directoryHandle <- directoryWithPrincipals [heartbeatPrincipal, triagePrincipal]
            inventory <- buildAgentInventory True directoryHandle report
            results <-
              reconcileAgentAliases
                (pool store)
                Set.empty
                []
                inventory
                ["former-name=agent_heartbeat", "former-name=agent_triage_note"]
                >>= either (assertFailure . show) pure
            case results of
              [AliasSyncEntry {legacyName = "former-name", outcome = AliasMultiplyClaimed principals}] ->
                assertEqual "both claims are named" ["agent_heartbeat", "agent_triage_note"] principals
              other -> assertFailure ("expected one multiply-claimed mapping, got " <> show other),
      testCase "an invalid explicit mapping blocks automatic reconciliation for that name" do
        withShikigamiMigratedDatabase \connStr ->
          withStore (defaultConnectionSettings connStr) \store -> do
            report <- loadAgentsReport "../agents"
            directoryHandle <- directoryWithPrincipals [heartbeatPrincipal]
            inventory <- buildAgentInventory True directoryHandle report
            results <-
              reconcileAgentAliases
                (pool store)
                (Set.singleton "heartbeat")
                []
                inventory
                ["heartbeat=not-a-principal"]
                >>= either (assertFailure . show) pure
            case results of
              [AliasSyncEntry {legacyName = "heartbeat", outcome = AliasInvalidMapping _}] -> pure ()
              other -> assertFailure ("expected one invalid mapping, got " <> show other)
            principal <- either (assertFailure . show) pure (mkAgentPrincipal "agent_heartbeat")
            aliases <- AliasStore.aliasesForPrincipal (pool store) principal >>= either (assertFailure . show) pure
            assertEqual "invalid operator input wrote no alias" [] aliases
    ]

directoryWithPrincipals :: [PrincipalRecord] -> IO Directory.DirectoryHandle
directoryWithPrincipals principals = do
  directoryHandle <- newDirectoryHandle (staticDirectorySource principals)
  refreshDirectory directoryHandle >>= either (assertFailure . show) pure
  pure directoryHandle

heartbeatPrincipal :: PrincipalRecord
heartbeatPrincipal =
  PrincipalRecord
    { principalId = "agent_heartbeat",
      handle = "heartbeat",
      lifecycle = Active
    }

triagePrincipal :: PrincipalRecord
triagePrincipal =
  PrincipalRecord
    { principalId = "agent_triage_note",
      handle = "triage-note",
      lifecycle = Active
    }

findDeclared :: Text -> [AgentInventoryEntry] -> IO AgentInventoryEntry
findDeclared wanted inventory =
  case find matches inventory of
    Just entry -> pure entry
    Nothing -> assertFailure ("missing declaration " <> show wanted)
  where
    matches AgentInventoryEntry {declaration = Just decl} = (.name) decl == wanted
    matches _ = False

isFailure :: AgentInventoryEntry -> Bool
isFailure AgentInventoryEntry {failure = Just _} = True
isFailure _ = False

isDirectoryOnly :: AgentInventoryEntry -> Bool
isDirectoryOnly AgentInventoryEntry {declaration = Nothing, principal = Just joined} =
  (.principalId) joined == "agent_directory_only"
isDirectoryOnly _ = False

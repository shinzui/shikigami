module Shikigami.Server.AgentsSpec (tests) where

import Data.List (find)
import Data.Text (Text)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgentsReport)
import Shikigami.Directory
  ( Lifecycle (..),
    PrincipalRecord (..),
    disabledDirectoryHandle,
    newDirectoryHandle,
    refreshDirectory,
    staticDirectorySource,
  )
import Shikigami.Directory qualified as Directory
import Shikigami.Server.Command.Agents (AgentInventoryEntry (..), buildAgentInventory)
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
          (Directory.principalId <$> principal heartbeat)
        triage <- findDeclared "triage-note" inventory
        assertEqual "declared-only principal" Nothing (principal triage)
        assertBool "broken manifest missing" (any isFailure inventory)
        assertBool "directory-only principal missing" (any isDirectoryOnly inventory),
      testCase "disabled mode labels declarations without inventing principals" do
        report <- loadAgentsReport "../agents"
        inventory <- buildAgentInventory False disabledDirectoryHandle report
        heartbeat <- findDeclared "heartbeat" inventory
        assertEqual "disabled join" Nothing (principal heartbeat)
        assertBool "disabled marker" (not (directoryConfigured heartbeat))
        assertBool "disabled mode invented a principal-only row" (not (any isDirectoryOnly inventory))
    ]

findDeclared :: Text -> [AgentInventoryEntry] -> IO AgentInventoryEntry
findDeclared wanted inventory =
  case find matches inventory of
    Just entry -> pure entry
    Nothing -> assertFailure ("missing declaration " <> show wanted)
  where
    matches AgentInventoryEntry {declaration = Just decl} = name decl == wanted
    matches _ = False

isFailure :: AgentInventoryEntry -> Bool
isFailure AgentInventoryEntry {failure = Just _} = True
isFailure _ = False

isDirectoryOnly :: AgentInventoryEntry -> Bool
isDirectoryOnly AgentInventoryEntry {declaration = Nothing, principal = Just joined} =
  Directory.principalId joined == "agent_directory_only"
isDirectoryOnly _ = False

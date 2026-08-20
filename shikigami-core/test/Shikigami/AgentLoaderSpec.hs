module Shikigami.AgentLoaderSpec (tests) where

import Data.Aeson (Value (Object), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    IdentityDecl (..),
    MemoryPolicy (..),
    MemoryScopeDecl (AgentScope),
    RecordPolicy (Never, OnSuccess),
    recallLimitNatural,
  )
import Shikigami.Agent.Loader
  ( AgentLoadEntry (..),
    AgentLoadReport (..),
    LoadError (..),
    enabledAgentsFromReport,
    loadAgent,
    loadAgentsReport,
    loadedAgents,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "AgentLoader"
    [ testCase "decodes declared identity, memory policy, and enablement" do
        decl <- expectLoaded "../agents/proof/declared-identity.dhall"
        case decl of
          AgentDecl
            { identity = Just (IdentityDecl {principal}),
              memory = MemoryPolicy {scope, recallLimit, recordPolicy},
              enabled
            } -> do
              principal @?= "principal_shikigami_proof"
              scope @?= AgentScope
              recallLimitNatural recallLimit @?= 3
              recordPolicy @?= Never
              enabled @?= False
          other -> assertFailure ("unexpected proof declaration: " <> show other),
      testCase "restores defaults for an unchanged manifest" do
        decl <- expectLoaded "../agents/heartbeat.dhall"
        case decl of
          AgentDecl
            { identity,
              memory = MemoryPolicy {scope, recallLimit, recordPolicy},
              enabled
            } -> do
              identity @?= Nothing
              scope @?= AgentScope
              recallLimitNatural recallLimit @?= 10
              recordPolicy @?= OnSuccess
              enabled @?= True,
      testCase "default declarations retain their old JSON shape and decode it" do
        decl <- expectLoaded "../agents/heartbeat.dhall"
        let oldShape =
              object
                [ "name" .= name decl,
                  "description" .= description decl,
                  "trigger" .= trigger decl,
                  "behavior" .= behavior decl,
                  "sinks" .= sinks decl
                ]
        case toJSON decl of
          Object fields -> do
            assertBool "identity is omitted" (not (KeyMap.member "identity" fields))
            assertBool "memory is omitted" (not (KeyMap.member "memory" fields))
            assertBool "enabled is omitted" (not (KeyMap.member "enabled" fields))
          other -> assertFailure ("declaration must encode as an object: " <> show other)
        encode decl @?= encode oldShape
        eitherDecode (encode decl) @?= Right decl,
      testCase "non-default declarations retain their policy in JSON" do
        decl <- expectLoaded "../agents/proof/declared-identity.dhall"
        eitherDecode (encode decl) @?= Right decl,
      testCase "rejects recall limits before runtime conversion" do
        expectBoundError "test/fixtures/agents/invalid-recall-limit-zero.dhall" "got 0"
        expectBoundError "test/fixtures/agents/invalid-recall-limit-too-large.dhall" "got 1001",
      testCase "directory reports preserve a broken manifest" do
        report@AgentLoadReport {entries} <- loadAgentsReport "../agents"
        let broken = find isBroken entries
        assertBool "broken manifest is retained as a failure" (maybe False isFailure broken)
        assertBool "broken manifest is absent from loaded declarations" (all ((/= "broken") . agentName) (loadedAgents report)),
      testCase "enabled selection omits the disabled proof declaration" do
        report <- loadAgentsReport "../agents/proof"
        selected <- enabledAgentsFromReport report
        assertBool "disabled declaration is omitted" (all ((/= "declared-identity") . agentName) selected)
    ]

expectLoaded :: FilePath -> IO AgentDecl
expectLoaded path =
  loadAgent path >>= \case
    Left err -> assertFailure ("expected " <> path <> " to load, got " <> show err)
    Right decl -> pure decl

expectBoundError :: FilePath -> Text -> IO ()
expectBoundError path expected =
  loadAgent path >>= \case
    Left (LoadError message) -> do
      assertBool "diagnostic states both bounds" ("between 1 and 1000 inclusive" `Text.isInfixOf` message)
      assertBool "diagnostic states the invalid value" (expected `Text.isInfixOf` message)
    Right decl -> assertFailure ("expected invalid recall limit, loaded " <> show decl)

isBroken :: AgentLoadEntry -> Bool
isBroken = \case
  AgentLoaded {path} -> path == "../agents/broken.dhall"
  AgentLoadFailed {path} -> path == "../agents/broken.dhall"

isFailure :: AgentLoadEntry -> Bool
isFailure AgentLoadFailed {} = True
isFailure AgentLoaded {} = False

agentName :: AgentDecl -> Text
agentName AgentDecl {name} = name

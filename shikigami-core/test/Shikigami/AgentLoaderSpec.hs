module Shikigami.AgentLoaderSpec (tests) where

import Control.Exception (try)
import Data.Aeson (Value (Object), eitherDecode, eitherDecodeStrict, encode, toJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.Foldable (traverse_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find, isSuffixOf, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    ExpertiseDecl (..),
    IdentityDecl (..),
    MemoryPolicy (..),
    MemoryScopeDecl (AgentScope),
    RecordPolicy (Never, OnSuccess),
    RouterConfidence (RoutingMedium),
    RouterPolicy (..),
    Sink (..),
    delegationBudgetNatural,
    recallLimitNatural,
  )
import Shikigami.Agent.ExpertiseKey (expertiseKeyText)
import Shikigami.Agent.Loader
  ( AgentLoadEntry (..),
    AgentLoadReport (..),
    LoadError (..),
    enabledAgentsFromReport,
    loadAgent,
    loadAgentsLoud,
    loadAgentsReport,
    loadedAgents,
  )
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Capability.Overlay (capabilityIdText)
import Shikigami.Log qualified as Log
import Shikigami.Router.SelectionLimit (selectionLimitInt)
import System.Directory (doesDirectoryExist, listDirectory)
import System.Exit (ExitCode (ExitFailure))
import System.FilePath (takeExtension, (</>))
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
              delegates,
              delegationBudget,
              capabilityOverlays,
              enabled
            } -> do
              identity @?= Nothing
              scope @?= AgentScope
              recallLimitNatural recallLimit @?= 10
              recordPolicy @?= OnSuccess
              delegates @?= []
              delegationBudget @?= Nothing
              capabilityOverlays @?= []
              enabled @?= True,
      testCase "decodes a declared delegation allow-list and budget" do
        AgentDecl {delegates, delegationBudget} <- expectLoaded "../agents/proof/research-supervisor.dhall"
        map agentNameText delegates @?= ["web-researcher", "code-researcher"]
        fmap delegationBudgetNatural delegationBudget @?= Just 8,
      testCase "decodes the router policy proof declaration" do
        decl <- expectLoaded "../agents/proof/architecture-practice-router.dhall"
        case decl of
          AgentDecl {delegates, routing = Just RouterPolicy {maxSelections, minimumConfidence}} -> do
            map agentNameText delegates @?= ["opentelemetry-practice-reviewer", "code-researcher"]
            selectionLimitInt maxSelections @?= 2
            minimumConfidence @?= RoutingMedium
          other -> assertFailure ("unexpected router declaration: " <> show other),
      testCase "decodes the specialist expertise proof declaration" do
        decl <- expectLoaded "../agents/proof/opentelemetry-practice-reviewer.dhall"
        case decl of
          AgentDecl {expertise = [ExpertiseDecl {key, aliases, evidenceHints}]} -> do
            expertiseKeyText key @?= "opentelemetry"
            aliases @?= ["otel", "telemetry"]
            evidenceHints @?= ["traceparent", "service.name", "instrumentation scope"]
          other -> assertFailure ("unexpected specialist declaration: " <> show other),
      testCase "decodes and round-trips the ChannelEgress proof declaration" do
        decl@AgentDecl {sinks} <- expectLoaded "../agents/proof/channel-reply.dhall"
        sinks @?= [ChannelEgress {channel = "intercom", action = "reply_to_conversation", conversationKey = Nothing}]
        eitherDecode (encode decl) @?= Right decl,
      testCase "the v1 declaration JSON shape contains every field and round-trips" do
        decl <- expectLoaded "../agents/heartbeat.dhall"
        fixtureBytes <- ByteString.Char8.readFile "test/fixtures/wire/agent-decl-v1.json"
        fixtureValue <-
          either
            (assertFailure . ("could not decode the v1 declaration fixture: " <>))
            pure
            (eitherDecodeStrict @Value fixtureBytes)
        toJSON decl @?= fixtureValue
        eitherDecodeStrict @AgentDecl fixtureBytes @?= Right decl
        case toJSON decl of
          Object fields -> do
            sort (KeyMap.keys fields)
              @?= sort
                [ "behavior",
                  "capabilityOverlays",
                  "delegates",
                  "delegationBudget",
                  "description",
                  "enabled",
                  "expertise",
                  "identity",
                  "memory",
                  "name",
                  "routing",
                  "sanctionedProfile",
                  "sinks",
                  "trigger"
                ]
          other -> assertFailure ("declaration must encode as an object: " <> show other)
        eitherDecode (encode decl) @?= Right decl,
      testCase "non-default declarations retain their policy in JSON" do
        decl <- expectLoaded "../agents/proof/declared-identity.dhall"
        eitherDecode (encode decl) @?= Right decl,
      testCase "loads and round-trips an explicit capability overlay request" do
        decl@AgentDecl {capabilityOverlays} <- expectLoaded "../agents/proof/capability-overlay.dhall"
        map capabilityIdText capabilityOverlays @?= ["workspace.read"]
        eitherDecode (encode decl) @?= Right decl,
      testCase "rejects malformed capability ids during Dhall decoding" do
        loadAgent "test/fixtures/agents/invalid-capability-id.dhall" >>= \case
          Left (LoadError message) -> do
            assertBool "diagnostic states the identifier grammar" ("[a-z][a-z0-9.-]*" `Text.isInfixOf` message)
            assertBool "diagnostic states the invalid value" ("Workspace.read" `Text.isInfixOf` message)
          Right decl -> assertFailure ("expected invalid capability id, loaded " <> show decl),
      testCase "loads duplicate requests so pure resolution can refuse them" do
        AgentDecl {capabilityOverlays} <- expectLoaded "test/fixtures/agents/duplicate-capability-overlay.dhall"
        map capabilityIdText capabilityOverlays @?= ["workspace.read", "workspace.read"],
      testCase "rejects recall limits before runtime conversion" do
        expectBoundError "test/fixtures/agents/invalid-recall-limit-zero.dhall" "got 0"
        expectBoundError "test/fixtures/agents/invalid-recall-limit-too-large.dhall" "got 1001",
      testCase "every live manifest still decodes through record-completion defaults" do
        paths <- filter isLiveManifest <$> dhallFilesRecursively "../agents"
        traverse_ (fmap (const ()) . expectLoaded) paths,
      testCase "directory reports preserve a broken manifest" do
        report@AgentLoadReport {entries} <- loadAgentsReport "../agents"
        let broken = find isBroken entries
        assertBool "broken manifest is retained as a failure" (maybe False isFailure broken)
        assertBool "broken manifest is absent from loaded declarations" (all ((/= "broken") . agentName) (loadedAgents report)),
      testCase "enabled selection omits the disabled proof declaration" do
        (logger, _captured) <- capturingLogger
        report <- loadAgentsReport "../agents/proof"
        selected <- enabledAgentsFromReport logger report
        assertBool "disabled declaration is omitted" (all ((/= "declared-identity") . agentName) selected),
      -- A manifest typo used to be invisible: the directory walk dropped the file
      -- and the process started with one fewer agent than the operator declared.
      -- @agents/broken.dhall@ is the checked-in fixture for that, and it is the
      -- only failing file the walk reaches — the traversal is not recursive, so
      -- @agents/detectors/schema.dhall@ is never opened.
      testCase "loadAgentsLoud reports the broken manifest through the logger" do
        (logger, captured) <- capturingLogger
        report@AgentLoadReport {entries} <- loadAgentsLoud logger "../agents" False (const (pure ()))
        lines' <- readIORef captured
        assertBool
          ("expected agents.manifest.load_failed in " <> show lines')
          (any (ByteString.Char8.isInfixOf "\"event\":\"agents.manifest.load_failed\"") lines')
        assertBool
          ("expected the broken manifest's path in " <> show lines')
          (any (ByteString.Char8.isInfixOf "../agents/broken.dhall") lines')
        assertBool
          ("expected a summary naming one failure in " <> show lines')
          (any (ByteString.Char8.isInfixOf "\"failed\":1") lines')
        assertBool "the report retains the failure" (any isFailure (filter isBroken entries))
        assertBool
          "loadedAgents excludes it"
          (all ((/= "broken") . agentName) (loadedAgents report)),
      -- Before this there was no configuration source for strict mode, so every
      -- call site hard-coded False and the refusal was unreachable.
      testCase "strict mode refuses to start when a manifest fails" do
        (logger, captured) <- capturingLogger
        persisted <- newIORef False
        outcome <- try @ExitCode (loadAgentsLoud logger "../agents" True (const (writeIORef persisted True)))
        case outcome of
          Left code -> code @?= ExitFailure 1
          Right _ -> assertFailure "strict mode must refuse to start when a manifest fails"
        readIORef persisted >>= (@?= True)
        lines' <- readIORef captured
        assertBool
          ("the failures are reported before the refusal: " <> show lines')
          (any (ByteString.Char8.isInfixOf "\"event\":\"agents.manifest.load_failed\"") lines')
        assertBool
          ("the refusal says why: " <> show lines')
          (any (ByteString.Char8.isInfixOf "\"event\":\"agents.manifest.strict_refused\"") lines'),
      testCase "strict mode starts when every manifest loads" do
        (logger, _captured) <- capturingLogger
        AgentLoadReport {entries} <- loadAgentsLoud logger "../agents/proof" True (const (pure ()))
        assertBool "the proof directory has no failing manifest" (not (any isFailure entries))
    ]

-- | A logger that keeps every line it is given, so a case can assert on the
-- structured event rather than on a side effect the event happens to accompany.
capturingLogger :: IO (Log.Logger, IORef [ByteString])
capturingLogger = do
  captured <- newIORef []
  pure
    ( Log.Logger
        { Log.minLevel = Log.Debug,
          Log.sink = \line -> modifyIORef' captured (<> [line])
        },
      captured
    )

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
agentName AgentDecl {name} = agentNameText name

dhallFilesRecursively :: FilePath -> IO [FilePath]
dhallFilesRecursively directory = do
  names <- sort <$> listDirectory directory
  fmap concat $ traverse visit names
  where
    visit name = do
      let path = directory </> name
      isDirectory <- doesDirectoryExist path
      if isDirectory
        then dhallFilesRecursively path
        else pure [path | takeExtension path == ".dhall"]

isLiveManifest :: FilePath -> Bool
isLiveManifest path =
  not ("/broken.dhall" `isSuffixOf` path)
    && not ("/detectors/schema.dhall" `isSuffixOf` path)

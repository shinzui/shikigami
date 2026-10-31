module Shikigami.Agent.Capability.WorkspaceSpec (tests) where

import Baikai.Content (ToolCall (..), emptyToolCall)
import Control.Exception (bracket)
import Control.Lens ((&), (.~))
import Data.Aeson (Value, object, (.=))
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.Agent.Capability.OneOff (withOneOffCapabilityOverlays)
import Shikigami.Agent.Capability.Workspace
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    Behavior (..),
    IdentityDecl (..),
    Trigger (..),
    defaultMemoryPolicy,
  )
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Behavior.Run (BehaviorEnv (..), newBehaviorEnv)
import Shikigami.Capability.Overlay (CapabilityId)
import Shikigami.Log qualified as Log
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (runLLM)
import Shikumi.Tool (ToolError (..), runToolCall)
import System.Directory
  ( canonicalizePath,
    createDirectory,
    createDirectoryIfMissing,
    createDirectoryLink,
    createFileLink,
    getTemporaryDirectory,
    removeFile,
    removePathForcibly,
  )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Process (callProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

data Fixture = Fixture
  { container :: !FilePath,
    repository :: !FilePath,
    outsideFile :: !FilePath
  }

tests :: TestTree
tests =
  testGroup
    "confined workspace capability"
    [ scopeTests,
      pathTests,
      dispatchTests,
      boundTests
    ]

scopeTests :: TestTree
scopeTests =
  testGroup
    "worktree discovery"
    [ testCase "an explicit nested directory resolves to the canonical Git root" $
        withFixture \Fixture {repository} -> do
          expected <- canonicalizePath repository
          resolved <- resolveWorkspaceScope (Just (repository </> "nested"))
          resolved @?= Right WorkspaceScope {root = expected},
      testCase "a non-repository directory is a typed refusal" $
        withFixture \Fixture {container} -> do
          resolved <- resolveWorkspaceScope (Just container)
          case resolved of
            Left NotGitWorktree {} -> pure ()
            other -> assertFailure ("expected NotGitWorktree, got " <> show other)
    ]

pathTests :: TestTree
pathTests =
  testGroup
    "path containment"
    [ testCase "an ordinary relative file resolves inside the root" $
        withFixture \fixture@Fixture {repository} -> do
          scope <- fixtureScope fixture
          expected <- canonicalizePath (repository </> "nested" </> "note.txt")
          resolved <- resolveWorkspacePath scope "nested/note.txt"
          resolved @?= Right expected,
      testCase "absolute and traversal paths are refused" $
        withFixture \fixture@Fixture {outsideFile} -> do
          scope <- fixtureScope fixture
          assertWorkspaceError isEscape =<< resolveWorkspacePath scope outsideFile
          assertWorkspaceError isInvalid =<< resolveWorkspacePath scope "../outside.txt",
      testCase "symlinked files and directories are refused" $
        withFixture \fixture -> do
          scope <- fixtureScope fixture
          assertWorkspaceError isSymlink =<< resolveWorkspacePath scope "escape-file"
          assertWorkspaceError isSymlink =<< resolveWorkspacePath scope "escape-dir/secret.txt",
      testCase "Git internals and noisy build directories are excluded" $
        withFixture \fixture -> do
          scope <- fixtureScope fixture
          assertWorkspaceError isExcluded =<< resolveWorkspacePath scope ".git/config"
          assertWorkspaceError isExcluded =<< resolveWorkspacePath scope "dist-newstyle/ignored.txt"
    ]

dispatchTests :: TestTree
dispatchTests =
  testGroup
    "typed tool dispatch"
    [ testCase "read, grep, and glob return bounded in-worktree observations" $
        withFixture \fixture ->
          withWorkspaceEnv fixture \env -> do
            readResult <- dispatch env "overlay__workspace-read__read" (object ["path" .= ("nested/note.txt" :: Text)])
            assertObservationContains "needle" readResult
            grepResult <-
              dispatch
                env
                "overlay__workspace-read__grep"
                (object ["patternText" .= ("needle" :: Text), "path" .= ("nested" :: Text), "ignoreCase" .= False])
            assertObservationContains "nested/note.txt" grepResult
            globResult <-
              dispatch
                env
                "overlay__workspace-read__glob"
                (object ["patternText" .= ("*.txt" :: Text), "path" .= (Nothing :: Maybe Text)])
            assertObservationContains "nested/note.txt" globResult,
      testCase "tool calls refuse traversal, absolute, symlink, excluded, and binary files" $
        withFixture \fixture@Fixture {outsideFile} ->
          withWorkspaceEnv fixture \env -> do
            mapM_
              (\path -> dispatch env "overlay__workspace-read__read" (object ["path" .= path]) >>= assertToolRefusal)
              [ "../outside.txt",
                Text.pack outsideFile,
                "escape-file",
                "escape-dir/secret.txt",
                ".git/config",
                "binary.dat"
              ]
    ]

boundTests :: TestTree
boundTests =
  testGroup
    "resource bounds"
    [ testCase "read refuses an oversized file" $
        withFixture \fixture@Fixture {repository} -> do
          BS.writeFile (repository </> "large.txt") (BS.replicate (maxReadBytes + 1) 120)
          withWorkspaceEnv fixture \env ->
            dispatch env "overlay__workspace-read__read" (object ["path" .= ("large.txt" :: Text)]) >>= assertToolRefusal,
      testCase "read refuses an oversized encoded response" $
        withFixture \fixture@Fixture {repository} -> do
          BS.writeFile (repository </> "large-response.txt") (BS.replicate maxResponseBytes 120)
          withWorkspaceEnv fixture \env ->
            dispatch env "overlay__workspace-read__read" (object ["path" .= ("large-response.txt" :: Text)]) >>= assertToolRefusal,
      testCase "grep refuses an excessive match set" $
        withFixture \fixture@Fixture {repository} -> do
          BS.writeFile
            (repository </> "many-matches.txt")
            (BS.intercalate "\n" (replicate (maxSearchMatches + 1) "needle"))
          withWorkspaceEnv fixture \env ->
            dispatch
              env
              "overlay__workspace-read__grep"
              (object ["patternText" .= ("needle" :: Text), "path" .= (Nothing :: Maybe Text), "ignoreCase" .= False])
              >>= assertToolRefusal,
      testCase "grep refuses an invalid regular expression" $
        withFixture \fixture ->
          withWorkspaceEnv fixture \env ->
            dispatch
              env
              "overlay__workspace-read__grep"
              (object ["patternText" .= ("[" :: Text), "path" .= (Nothing :: Maybe Text), "ignoreCase" .= False])
              >>= assertToolRefusal,
      testCase "glob refuses an excessive result set" $
        withFixture \fixture@Fixture {repository} -> do
          let directory = repository </> "many-glob"
          createDirectory directory
          mapM_ (\index -> BS.writeFile (directory </> (show index <> ".txt")) "x") [1 .. maxGlobResults + 1]
          withWorkspaceEnv fixture \env ->
            dispatch
              env
              "overlay__workspace-read__glob"
              (object ["patternText" .= ("*.txt" :: Text), "path" .= (Just "many-glob" :: Maybe Text)])
              >>= assertToolRefusal,
      testCase "traversal refuses a tree deeper than the configured bound" $
        withFixture \fixture@Fixture {repository} -> do
          let deep = foldl (</>) repository (replicate (maxTraversalDepth + 1) "d")
          createDirectoryIfMissing True deep
          BS.writeFile (deep </> "bottom.txt") "x"
          withWorkspaceEnv fixture \env ->
            dispatch
              env
              "overlay__workspace-read__glob"
              (object ["patternText" .= ("*.txt" :: Text), "path" .= (Nothing :: Maybe Text)])
              >>= assertToolRefusal,
      testCase "traversal refuses more than the configured file count" $
        withFixture \fixture@Fixture {repository} -> do
          let directory = repository </> "many-files"
          createDirectory directory
          mapM_ (\index -> BS.writeFile (directory </> show index) "") [1 .. maxVisitedFiles + 1]
          withWorkspaceEnv fixture \env ->
            dispatch
              env
              "overlay__workspace-read__grep"
              (object ["patternText" .= ("never" :: Text), "path" .= (Just "many-files" :: Maybe Text), "ignoreCase" .= False])
              >>= assertToolRefusal
    ]

withWorkspaceEnv :: Fixture -> (BehaviorEnv -> IO value) -> IO value
withWorkspaceEnv Fixture {repository} callback = do
  base <- newBehaviorEnv
  result <-
    withOneOffCapabilityOverlays
      Log.silentLogger
      allowAllActionAuthorizerForTests
      (Just repository)
      (testDecl [workspaceReadId])
      base
      callback
  case result of
    Left err -> assertFailure ("overlay setup failed: " <> show err)
    Right value -> pure value

dispatch :: BehaviorEnv -> Text -> Value -> IO (Either ShikumiError (Either ToolError Text))
dispatch BehaviorEnv {tools} name arguments =
  runEff . runErrorNoCallStack . runLLM $
    runToolCall tools (emptyToolCall & #id_ .~ ("test-call") & #name .~ (name) & #arguments .~ (arguments))

assertObservationContains :: Text -> Either ShikumiError (Either ToolError Text) -> Assertion
assertObservationContains needle = \case
  Right (Right observation) ->
    assertBool ("observation does not contain " <> Text.unpack needle <> ": " <> Text.unpack observation) (needle `Text.isInfixOf` observation)
  other -> assertFailure ("expected a successful observation, got " <> show other)

assertToolRefusal :: Either ShikumiError (Either ToolError Text) -> Assertion
assertToolRefusal = \case
  Right (Left ToolRunFailed {}) -> pure ()
  other -> assertFailure ("expected a typed tool refusal, got " <> show other)

testDecl :: [CapabilityId] -> AgentDecl
testDecl capabilityOverlays =
  AgentDecl
    { name = fixtureAgentName "workspace-capability-test",
      description = "workspace capability test",
      trigger = Event {eventType = "test"},
      behavior = Skill {path = "unused"},
      sinks = [],
      delegates = map fixtureAgentName [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays,
      identity = Just IdentityDecl {principal = "principal_workspace_test"},
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

fixtureScope :: Fixture -> IO WorkspaceScope
fixtureScope Fixture {repository} = do
  resolved <- resolveWorkspaceScope (Just repository)
  case resolved of
    Left err -> assertFailure ("fixture is not a worktree: " <> show err)
    Right scope -> pure scope

withFixture :: (Fixture -> IO value) -> IO value
withFixture = bracket createFixture (removePathForcibly . (.container))

createFixture :: IO Fixture
createFixture = do
  temporary <- getTemporaryDirectory
  (allocated, handle) <- openTempFile temporary "shikigami-workspace-test"
  hClose handle
  removeFile allocated
  createDirectory allocated
  let repository = allocated </> "repo"
      outsideFile = allocated </> "outside.txt"
      outsideDirectory = allocated </> "outside-dir"
  createDirectory repository
  callProcess "git" ["-C", repository, "init", "-q"]
  createDirectory (repository </> "nested")
  createDirectory (repository </> "dist-newstyle")
  createDirectory outsideDirectory
  BS.writeFile (repository </> "nested" </> "note.txt") "alpha needle omega\n"
  BS.writeFile (repository </> "dist-newstyle" </> "ignored.txt") "ignored\n"
  BS.writeFile (repository </> "binary.dat") (BS.pack [0, 1, 2, 3])
  BS.writeFile outsideFile "outside secret\n"
  BS.writeFile (outsideDirectory </> "secret.txt") "directory secret\n"
  createFileLink outsideFile (repository </> "escape-file")
  createDirectoryLink outsideDirectory (repository </> "escape-dir")
  pure Fixture {container = allocated, repository, outsideFile}

assertWorkspaceError :: (WorkspaceError -> Bool) -> Either WorkspaceError value -> Assertion
assertWorkspaceError predicate = \case
  Left err | predicate err -> pure ()
  other -> assertFailure ("unexpected workspace result: " <> showResult other)
  where
    showResult = \case
      Left err -> show err
      Right _ -> "Right <value>"

isEscape :: WorkspaceError -> Bool
isEscape WorkspacePathEscapes {} = True
isEscape _ = False

isInvalid :: WorkspaceError -> Bool
isInvalid InvalidWorkspacePath {} = True
isInvalid _ = False

isSymlink :: WorkspaceError -> Bool
isSymlink WorkspaceSymlinkRefused {} = True
isSymlink _ = False

isExcluded :: WorkspaceError -> Bool
isExcluded WorkspaceExcludedPath {} = True
isExcluded _ = False

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

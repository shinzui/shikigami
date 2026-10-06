module Shikigami.Agent.LaunchSpec (tests) where

import Baikai.Agent.Cli qualified as Agent
import Baikai.Agent.Config (AgentConfigPaths (..), emptyAgentConfigPaths)
import Control.Exception (bracket)
import Data.Text (Text)
import Data.Text qualified as Text
import Options.Applicative qualified as Opt
import Settei (Source, parseKey)
import Settei.Env (bindings, envSnapshot, environmentSource)
import Settei.Optparse (DiagnosticMode (..), cliOverride)
import Shikigami.Agent.Command.Launch
import Shikigami.App.Config.Load (ConfigOptions (..))
import System.Directory
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "foreground Baikai launch"
    [ testCase "config check starts no process and needs no model or API key" do
        case launchConfigRun (options CheckConfig []) (Right []) emptyEnvironment of
          Left (ExitSuccess, _, _) -> pure ()
          _ -> assertFailure "expected admitted pure check",
      testCase "explicit safety is required" do
        case launchConfigRun ((options NoDiagnostic []) {overrides = take 2 (options NoDiagnostic []).overrides}) (Right []) emptyEnvironment of
          Left (ExitFailure 4, _, _) -> pure ()
          _ -> assertFailure "invalid sandbox admitted",
      testCase "wrong-provider safety fails before spawn" do
        case launchConfigRun (options NoDiagnostic [("launch.safety.claude_allowed_tools", "[\"Read\"]")]) (Right []) emptyEnvironment of
          Left (ExitFailure 4, _, _) -> pure ()
          _ -> assertFailure "cross-provider policy admitted",
      testCase "operator arguments are redacted in an effective report" do
        case launchConfigRun (options ExplainJson [("launch.arguments", "[\"planted-secret-args\"]")]) (Right []) emptyEnvironment of
          Left (ExitSuccess, output, err) -> assertBool "raw arguments leaked" (not ("planted-secret-args" `Text.isInfixOf` (output <> err)))
          _ -> assertFailure "expected an effective report",
      testCase "fake interactive launch preserves cwd, prompt, model, effort and exit" $ withDirectory \dir -> do
        let exe = dir </> "vendor"
        writeFile exe "#!/bin/sh\npwd > cwd\nprintf '%s\\n' \"$@\" > args\nexit 7\n"
        permissions <- getPermissions exe
        setPermissions exe permissions {executable = True}
        config <- resolved [("launch.working_directory", Text.pack dir), ("launch.executable", Text.pack exe), ("launch.model", "explicit-model"), ("launch.thinking", "low")]
        (code, _) <- launchInteractive False config "public-marker" Nothing
        code @?= ExitFailure 7
        cwd <- readFile (dir </> "cwd")
        canonical <- canonicalizePath dir
        lines cwd @?= [canonical]
        args <- lines <$> readFile (dir </> "args")
        mapM_ (\arg -> assertBool ("missing argument " <> arg) (arg `elem` args)) ["public-marker", "explicit-model", "model_reasoning_effort=low", "read-only", "on-request"],
      testCase "unattended executed nonzero exit passes through and ceiling refusal starts nothing" $ withDirectory \dir -> withDirectory \operatorDir -> do
        let exe = dir </> "vendor"
            repo = dir </> "agents.kdl"
            user = operatorDir </> "operator.kdl"
            paths = emptyAgentConfigPaths {userConfig = Just user, repoConfig = Just repo, repositoryRoot = dir}
            job capability = "jobs {\n  inspect {\n    provider \"codex\"\n    working-dir \".\"\n    output \"capture\"\n    timeout \"2s\"\n    safety {\n      capability \"" <> capability <> "\"\n    }\n  }\n}\n"
        writeFile exe "#!/bin/sh\npwd > started\ncat >/dev/null\nexit 7\n"
        permissions <- getPermissions exe
        setPermissions exe permissions {executable = True}
        writeFile user ("policy {\n  max-capability \"read-only\"\n}\njobs {\n  inspect {\n    executable \"" <> exe <> "\"\n  }\n}\n")
        writeFile repo (job "read-only")
        command <- parseNative ["agent", "run", "inspect", "--prompt", "public-marker"]
        result <- Agent.runAgentCliWithPaths paths (envSnapshot []) command
        assertEqual (Text.unpack result.standardError) 7 result.exitCode
        doesFileExist (dir </> "started") >>= (@?= True)
        removeFile (dir </> "started")
        writeFile repo (job "full-access")
        refused <- Agent.runAgentCliWithPaths paths (envSnapshot []) command
        refused.exitCode @?= Agent.refusedExitCode
        doesFileExist (dir </> "started") >>= (@?= False)
        writeFile repo ("policy {\n  max-capability \"full-access\"\n}\n" <> job "full-access")
        overrideRefused <- Agent.runAgentCliWithPaths paths (envSnapshot []) command
        overrideRefused.exitCode @?= Agent.refusedExitCode
        doesFileExist (dir </> "started") >>= (@?= False),
      testCase "mounted unattended parser preserves Baikai's show result" $ withDirectory \dir -> do
        let repo = dir </> "agents.kdl"
        writeFile repo "jobs {\n  inspect {\n    provider \"codex\"\n    working-dir \".\"\n    safety {\n      capability \"read-only\"\n    }\n  }\n}\n"
        let paths = emptyAgentConfigPaths {repoConfig = Just repo, repositoryRoot = dir}
        native <- parseNative ["agent", "show", "inspect"]
        mounted <- case Opt.execParserPure Opt.defaultPrefs launchParserInfo ["unattended", "agent", "show", "inspect"] of
          Opt.Success (UnattendedLaunch value) -> pure value
          _ -> assertFailure "unattended subtree did not parse"
        a <- Agent.runAgentCliWithPaths paths (envSnapshot []) native
        b <- Agent.runAgentCliWithPaths paths (envSnapshot []) mounted
        a @?= b
        a.exitCode @?= 0
    ]

options :: DiagnosticMode -> [(Text, Text)] -> ConfigOptions
options diagnosticMode extra =
  ConfigOptions
    { configPaths = [],
      namedSources = [],
      diagnosticMode,
      overrides = [cliOverride (either (error . show) id (parseKey key)) value | (key, value) <- defaults <> extra]
    }
  where
    defaults = [("launch.provider", "codex"), ("launch.working_directory", "/tmp"), ("launch.safety.codex_sandbox", "read-only"), ("launch.safety.codex_approval", "on-request")]

emptyEnvironment :: Source
emptyEnvironment = environmentSource (either (const (error "invalid bindings")) id (bindings [])) (envSnapshot [])

resolved :: [(Text, Text)] -> IO LaunchConfig
resolved extra = case launchConfigRun (options NoDiagnostic extra) (Right []) emptyEnvironment of
  Right config -> pure config
  Left (_, _, err) -> assertFailure (Text.unpack err)

parseNative :: [String] -> IO Agent.AgentCliOptions
parseNative args = case Opt.execParserPure Opt.defaultPrefs Agent.agentCliParserInfo args of
  Opt.Success value -> pure value
  _ -> assertFailure "native Baikai command did not parse"

withDirectory :: (FilePath -> IO a) -> IO a
withDirectory = bracket acquire removeDirectoryRecursive
  where
    acquire = do
      root <- getTemporaryDirectory
      (path, h) <- openTempFile root "shikigami-launch-test"
      hClose h
      removeFile path
      createDirectory path
      pure path

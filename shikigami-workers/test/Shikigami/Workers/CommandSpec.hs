-- | Every worker executable has a working command line.
--
-- These are smoke tests in the literal sense: they prove each binary's parser is
-- reachable, renders @--help@, names itself in the output, and accepts its
-- documented options. That is exactly the class of breakage a package split or a
-- configuration migration causes — an executable wired to the wrong parser, or
-- one whose options were dropped in the move — and it is invisible to the type
-- checker because every parser has the same type.
--
-- Since the move to resolved configuration, two more things are worth asserting.
-- The operator-facing flags now target declared configuration keys rather than
-- private parser values, so a flag that was silently dropped in that rewrite
-- would still compile; and every role must offer the same five diagnostic modes,
-- because an operator who learns them on one binary should not find them missing
-- on another.
--
-- They run the parser purely with @execParserPure@ rather than executing a built
-- binary, so they are fast, need no build-tool dependency, and can assert on the
-- rendered help text.
module Shikigami.Workers.CommandSpec (tests) where

import Data.List (isInfixOf)
import Data.Text qualified as Text
import Options.Applicative
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.App.Config
import Shikigami.App.Config.Load (ConfigRun (..), appConfigRun)
import Shikigami.Trust.Tier (TrustTier (..))
import Shikigami.Workers.Command
  ( RoleInfo (..),
    schedulerRoleInfo,
    workerRoleInfo,
    workerRoles,
  )
import Shikigami.Workers.Command.Worker (workerTierAdmission)
import System.Exit (ExitCode (ExitSuccess))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | The options every configurable executable offers, whatever its role.
configurationFlags :: [String]
configurationFlags =
  [ "--config",
    "--set",
    "--describe-config",
    "--describe-config-json",
    "--explain-config",
    "--explain-config-json",
    "--check-config"
  ]

tests :: TestTree
tests =
  testGroup
    "worker command lines"
    [ testCase "the worker admits the local-operator tier and refuses a multi-tenant tier without a service authority" do
        workerTierAdmission defaultAppConfig @?= Right ()
        workerTierAdmission defaultAppConfig {trustTier = LocalOperator} @?= Right ()
        assertBool "bare multi-tenant refused" (either (const True) (const False) (workerTierAdmission defaultAppConfig {trustTier = MultiTenant})),
      testCase "every worker executable renders --help" $
        mapM_
          ( \info -> do
              let rendered = helpTextOf info
              assertBool
                ((.binaryName) info <> ": --help produced no usage line:\n" <> rendered)
                ("Usage:" `isInfixOf` rendered)
          )
          workerRoles,
      -- The one-off roles moved to shikigami-agent; see
      -- "Shikigami.Agent.CommandSpec". Their absence here is the assertion that
      -- they did not stay behind and quietly keep linking PGMQ. The stream and
      -- event consumers are the Kikan distribution's (plan 135, M5); their
      -- cases are in the binding's suite.
      testCase "the worker roles are named exactly once each" $
        fmap (.binaryName) workerRoles
          @?= [ "shikigami-worker",
                "shikigami-scheduler",
                "shikigami-workspace-supervisor"
              ],
      testCase "each binary is wired to the role whose requirements it must meet" $
        fmap (.role) workerRoles
          @?= [ WorkerRole,
                SchedulerRole,
                WorkspaceSupervisorRole
              ],
      testCase "every worker executable offers the same configuration and diagnostic options" $
        mapM_ (`assertHasAll` configurationFlags) workerRoles,
      testCase "every worker executable reports its version offline" $
        mapM_ assertVersion workerRoles,
      -- Service endpoints are pack settings (plan 135, M3): an operator sets
      -- them with --set or their variables, so the worker names no service.
      testCase "the worker keeps its agents option" $
        assertHasAll workerRoleInfo ["--agents"],
      testCase "workspace maintenance requires an explicit actor and exclusive action" $ do
        mapM_ (\args -> case execParserPure defaultPrefs workerRoleInfo.parserInfo args of Success _ -> pure (); _ -> assertFailure "maintenance command refused") [["--workspace-actor", "agent_01h000000000000000triage", "--workspace-list"], ["--workspace-actor", "agent_01h000000000000000triage", "--workspace-cleanup", replicate 64 'a']]
        mapM_ (\args -> case execParserPure defaultPrefs workerRoleInfo.parserInfo args of Success _ -> assertFailure "incomplete maintenance command admitted"; _ -> pure ()) [["--workspace-list"], ["--workspace-actor", "agent_01h000000000000000triage"], ["--workspace-actor", "agent_01h000000000000000triage", "--workspace-list", "--workspace-cleanup", replicate 64 'a']],
      testCase "the scheduler keeps its agents directory option" $
        assertHasAll schedulerRoleInfo ["--agents"],
      testCase "each downstream flag names the configuration key it sets" do
        let rendered = helpTextOf workerRoleInfo
        mapM_
          ( \key ->
              assertBool
                ("shikigami-worker help does not name " <> key <> ":\n" <> rendered)
                (key `isInfixOf` rendered)
          )
          ["agents.directory"],
      resolutionTests
    ]

-- | The flags actually reach the configuration they claim to.
--
-- The help-text cases above prove a flag exists and names a key. They cannot
-- prove it is wired to that key: @namedOption@ takes the spelling and the target
-- key as separate arguments, so a copy-paste that points @--topic@ at
-- @kafka.groups.stream@ produces perfect help text and the wrong deployment.
-- These cases run the real parser and then the real resolver, with an injected
-- environment so they do not depend on the developer's shell.
resolutionTests :: TestTree
resolutionTests =
  testGroup
    "resolution through the real parser"
    [ testCase "every worker flag lands on the setting it names" do
        config <-
          resolveArgs
            workerRoleInfo
            ["--agents", "/srv/agents"]
        (.agentsDirectory) config @?= "/srv/agents",
      testCase "a --set override beats the equivalent named flag" do
        config <- resolveArgs workerRoleInfo ["--agents", "/from-flag", "--set", "agents.directory=/from-set"]
        (.agentsDirectory) config @?= "/from-set"
    ]

-- | Parse the given arguments with a role's real parser, then resolve the
-- sources it produced.
--
-- The environment is injected rather than read from the process, so these cases
-- do not depend on the developer's shell. It supplies only a connection string,
-- because every worker role but @run-behavior@ refuses to start without one and
-- these cases are about where the /other/ values come from.
resolveArgs :: RoleInfo -> [String] -> IO AppConfig
resolveArgs info args =
  case execParserPure defaultPrefs ((.parserInfo) info) args of
    Success (_, options) ->
      let environment =
            environmentSource
              environmentBindings
              (envSnapshot [("PG_CONNECTION_STRING", "postgresql:///shikigami-test")])
          run = appConfigRun ((.role) info) options (Right []) environment
       in case (.resolved) run of
            Just config -> pure config
            Nothing ->
              assertFailure
                ( (.binaryName) info
                    <> ": expected a resolved configuration, got exit "
                    <> show ((.exitCode) run)
                    <> ":\n"
                    <> Text.unpack ((.standardError) run)
                )
    Failure failure ->
      let (message, _) = renderFailure failure ((.binaryName) info)
       in assertFailure ((.binaryName) info <> ": arguments did not parse:\n" <> message)
    CompletionInvoked _ -> assertFailure "unexpected completion invocation"

-- | Assert the rendered help mentions every flag the command is documented to take.
assertHasAll :: RoleInfo -> [String] -> IO ()
assertHasAll info flags =
  mapM_
    ( \flag ->
        assertBool
          ((.binaryName) info <> ": --help does not mention " <> flag <> ":\n" <> rendered)
          (flag `isInfixOf` rendered)
    )
    flags
  where
    rendered = helpTextOf info

-- | Run a parser on @--help@ and return what it printed.
--
-- @--help@ always ends in a parser 'Failure'; the help text is the failure's
-- rendering. A 'Success' would mean the parser did not understand @--help@ at
-- all, which is itself the bug these tests look for.
helpTextOf :: RoleInfo -> String
helpTextOf info =
  case execParserPure defaultPrefs ((.parserInfo) info) ["--help"] of
    Failure failure -> let (message, _) = renderFailure failure ((.binaryName) info) in message
    Success _ -> "unexpected success: the parser did not handle --help"
    CompletionInvoked _ -> "unexpected completion invocation"

assertVersion :: RoleInfo -> IO ()
assertVersion info =
  case execParserPure defaultPrefs ((.parserInfo) info) ["--version"] of
    Failure failure -> do
      let (message, exitCode) = renderFailure failure ((.binaryName) info)
      exitCode @?= ExitSuccess
      assertBool ("version does not name the executable: " <> message) ((.binaryName) info `isInfixOf` message)
    _ -> assertBool "--version did not exit through optparse-applicative" False

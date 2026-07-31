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
import Options.Applicative
import Shikigami.App.Config (Role (..))
import Shikigami.Workers.Command
  ( WorkerRoleInfo (..),
    agentRunRoleInfo,
    consumeEventsRoleInfo,
    consumeStreamRoleInfo,
    runBehaviorRoleInfo,
    schedulerRoleInfo,
    workerRoleInfo,
    workerRoles,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

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
    [ testCase "every worker executable renders --help" $
        mapM_
          ( \info -> do
              let rendered = helpTextOf info
              assertBool
                (binaryName info <> ": --help produced no usage line:\n" <> rendered)
                ("Usage:" `isInfixOf` rendered)
          )
          workerRoles,
      testCase "the six worker roles are named exactly once each" $
        fmap binaryName workerRoles
          @?= [ "shikigami-worker",
                "shikigami-scheduler",
                "shikigami-consume-stream",
                "shikigami-consume-events",
                "shikigami-run-behavior",
                "shikigami-agent-run"
              ],
      testCase "each binary is wired to the role whose requirements it must meet" $
        fmap role workerRoles
          @?= [ WorkerRole,
                SchedulerRole,
                StreamConsumerRole,
                EventConsumerRole,
                RunBehaviorRole,
                AgentRunRole
              ],
      testCase "every worker executable offers the same configuration and diagnostic options" $
        mapM_ (`assertHasAll` configurationFlags) workerRoles,
      testCase "the worker keeps its downstream options" $
        assertHasAll
          workerRoleInfo
          ["--agents", "--kawa-url", "--kizashi-url", "--danwa-url", "--danwa-agent"],
      testCase "the scheduler keeps its agents directory option" $
        assertHasAll schedulerRoleInfo ["--agents"],
      testCase "the stream consumer keeps its topic and feedback-guard options" $
        assertHasAll
          consumeStreamRoleInfo
          ["--agents", "--broker", "--topic", "--group", "--include-agent-actors"],
      testCase "the event consumer keeps its topic and group options" $
        assertHasAll
          consumeEventsRoleInfo
          ["--agents", "--broker", "--topic", "--group"],
      testCase "run-behavior keeps its agent and payload options" $
        assertHasAll runBehaviorRoleInfo ["--agent", "--payload"],
      testCase "agent-run keeps its agent and activity options" $
        assertHasAll agentRunRoleInfo ["--agent", "--from-activity"],
      testCase "each downstream flag names the configuration key it sets" do
        let rendered = helpTextOf workerRoleInfo
        mapM_
          ( \key ->
              assertBool
                ("shikigami-worker help does not name " <> key <> ":\n" <> rendered)
                (key `isInfixOf` rendered)
          )
          [ "agents.directory",
            "sinks.kawa.base_url",
            "sinks.kizashi.base_url",
            "sinks.danwa.base_url",
            "sinks.danwa.agent_participant"
          ],
      testCase "the two consumers aim their identically-spelled flags at different keys" do
        let streamHelp = helpTextOf consumeStreamRoleInfo
            eventsHelp = helpTextOf consumeEventsRoleInfo
        assertBool
          ("consume-stream --topic must set kafka.activity.topic:\n" <> streamHelp)
          ("kafka.activity.topic" `isInfixOf` streamHelp)
        assertBool
          ("consume-events --topic must set kafka.events.topic:\n" <> eventsHelp)
          ("kafka.events.topic" `isInfixOf` eventsHelp)
        assertBool
          ("consume-stream --group must set kafka.groups.stream:\n" <> streamHelp)
          ("kafka.groups.stream" `isInfixOf` streamHelp)
        assertBool
          ("consume-events --group must set kafka.groups.events:\n" <> eventsHelp)
          ("kafka.groups.events" `isInfixOf` eventsHelp)
    ]

-- | Assert the rendered help mentions every flag the command is documented to take.
assertHasAll :: WorkerRoleInfo -> [String] -> IO ()
assertHasAll info flags =
  mapM_
    ( \flag ->
        assertBool
          (binaryName info <> ": --help does not mention " <> flag <> ":\n" <> rendered)
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
helpTextOf :: WorkerRoleInfo -> String
helpTextOf info =
  case execParserPure defaultPrefs (parserInfo info) ["--help"] of
    Failure failure -> let (message, _) = renderFailure failure (binaryName info) in message
    Success _ -> "unexpected success: the parser did not handle --help"
    CompletionInvoked _ -> "unexpected completion invocation"

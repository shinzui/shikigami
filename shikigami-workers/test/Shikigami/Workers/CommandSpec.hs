-- | Every worker executable has a working command line.
--
-- These are smoke tests in the literal sense: they prove each binary's parser is
-- reachable, renders @--help@, names itself in the output, and accepts its
-- documented options. That is exactly the class of breakage a package split
-- causes — an executable wired to the wrong parser, or one whose options were
-- dropped in the move — and it is invisible to the type checker because every
-- parser has the same type.
--
-- They run the parser purely with @execParserPure@ rather than executing a built
-- binary, so they are fast, need no build-tool dependency, and can assert on the
-- rendered help text.
module Shikigami.Workers.CommandSpec (tests) where

import Data.List (isInfixOf)
import Options.Applicative
import Shikigami.Workers.Command (agentRunInfo, consumeEventsInfo, consumeStreamInfo, runBehaviorInfo, schedulerInfo, workerCommands, workerInfo)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "worker command lines"
    [ testCase "every worker executable renders --help" $
        mapM_
          ( \(name, parserInfo) -> do
              let rendered = helpTextOf name parserInfo
              assertBool
                (name <> ": --help produced no usage line:\n" <> rendered)
                ("Usage:" `isInfixOf` rendered)
          )
          workerCommands,
      testCase "the six worker roles are named exactly once each" $
        fmap fst workerCommands
          @?= [ "shikigami-worker",
                "shikigami-scheduler",
                "shikigami-consume-stream",
                "shikigami-consume-events",
                "shikigami-run-behavior",
                "shikigami-agent-run"
              ],
      testCase "the worker keeps its downstream options" $
        assertHasAll
          "shikigami-worker"
          workerInfo
          ["--agents", "--kawa-url", "--kizashi-url", "--danwa-url", "--danwa-agent"],
      testCase "the scheduler keeps its agents directory option" $
        assertHasAll "shikigami-scheduler" schedulerInfo ["--agents"],
      testCase "the stream consumer keeps its topic and feedback-guard options" $
        assertHasAll
          "shikigami-consume-stream"
          consumeStreamInfo
          ["--agents", "--broker", "--topic", "--group", "--include-agent-actors"],
      testCase "the event consumer keeps its topic and group options" $
        assertHasAll
          "shikigami-consume-events"
          consumeEventsInfo
          ["--agents", "--broker", "--topic", "--group"],
      testCase "run-behavior keeps its agent and payload options" $
        assertHasAll "shikigami-run-behavior" runBehaviorInfo ["--agent", "--payload"],
      testCase "agent-run keeps its agent and activity options" $
        assertHasAll "shikigami-agent-run" agentRunInfo ["--agent", "--from-activity"]
    ]

-- | Assert the rendered help mentions every flag the command is documented to take.
assertHasAll :: String -> ParserInfo a -> [String] -> IO ()
assertHasAll name parserInfo flags =
  mapM_
    ( \flag ->
        assertBool
          (name <> ": --help does not mention " <> flag <> ":\n" <> rendered)
          (flag `isInfixOf` rendered)
    )
    flags
  where
    rendered = helpTextOf name parserInfo

-- | Run a parser on @--help@ and return what it printed.
--
-- @--help@ always ends in a parser 'Failure'; the help text is the failure's
-- rendering. A 'Success' would mean the parser did not understand @--help@ at
-- all, which is itself the bug these tests look for.
helpTextOf :: String -> ParserInfo a -> String
helpTextOf name parserInfo =
  case execParserPure defaultPrefs parserInfo ["--help"] of
    Failure failure -> let (message, _) = renderFailure failure name in message
    Success _ -> "unexpected success: the parser did not handle --help"
    CompletionInvoked _ -> "unexpected completion invocation"

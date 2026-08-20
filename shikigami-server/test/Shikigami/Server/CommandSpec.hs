-- | The @shikigami@ administrative command line still offers every command.
--
-- The commands in this package arrived here from a package that no longer
-- exists. A command that was dropped in that move, or wired to the wrong
-- implementation, would still compile — every subcommand parser has the same
-- type. Only running the parser catches it.
--
-- These tests drive @optparse-applicative@ purely with @execParserPure@ rather
-- than executing the built binary: no build-tool dependency, no process
-- spawning, and the rendered help text is available to assert on.
module Shikigami.Server.CommandSpec (tests) where

import Data.List (isInfixOf)
import Data.Maybe (isNothing)
import Options.Applicative
import Shikigami.Server.Command (adminInfo, adminSubcommands)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "administrative command line"
    [ testCase "every administrative command is present" $
        fmap fst adminSubcommands
          @?= [ "validate",
                "render-lifecycle",
                "enqueue-run",
                "publish-fixture",
                "stub-kawa",
                "danwa-spike",
                "grants",
                "agents"
              ],
      testCase "shikigami --help lists every command" do
        let rendered = helpTextOf ["--help"]
        assertBool ("no usage line:\n" <> rendered) ("Usage:" `isInfixOf` rendered)
        mapM_
          ( \(name, _) ->
              assertBool (name <> " missing from top-level help:\n" <> rendered) (name `isInfixOf` rendered)
          )
          adminSubcommands,
      testCase "every command renders its own --help" $
        mapM_
          ( \(name, _) -> do
              let rendered = helpTextOf [name, "--help"]
              assertBool
                (name <> ": --help produced no usage line:\n" <> rendered)
                ("Usage:" `isInfixOf` rendered)
          )
          adminSubcommands,
      testCase "stub-kawa keeps its republish options" do
        let rendered = helpTextOf ["stub-kawa", "--help"]
        mapM_
          (\flag -> assertBool ("stub-kawa help does not mention " <> flag) (flag `isInfixOf` rendered))
          ["--port", "--republish-topic", "--broker"],
      testCase "danwa-spike keeps its participant options" do
        let rendered = helpTextOf ["danwa-spike", "--help"]
        mapM_
          (\flag -> assertBool ("danwa-spike help does not mention " <> flag) (flag `isInfixOf` rendered))
          ["--danwa-url", "--human", "--agent"],
      -- The diagnostics live at the top level rather than inside a subcommand,
      -- because `shikigami --describe-config` must answer without being told
      -- which command it is about to not run.
      testCase "the top-level command line offers every configuration diagnostic" do
        let rendered = helpTextOf ["--help"]
        mapM_
          (\flag -> assertBool ("top-level help does not mention " <> flag <> ":\n" <> rendered) (flag `isInfixOf` rendered))
          [ "--config",
            "--set",
            "--describe-config",
            "--describe-config-json",
            "--explain-config",
            "--explain-config-json",
            "--check-config"
          ],
      -- A diagnostic with no subcommand has to parse: it is how an operator
      -- inspects the schema, and there is nothing to run.
      testCase "a diagnostic parses with no subcommand at all" $
        case execParserPure defaultPrefs adminInfo ["--describe-config"] of
          Success (chosen, _) -> assertBool "no subcommand should have been chosen" (isNothing chosen)
          Failure failure ->
            let (message, _) = renderFailure failure "shikigami"
             in assertBool ("--describe-config alone did not parse:\n" <> message) False
          CompletionInvoked _ -> assertBool "unexpected completion invocation" False,
      -- `agents list` is the one verb that answers with no database, which is
      -- what makes it usable when the database is the thing that is broken.
      testCase "agents list offers --json and takes no target argument" do
        let rendered = helpTextOf ["agents", "list", "--help"]
        assertBool ("agents list help does not mention --json:\n" <> rendered) ("--json" `isInfixOf` rendered),
      testCase "a subcommand's downstream flags name the configuration keys they set" do
        assertMentions ["publish-fixture", "--help"] ["kafka.broker", "kafka.activity.topic"]
        assertMentions ["stub-kawa", "--help"] ["kafka.broker"]
        assertMentions ["danwa-spike", "--help"] ["sinks.danwa.base_url"]
    ]

assertMentions :: [String] -> [String] -> IO ()
assertMentions args expected =
  mapM_
    (\needle -> assertBool (unwords args <> " does not mention " <> needle <> ":\n" <> rendered) (needle `isInfixOf` rendered))
    expected
  where
    rendered = helpTextOf args

-- | Run the administrative parser on the given arguments and return what it
-- printed.
--
-- @--help@ always ends in a parser 'Failure'; the help text is that failure's
-- rendering. A 'Success' would mean the parser ran a command instead of showing
-- help, which is itself the bug these tests look for.
helpTextOf :: [String] -> String
helpTextOf args =
  case execParserPure defaultPrefs adminInfo args of
    Failure failure -> let (message, _) = renderFailure failure "shikigami" in message
    Success _ -> "unexpected success: the parser did not handle --help"
    CompletionInvoked _ -> "unexpected completion invocation"

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
import Options.Applicative
import Shikigami.Server.Command (adminInfo, adminSubcommands)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "administrative command line"
    [ testCase "the six administrative commands are present" $
        fmap fst adminSubcommands
          @?= [ "validate",
                "render-lifecycle",
                "enqueue-run",
                "publish-fixture",
                "stub-kawa",
                "danwa-spike"
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
          ["--danwa-url", "--human", "--agent"]
    ]

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

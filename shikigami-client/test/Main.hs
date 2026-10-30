module Main (main) where

import Data.List (isInfixOf)
import Options.Applicative
import Shikigami.Client.Command (clientInfo, clientSubcommands)
import Shikigami.Client.ConfigSpec qualified as ConfigSpec
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

main :: IO ()
main = defaultMain (testGroup "shikigami-client" [commandTests, ConfigSpec.tests])

-- | The client binary's command line is reachable and complete.
--
-- The client's endpoint functions are derived from the served route type, so a
-- mismatch there is a compile error and needs no test. What compilation does not
-- catch is a subcommand that was never wired into the parser, which is what
-- these cases cover.
commandTests :: TestTree
commandTests =
  testGroup
    "command line"
    [ testCase "global token is accepted and help never supplies its default" do
        case execParserPure defaultPrefs clientInfo ["--token", "test-token-value", "agents", "show", "heartbeat"] of
          Success _ -> pure ()
          _ -> assertBool "token option rejected" False
        assertBool "token option missing" ("--token" `isInfixOf` helpTextOf ["--help"]),
      testCase "version and static diagnostics are available without a command" do
        assertBool "version prefix missing" ("shikigami-client v0.1.0.0" `isInfixOf` helpTextOf ["--version"])
        case execParserPure defaultPrefs clientInfo ["--describe-config"] of
          Success _ -> pure ()
          _ -> assertBool "standalone diagnostic rejected" False,
      testCase "the client offers a health command" $
        fmap fst clientSubcommands @?= ["health", "agents", "runs"],
      testCase "shikigami-client --help lists every command" do
        let rendered = helpTextOf ["--help"]
        assertBool ("no usage line:\n" <> rendered) ("Usage:" `isInfixOf` rendered)
        mapM_
          (\(name, _) -> assertBool (name <> " missing from help:\n" <> rendered) (name `isInfixOf` rendered))
          clientSubcommands,
      testCase "health takes a server URL" do
        let rendered = helpTextOf ["health", "--help"]
        assertBool ("health help does not mention --server:\n" <> rendered) ("--server" `isInfixOf` rendered)
    ]

helpTextOf :: [String] -> String
helpTextOf args =
  case execParserPure defaultPrefs clientInfo args of
    Failure failure -> let (message, _) = renderFailure failure "shikigami-client" in message
    Success _ -> "unexpected success: the parser did not handle --help"
    CompletionInvoked _ -> "unexpected completion invocation"

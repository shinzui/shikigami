module Main (main) where

import Data.List (isInfixOf)
import Options.Applicative
import Shikigami.Client.Command (clientInfo, clientSubcommands)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

main :: IO ()
main = defaultMain (testGroup "shikigami-client" [commandTests])

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
      testCase "the client offers a health command" $
        fmap fst clientSubcommands @?= ["health", "agents"],
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

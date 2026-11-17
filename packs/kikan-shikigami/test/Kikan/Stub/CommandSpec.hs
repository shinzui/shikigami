-- | The stub verbs as the distribution's admin command offers them.
module Kikan.Stub.CommandSpec (tests) where

import Data.List (isInfixOf)
import Data.Maybe (isNothing)
import Kikan.Shikigami.Stub (stubsPack)
import Options.Applicative
import Shikigami.Server.Command (adminInfo, adminInfoWith, adminPrefs)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)

tests :: TestTree
tests =
  testGroup
    "stub verbs"
    [ testCase "the stock admin command offers no Kikan stub" $
        mapM_
          ( \verb -> case execParserPure adminPrefs adminInfo [verb, "--port", "8088"] of
              Success _ -> assertBool (verb <> " parsed in the stock admin command") False
              _ -> pure ()
          )
          ["stub-kawa", "stub-kanmon"],
      testCase "the stock admin command does not publish to Kafka" $
        case execParserPure adminPrefs adminInfo ["publish-fixture", "envelope.json"] of
          Success _ -> assertBool "publish-fixture parsed in the stock admin command" False
          _ -> pure (),
      testCase "publish-fixture takes a file, a broker and a topic" do
        let rendered = helpTextOf ["publish-fixture", "--help"]
        mapM_
          (\needle -> assertBool ("publish-fixture help does not mention " <> needle) (needle `isInfixOf` rendered))
          ["FILE", "--broker", "--topic", "activity.v1"],
      testCase "stub-kawa keeps its republish options" do
        let rendered = helpTextOf ["stub-kawa", "--help"]
        mapM_
          (\needle -> assertBool ("stub-kawa help does not mention " <> needle) (needle `isInfixOf` rendered))
          ["--port", "--republish-topic", "--broker"],
      testCase "stub-kanmon exposes only its port and repeatable destination allow-list" do
        let rendered = helpTextOf ["stub-kanmon", "--help"]
        mapM_
          (\needle -> assertBool ("stub-kanmon help does not mention " <> needle) (needle `isInfixOf` rendered))
          ["--port", "--allow-conversation"]
        assertBool ("stub-kanmon must not accept a token argument:\n" <> rendered) (not ("--token" `isInfixOf` rendered))
        case execParserPure adminPrefs composed ["stub-kanmon", "--port", "8090", "--allow-conversation", "conv_1", "--allow-conversation", "conv_2"] of
          Success (chosen, _) -> assertBool "stub-kanmon did not select an action" (not (isNothing chosen))
          Failure failure ->
            let (message, _) = renderFailure failure "kikan-shikigami"
             in assertBool ("stub-kanmon options did not parse:\n" <> message) False
          CompletionInvoked _ -> assertBool "unexpected completion invocation" False,
      testCase "stub-kanmon rejects a token flag" $
        case execParserPure adminPrefs composed ["stub-kanmon", "--port", "8090", "--token", "secret"] of
          Success _ -> assertBool "stub-kanmon accepted a plaintext token argument" False
          Failure _ -> pure ()
          CompletionInvoked _ -> assertBool "unexpected completion invocation" False
    ]
  where
    composed = adminInfoWith [stubsPack]
    helpTextOf args =
      case execParserPure adminPrefs composed args of
        Failure failure -> fst (renderFailure failure "kikan-shikigami")
        Success _ -> "unexpected success: the parser did not handle --help"
        CompletionInvoked _ -> "unexpected completion invocation"

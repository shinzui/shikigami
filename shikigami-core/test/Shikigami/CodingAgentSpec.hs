module Shikigami.CodingAgentSpec (tests) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Shikigami.Agent.Decl (AgentDecl (..), codingAgentStepOf)
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.CodingAgent.Types
import Shikigami.Process.Attempt
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "CodingAgent"
    [ testCase "checked values refuse what the declaration may not say" do
        isLeft (mkCodingAgentPrompt "   ") @?= True
        isRight (mkCodingAgentPrompt "add a Haddock comment") @?= True
        isLeft (mkDeadlineMinutes 0) @?= True
        isLeft (mkDeadlineMinutes 721) @?= True
        isRight (mkDeadlineMinutes 720) @?= True
        isLeft (mkVendorModelId "") @?= True
        isLeft (mkVendorModelId "two words") @?= True,
      testCase "the example declaration decodes to a CodingAgent step and round-trips" do
        loaded <- loadAgent "../agents/coding-agent-example.dhall"
        case loaded of
          Left problem -> assertFailure (show problem)
          Right decl -> do
            fmap (.provider) (codingAgentStepOf decl.behavior) @?= Just ClaudeCode
            fmap (.access) (codingAgentStepOf decl.behavior) @?= Just EditWorkspace
            Aeson.decode (Aeson.encode decl) @?= Just decl,
      testGroup
        "recovery"
        [ testCase "a complete result is collected even with the launcher alive" $
            recoverAttempt (facts (Just intent) (Just record) (Envelope envelope) LauncherRunning 0) @?= Collect envelope,
          testCase "a live launcher inside the deadline is reattached" $
            recoverAttempt (facts (Just intent) (Just record) NoEnvelope LauncherRunning 0) @?= Reattach record,
          testCase "a live launcher past the deadline plus grace overran" $
            recoverAttempt (facts (Just intent) (Just record) NoEnvelope LauncherRunning 7200) @?= GiveUp LauncherOverran,
          testCase "an intent without a launch record is uncertain, never relaunched" $
            recoverAttempt (facts (Just intent) Nothing NoEnvelope LauncherAbsent 0) @?= GiveUp IntentWithoutLaunch,
          testCase "a gone launcher without a result is uncertain" $
            recoverAttempt (facts (Just intent) (Just record) NoEnvelope LauncherGone 0) @?= GiveUp LauncherGoneWithoutResult,
          testCase "a gone launcher with a partial result is unreadable" $
            recoverAttempt (facts (Just intent) (Just record) PartialEnvelope LauncherGone 0) @?= GiveUp UnreadableResult,
          testCase "nothing attempted launches fresh" $
            recoverAttempt (facts Nothing Nothing NoEnvelope LauncherAbsent 0) @?= (LaunchFresh :: RecoveryDecision Value)
        ],
      testCase "outcomes keep their codec" do
        let outcome = Uncertain UncertainRun {reason = LauncherGoneWithoutResult, uncommitted = ChangeSummary [ChangedFile "src/A.hs" Modified] 0, launcherPid = Just 42}
        Aeson.decode (Aeson.encode outcome) @?= Just outcome
        outcomeLabel outcome @?= ("uncertain" :: Text)
    ]
  where
    start = UTCTime (fromGregorian 2026 11 15) 0
    intent = AttemptIntent {at = start}
    record = LaunchRecord {pid = 4242, startedAt = "Sun Nov 15 10:00:00 2026"}
    envelope = object ["outcome" .= ("ran" :: Text), "exitCode" .= (0 :: Int)]
    facts :: Maybe AttemptIntent -> Maybe LaunchRecord -> EnvelopeState Value -> LauncherState -> Integer -> AttemptFacts Value
    facts i l e state seconds =
      AttemptFacts {intent = i, launch = l, envelope = e, launcher = state, now = addUTCTime (fromInteger seconds) start, deadline = addUTCTime 1200 start}

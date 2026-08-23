module Shikigami.BehaviorRetrySpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Exception (AsyncException (ThreadKilled), throwIO, try)
import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Data.Time (secondsToNominalDiffTime)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Behavior.Error
  ( FailureClass (..),
    RunError (..),
    TransientBehaviorFailure,
    boundedBehaviorDetail,
    classifyRunError,
  )
import Shikigami.Behavior.Run (newBehaviorEnv, runBehaviorAttempt, runBehaviorAttemptWith, triggerOnly)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "RetrySemantics"
    [ testCase "classifies retryable failures before rendering" do
        traverse_
          (\err -> assertEqual (show err) Transient (classifyRunError err))
          [ ProgramRuntimeFailed "runtime",
            SkillRunFailed "skill",
            ProviderFailed True "provider"
          ]
        traverse_
          (\err -> assertEqual (show err) Permanent (classifyRunError err))
          [ UnknownTask "missing",
            ProgramInputFailed "bad input",
            SkillLoadFailed "missing SKILL.md",
            ProviderFailed False "provider",
            UnsupportedBehavior "deterministic"
          ],
      testCase "bounds and redacts durable failure detail" do
        let detail = boundedBehaviorDetail ("Authorization secret-token " <> Text.replicate 600 "x")
        assertBool "the secret is removed" (not ("secret-token" `Text.isInfixOf` detail))
        assertBool "the detail is bounded" (Text.length detail <= 512),
      testCase "a permanent attempt returns one bounded value" do
        env <- newBehaviorEnv
        result <-
          runBehaviorAttempt
            (secondsToNominalDiffTime 1)
            env
            missingTaskAgent
            (triggerOnly Aeson.Null)
        assertEqual "unknown task stays in band" (Left "unknown task: missing-task") result,
      testCase "a timeout and a retryable provider failure escape" do
        timedOut <-
          try @TransientBehaviorFailure $
            runBehaviorAttemptWith
              (secondsToNominalDiffTime 0.01)
              (threadDelay 100000 >> pure (Right Aeson.Null))
        assertBool "timeout throws a transient failure" (either (const True) (const False) timedOut)
        retryable <-
          try @TransientBehaviorFailure $
            runBehaviorAttemptWith
              (secondsToNominalDiffTime 1)
              (pure (Left (ProviderFailed True "temporary")))
        assertBool "retryable provider error throws" (either (const True) (const False) retryable),
      testCase "asynchronous cancellation is not converted" do
        cancelled <-
          try @AsyncException $
            runBehaviorAttemptWith
              (secondsToNominalDiffTime 1)
              (throwIO ThreadKilled)
        assertEqual "ThreadKilled propagates" (Left ThreadKilled) cancelled
    ]

missingTaskAgent :: AgentDecl
missingTaskAgent =
  AgentDecl
    { name = "missing-task-agent",
      description = "Exercises permanent behavior classification",
      trigger = Schedule {cron = "* * * * *"},
      behavior =
        ShikumiProgram
          { task = "missing-task",
            preferEnrichment = False,
            grounding = Nothing,
            enabledBy = Nothing
          },
      sinks = [],
      delegates = [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [],
      routing = Nothing
    }

module Shikigami.BehaviorRetrySpec (tests) where

import Control.Concurrent (newEmptyMVar, takeMVar)
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
import System.Timeout (timeout)
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
        neverCompletes <- newEmptyMVar
        timedOut <-
          timeout 2_000_000 $
            try @TransientBehaviorFailure $
              runBehaviorAttemptWith
                (secondsToNominalDiffTime 0.01)
                (takeMVar neverCompletes)
        -- A finite sleep can complete before the timeout thread gets CPU under
        -- load. This action cannot complete on its own; the outer timeout also
        -- makes a missing behavior timeout fail rather than hanging the suite.
        assertBool "timeout throws a transient failure" (case timedOut of Just (Left _) -> True; _ -> False)
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
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

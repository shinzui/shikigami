module Shikigami.TypeSafeDecisionSpec (tests) where

import Baikai.Content (DataContent (..))
import Baikai.ThinkingLevel (ThinkingLevel (ThinkingNone))
import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, fromException, try)
import Control.Lens ((&), (.~))
import Control.Monad (void)
import Data.Aeson (Value (..), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Shikigami.Decision.Answer (answerBlocks)
import Shikigami.Decision.Contract
import Shikigami.Decision.ModelCatalog
import Shikigami.Fixture.TypeSafe
import Shikigami.Program.Decision (SomeProgram (..), descriptor, programRef, programRegistry)
import Shikigami.Program.Decision.JudgmentExample
import Shikigami.Program.DecisionRunner
import Shikumi.Decision.Setting (DecisionSetting (NoulSetting))
import Shikumi.Program (emptyParams, setDecisionSetting)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "TypeSafe judgments"
    [ testCase "configured public adapter returns raw answers and pinned rich local derivation" $
        withTypeSafeFixture 200 0 fixtureResponse \fixture -> do
          let catalog = fixtureCatalog fixture.endpoint
          (hooks, inspect) <- newMemoryCallHooks
          env <- fixtureRuntime catalog hooks
          (result, answers) <- runDecisionProgramWithAnswers env (fixturePrepared catalog) (programRef judgmentProgram) fixtureTicket
          output <- either (assertFailure . show) pure result
          output.urgent.value @?= True
          output.urgent.probability @?= 0.83
          output.category.value @?= Billing
          output.category.probabilities @?= Map.fromList [("billing", 0.2), ("technical", 0.7)]
          output.severity.value @?= 1.5
          output.severity.level @?= 1
          output.severity.label @?= "Disruptive"
          case answers of
            [observation] -> case answerBlocks observation.snapshot of
              [dat] -> case dat.value of
                Object fields -> do
                  KM.lookup "category" fields @?= Just (String "technical")
                  KM.lookup "severity" fields @?= Just (Number 1.5)
                _ -> assertFailure "raw structured object expected"
              _ -> assertFailure "one structured answer expected"
            _ -> assertFailure "one correlated answer expected"
          calls <- inspect
          Map.size calls @?= 1
          assertBool "terminal is retained" (all (\call -> call.terminal /= Nothing) calls)
          let prepared = fixturePrepared catalog
              outcome = decisionOutcome prepared.identity prepared.program (Right (toJSON output)) (Map.keys calls) answers
          eitherDecode (encode outcome) @?= Right outcome
          requests <- fixture.requests
          case requests of
            [(path, Object body)] -> do
              path @?= "/v1/systemone"
              KM.lookup "model" body @?= Just (String "jev-latest")
              assertBool "no generation defaults" (all (\key -> not (KM.member key body)) ["thinking", "max_tokens", "temperature", "speed"])
            _ -> assertFailure "one HTTP request expected",
      testCase "fresh changed settings change derived values while raw probabilities remain identical" $
        withTypeSafeFixture 200 0 fixtureResponse \fixture -> do
          let catalog = fixtureCatalog fixture.endpoint
              prepared = fixturePrepared catalog
              changed = judgmentProgramWithSettings "2" (setDecisionSetting "urgent" (NoulSetting 0.99) emptyParams)
              changedRef = programRef changed
          (hooks, _) <- newMemoryCallHooks
          env <- fixtureRuntime catalog hooks
          (firstResult, firstAnswers) <- runDecisionProgramWithAnswers env prepared (programRef judgmentProgram) fixtureTicket
          let secondEnv = env & #programs .~ mustRight (programRegistry [SomeProgram changed])
              secondPrepared = prepared & #program .~ descriptor changedRef
          (secondResult, secondAnswers) <- runDecisionProgramWithAnswers secondEnv secondPrepared changedRef fixtureTicket
          first <- either (assertFailure . show) pure firstResult
          second <- either (assertFailure . show) pure secondResult
          first.urgent.value @?= True
          second.urgent.value @?= False
          first.category.value @?= Billing
          second.category.value @?= Technical
          first.urgent.probability @?= second.urgent.probability
          first.category.probabilities @?= second.category.probabilities
          map (toJSON . (.snapshot)) firstAnswers @?= map (toJSON . (.snapshot)) secondAnswers
          assertBool "program identity changes" (prepared.program /= secondPrepared.program)
          fixture.requests >>= (\requests -> length requests @?= 2),
      testCase "provider refusal retains a failed actual attempt and no probability-shaped success" $
        withTypeSafeFixture 403 0 (object ["error" .= ("fixture denied" :: String)]) \fixture -> do
          let catalog = fixtureCatalog fixture.endpoint
          (hooks, inspect) <- newMemoryCallHooks
          env <- fixtureRuntime catalog hooks
          (result, answers) <- runDecisionProgramWithAnswers env (fixturePrepared catalog) (programRef judgmentProgram) fixtureTicket
          assertBool "provider refusal" (isLeft result)
          answers @?= []
          calls <- inspect
          Map.size calls @?= 1
          assertBool "one failed terminal" (all (\call -> case call.terminal of Just (CallFailed, Just _) -> True; _ -> False) calls)
          fixture.requests >>= (\requests -> length requests @?= 1),
      testCase "terminal persistence failure returns no structured success and cannot retry" $
        withTypeSafeFixture 200 0 fixtureResponse \fixture -> do
          let catalog = fixtureCatalog fixture.endpoint
          (hooks, inspect) <- newMemoryCallHooks
          let broken = hooks & #finishCall .~ (\_ _ _ -> pure (Left (decisionFailure EvidenceFailure "fixture unavailable")))
          env <- fixtureRuntime catalog broken
          (result, answers) <- runDecisionProgramWithAnswers env (fixturePrepared catalog) (programRef judgmentProgram) fixtureTicket
          fmap failureCode (either Right (const (Left ())) result) @?= Right EvidenceFailure
          answers @?= []
          calls <- inspect
          Map.size calls @?= 1
          assertBool "terminal stays unresolved" (all (\call -> call.terminal == Nothing) calls)
          fixture.requests >>= (\requests -> length requests @?= 1),
      testCase "HTTP cancellation propagates and leaves an unresolved actual attempt" $
        withTypeSafeFixture 200 500000 fixtureResponse \fixture -> do
          let catalog = fixtureCatalog fixture.endpoint
          (hooks, inspect) <- newMemoryCallHooks
          env <- fixtureRuntime catalog hooks
          finished <- newEmptyMVar
          worker <- forkIO (try @SomeException (runDecisionProgramWithAnswers env (fixturePrepared catalog) (programRef judgmentProgram) fixtureTicket) >>= putMVar finished)
          ready <- timeout 2000000 (takeMVar fixture.ready)
          ready @?= Just ()
          void (forkIO (killThread worker))
          completed <- timeout 2000000 (takeMVar finished)
          case completed of
            Just (Left failure) -> fromException @AsyncException failure @?= Just ThreadKilled
            _ -> assertFailure "cancellation did not propagate"
          calls <- inspect
          Map.size calls @?= 1
          assertBool "no fabricated terminal" (all (\call -> call.terminal == Nothing) calls)
          fixture.requests >>= (\requests -> length requests @?= 1),
      testCase "explicit generation controls and missing credentials refuse binding before HTTP" $
        withTypeSafeFixture 200 0 fixtureResponse \fixture -> do
          let catalog = fixtureCatalog fixture.endpoint
              prepared = fixturePrepared catalog
              pinned = mustRight (pinnedBinding catalog prepared.model)
              bind options secret = modelBinding prepared.model.alias "1" "fixture-refusal" "1" (bindingModel pinned) options secret
          mapM_
            (assertBool "generation option refused" . isLeft . (\options -> bind options (bindingCredential pinned)))
            [ bindingOptions pinned & #thinking .~ Just ThinkingNone,
              bindingOptions pinned & #maxTokens .~ Just 64,
              bindingOptions pinned & #temperature .~ Just 0
            ]
          assertBool "missing credential refused" (isLeft (bind (bindingOptions pinned) Nothing))
          fixture.requests >>= (@?= [])
    ]

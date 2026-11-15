-- | Routine agents (EP-9 of MasterPlan 22): what @shikigami-local new@
-- writes is a short, ordinary declaration with the routine defaults.
module Shikigami.Agent.RoutineSpec (tests) where

import Data.Unique (hashUnique, newUnique)
import Shikigami.Agent.Command.Routine (NewRoutine (..), scaffoldRoutine)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Trigger (..))
import Shikigami.Agent.Loader (loadAgent)
import System.Directory (getTemporaryDirectory, makeAbsolute, removePathForcibly)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "routine agents"
    [ testCase "new writes a short Skill declaration that loads with a manual trigger and no outputs" $ withDirectory \agents -> do
        schema <- makeAbsolute "../schema"
        Right [declaration, skill] <- scaffoldRoutine agents schema NewRoutine {name = "repo-digest", coder = False, every = Nothing}
        skill @?= agents </> "skills" </> "repo-digest" </> "SKILL.md"
        lines' <- lines <$> readFile declaration
        assertBool "at most fifteen lines" (length lines' <= 15)
        loaded <- loadAgent declaration
        decl <- either (assertFailure . show) pure loaded
        decl.trigger @?= Manual
        decl.outputs @?= []
        case decl.behavior of
          Skill {} -> pure ()
          other -> assertFailure (show other)
        again <- scaffoldRoutine agents schema NewRoutine {name = "repo-digest", coder = False, every = Nothing}
        either (const True) (const False) again @?= True,
      testCase "new --coder --every writes a scheduled coding agent" $ withDirectory \agents -> do
        schema <- makeAbsolute "../schema"
        Right [declaration] <- scaffoldRoutine agents schema NewRoutine {name = "readme-keeper", coder = True, every = Just "*/2 * * * *"}
        loaded <- loadAgent declaration
        decl <- either (assertFailure . show) pure loaded
        case (decl.behavior, decl.trigger) of
          (CodingAgent {}, Schedule {}) -> pure ()
          other -> assertFailure (show other)
    ]

withDirectory :: (FilePath -> IO a) -> IO a
withDirectory action = do
  temporary <- getTemporaryDirectory
  unique <- hashUnique <$> newUnique
  let directory = temporary </> ("shikigami-routine-test-" <> show unique)
  removePathForcibly directory
  result <- action directory
  removePathForcibly directory
  pure result

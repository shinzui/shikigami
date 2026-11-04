module Shikigami.WorkflowInputSpec (tests) where

import Control.Concurrent.Async (concurrently_)
import Control.Exception (SomeException, try)
import Data.Aeson (toJSON)
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Keiro.Workflow qualified as W
import Shikigami.ExecutionTranscriptSpec qualified as Fixture
import Shikigami.Migrations.TestSupport (DatabaseFixture)
import Shikigami.Prelude
import Shikigami.Workflow.Versioning
import Test.Tasty
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "WorkflowInput"
    [ testCase "concurrent external admission commits deployment patches with its first native input" $
        Fixture.withFixture fixture \env _ _ -> do
          concurrently_ (Fixture.run env (admitWorkflowInput name fresh label (toJSON ("first" :: Text)))) (Fixture.run env (admitWorkflowInput name fresh label (toJSON ("second" :: Text))))
          journal <- Fixture.run env (W.loadStepIndex name fresh 0)
          Map.lookup W.patchSetStepName journal @?= Just (toJSON (map W.unPatchId (Set.toList shikigamiActivePatches)))
          assertBool "one original input retained" (Map.lookup "ingest" journal `elem` map (Just . toJSON) (["first", "second"] :: [Text]))
          Fixture.run env (W.runWorkflowWith (shikigamiWorkflowRunOptions env) name fresh (W.patch added)) >>= (@?= W.Completed True),
      testCase "an old bare ingestion keeps its historical patch branch and original input" $
        Fixture.withFixture fixture \env _ _ -> do
          now <- getCurrentTime
          Fixture.run env (W.appendJournalEntry name old (W.StepRecorded "ingest" (toJSON ("original" :: Text)) now))
          Fixture.run env (admitWorkflowInput name old label (toJSON ("new bytes cannot replace history" :: Text)))
          journal <- Fixture.run env (W.loadStepIndex name old 0)
          Map.lookup W.patchSetStepName journal @?= Nothing
          Map.lookup "ingest" journal @?= Just (toJSON ("original" :: Text))
          Fixture.run env (W.runWorkflowWith (shikigamiWorkflowRunOptions env) name old (W.patch added)) >>= (@?= W.Completed False),
      testCase "an existing patch snapshot wins even before ingestion and a terminal journal gains neither input nor patches" $
        Fixture.withFixture fixture \env _ _ -> do
          now <- getCurrentTime
          Fixture.run env (W.appendJournalEntry name old (W.StepRecorded W.patchSetStepName (toJSON ([] :: [Text])) now))
          Fixture.run env (admitWorkflowInput name old label (toJSON ("first admitted input" :: Text)))
          Fixture.run env (W.runWorkflowWith (shikigamiWorkflowRunOptions env) name old (W.patch added)) >>= (@?= W.Completed False)
          Fixture.run env (W.appendJournalEntry name fresh (W.WorkflowCompleted now))
          failed <- try @SomeException (Fixture.run env (admitWorkflowInput name fresh label (toJSON True)))
          assertBool "terminal admission refused" (isLeft failed)
          journal <- Fixture.run env (W.loadStepIndex name fresh 0)
          Map.lookup "ingest" journal @?= Nothing
          Map.lookup W.patchSetStepName journal @?= Nothing
    ]
  where
    name = W.WorkflowName "native-input-spec"
    fresh = W.WorkflowId "fresh-native-input"
    old = W.WorkflowId "old-native-input"
    label = W.StepName "ingest"
    added = W.PatchId "shikigami-worker-objective-children-v1"

module Shikigami.ObjectiveSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text qualified
import Data.Time (UTCTime (..), fromGregorian)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Execution.Identity (ExecutionRootId (..))
import Shikigami.Objective.Acceptance
import Shikigami.Objective.Command
import Shikigami.Objective.Types
import Shikigami.Prelude hiding ((.=))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "Objectives"
    [ testCase "bounded graphs reject cycles, duplicates and dangling dependencies" do
        validateGraph [draft "a" [], draft "b" [ObjectiveAssignmentId "a"]] @?= Right ()
        mapM_
          (assertBool "graph refused" . either (const True) (const False) . validateGraph)
          [[draft "a" [ObjectiveAssignmentId "b"], draft "b" [ObjectiveAssignmentId "a"]], [draft "a" [ObjectiveAssignmentId "missing"]], [draft "a" [], draft "a" []]],
      testCase "dense acyclic graph stays bounded and validates" do
        validateGraph [draft (showText n) [ObjectiveAssignmentId (showText p) | p <- [1 .. n - 1]] | n <- [1 .. 128 :: Int]] @?= Right (),
      testCase "internal checkpoint and transfer tags are absent from public JSON" do
        forM_ ["IngestCheckpoint", "TransferOwnership"] \tag ->
          assertBool "private command refused" (case Aeson.fromJSON (Aeson.object ["tag" .= (tag :: Text)]) :: Aeson.Result Command of Aeson.Error _ -> True; _ -> False),
      testCase "criteria require unique, nonempty structured keys" do
        validateCriteria [Criterion "build" "build passes" Automatic False] @?= Right ()
        assertBool "empty criteria refused" (validateCriteria [] /= Right ())
        assertBool "duplicate criteria refused" (validateCriteria [criterion, criterion] /= Right ()),
      testCase "acceptance rejects stale instructions, missing journey and child success alone" do
        validateAcceptance objective proposal @?= Right ()
        validateAcceptance (objective & #instructionsRevision .~ 1) proposal @?= Left ObjectiveConflict
        validateAcceptance (objective & #evidence .~ []) proposal @?= Left ObjectiveInvalidEvidence
        validateAcceptance (objective & #assignments .~ [assignment & #instructionsRevision .~ 2]) proposal @?= Left ObjectiveInvalidEvidence
        validateAcceptance (objective & #evidence .~ [evidence & #verification .~ EvidenceVerification CheckFailed (Just "human") False]) proposal @?= Left ObjectiveInvalidEvidence
        validateAcceptance (objective & #criteria .~ [criterion & #journeyRequired .~ True]) proposal @?= Left ObjectiveInvalidEvidence
    ]
  where
    criterion = Criterion "human" "integrated user journey" HumanVerifiable False
    actor = VerifiedCaller "fixture"
    proposal = CompletionProposal 0 0 0 ["artifact"] ["check"] []
    assignment = Assignment (draft "a" [] & #state .~ Done) 0 0 0 []
    evidence = Evidence (Attestation "check" "human" "artifact" "reviewed" False) (EvidenceVerification CheckPassed (Just "human") False) (ObjectiveAssignmentId "a") (assignmentMeaning assignment) actor 0 0 0
    objective = Objective (ObjectiveId "fixture") actor [Member actor [Owner]] "title" "goal" "instructions" 1 0 0 [criterion] Open [assignment] [evidence] [] [] [] [] [] (Just (proposal, actor)) Nothing

draft :: Text -> [ObjectiveAssignmentId] -> AssignmentDraft
draft key dependencies = AssignmentDraft (ObjectiveAssignmentId key) "work" dependencies (compatibilityIdentity "worker") Pending Nothing (Just (ExecutionRootId "root")) (Just (UTCTime (fromGregorian 2027 1 1) 0))

showText :: Int -> Text
showText = Data.Text.pack . show

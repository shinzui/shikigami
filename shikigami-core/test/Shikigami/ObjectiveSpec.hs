{-# LANGUAGE DataKinds #-}

module Shikigami.ObjectiveSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text qualified
import Data.Time (UTCTime (..), fromGregorian)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Fixture.ExecutionIdentity (fixtureRootId)
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
    [ testCase "objective identity admits only its canonical TypeID-v7 domain" do
        let canonical = "shikigami_objective_01h455vb4pex5vsknk084sn02q"
        identifier <- either (assertFailure . show) pure (parseObjectiveId canonical)
        objectiveIdText identifier @?= canonical
        Aeson.toJSON identifier @?= Aeson.String canonical
        mapM_
          (assertBool "invalid objective identity refused" . either (const True) (const False) . parseObjectiveId)
          ["", "objective-digest", "shikigami_run_evidence_01h455vb4pex5vsknk084sn02q", "SHIKIGAMI_OBJECTIVE_01h455vb4pex5vsknk084sn02q", "shikigami_objective_0000000000a000000000000000"],
      testCase "objective locators validate at admission and retain their wire codecs" do
        Aeson.toJSON (criterionKey "build") @?= Aeson.String "build"
        Aeson.toJSON (evidenceKey "check") @?= Aeson.String "check"
        Aeson.encode (objectiveAssignment "a") @?= "{\"value\":\"a\"}"
        Aeson.toJSON (artifact "artifact") @?= Aeson.String "artifact"
        forM_ ["", "space key", Data.Text.replicate 257 "x"] \invalid -> do
          assertBool "criterion admission refused" (either (const True) (const False) (parseCriterionKey invalid))
          assertBool "evidence admission refused" (either (const True) (const False) (parseEvidenceKey invalid))
          assertBool "assignment admission refused" (either (const True) (const False) (parseObjectiveAssignmentId invalid))
          assertBool "artifact admission refused" (either (const True) (const False) (parseArtifactRef invalid))
          assertBool "criterion JSON refused" (case Aeson.fromJSON (Aeson.String invalid) :: Aeson.Result CriterionKey of Aeson.Error _ -> True; _ -> False)
          assertBool "evidence JSON refused" (case Aeson.fromJSON (Aeson.String invalid) :: Aeson.Result EvidenceKey of Aeson.Error _ -> True; _ -> False),
      testCase "revision admission is nonnegative and preserves numeric JSON" do
        let value = revision 7 :: StateRevision "objective"
        revisionNumber initialRevision @?= 0
        revisionNumber (advanceRevision value) @?= 8
        previousRevision initialRevision @?= (Nothing :: Maybe (StateRevision "objective"))
        previousRevision (advanceRevision value) @?= Just value
        Aeson.toJSON value @?= Aeson.toJSON (7 :: Integer)
        Aeson.encode value @?= Aeson.encode (7 :: Integer)
        Aeson.fromJSON (Aeson.toJSON value) @?= Aeson.Success value
        assertBool "negative revision refused" (case Aeson.fromJSON (Aeson.toJSON (-1 :: Integer)) :: Aeson.Result (StateRevision "objective") of Aeson.Error _ -> True; _ -> False),
      testCase "protected objective prose keeps its string codec and construction bounds" do
        Aeson.encode (title "title") @?= Aeson.encode ("title" :: Text)
        Aeson.encode (instructions "") @?= Aeson.encode ("" :: Text)
        forM_
          [ either (const True) (const False) (parseTitle ""),
            either (const True) (const False) (parseGoal ""),
            either (const True) (const False) (parseInstructions (Data.Text.replicate 32769 "x")),
            either (const True) (const False) (parseAttestationStatement "")
          ]
          (assertBool "invalid content refused before domain construction")
        assertBool "protected text is not a Show diagnostic" (not ("PRIVATE_INSTRUCTIONS_SENTINEL" `Data.Text.isInfixOf` Data.Text.pack (show (instructions "PRIVATE_INSTRUCTIONS_SENTINEL")))),
      testCase "bounded graphs reject cycles, duplicates and dangling dependencies" do
        validateGraph [draft "a" [], draft "b" [objectiveAssignment "a"]] @?= Right ()
        mapM_
          (assertBool "graph refused" . either (const True) (const False) . validateGraph)
          [[draft "a" [objectiveAssignment "b"], draft "b" [objectiveAssignment "a"]], [draft "a" [objectiveAssignment "missing"]], [draft "a" [], draft "a" []]],
      testCase "dense acyclic graph stays bounded and validates" do
        validateGraph [draft (showText n) [objectiveAssignment (showText p) | p <- [1 .. n - 1]] | n <- [1 .. 128 :: Int]] @?= Right (),
      testCase "internal checkpoint and transfer tags are absent from public JSON" do
        forM_ ["IngestCheckpoint", "TransferOwnership"] \tag ->
          assertBool "private command refused" (case Aeson.fromJSON (Aeson.object ["tag" .= (tag :: Text)]) :: Aeson.Result Command of Aeson.Error _ -> True; _ -> False),
      testCase "criteria require unique, nonempty structured keys" do
        validateCriteria [Criterion (criterionKey "build") (description "build passes") Automatic False] @?= Right ()
        assertBool "empty criteria refused" (validateCriteria [] /= Right ())
        assertBool "duplicate criteria refused" (validateCriteria [criterion, criterion] /= Right ()),
      testCase "acceptance rejects stale instructions, missing journey and child success alone" do
        validateAcceptance objective proposal @?= Right ()
        validateAcceptance (objective & #instructionsRevision .~ revision 1) proposal @?= Left ObjectiveConflict
        validateAcceptance (objective & #evidence .~ []) proposal @?= Left ObjectiveInvalidEvidence
        validateAcceptance (objective & #assignments .~ [assignment & #instructionsRevision .~ revision 2]) proposal @?= Left ObjectiveInvalidEvidence
        validateAcceptance (objective & #evidence .~ [evidence & #verification .~ EvidenceVerification CheckFailed (Just (criterionKey "human")) False]) proposal @?= Left ObjectiveInvalidEvidence
        validateAcceptance (objective & #criteria .~ [criterion & #journeyRequired .~ True]) proposal @?= Left ObjectiveInvalidEvidence
    ]
  where
    criterion = Criterion (criterionKey "human") (description "integrated user journey") HumanVerifiable False
    actor = VerifiedCaller "fixture"
    proposal = CompletionProposal (revision 0) (revision 0) (revision 0) [artifact "artifact"] [evidenceKey "check"] []
    assignment = Assignment (draft "a" [] & #state .~ Done) initialRevision initialRevision initialRevision []
    evidence = Evidence (Attestation (evidenceKey "check") (criterionKey "human") (artifact "artifact") (statement "reviewed") False) (EvidenceVerification CheckPassed (Just (criterionKey "human")) False) (objectiveAssignment "a") (assignmentMeaning assignment) actor initialRevision initialRevision initialRevision
    objective = Objective (either (error . show) id (parseObjectiveId "shikigami_objective_01h455vb4pex5vsknk084sn02q")) actor [Member actor [Owner]] (title "title") (goal "goal") (instructions "instructions") (revision 1) initialRevision initialRevision [criterion] Open [assignment] [evidence] [] [] [] [] [] (Just (proposal, actor)) Nothing

draft :: Text -> [ObjectiveAssignmentId] -> AssignmentDraft
draft key dependencies = AssignmentDraft (objectiveAssignment key) (instructions "work") dependencies (compatibilityIdentity (fixtureAgentName "worker")) Pending Nothing (Just (fixtureRootId "root")) (Just (UTCTime (fromGregorian 2027 1 1) 0))

showText :: Int -> Text
showText = Data.Text.pack . show

criterionKey :: Text -> CriterionKey
criterionKey = either (error . show) id . parseCriterionKey

evidenceKey :: Text -> EvidenceKey
evidenceKey = either (error . show) id . parseEvidenceKey

revision :: Integer -> StateRevision scope
revision = either (error . show) id . parseRevision

objectiveAssignment :: Text -> ObjectiveAssignmentId
objectiveAssignment = either (error . show) id . parseObjectiveAssignmentId

artifact :: Text -> ArtifactRef
artifact = either (error . show) id . parseArtifactRef

title :: Text -> Title
title = either (error . show) id . parseTitle

goal :: Text -> Goal
goal = either (error . show) id . parseGoal

instructions :: Text -> Instructions
instructions = either (error . show) id . parseInstructions

description :: Text -> CriterionDescription
description = either (error . show) id . parseCriterionDescription

statement :: Text -> AttestationStatement
statement = either (error . show) id . parseAttestationStatement

nextAction :: Text -> NextAction
nextAction = either (error . show) id . parseNextAction

limitation :: Text -> CompletionLimitation
limitation = either (error . show) id . parseCompletionLimitation

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

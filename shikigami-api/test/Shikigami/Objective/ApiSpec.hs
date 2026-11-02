module Shikigami.Objective.ApiSpec (tests) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.OpenApi (validateToJSON)
import Shikigami.Execution.Identity (parseOperationId)
import Shikigami.Objective.Api
import Shikigami.Objective.Command
import Shikigami.Objective.Types
import Shikigami.Prelude hiding ((.=))
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "objective wire contract"
    [ testCase "create envelope has a required version and rejects authority fields" do
        Aeson.eitherDecode (Aeson.encode creation) @?= Right creation
        validateToJSON creation @?= []
        forM_ [remove "format", replace "format" (Aeson.Number 2), replace "actor" (Aeson.String "forged")] \change -> assertBool "invalid creation envelope refused" (isLeft (resultEither (Aeson.fromJSON (change (toJSON creation)) :: Aeson.Result ObjectiveCreate))),
      testCase "all public command shapes match the closed schema and roundtrip" do
        forM_ commands \value -> do
          let envelope = ObjectiveCommand operation initialRevision value
          Aeson.eitherDecode (Aeson.encode envelope) @?= Right envelope
          validateToJSON envelope @?= [],
      testCase "internal command tags and model-supplied envelope authority cannot decode" do
        let document = toJSON (ObjectiveCommand operation initialRevision AcceptCompletion)
        forM_ [remove "format", replace "format" Aeson.Null, replace "identity" (Aeson.String "forged"), replace "command" (Aeson.object ["tag" .= ("TransferSessionOwnership" :: Text)])] \change -> assertBool "invalid command refused" (isLeft (resultEither (Aeson.fromJSON (change document) :: Aeson.Result ObjectiveCommand)))
    ]
  where
    operation = checked parseOperationId "wire-contract"
    creation = ObjectiveCreate operation (CreateRequest (checked parseTitle "deliver") (checked parseGoal "goal") (checked parseInstructions "protected") [criterion] [])
    criterion = Criterion (checked parseCriterionKey "review") (checked parseCriterionDescription "review the result") HumanVerifiable JourneyOptional
    assignment = checked parseObjectiveAssignmentId "work"
    commands = [ReviseInstructions (checked parseInstructions "new"), ReviseCriteria [criterion], SetAssignments [], RecordProgress assignment Working [] [], RecordEvidence assignment (Attestation (checked parseEvidenceKey "human-review") criterion.key (checked parseArtifactRef "artifact") (checked parseAttestationStatement "reviewed") NoJourney), SetNextAction [], SetBlocked IsBlocked, ProposeCompletion (CompletionProposal initialRevision initialRevision initialRevision [] [] []), AcceptCompletion, CancelObjective, GrantMember (VerifiedCaller (checked parseCallerId "caller")) [Reader], RevokeMember (VerifiedCaller (checked parseCallerId "caller")), BindConversation (checked parseConversationRef "conversation"), LinkExternal (ExecPlan (execPlanRef "docs/plans/example.md"))]

checked parser = either (error . show) id . parser

remove field (Aeson.Object fields) = Aeson.Object (KeyMap.delete field fields)
remove _ value = value

replace field value (Aeson.Object fields) = Aeson.Object (KeyMap.insert field value fields)
replace _ _ value = value

resultEither (Aeson.Error message) = Left message
resultEither (Aeson.Success value) = Right value

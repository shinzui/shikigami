{-# LANGUAGE DataKinds #-}

-- | The one objective unrequested work may become. Acceptance and admission share
-- it, so an admitted objective says what a person would have approved: it stops at
-- a reviewable artifact and forbids publication, and it links back to its source.
module Shikigami.Initiative.Template
  ( objectiveRequest,
    instructionsFor,
    actionClassInstructions,
    retainedArtifactCriterion,
    deliverAssignment,
    admissionRequest,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Activity.Coordinate (activityCoordinate, activityCoordinateText)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Initiative.Types
import Shikigami.Objective.Keys (ObservedSource (..))
import Shikigami.Objective.Types

-- | Model-authored text reaches only the goal and the human-verifiable criteria.
-- It is untrusted description, and a person or a retained artifact judges it.
objectiveRequest :: AgentName -> ProposalView -> Either Text CreateRequest
objectiveRequest agent view = do
  proposal <- parseProposalId view.proposalId
  actionClass <- parseActionClass view.assessment.actionClass
  title <- parseTitle ("Unrequested: " <> Text.take 480 view.assessment.outcome)
  goal <- parseGoal view.assessment.outcome
  instructions <- parseInstructions (instructionsFor agent view actionClass)
  stated <- traverse statedCriterion (zip [1 :: Int ..] (take 8 view.assessment.criteria))
  artifact <- retainedArtifactCriterion
  pure
    CreateRequest
      { title,
        goal,
        instructions,
        criteria = stated <> [artifact],
        external = [UnrequestedProposal (proposalRefFor proposal) (sourceOf view)]
      }
  where
    statedCriterion (position, text) = do
      key <- parseCriterionKey ("stated-" <> Text.pack (show position))
      description <- first (const "criterion is out of bounds") (parseCriterionDescription text)
      pure (Criterion key description HumanVerifiable JourneyOptional)

retainedArtifactCriterion :: Either Text Criterion
retainedArtifactCriterion = do
  key <- parseCriterionKey "retained-artifact"
  description <- parseCriterionDescription "The result is a reviewable artifact retained in the workspace, identified by an artifact reference. Nothing was published."
  pure (Criterion key description Automatic JourneyOptional)

-- | The single assignment an admitted objective is staffed with.
deliverAssignment :: ObjectiveAssignmentId
deliverAssignment = either (error . Text.unpack) id (parseObjectiveAssignmentId "deliver")

-- | What the coordinator is asked to do: the same words a person would approve,
-- with coordinates only.
admissionRequest :: AgentName -> ProposalView -> ObjectiveId -> Value
admissionRequest agent view objective =
  object
    [ "proposal" .= view.proposalId,
      "objective" .= objective,
      "actionClass" .= view.assessment.actionClass,
      "instructions" .= either (const "") (instructionsFor agent view) (parseActionClass view.assessment.actionClass)
    ]

sourceOf :: ProposalView -> ObservedSource
sourceOf view =
  ObservedSource
    { source = activityCoordinate view.source,
      subjectKind = activityCoordinate view.subjectKind,
      subjectId = activityCoordinate view.subjectId
    }

actionClassInstructions :: ActionClass -> Text
actionClassInstructions = \case
  ReproduceAndDiagnose -> "Reproduce and diagnose; do not change code beyond a failing test."
  DraftFix -> "Draft a fix in an isolated workspace; do not publish, push or open a pull request."
  DraftDocumentation -> "Draft documentation in an isolated workspace; do not publish."

instructionsFor :: AgentName -> ProposalView -> ActionClass -> Text
instructionsFor agent view actionClass =
  Text.intercalate
    "\n"
    ( [ "Agent " <> agentNameText agent <> " proposed this work from observed activity; nobody requested it.",
        "Proposal: " <> view.proposalId,
        "Observed source: " <> view.source <> " / " <> view.subjectKind <> " / " <> view.subjectId,
        "Repository: " <> view.assessment.repository,
        actionClassInstructions actionClass,
        "The result must end at a reviewable artifact retained in the workspace. Nothing is merged, deployed or published."
      ]
        <> map evidenceLine view.assessment.evidence
    )
  where
    evidenceLine evidence =
      "Evidence: " <> activityCoordinateText evidence.activity <> " in " <> activityCoordinateText evidence.subject.subjectId

-- | Bounded public metadata. Instructions and retained output stay protected.
module Shikigami.Objective.Inspection where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Shikigami.Agent.Principal (identityText)
import Shikigami.Coordination.Proposal qualified as Adaptive
import Shikigami.Execution.Identity (executionRootIdText, operationIdText)
import Shikigami.Execution.Payload (payloadDigestText)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.Transcript (PayloadRef (..))
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.WorkerSession.Types qualified as WS

-- Receipts commit the complete protected body; history exposes attribution only.
data HistoryEntry = HistoryEntry {receipt :: !Receipt, actor :: !AccessPrincipal, command :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CriterionView = CriterionView {key :: !Text, description :: !Text, kind :: !Text, journeyRequired :: !Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AssignmentView = AssignmentView {assignmentId :: !Text, owner :: !Text, state :: !Text, revision :: !Integer, ownerEpoch :: !Integer, rootId :: !(Maybe Text), cutoff :: !(Maybe UTCTime)}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data EvidenceView = EvidenceView {key :: !Text, assignmentId :: !Text, criterion :: !Text, artifact :: !Text, disposition :: !Text, recordedBy :: !Text, revision :: !Integer}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ReportedResultView = ReportedResultView {assignmentId :: !Text, operationId :: !Text, digest :: !Text, artifacts :: ![Text]}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data PlacementView = PlacementView
  {assignmentId :: !Text, target :: !Text, parent :: !(Maybe Text), dependencies :: ![Text], sessionId :: !(Maybe Text)}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AdaptiveDecisionView = AdaptiveDecisionView
  { operationId :: !Text,
    checkpointRevision :: !Integer,
    validator :: !Text,
    rationale :: !Text,
    friction :: !(Maybe Text),
    expectedBenefit :: !Text,
    laterEvidence :: !Text,
    changes :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ResourceView = ResourceView {rootId :: !Text, state :: !Resources.Root}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AdaptiveObservationView = AdaptiveObservationView {operationId :: !Text, kind :: !Text, revision :: !Integer, status :: !Text, refusal :: !(Maybe Text)}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AdaptiveView = AdaptiveView
  {graph :: ![PlacementView], decisions :: ![AdaptiveDecisionView], resources :: ![ResourceView], observations :: ![AdaptiveObservationView], next :: !(Maybe Int)}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

decisionView :: Adaptive.AcceptedDecision -> AdaptiveDecisionView
decisionView value = AdaptiveDecisionView (operationIdText proposal.operationId) (revisionNumber proposal.checkpointRevision) value.validatorVersion (criterionDescriptionText proposal.rationale) (criterionDescriptionText <$> proposal.friction) (criterionDescriptionText proposal.expectedBenefit) (evidenceKeyText proposal.laterEvidence) (map changeTag proposal.changes)
  where
    proposal = value.proposal
    changeTag = \case
      Adaptive.DirectWork {} -> "DirectWork"
      Adaptive.CreateAssignment {} -> "CreateAssignment"
      Adaptive.NarrowAssignment {} -> "NarrowAssignment"
      Adaptive.SplitAssignment {} -> "SplitAssignment"
      Adaptive.ConsolidateAssignments {} -> "ConsolidateAssignments"
      Adaptive.FollowUpContext {} -> "FollowUpContext"
      Adaptive.TransferAssignment {} -> "TransferAssignment"
      Adaptive.EscalateModel {} -> "EscalateModel"
      Adaptive.ChangeConcurrency {} -> "ChangeConcurrency"
      Adaptive.IntegrateResult {} -> "IntegrateResult"
      Adaptive.AwaitAssignments {} -> "AwaitAssignments"
      Adaptive.ProposeCompletion {} -> "ProposeCompletion"

data ObjectiveView = ObjectiveView
  { objectiveId :: !Text,
    title :: !Text,
    goal :: !Text,
    status :: !Text,
    revision :: !Integer,
    instructionsRevision :: !Integer,
    criteriaRevision :: !Integer,
    assignmentCount :: !Int,
    evidenceCount :: !Int,
    unresolvedCount :: !Int,
    criteria :: ![CriterionView],
    assignments :: ![AssignmentView],
    evidence :: ![EvidenceView],
    reportedResults :: ![ReportedResultView],
    nextActions :: ![Text],
    next :: !(Maybe Int),
    adaptive :: !(Maybe AdaptiveView)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON ObjectiveView where
  parseJSON = Aeson.withObject "ObjectiveView" \fields ->
    Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object (if KeyMap.member "adaptive" fields then fields else KeyMap.insert "adaptive" Aeson.Null fields))

objectiveView :: Objective -> ObjectiveView
objectiveView = objectiveViewPage 0 20

-- Each page belongs to the returned objective revision. A caller that observes
-- a different revision starts over; offsets never select protected payloads.
objectiveViewPage :: Int -> Int -> Objective -> ObjectiveView
objectiveViewPage after limit objective =
  ObjectiveView
    { objectiveId = objectiveIdText objective.objectiveId,
      title = titleText objective.title,
      goal = goalText objective.goal,
      status = case objective.status of Open -> "Open"; Blocked -> "Blocked"; Completed -> "Completed"; Cancelled -> "Cancelled",
      revision = revisionNumber objective.revision,
      instructionsRevision = revisionNumber objective.instructionsRevision,
      criteriaRevision = revisionNumber objective.criteriaRevision,
      assignmentCount = length objective.assignments,
      evidenceCount = length objective.evidence,
      unresolvedCount = length objective.unresolved,
      criteria = map criterionView (page objective.criteria),
      assignments = map assignmentView (page objective.assignments),
      evidence = map evidenceView (page objective.evidence),
      reportedResults = map resultView (page objective.reportedResults),
      nextActions = map nextActionText (page objective.nextActions),
      adaptive = Nothing,
      next = if any (> after + limit) [length objective.criteria, length objective.assignments, length objective.evidence, length objective.reportedResults, length objective.nextActions] then Just (after + limit) else Nothing
    }
  where
    page :: [a] -> [a]
    page values = take limit (drop after values)
    criterionView :: Criterion -> CriterionView
    criterionView value = CriterionView (criterionKeyText value.key) (criterionDescriptionText value.description) (case value.kind of Automatic -> "Automatic"; HumanVerifiable -> "HumanVerifiable") (value.journeyRequired == JourneyRequired)
    assignmentView :: Assignment -> AssignmentView
    assignmentView value = AssignmentView (objectiveAssignmentIdText value.definition.assignmentId) (either (const "unavailable") id (identityText value.definition.owner)) (case value.definition.state of Pending -> "Pending"; Working -> "Working"; Done -> "Done"; Withdrawn -> "Withdrawn") (revisionNumber value.revision) (revisionNumber value.ownerEpoch) (executionRootIdText <$> value.definition.rootId) value.definition.cutoff
    evidenceView :: Evidence -> EvidenceView
    evidenceView value = EvidenceView (evidenceKeyText value.input.key) (objectiveAssignmentIdText value.assignmentId) (criterionKeyText value.input.criterion) (artifactRefText (case value.input of Attestation {artifact} -> artifact; ResultEvidence {result} -> result.artifact)) (case value.verification.disposition of CheckPassed -> "CheckPassed"; CheckFailed -> "CheckFailed"; ResultObserved -> "ResultObserved") (principalText value.recordedBy) (revisionNumber value.revision)
    resultView :: ReportedResult -> ReportedResultView
    resultView value = ReportedResultView (objectiveAssignmentIdText value.assignmentId) (operationIdText value.receipt.operationId) (payloadDigestText value.receipt.output.digest) (map artifactRefText value.artifacts)
    principalText = \case
      VerifiedCaller value -> "caller:" <> callerIdText value
      LocalOperator value -> "operator:" <> operatorIdText value
      RecordedAgent value -> "agent:" <> either (const "unavailable") id (identityText value)

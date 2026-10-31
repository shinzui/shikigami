-- | Completion is an explicit acceptance of integrated artifacts. Child success
-- alone supplies no criterion checks or approving authority.
module Shikigami.Objective.Acceptance (validateAcceptance, validateGraph, validateCriteria, evidenceArtifact, assignmentMeaning) where

import Data.List (find, nub)
import Data.Text qualified as Text
import Shikigami.Agent.Principal (identityText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Objective.Types
import Shikigami.Prelude

validateCriteria :: [Criterion] -> Either ObjectiveError ()
validateCriteria criteria = do
  unless (not (null criteria) && length criteria <= 64 && length (nub (map (.key) criteria)) == length criteria) (Left (ObjectiveInvalid "criteria must have distinct keys and contain 1..64 items"))
  forM_ criteria \item -> unless (not (Text.null item.description) && Text.length item.description <= 4096) (Left (ObjectiveInvalid "invalid criterion"))

validateGraph :: [AssignmentDraft] -> Either ObjectiveError ()
validateGraph graph = do
  let keys = map (.assignmentId) graph
      invalid = Left (ObjectiveInvalid "invalid assignment graph")
  unless (length graph <= 128 && length (nub keys) == length keys) invalid
  forM_ graph \node -> do
    unless (validKey node.assignmentId.value && Text.length node.instructions <= 32768 && length node.dependencies <= 128 && length (nub node.dependencies) == length node.dependencies && all (`elem` keys) node.dependencies) invalid
    unless (either (const False) validKey (identityText node.owner)) invalid
    unless (isJust node.rootId == isJust node.cutoff && (isNothing node.sessionId || isJust node.rootId)) invalid
  unless (acyclic [] graph) invalid
  where
    acyclic _ [] = True
    acyclic visited remaining =
      let ready = filter (all (`elem` visited) . (.dependencies)) remaining
       in not (null ready) && acyclic (visited <> map (.assignmentId) ready) (filter (\a -> a.assignmentId `notElem` map (.assignmentId) ready) remaining)

evidenceArtifact :: EvidenceInput -> Text
evidenceArtifact = \case
  ResultEvidence {result} -> case result of WorkerResult {artifact} -> artifact; RetainedResult {artifact} -> artifact
  Attestation {artifact} -> artifact

assignmentMeaning :: Assignment -> Text
assignmentMeaning assignment = versionedDigest "shikigami.objective-assignment-meaning/1" (toJSON (assignment.instructionsRevision, assignment.definition.instructions, assignment.definition.dependencies, assignment.definition.owner, assignment.ownerEpoch, assignment.definition.rootId, assignment.definition.cutoff))

validateAcceptance :: Objective -> CompletionProposal -> Either ObjectiveError ()
validateAcceptance objective proposal = do
  unless (objective.status == Open && objective.revision == advanceRevision proposal.objectiveRevision && objective.instructionsRevision == proposal.instructionsRevision && objective.criteriaRevision == proposal.criteriaRevision) (Left ObjectiveConflict)
  unless (null objective.unresolved) (Left ObjectiveUnresolved)
  unless (not (null proposal.artifacts) && length proposal.artifacts <= 128 && all validKey proposal.artifacts && length (nub proposal.artifacts) == length proposal.artifacts && length proposal.checks <= 256 && length (nub proposal.checks) == length proposal.checks && length proposal.limitations <= 64 && all ((<= 4096) . Text.length) proposal.limitations) invalid
  forM_ objective.assignments \assignment -> do
    unless (assignment.definition.state `elem` [Done, Withdrawn]) invalid
    when (assignment.definition.state == Done) $
      forM_ assignment.definition.dependencies \dependency ->
        unless (any (\other -> other.definition.assignmentId == dependency && other.definition.state == Done) objective.assignments) invalid
  selected <- forM proposal.checks \key -> maybe invalid pure (find ((== key) . (.input.key)) objective.evidence)
  forM_ selected \evidence -> do
    assignment <- maybe invalid Right (find ((== evidence.assignmentId) . (.definition.assignmentId)) objective.assignments)
    unless (evidence.assignmentDigest == assignmentMeaning assignment) invalid
    unless (evidence.verification.disposition == CheckPassed && evidence.verification.criterion == Just evidence.input.criterion && evidence.instructionsRevision == objective.instructionsRevision && evidence.criteriaRevision == objective.criteriaRevision && evidenceArtifact evidence.input `elem` proposal.artifacts) invalid
  unless (all (\artifact -> any ((== artifact) . evidenceArtifact . (.input)) selected) proposal.artifacts) invalid
  forM_ objective.criteria \criterion -> do
    let checks = filter ((== criterion.key) . (.input.criterion)) selected
        correctKind evidence = case (criterion.kind, evidence.input) of
          (Automatic, ResultEvidence {}) -> True
          (HumanVerifiable, Attestation {}) -> True
          _ -> False
    unless (any correctKind checks && (not criterion.journeyRequired || any (\e -> correctKind e && e.input.journey && e.verification.journey) checks)) invalid
  where
    invalid = Left ObjectiveInvalidEvidence

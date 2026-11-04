{-# LANGUAGE DataKinds #-}

-- | Admission is a whole-proposal operation. Pure validation cannot dispatch,
-- reserve resources or grant a principal access to an objective.
module Shikigami.Coordination.Validate (validateProposal, checkpointDigest, initialArrangement, currentArrangement) where

import Control.Monad (foldM)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as Lazy
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.List (find, nub)
import Shikigami.Coordination.Proposal
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (operationIdWithPrefix)
import Shikigami.Execution.Request (ExecutionRequest (..))
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Objective.Acceptance (validateAcceptance, validateGraph)
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.WorkerSession.Capability (WorkerInstruction (..))

checkpointDigest :: Objective -> Text
checkpointDigest = versionedDigest "shikigami.adaptive-checkpoint/1" . toJSON

-- | Used only before an objective has a retained adaptive arrangement. Each
-- owner must have exactly one pinned name; guessing an ambiguous role refuses.
initialArrangement :: Policy -> Objective -> Either ObjectiveError [Placement]
initialArrangement policy objective = forM objective.assignments \assignment -> do
  target <-
    if assignment.definition.owner == policy.identity
      then Right policy.coordinator
      else case [entry.name | entry <- policy.targets, entry.identity == assignment.definition.owner] of
        [name] -> Right name
        _ -> Left ObjectiveDenied
  pure (Placement assignment.definition target Nothing)

-- Current definitions and owners remain authoritative after operator edits or
-- fenced transfers. Retain only hierarchy edges from prior adaptive decisions.
currentArrangement :: Policy -> Maybe [Placement] -> Objective -> Either ObjectiveError [Placement]
currentArrangement policy retained objective = forM objective.assignments \assignment -> do
  let previous = find ((== assignment.definition.assignmentId) . (.assignment.assignmentId)) (fromMaybe [] retained)
      matches placement = (placement.target == policy.coordinator && assignment.definition.owner == policy.identity) || any (\target -> target.name == placement.target && target.identity == assignment.definition.owner) policy.targets
  case previous of
    Just placement | matches placement -> Right (placement {assignment = assignment.definition})
    _ -> do
      inferred <- initialArrangement policy (objective & #assignments .~ [assignment])
      case inferred of
        [placement] -> Right (placement {parent = previous >>= (.parent)})
        _ -> Left ObjectiveConflict

validateProposal :: UTCTime -> Policy -> [Placement] -> Objective -> Proposal -> Either ObjectiveError AcceptedDecision
validateProposal now policy prior objective proposal = do
  unless (policy.format == V1 && proposal.format == V1 && policy.maximumDepth >= 1 && policy.maximumDepth <= 16 && policy.maximumAssignments >= 1 && policy.maximumAssignments <= 128 && policy.maximumConcurrency >= 1 && policy.maximumConcurrency <= 128 && length policy.targets <= 128 && length (nub (map (.name) policy.targets)) == length policy.targets && all ((/= policy.coordinator) . (.name)) policy.targets) invalid
  unless (length policy.workspaces <= 128 && length (nub (map fst policy.workspaces)) == length policy.workspaces) invalid
  unless (objective.status == Open && now < policy.cutoff) (Left ObjectiveDenied)
  unless (proposal.objectiveId == objective.objectiveId && proposal.checkpointRevision == objective.revision && proposal.instructionsRevision == objective.instructionsRevision && proposal.criteriaRevision == objective.criteriaRevision) (Left ObjectiveConflict)
  unless (not (null proposal.changes) && length proposal.changes <= 32 && length proposal.evidence <= 128 && length (nub proposal.evidence) == length proposal.evidence && Lazy.length (encode proposal) <= 262144) invalid
  unless (all (\key -> any ((== key) . (.input.key)) objective.evidence) proposal.evidence) (Left ObjectiveInvalidEvidence)
  -- The prior hierarchy is retained by the adapter, while definitions always
  -- come from the current objective owner (including new revisions/fences).
  unless (length prior == length objective.assignments && length (nub (map (.assignment.assignmentId) prior)) == length prior && all (\placement -> any ((== placement.assignment.assignmentId) . (.definition.assignmentId)) objective.assignments) prior) (Left ObjectiveConflict)
  current <- forM prior \placement -> do
    assignment <- lookupAssignment placement.assignment.assignmentId
    let draft = assignment.definition
        bound =
          if placement.target == policy.coordinator && draft.owner == policy.identity && isNothing draft.rootId && isNothing draft.cutoff
            then draft & #rootId .~ Just policy.rootId & #cutoff .~ Just policy.cutoff
            else draft
    pure (placement {assignment = bound})
  arrangement <- foldM apply current proposal.changes
  validateGraph (map (.assignment) arrangement)
  unless (length arrangement <= policy.maximumAssignments) invalid
  forM_ arrangement \placement -> when (placement.assignment.state `notElem` [Done, Withdrawn]) do
    let draft = placement.assignment
    unless (all (\key -> any (\dependency -> dependency.assignment.assignmentId == key && dependency.assignment.state /= Withdrawn) arrangement) draft.dependencies) invalid
    unless (draft.rootId == Just policy.rootId && maybe False (\cutoff -> now < cutoff && cutoff <= policy.cutoff) draft.cutoff) (Left ObjectiveDenied)
    target <- targetFor placement.target draft.owner
    unless (any (\member -> member.principal == RecordedAgent draft.owner && any (`elem` member.roles) [Owner, Coordinator, Worker]) objective.members) (Left ObjectiveDenied)
    parentName <- case placement.parent of
      Nothing -> Right policy.coordinator
      Just key -> do
        parent <- maybe (Left ObjectiveMissing) Right (find ((== key) . (.assignment.assignmentId)) arrangement)
        unless (parent.assignment.state `notElem` [Done, Withdrawn]) invalid
        pure parent.target
    unless (placement.target == policy.coordinator && isNothing placement.parent || parentName `elem` target.parents) (Left ObjectiveDenied)
    depth arrangement [] [] placement >>= \value -> unless (value <= policy.maximumDepth) invalid
  let operations = zipWith (\ordinal change -> ExecutableOperation (operationIdWithPrefix ('a' :| "daptive:") (versionedDigest "shikigami.adaptive-operation/1" (toJSON (proposal.operationId, ordinal :: Int)))) change) [0 ..] proposal.changes
  pure (AcceptedDecision V1 "shikigami.adaptive-validator/3" policy proposal (checkpointDigest objective) arrangement operations)
  where
    invalid = Left (ObjectiveInvalid "invalid adaptive proposal")
    lookupAssignment key = maybe (Left ObjectiveMissing) Right (find ((== key) . (.definition.assignmentId)) objective.assignments)
    targetFor name identity
      | name == policy.coordinator && identity == policy.identity = Right (Target name identity [name] [])
      | otherwise = maybe (Left ObjectiveDenied) Right (find (\target -> target.name == name && target.identity == identity) policy.targets)
    active key = do
      assignment <- lookupAssignment key
      unless (assignment.definition.state `notElem` [Done, Withdrawn]) invalid
      pure assignment
    unfenced key = do
      assignment <- active key
      unless (isNothing assignment.definition.sessionId) (Left (ObjectiveInvalid "settle and fence a session before restructuring its assignment"))
    fresh graph placement = do
      unless (placement.assignment.assignmentId `notElem` map (.assignment.assignmentId) graph && placement.assignment.state == Pending && isNothing placement.assignment.sessionId) invalid
      pure (graph <> [placement])
    withdraw graph keys = do
      unless (not (null keys) && length (nub keys) == length keys) invalid
      traverse_ unfenced keys
      pure [if entry.assignment.assignmentId `elem` keys then entry {assignment = entry.assignment {state = Withdrawn}} else entry | entry <- graph]
    assignmentTarget key = do
      assignment <- active key
      placement <- maybe (Left ObjectiveMissing) Right (find ((== key) . (.assignment.assignmentId)) prior)
      targetFor placement.target assignment.definition.owner
    instruction key input = do
      assignment <- active key
      unless (input.objectiveRevision == objective.revision && input.assignmentRevision == assignment.revision && input.criteriaRevision == objective.criteriaRevision) (Left ObjectiveConflict)
      case input.selection of
        Nothing -> pure ()
        Just selection -> do
          target <- assignmentTarget key
          let aliases = maybe [] pure selection.alias <> fromMaybe [] selection.permittedAliases
          unless (not (null aliases) && all (`elem` target.models) aliases && selection.thinking == Nothing) (Left ObjectiveDenied)
    apply graph = \case
      CreateAssignment placement -> fresh graph placement
      NarrowAssignment key instructions -> do
        unfenced key
        pure [if entry.assignment.assignmentId == key then entry & #assignment . #instructions .~ instructions else entry | entry <- graph]
      SplitAssignment key placements -> do
        unless (length placements >= 2 && length placements <= 32) invalid
        withdrawn <- withdraw graph [key]
        foldM fresh withdrawn placements
      ConsolidateAssignments keys placement -> do
        unless (length keys >= 2 && length keys <= 32) invalid
        withdrawn <- withdraw graph keys
        fresh withdrawn placement
      DirectWork key input -> do
        assignment <- active key
        unless (assignment.definition.owner == policy.identity) (Left ObjectiveDenied)
        instruction key input
        pure graph
      FollowUpContext key input -> instruction key input >> pure graph
      TransferAssignment key name workspace -> do
        unless (length proposal.changes == 1) invalid
        assignment <- active key
        unless (lookup key policy.workspaces == Just workspace) (Left ObjectiveDenied)
        placement <- maybe (Left ObjectiveMissing) Right (find ((== key) . (.assignment.assignmentId)) prior)
        ancestors <- ancestorNames [] placement
        let permits target = target.name == name && name `notElem` ancestors && any (`elem` target.parents) (take 1 ancestors) && target.identity /= assignment.definition.owner && any (\member -> member.principal == RecordedAgent target.identity && any (`elem` member.roles) [Owner, Coordinator, Worker]) objective.members
        unless (isJust assignment.definition.sessionId && any permits policy.targets) (Left ObjectiveDenied)
        pure graph
      EscalateModel key model -> do
        target <- assignmentTarget key
        unless (model `elem` target.models) (Left ObjectiveDenied)
        pure graph
      ChangeConcurrency bound -> unless (bound >= 1 && bound <= policy.maximumConcurrency) invalid >> pure graph
      IntegrateResult key evidence -> do
        assignment <- lookupAssignment key
        unless (assignment.definition.state /= Withdrawn) invalid
        unless (any ((== evidence.criterion) . (.key)) objective.criteria) (Left ObjectiveInvalidEvidence)
        pure [if entry.assignment.assignmentId == key then entry {assignment = entry.assignment {state = Done}} else entry | entry <- graph]
      AwaitAssignments keys -> do
        unless (not (null keys) && length keys <= 128 && length (nub keys) == length keys) invalid
        traverse_ active keys
        pure graph
      ProposeCompletion acceptance -> do
        unless (length proposal.changes == 1) invalid
        let completion = completionProposal acceptance
        -- The owner's acceptance predicate expects the proposal revision plus
        -- the one atomic proposal write. We check the same exact evidence now.
        -- A sessionless coordinator assignment records responsibility for the
        -- finite delivery itself. Its completion is implied only by the same
        -- exact integrated acceptance predicate that all other work must pass.
        let completed =
              [ if entry.target == policy.coordinator && entry.assignment.owner == policy.identity && isNothing entry.assignment.sessionId
                  then entry {assignment = entry.assignment {state = Done}}
                  else entry
              | entry <- graph
              ]
            projected =
              objective
                & #assignments
                %~ map
                  ( \assignment -> case find ((== assignment.definition.assignmentId) . (.assignment.assignmentId)) completed of
                      Just placement -> assignment & #definition .~ placement.assignment
                      Nothing -> assignment
                  )
        validateAcceptance (projected & #revision .~ advanceRevision objective.revision) completion
        pure completed
    ancestorNames seen placement
      | placement.assignment.assignmentId `elem` seen = invalid
      | otherwise = case placement.parent of
          Nothing -> Right [policy.coordinator]
          Just key -> do
            parent <- maybe (Left ObjectiveMissing) Right (find ((== key) . (.assignment.assignmentId)) prior)
            (parent.target :) <$> ancestorNames (placement.assignment.assignmentId : seen) parent
    depth graph seen names placement
      | placement.assignment.assignmentId `elem` seen || placement.target `elem` names = invalid
      | otherwise = case placement.parent of
          Nothing -> Right 1
          Just key -> do
            parent <- maybe (Left ObjectiveMissing) Right (find ((== key) . (.assignment.assignmentId)) graph)
            (1 +) <$> depth graph (placement.assignment.assignmentId : seen) (placement.target : names) parent

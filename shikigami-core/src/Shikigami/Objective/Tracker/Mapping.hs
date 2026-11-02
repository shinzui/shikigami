{-# LANGUAGE DataKinds #-}

-- | Pure admission and mapping shared by deterministic and production adapters.
module Shikigami.Objective.Tracker.Mapping where

import Data.List (nub)
import Shikigami.Objective.Tracker.Config
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as O
import Shikigami.Prelude
import Shikigami.StateRevision

data ObservationDisposition = Advance | Duplicate | Older | Equivocation
  deriving stock (Eq, Show)

supportedMappingRevision :: MappingRevision
supportedMappingRevision = either (error . show) id (parseCoordinate "shikigami.tracker-mapping/1")

validatePolicy :: FieldPolicy -> Either TrackerError ()
validatePolicy policy = unless (policy.revision == supportedMappingRevision) (Left (TrackerInvalid "unsupported tracker mapping revision"))

validateObservation :: Capabilities -> ResourceScope -> TrackerObservation -> Either TrackerError ()
validateObservation capabilities scope observation = do
  unless (observation.scope == scope && capabilities.revision == scope.providerRevision) (Left TrackerDenied)
  unless (observation.digest == observationDigest observation.snapshot) (Left TrackerConflict)
  unless (case capabilities.observations of OrderedObservations -> isJust observation.position; UnorderedObservations -> isNothing observation.position) (Left (TrackerInvalid "observation position does not match provider capability"))

compareObservation :: TrackerObservation -> TrackerObservation -> Either TrackerError ObservationDisposition
compareObservation previous next
  | previous.scope /= next.scope = Left TrackerDenied
  | otherwise = case (previous.position, next.position) of
      (Just before, Just after)
        | after < before -> Right Older
        | after == before -> Right (if previous.digest == next.digest then Duplicate else Equivocation)
        | otherwise -> Right Advance
      (Nothing, Nothing) -> Right (if previous.digest == next.digest then Duplicate else Advance)
      _ -> Left TrackerConflict

admitBinding :: TrackerSettings -> O.AccessPrincipal -> Bool -> [TrackerBinding] -> TrackerBindingId -> ResourceScope -> FieldPolicy -> Capabilities -> TrackerObservation -> O.Objective -> Either TrackerError TrackerBinding
admitBinding settings actor objectivePermission existing identifier scope policy capabilities observation objective = do
  unless (objectivePermission && mayUseConnection settings actor scope) (Left TrackerDenied)
  connection <- connectionFor settings scope
  validatePolicy policy
  validateObservation capabilities scope observation
  unless (length existing < 64 && length (nub (map (.bindingId) existing)) == length existing) (Left TrackerConflict)
  unless (all ((/= identifier) . (.bindingId)) existing && all (\binding -> not (sameResource binding.scope scope) || binding.state == ReconciliationOnly) existing) (Left TrackerConflict)
  let active = filter (\binding -> binding.objectiveId == objective.objectiveId && binding.state /= ReconciliationOnly) existing
  unless (all (\binding -> not (policy.instructions == ProposeField && binding.policy.instructions == ProposeField) && not (policy.lifecycle == ProposeField && binding.policy.lifecycle == ProposeField)) active) (Left TrackerConflict)
  pure (TrackerBinding TrackerV1 identifier objective.objectiveId scope (connectionDigestFor connection) initialRevision policy Active actor observation observation objective.instructions objective.revision (summaryFor objective))

sameResource :: ResourceScope -> ResourceScope -> Bool
sameResource first second = first.connectionId == second.connectionId && first.incarnation == second.incarnation && first.resourceId == second.resourceId

-- Advances of a display field or an action echo merely advance the watermark.
-- Unordered providers still stage proposals; nothing imports automatically.
proposedChanges :: FieldPolicy -> TrackerObservation -> TrackerObservation -> [ProposedChange]
proposedChanges policy before after =
  [InstructionsChange after.snapshot.instructions | policy.instructions == ProposeField, before.snapshot.instructions /= after.snapshot.instructions]
    <> [LifecycleChange after.snapshot.lifecycle | policy.lifecycle == ProposeField, before.snapshot.lifecycle /= after.snapshot.lifecycle]

proposalIdentifier :: TrackerBinding -> TrackerObservation -> ProposedChange -> Either Text ProposalId
proposalIdentifier binding observation change = parseCoordinate (digestText (trackerDigest "shikigami.tracker-proposal/1" (toJSON (binding.bindingId, binding.revision, observation.digest, observation.position, change)) :: TrackerDigest "proposal-identity"))

stageProposals :: TrackerBinding -> TrackerObservation -> Either TrackerError (ObservationDisposition, [ImportProposal])
stageProposals binding observation = do
  disposition <- compareObservation binding.latest observation
  proposals <- case disposition of
    Advance -> forM (proposedChanges binding.policy binding.latest observation) \change -> do
      identifier <- either (Left . TrackerInvalid) pure (proposalIdentifier binding observation change)
      pure (ImportProposal TrackerV1 identifier binding.bindingId binding.revision observation binding.localBase binding.localRevision change AwaitingDecision)
    _ -> pure []
  pure (disposition, proposals)

validateDecision :: TrackerBinding -> ImportProposal -> O.Objective -> StateRevision "objective" -> Either TrackerError ()
validateDecision binding proposal objective expected = do
  unless (binding.state == Active && proposal.state == AwaitingDecision && proposal.bindingId == binding.bindingId && proposal.bindingRevision == binding.revision && objective.objectiveId == binding.objectiveId && proposal.observation == binding.latest && proposal.localBase == binding.localBase && proposal.localRevision == binding.localRevision) (Left TrackerConflict)
  unless (expected == objective.revision && objective.instructions == proposal.localBase) (Left TrackerConflict)
  unless (objective.status `elem` [O.Open, O.Blocked]) (Left TrackerConflict)

summaryFor :: O.Objective -> ProgressSummary
summaryFor objective = ProgressSummary objective.status (length objective.assignments) (length (filter ((== O.Done) . (.definition.state)) objective.assignments)) (length objective.evidence)

publicationIdentifier :: TrackerBinding -> O.Objective -> Either Text PublicationId
publicationIdentifier binding objective = parseCoordinate (digestText (trackerDigest "shikigami.tracker-publication-id/1" (toJSON (TrackerV1, binding.bindingId, binding.revision, binding.scope, binding.policy.revision, objective.objectiveId, objective.revision)) :: TrackerDigest "publication-identity"))

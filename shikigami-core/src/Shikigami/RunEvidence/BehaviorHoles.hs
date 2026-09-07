-- Consumer-owned behavioral witnesses. Created once; never overwritten.
--
-- Every state/command cell is exercised against one canonical history. The
-- generated requirement ledger supplies stable keys, while the cases below
-- remain hand-owned descriptions of how to reach each state and what each
-- command must do there.
module Shikigami.RunEvidence.BehaviorHoles (behaviorWitnesses) where

import Shikigami.Generated.Nominals (RunEvidenceId, parseRunEvidenceId)
import Shikigami.Prelude
import Shikigami.RunEvidence.Generated.BehaviorContract
import Shikigami.RunEvidence.Generated.Domain

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses = witness <$> behaviorRequirements

witness :: BehaviorRequirement -> BehaviorWitness
witness requirement =
  LiveWitness
    { key = requirement.key,
      history = historyFor requirement.source,
      command = commandFor requirement.commandName,
      expected = expectationFor requirement
    }

expectationFor :: BehaviorRequirement -> LiveExpectation
expectationFor BehaviorRequirement {kind, commandName, source} =
  case kind of
    LiveTransition -> Emits (eventFor commandName :| [])
    RequiredRejection -> Rejects (rejectionFor source)
    ReplayTransition -> error "RunEvidence has no replay-only behavior requirement"

rejectionFor :: RunEvidenceVertex -> RejectionClass
rejectionFor = \case
  RunEvidenceAttested -> RejectNoOutgoingEdges
  RunEvidenceNonConforming -> RejectNoOutgoingEdges
  RunEvidenceIncomplete -> RejectNoOutgoingEdges
  RunEvidenceFailed -> RejectNoOutgoingEdges
  _ -> RejectNoMatchingEdge

historyFor :: RunEvidenceVertex -> [RunEvidenceEvent]
historyFor = \case
  RunEvidenceRequested -> []
  RunEvidenceProfileResolved -> [profileBound]
  RunEvidenceRunning -> [profileBound, collectionStarted]
  RunEvidenceEvidenceSealed -> [profileBound, collectionStarted, evidenceSealed]
  RunEvidenceAttested -> [profileBound, collectionStarted, evidenceSealed, evidenceAttested]
  RunEvidenceNonConforming -> [profileBound, collectionStarted, evidenceNonConforming]
  RunEvidenceIncomplete -> [profileBound, collectionStarted, evidenceIncomplete]
  RunEvidenceFailed -> [profileBound, collectionStarted, evidenceFailed]

commandFor :: Text -> RunEvidenceCommand
commandFor = \case
  "BindProfile" -> BindProfile (BindProfileData fixtureId fixtureRunId)
  "StartCollection" -> StartCollection (StartCollectionData fixtureId fixtureRunId)
  "SealEvidence" -> SealEvidence (SealEvidenceData fixtureId fixtureRunId)
  "MarkAttested" -> MarkAttested (MarkAttestedData fixtureId fixtureRunId)
  "MarkNonConforming" -> MarkNonConforming (MarkNonConformingData fixtureId fixtureRunId)
  "MarkIncomplete" -> MarkIncomplete (MarkIncompleteData fixtureId fixtureRunId)
  "MarkFailed" -> MarkFailed (MarkFailedData fixtureId fixtureRunId)
  other -> error ("unknown RunEvidence command requirement: " <> show other)

eventFor :: Text -> RunEvidenceEvent
eventFor = \case
  "BindProfile" -> profileBound
  "StartCollection" -> collectionStarted
  "SealEvidence" -> evidenceSealed
  "MarkAttested" -> evidenceAttested
  "MarkNonConforming" -> evidenceNonConforming
  "MarkIncomplete" -> evidenceIncomplete
  "MarkFailed" -> evidenceFailed
  other -> error ("unknown RunEvidence event requirement: " <> show other)

profileBound :: RunEvidenceEvent
profileBound = ProfileBound (ProfileBoundData fixtureId fixtureRunId)

collectionStarted :: RunEvidenceEvent
collectionStarted = CollectionStarted (CollectionStartedData fixtureId fixtureRunId)

evidenceSealed :: RunEvidenceEvent
evidenceSealed = EvidenceSealed (EvidenceSealedData fixtureId fixtureRunId)

evidenceAttested :: RunEvidenceEvent
evidenceAttested = EvidenceAttested (EvidenceAttestedData fixtureId fixtureRunId)

evidenceNonConforming :: RunEvidenceEvent
evidenceNonConforming = EvidenceNonConforming (EvidenceNonConformingData fixtureId fixtureRunId)

evidenceIncomplete :: RunEvidenceEvent
evidenceIncomplete = EvidenceIncomplete (EvidenceIncompleteData fixtureId fixtureRunId)

evidenceFailed :: RunEvidenceEvent
evidenceFailed = EvidenceFailed (EvidenceFailedData fixtureId fixtureRunId)

fixtureId :: RunEvidenceId
fixtureId =
  either (error . show) id (parseRunEvidenceId "runevidence_01h455vb4pex5vsknk084sn02q")

fixtureRunId :: Text
fixtureRunId = "run-evidence-conformance"

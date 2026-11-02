{-# LANGUAGE DataKinds #-}

-- | Provider-neutral retained protocol, version 1. Credentials and provider
-- clients never enter these records. A source status is only an observation.
module Shikigami.Objective.Tracker.Types
  ( module Shikigami.Objective.Tracker.Types,
    module Shikigami.Objective.Tracker.Coordinate,
  )
where

import Data.Aeson qualified as Aeson
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Objective.Tracker.Coordinate
import Shikigami.Objective.Types (AccessPrincipal, Instructions, ObjectiveId, Status)
import Shikigami.Objective.Types qualified as O
import Shikigami.Prelude
import Shikigami.StateRevision

data ProtocolVersion = TrackerV1
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- No Boolean implies another capability. In particular ordered reads do not
-- promise conditional writes, and receipt lookup need not prove absence.
data Capabilities = Capabilities
  { revision :: !ProviderRevision,
    observations :: !ObservationOrdering,
    conditionalWrites :: !ConditionalWrites,
    idempotency :: !Idempotency,
    receiptLookup :: !ReceiptLookup
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ObservationOrdering = OrderedObservations | UnorderedObservations
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ConditionalWrites = ConditionalWrites | UnconditionalWrites
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Idempotency = NoIdempotency | ServerKeysUntil !UTCTime
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ReceiptLookup = NoReceiptLookup | LookupApplied | LookupAppliedAndSettledAbsence
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ResourceScope = ResourceScope
  { connectionId :: !TrackerConnectionId,
    incarnation :: !ConnectionIncarnation,
    resourceId :: !ResourceId,
    providerRevision :: !ProviderRevision
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON ResourceScope where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

data FieldPolicy = FieldPolicy
  { revision :: !MappingRevision,
    instructions :: !ImportPolicy,
    lifecycle :: !ImportPolicy,
    publication :: !PublicationPolicy
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON FieldPolicy where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

data ImportPolicy = IgnoreField | ProposeField
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data PublicationPolicy = NoPublication | ProgressSummaries
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data BindingState = Active | Paused | ReconciliationOnly
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data TrackerBinding = TrackerBinding
  { version :: !ProtocolVersion,
    bindingId :: !TrackerBindingId,
    objectiveId :: !ObjectiveId,
    scope :: !ResourceScope,
    connectionDigest :: !(TrackerDigest "connection-target"),
    revision :: !(StateRevision "tracker-binding"),
    policy :: !FieldPolicy,
    state :: !BindingState,
    admittedBy :: !AccessPrincipal,
    baseline :: !TrackerObservation,
    latest :: !TrackerObservation,
    localBase :: !Instructions,
    localRevision :: !(StateRevision "objective"),
    exportBase :: !ProgressSummary
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data RemoteLifecycle = RemoteOpen | RemotePlanned | RemoteCompleted | RemoteCancelled | RemoteMissing
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data TrackerObservation = TrackerObservation
  { version :: !ProtocolVersion,
    scope :: !ResourceScope,
    position :: !(Maybe (StateRevision "tracker-source")),
    digest :: !(TrackerDigest "observation"),
    snapshot :: !RemoteSnapshot
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Display text has the same protection/bounds as objective prose. It is not
-- a local objective title, nor an authorization principal.
data RemoteSnapshot = RemoteSnapshot
  { display :: !Instructions,
    instructions :: !Instructions,
    lifecycle :: !RemoteLifecycle
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

observationDigest :: RemoteSnapshot -> TrackerDigest "observation"
observationDigest = trackerDigest "shikigami.tracker-observation/1" . toJSON

data ProposedChange = InstructionsChange !Instructions | LifecycleChange !RemoteLifecycle
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ProposalState = AwaitingDecision | Applied | Declined | Superseded
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ImportProposal = ImportProposal
  { version :: !ProtocolVersion,
    proposalId :: !ProposalId,
    bindingId :: !TrackerBindingId,
    bindingRevision :: !(StateRevision "tracker-binding"),
    observation :: !TrackerObservation,
    localBase :: !Instructions,
    localRevision :: !(StateRevision "objective"),
    change :: !ProposedChange,
    state :: !ProposalState
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Only these allowlisted facts leave the objective transaction. This type has
-- no instructions, artifacts, decisions, credentials or model output field.
data ProgressSummary = ProgressSummary
  { status :: !Status,
    assignmentCount :: !Int,
    completedAssignmentCount :: !Int,
    evidenceCount :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data PublicationIntent = PublicationIntent
  { version :: !ProtocolVersion,
    publicationId :: !PublicationId,
    bindingId :: !TrackerBindingId,
    bindingRevision :: !(StateRevision "tracker-binding"),
    scope :: !ResourceScope,
    connectionDigest :: !(TrackerDigest "connection-target"),
    mappingRevision :: !MappingRevision,
    objectiveId :: !ObjectiveId,
    objectiveRevision :: !(StateRevision "objective"),
    occurredAt :: !UTCTime,
    summary :: !ProgressSummary,
    digest :: !(TrackerDigest "publication")
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Commit identity includes both the immutable destination and format. The
-- digest covers the complete request except its own digest field.
publicationDigest :: PublicationIntent -> TrackerDigest "publication"
publicationDigest intent = trackerDigest "shikigami.tracker-publication/1" (Aeson.toJSON (intent.version, intent.publicationId, intent.bindingId, intent.bindingRevision, intent.scope, intent.connectionDigest, intent.mappingRevision, intent.objectiveId, intent.objectiveRevision, intent.occurredAt, intent.summary))

-- Transport carries routing coordinates only. The executor resolves the exact
-- protected request and current authority from the owning stores.
data PublicationDispatch = PublicationDispatch
  { version :: !ProtocolVersion,
    objectiveId :: !ObjectiveId,
    bindingId :: !TrackerBindingId,
    publicationId :: !PublicationId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data DeliveryState = Pending | Attempting | Delivered | Rejected | Conflict | Unknown | Suppressed
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data EvidenceKind = ProviderProved | OperatorAttested
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data DeliveryEvidence = DeliveryEvidence
  { kind :: !EvidenceKind,
    remoteReceiptId :: !RemoteReceiptId,
    verification :: !VerifiedDelivery,
    actor :: !(Maybe AccessPrincipal),
    reason :: !(Maybe Instructions)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Created only after a provider read. The store additionally checks all fields
-- against the exact retained attempt and publication before accepting it.
data VerifiedDelivery = VerifiedDelivery
  { publicationId :: !PublicationId,
    attemptId :: !AttemptId,
    scope :: !ResourceScope,
    remoteReceiptId :: !RemoteReceiptId,
    digest :: !(TrackerDigest "publication")
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data PublicationAttempt = PublicationAttempt
  { attemptId :: !AttemptId,
    publicationId :: !PublicationId,
    bindingRevision :: !(StateRevision "tracker-binding"),
    capabilities :: !Capabilities,
    admittedAt :: !UTCTime,
    expiresAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data PublicationReceipt = PublicationReceipt
  { version :: !ProtocolVersion,
    publicationId :: !PublicationId,
    revision :: !(StateRevision "tracker-receipt"),
    state :: !DeliveryState,
    attempt :: !(Maybe PublicationAttempt),
    evidence :: !(Maybe DeliveryEvidence),
    suppression :: !(Maybe Instructions),
    claim :: !(Maybe AttemptClaim)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AttemptClaim = AttemptClaim
  { claimId :: !(TrackerCoordinate "attempt-claim"),
    expiresAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data TrackerError = TrackerDenied | TrackerMissing | TrackerConflict | TrackerUnavailable | TrackerInvalid !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CommandReceipt = CommandReceipt
  { version :: !ProtocolVersion,
    operationId :: !OperationId,
    actor :: !AccessPrincipal,
    fingerprint :: !(TrackerDigest "command"),
    result :: !CommandResult
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show CommandReceipt where show _ = "CommandReceipt <protected>"

data CommandResult
  = BindingResult !TrackerBinding
  | ProposalResult !ImportProposal
  | RejectedProposal !ImportProposal !Instructions
  | AppliedProposal !ProposalId !O.Receipt
  | PublicationResult !PublicationReceipt
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

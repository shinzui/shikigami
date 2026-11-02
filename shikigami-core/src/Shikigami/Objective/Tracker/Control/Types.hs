{-# LANGUAGE DataKinds #-}

module Shikigami.Objective.Tracker.Control.Types where

import Data.Aeson qualified as Aeson
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Objective.Tracker.Command (Command)
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types (AccessPrincipal, ObjectiveId)
import Shikigami.Prelude
import Shikigami.StateRevision

-- Trusted worker reads can retry; this protocol never requests a direct POST.
data ControlRequest
  = RunCommand !Command
  | Observe !TrackerBindingId !(StateRevision "tracker-binding")
  | Reconcile !PublicationId
  | Verify !PublicationId !RemoteReceiptId
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON ControlRequest where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

data ControlState = Queued | Running | Finished
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ControlRecord = ControlRecord
  { version :: !ProtocolVersion,
    objectiveId :: !ObjectiveId,
    operationId :: !OperationId,
    admissionId :: !(TrackerCoordinate "control-admission"),
    actor :: !AccessPrincipal,
    fingerprint :: !(TrackerDigest "control"),
    request :: !ControlRequest,
    target :: !(Maybe (ResourceScope, TrackerDigest "connection-target")),
    state :: !ControlState,
    claim :: !(Maybe (TrackerCoordinate "control-claim", UTCTime)),
    failure :: !(Maybe TrackerError)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ControlRecord where show _ = "ControlRecord <protected>"

data HistoryKind = Observations | Proposals | Publications
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data HistoryRecord = HistoryRecord {identity :: !Text, document :: !Aeson.Value}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

controlFingerprint :: ControlRecord -> TrackerDigest "control"
controlFingerprint record = trackerDigest "shikigami.tracker-control/1" (toJSON (record.version, record.objectiveId, record.operationId, record.actor, record.request, record.target))

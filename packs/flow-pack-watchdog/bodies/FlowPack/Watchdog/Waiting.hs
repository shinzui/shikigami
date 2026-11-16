{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}

-- | Separately bounded public Keiro reads. Only an exact approval-owner link
-- permits a timer lookup: generic timer or child-result scans are forbidden.
module FlowPack.Watchdog.Waiting
  ( WorkflowCoordinate (..),
    HeaderStatus (..),
    WorkflowObservation (..),
    ApprovalObservation (..),
    ApprovalPhase (..),
    WaitingPage (..),
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, withText, (.:), (.=))
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Shikigami.Agent.Approval (ReviewRequestId, approvalTimeoutKind, reviewRequestIdText)
import Prelude hiding (until)

data WorkflowCoordinate = WorkflowCoordinate {name :: !Text, identifier :: !Text}
  deriving stock (Eq, Ord, Show, Generic)

data HeaderStatus = HeaderRunning | HeaderSuspended | HeaderCompleted | HeaderCancelled | HeaderFailed | HeaderAbsent | HeaderUnavailable
  deriving stock (Eq, Show)

data WorkflowObservation = WorkflowObservation
  { workflow :: !WorkflowCoordinate,
    generation :: !(Maybe Int),
    status :: !HeaderStatus,
    observedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

data ApprovalPhase = ApprovalPending | ApprovalNoTimer | ApprovalTerminal | ApprovalParentInactive | ApprovalUnavailable
  deriving stock (Eq, Show)

data ApprovalObservation = ApprovalObservation
  { review :: !ReviewRequestId,
    parent :: !WorkflowCoordinate,
    until :: !(Maybe UTCTime),
    phase :: !ApprovalPhase,
    observedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

data WaitingPage = WaitingPage
  { workflows :: ![WorkflowObservation],
    approvals :: ![ApprovalObservation],
    unknownParents :: ![WorkflowCoordinate]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON WorkflowCoordinate where
  toJSON value = object ["name" .= value.name, "identifier" .= value.identifier]

instance FromJSON WorkflowCoordinate where
  parseJSON = withObject "WorkflowCoordinate" \fields -> WorkflowCoordinate <$> fields .: "name" <*> fields .: "identifier"

instance ToJSON WorkflowObservation where
  toJSON value = object ["workflow" .= value.workflow, "generation" .= value.generation, "status" .= value.status, "observedAt" .= value.observedAt]

instance FromJSON WorkflowObservation where
  parseJSON = withObject "WorkflowObservation" \fields -> WorkflowObservation <$> fields .: "workflow" <*> fields .: "generation" <*> fields .: "status" <*> fields .: "observedAt"

instance ToJSON ApprovalObservation where
  toJSON value = object ["review" .= value.review, "parent" .= value.parent, "until" .= value.until, "phase" .= value.phase, "observedAt" .= value.observedAt]

instance FromJSON ApprovalObservation where
  parseJSON = withObject "ApprovalObservation" \fields -> ApprovalObservation <$> fields .: "review" <*> fields .: "parent" <*> fields .: "until" <*> fields .: "phase" <*> fields .: "observedAt"

instance ToJSON WaitingPage where
  toJSON value = object ["workflows" .= value.workflows, "approvals" .= value.approvals, "unknownParents" .= value.unknownParents]

instance FromJSON WaitingPage where
  parseJSON = withObject "WaitingPage" \fields -> WaitingPage <$> fields .: "workflows" <*> fields .: "approvals" <*> fields .: "unknownParents"

instance ToJSON HeaderStatus where
  toJSON =
    toJSON . \case
      HeaderRunning -> ("running" :: Text)
      HeaderSuspended -> ("suspended" :: Text)
      HeaderCompleted -> ("completed" :: Text)
      HeaderCancelled -> ("cancelled" :: Text)
      HeaderFailed -> ("failed" :: Text)
      HeaderAbsent -> ("absent" :: Text)
      HeaderUnavailable -> ("unavailable" :: Text)

instance FromJSON HeaderStatus where
  parseJSON = withText "HeaderStatus" \case
    "running" -> pure HeaderRunning
    "suspended" -> pure HeaderSuspended
    "completed" -> pure HeaderCompleted
    "cancelled" -> pure HeaderCancelled
    "failed" -> pure HeaderFailed
    "absent" -> pure HeaderAbsent
    "unavailable" -> pure HeaderUnavailable
    _ -> fail "unknown workflow header status"

instance ToJSON ApprovalPhase where
  toJSON =
    toJSON . \case
      ApprovalPending -> ("pending" :: Text)
      ApprovalNoTimer -> "no-timer"
      ApprovalTerminal -> "terminal"
      ApprovalParentInactive -> "parent-inactive"
      ApprovalUnavailable -> "unavailable"

instance FromJSON ApprovalPhase where
  parseJSON = withText "ApprovalPhase" \case
    "pending" -> pure ApprovalPending
    "no-timer" -> pure ApprovalNoTimer
    "terminal" -> pure ApprovalTerminal
    "parent-inactive" -> pure ApprovalParentInactive
    "unavailable" -> pure ApprovalUnavailable
    _ -> fail "unknown approval phase"

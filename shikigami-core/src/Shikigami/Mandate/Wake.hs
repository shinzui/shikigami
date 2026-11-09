{-# LANGUAGE DataKinds #-}

module Shikigami.Mandate.Wake (timerKind, timerIdFor, request) where

import Data.Aeson (object, (.=))
import Data.UUID.V5 qualified as UUID
import Keiro.Timer (TimerId (..), TimerRequest (..))
import Keiro.Workflow (WorkflowId (..), WorkflowName (..))
import Shikigami.Coordination.Wake (Listener (..))
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Mandate.Types
import Shikigami.Prelude hiding ((.=))

timerKind :: Text
timerKind = "shikigami.mandate"

timerIdFor :: MandateId -> Listener -> TimerId
timerIdFor identifier listener = TimerId (UUID.generateNamed UUID.namespaceURL (nameBytes (versionedDigest "shikigami.mandate-timer/1" (toJSON (identifier, listener)))))

request :: Mandate -> Listener -> UTCTime -> TimerRequest
request state listener due = TimerRequest (timerIdFor state.admission.mandateId listener) listener.ownerName.unWorkflowName listener.ownerId.unWorkflowId due (object ["kind" .= timerKind, "mandateId" .= state.admission.mandateId, "revision" .= state.revision, "listener" .= listener])

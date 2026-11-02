{-# LANGUAGE DataKinds #-}

-- | Public commands contain stable operation/precondition identities. Provider
-- observations and verification evidence arrive through trusted host methods,
-- never through these user-authored envelopes.
module Shikigami.Objective.Tracker.Command where

import Data.Aeson qualified as Aeson
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types (Instructions)
import Shikigami.Prelude
import Shikigami.StateRevision

data Command
  = Bind !TrackerBindingId !ResourceScope !FieldPolicy
  | Pause !TrackerBindingId !(StateRevision "tracker-binding")
  | Resume !TrackerBindingId !(StateRevision "tracker-binding")
  | Detach !TrackerBindingId !(StateRevision "tracker-binding")
  | ChangeMapping !TrackerBindingId !(StateRevision "tracker-binding") !FieldPolicy
  | ApplyProposal !TrackerBindingId !(StateRevision "tracker-binding") !ProposalId !(StateRevision "objective")
  | RejectProposal !TrackerBindingId !(StateRevision "tracker-binding") !ProposalId !(StateRevision "objective") !Instructions
  | RebaseProposal !TrackerBindingId !(StateRevision "tracker-binding") !ProposalId !(StateRevision "objective")
  | SuppressPublication !PublicationId !(StateRevision "tracker-receipt") !Instructions
  | AttestDelivery !PublicationId !AttemptId !ConnectionIncarnation !RemoteReceiptId !(TrackerDigest "publication") !(StateRevision "tracker-receipt") !Instructions
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON Command where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

-- | Closed network boundary. Providers return facts and never mutate local
-- objectives. The executor retains attempts before invoking publish.
module Shikigami.Objective.Tracker.Provider where

import Shikigami.Objective.Tracker.Types
import Shikigami.Prelude

data Provider = Provider
  { capabilities :: !Capabilities,
    readResource :: !(ResourceScope -> IO ReadOutcome),
    publish :: !(PublicationIntent -> PublicationAttempt -> IO PublishOutcome),
    reconcile :: !(PublicationIntent -> PublicationAttempt -> IO Reconciliation),
    verifyReceipt :: !(PublicationIntent -> PublicationAttempt -> RemoteReceiptId -> IO (Maybe VerifiedDelivery))
  }
  deriving stock (Generic)

data ReadOutcome = Observed !TrackerObservation | ResourceMissing | ReadDenied | ReadUnavailable
  deriving stock (Eq, Show, Generic)

data PublishOutcome
  = Acknowledged !RemoteReceiptId
  | DefinitelyNotSent
  | DefinitivelyRejected
  | PublicationConflict
  | OutcomeUnknown
  deriving stock (Eq, Show, Generic)

-- ProvedNotApplied asserts settlement of every possible original request,
-- including in-flight requests; an empty eventual read cannot construct it.
data Reconciliation = ProvedApplied !VerifiedDelivery | ProvedNotApplied | StillUnknown
  deriving stock (Eq, Show, Generic)

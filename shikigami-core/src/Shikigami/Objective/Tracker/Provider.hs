-- | Closed network boundary. Providers return facts and never mutate local
-- objectives. The executor retains attempts before invoking publish.
--
-- A pack installs a provider by its adapter revision
-- ('TrackerProviderRegistration', plan 135 M4); the kernel opens each
-- configured connection through the registration its revision names and holds
-- the connection, never the provider's client.
module Shikigami.Objective.Tracker.Provider where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text qualified as Text
import Shikigami.Objective.Tracker.Config (Connection (..))
import Shikigami.Objective.Tracker.Types
import Shikigami.Prelude
import Shikigami.Sink.Http (HttpLimits)
import System.Environment (lookupEnv)

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

-- | A tracker provider a pack installs, under the adapter revision a
-- connection's @provider@ names.
data TrackerProviderRegistration = TrackerProviderRegistration
  { revision :: !ProviderRevision,
    -- | Open one configured connection: resolve its credential and build its
    -- clients, once, at start. A 'Left' refuses the composition.
    connect :: !(HttpLimits -> Connection -> IO (Either TrackerError TrackerConnection))
  }

-- | One opened connection: a provider for each resource scope it serves, and
-- the release of what it opened.
data TrackerConnection = TrackerConnection
  { provider :: !(ResourceScope -> Either TrackerError Provider),
    close :: !(IO ())
  }

-- | The secret an @env:NAME@ credential reference names. A malformed or
-- absent reference is invalid; an unset variable is unavailable.
environmentCredential :: Connection -> IO (Either TrackerError Text)
environmentCredential connection = case connection.credential >>= environmentName of
  Nothing -> pure (Left (TrackerInvalid "objective tracker connections require an env:NAME credential reference"))
  Just name -> maybe (Left TrackerUnavailable) (Right . Text.pack) <$> lookupEnv (Text.unpack name)

environmentName :: CredentialReference -> Maybe Text
environmentName reference = do
  name <- Text.stripPrefix "env:" (coordinateText reference)
  (first, _) <- Text.uncons name
  guard (Text.length name <= 128 && (letter first || first == '_') && Text.all (\character -> letter character || isDigit character && character <= '9' || character == '_') name)
  pure name
  where
    letter character = isAsciiLower character || isAsciiUpper character

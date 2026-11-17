-- | Process composition shared by workers, HTTP controls and the operator CLI.
-- Connections own bounded managers and opaque tokens; durable records own none.
--
-- The runtime names no provider (plan 135, M4): each configured connection is
-- opened by the registration a composed pack installs for its adapter
-- revision, and a revision nobody installs refuses the composition.
module Shikigami.Objective.Tracker.Runtime
  ( TrackerProviders,
    withTrackerProviders,
    providerFor,
    operatorHost,
  )
where

import Control.Exception (bracket)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Shikigami.Authority (Authority)
import Shikigami.Objective.Capability qualified as Objective
import Shikigami.Objective.Tracker.Config
import Shikigami.Objective.Tracker.Provider qualified as Provider
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as O
import Shikigami.Prelude hiding (Context)
import Shikigami.Sink.Http (HttpLimits)

data Context = Context
  { target :: !(TrackerDigest "connection-target"),
    connection :: !Provider.TrackerConnection
  }

newtype TrackerProviders = TrackerProviders (Map.Map (TrackerConnectionId, ConnectionIncarnation) Context)

-- | Open every configured connection through the installed providers, run the
-- action, and close them.
withTrackerProviders :: [Provider.TrackerProviderRegistration] -> HttpLimits -> TrackerSettings -> (Either TrackerError TrackerProviders -> IO a) -> IO a
withTrackerProviders installed limits settings = bracket (buildProviders installed limits settings) (either (const (pure ())) closeProviders)

closeProviders :: TrackerProviders -> IO ()
closeProviders (TrackerProviders contexts) = mapM_ (\context -> context.connection.close) (Map.elems contexts)

buildProviders :: [Provider.TrackerProviderRegistration] -> HttpLimits -> TrackerSettings -> IO (Either TrackerError TrackerProviders)
buildProviders installed limits settings = case validateTrackerSettings settings of
  Left _ -> pure (Left (TrackerInvalid "invalid objective tracker configuration"))
  Right () | settings.enabled == TrackersDisabled -> pure (Right (TrackerProviders Map.empty))
  Right () -> loop Map.empty settings.connections
  where
    loop contexts [] = pure (Right (TrackerProviders contexts))
    loop contexts (connection : rest) = do
      created <- makeContext installed limits connection
      case created of
        Left refusal -> closeProviders (TrackerProviders contexts) >> pure (Left refusal)
        Right context -> loop (Map.insert (connection.connectionId, connection.incarnation) context contexts) rest

makeContext :: [Provider.TrackerProviderRegistration] -> HttpLimits -> Connection -> IO (Either TrackerError Context)
makeContext installed limits connection =
  case find (\registration -> registration.revision == connection.provider) installed of
    Nothing -> pure (Left (TrackerInvalid "objective tracker provider revision is not installed"))
    Just registration -> fmap (Context (connectionDigestFor connection)) <$> registration.connect limits connection

providerFor :: TrackerProviders -> TrackerSettings -> ResourceScope -> IO (Either TrackerError Provider.Provider)
providerFor (TrackerProviders contexts) settings scope = pure do
  connection <- connectionFor settings scope
  context <- maybe (Left TrackerUnavailable) Right (Map.lookup (scope.connectionId, scope.incarnation) contexts)
  unless (context.target == connectionDigestFor connection) (Left TrackerConflict)
  context.connection.provider scope

-- The configured local operator is a process identity, never an external
-- provider actor or a caller-selected principal. Current objective
-- membership/admin and connection export grants still gate every accepted
-- send.
operatorHost :: O.ObjectiveSettings -> Authority -> Either TrackerError Objective.ObjectiveHost
operatorHost settings actions = do
  operator <- maybe (Left (TrackerInvalid "objective tracker worker requires a configured local operator")) Right settings.operator
  pure (Objective.ObjectiveHost settings (pure (Right (O.LocalOperator operator))) actions (\_ _ -> pure (Left O.ObjectiveDenied)) (\_ _ -> pure (Left O.ObjectiveDenied)) (\_ -> pure (Left O.ObjectiveInvalidEvidence)))

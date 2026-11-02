{-# LANGUAGE DataKinds #-}

-- | Process composition shared by workers, HTTP controls and the operator CLI.
-- Connections own bounded managers and opaque tokens; durable records own none.
module Shikigami.Objective.Tracker.Runtime
  ( TrackerProviders,
    withTrackerProviders,
    providerFor,
    operatorHost,
  )
where

import Control.Exception (bracket)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Network.HTTP.Client (Manager, closeManager)
import Rei.Client qualified as Client
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.App.Config (opaqueSecretText)
import Shikigami.Objective.Capability qualified as Objective
import Shikigami.Objective.Tracker.Config
import Shikigami.Objective.Tracker.Provider qualified as Provider
import Shikigami.Objective.Tracker.Rei qualified as Rei
import Shikigami.Objective.Tracker.Store qualified as Store
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as O
import Shikigami.Prelude hiding (Context)
import Shikigami.Sink.Auth (credentialToken, staticTokenSource)
import Shikigami.Sink.Http (HttpLimits, newTypedClientManager)
import System.Environment (lookupEnv)

data Context = Context
  { target :: !(TrackerDigest "connection-target"),
    environment :: !Client.ClientEnv,
    token :: !Client.BearerToken,
    manager :: !Manager
  }

newtype TrackerProviders = TrackerProviders (Map.Map (TrackerConnectionId, ConnectionIncarnation) Context)

withTrackerProviders :: HttpLimits -> TrackerSettings -> (Either TrackerError TrackerProviders -> IO a) -> IO a
withTrackerProviders limits settings = bracket (buildProviders limits settings) (either (const (pure ())) closeProviders)

closeProviders :: TrackerProviders -> IO ()
closeProviders (TrackerProviders contexts) = mapM_ (closeManager . (.manager)) (Map.elems contexts)

buildProviders :: HttpLimits -> TrackerSettings -> IO (Either TrackerError TrackerProviders)
buildProviders limits settings = case validateTrackerSettings settings of
  Left _ -> pure (Left (TrackerInvalid "invalid objective tracker configuration"))
  Right () | settings.enabled == TrackersDisabled -> pure (Right (TrackerProviders Map.empty))
  Right () -> loop Map.empty settings.connections
  where
    loop contexts [] = pure (Right (TrackerProviders contexts))
    loop contexts (connection : rest) = do
      created <- makeContext limits connection
      case created of
        Left refusal -> closeProviders (TrackerProviders contexts) >> pure (Left refusal)
        Right context -> loop (Map.insert (connection.connectionId, connection.incarnation) context contexts) rest

makeContext :: HttpLimits -> Connection -> IO (Either TrackerError Context)
makeContext limits connection
  | connection.provider /= Rei.reiProviderRevision = pure (Left (TrackerInvalid "objective tracker provider revision is not installed"))
  | otherwise = case connection.credential >>= environmentName of
      Nothing -> pure (Left (TrackerInvalid "Rei requires an env:NAME credential reference"))
      Just name -> do
        value <- lookupEnv (Text.unpack name)
        case value of
          Nothing -> pure (Left TrackerUnavailable)
          Just secret -> case Client.mkBearerToken (Text.pack secret) of
            Left _ -> pure (Left (TrackerInvalid "invalid Rei bearer credential"))
            Right token -> do
              attempted <- Store.safeNetwork do
                base <- Client.parseBaseUrl (Text.unpack connection.endpoint)
                manager <- newTypedClientManager limits (Just (staticTokenSource (credentialToken (opaqueSecretText (Text.pack secret)))))
                pure (Context (connectionDigestFor connection) (Client.mkClientEnv manager base) token manager)
              pure (either (const (Left TrackerUnavailable)) Right attempted)

environmentName :: CredentialReference -> Maybe Text
environmentName reference = do
  name <- Text.stripPrefix "env:" (coordinateText reference)
  (first, _) <- Text.uncons name
  guard (Text.length name <= 128 && (letter first || first == '_') && Text.all (\character -> letter character || isDigit character && character <= '9' || character == '_') name)
  pure name
  where
    letter character = isAsciiLower character || isAsciiUpper character

providerFor :: TrackerProviders -> TrackerSettings -> ResourceScope -> IO (Either TrackerError Provider.Provider)
providerFor (TrackerProviders contexts) settings scope = pure do
  connection <- connectionFor settings scope
  context <- maybe (Left TrackerUnavailable) Right (Map.lookup (scope.connectionId, scope.incarnation) contexts)
  unless (context.target == connectionDigestFor connection) (Left TrackerConflict)
  Rei.mkReiProvider context.environment context.token scope

-- The configured local operator is a process identity, never an external Rei
-- actor or a caller-selected principal. Current objective membership/admin and
-- connection export grants still gate every accepted send.
operatorHost :: O.ObjectiveSettings -> ActionAuthorizer -> Either TrackerError Objective.ObjectiveHost
operatorHost settings actions = do
  operator <- maybe (Left (TrackerInvalid "objective tracker worker requires a configured local operator")) Right settings.operator
  pure (Objective.ObjectiveHost settings (pure (Right (O.LocalOperator operator))) actions (\_ _ -> pure (Left O.ObjectiveDenied)) (\_ _ -> pure (Left O.ObjectiveDenied)) (\_ -> pure (Left O.ObjectiveInvalidEvidence)))

{-# LANGUAGE DataKinds #-}

-- | Operator-owned connection policy. Credential references identify a host
-- secret resolver entry; they never contain a token or grant objective access.
module Shikigami.Objective.Tracker.Config where

import Data.Aeson qualified as Aeson
import Data.List (nub)
import Data.Text qualified as Text
import Network.URI (URI (..), URIAuth (..), parseURI)
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types (AccessPrincipal, validPrincipal)
import Shikigami.Prelude

data TrackerEnablement = TrackersDisabled | TrackersEnabled
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data TrackerSettings = TrackerSettings
  { enabled :: !TrackerEnablement,
    connections :: ![Connection],
    pollSeconds :: !Int,
    batchSize :: !Int,
    reconciliationOperators :: ![AccessPrincipal]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON TrackerSettings where
  parseJSON value = do
    settings <- Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True}) value
    either (fail . Text.unpack) (const (pure settings)) (validateTrackerSettings settings)

data Connection = Connection
  { connectionId :: !TrackerConnectionId,
    incarnation :: !ConnectionIncarnation,
    provider :: !ProviderRevision,
    endpoint :: !Text,
    account :: !ResourceId,
    credential :: !(Maybe CredentialReference),
    useGrants :: ![AccessPrincipal],
    exportGrants :: ![AccessPrincipal]
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance Show Connection where show _ = "Connection <protected>"

instance FromJSON Connection where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

defaultTrackerSettings :: TrackerSettings
defaultTrackerSettings = TrackerSettings TrackersDisabled [] 60 20 []

validateTrackerSettings :: TrackerSettings -> Either Text ()
validateTrackerSettings settings = do
  unless (settings.pollSeconds >= 1 && settings.pollSeconds <= 86400 && settings.batchSize >= 1 && settings.batchSize <= 100) (Left "tracker polling requires 1..86400 seconds and batch size 1..100")
  let identifiers = map (\connection -> (connection.connectionId, connection.incarnation)) settings.connections
  unless (length identifiers <= 64 && length (nub identifiers) == length identifiers) (Left "tracker connection incarnations must be unique, at most 64")
  unless (validGrants settings.reconciliationOperators) (Left "invalid tracker reconciliation grants")
  forM_ settings.connections \connection -> do
    unless (validGrants connection.useGrants && validGrants connection.exportGrants) (Left "invalid tracker connection grants")
    -- No userinfo, query or fragment is accepted, so endpoints cannot carry
    -- credentials. Transport composition additionally enforces network policy.
    unless (validEndpoint connection.endpoint) (Left "tracker endpoint must be HTTPS or explicit loopback HTTP without credentials, query or fragment")
  where
    validGrants actors = length actors <= 256 && length (nub actors) == length actors && all validPrincipal actors

validEndpoint :: Text -> Bool
validEndpoint endpoint =
  Text.length endpoint <= 2048 && not (Text.any (\c -> c <= ' ' || c == '\\') endpoint) && case parseURI (Text.unpack endpoint) of
    Just URI {uriScheme, uriAuthority = Just URIAuth {uriUserInfo, uriRegName, uriPort}, uriQuery, uriFragment} ->
      (uriScheme == "https:" || uriScheme == "http:" && uriRegName `elem` ["127.0.0.1", "localhost", "[::1]"] && not (null uriPort)) && null uriUserInfo && not (null uriRegName) && '*' `notElem` uriRegName && null uriQuery && null uriFragment && validPort uriPort
    _ -> False
  where
    validPort "" = True
    validPort (':' : digits) = not (null digits) && length digits <= 5 && all (\c -> c >= '0' && c <= '9') digits && (read digits :: Int) >= 1 && (read digits :: Int) <= 65535
    validPort _ = False

connectionFor :: TrackerSettings -> ResourceScope -> Either TrackerError Connection
connectionFor settings scope = do
  either (const (Left TrackerUnavailable)) pure (validateTrackerSettings settings)
  case filter (\connection -> connection.connectionId == scope.connectionId && connection.incarnation == scope.incarnation && connection.provider == scope.providerRevision) settings.connections of
    [connection] -> Right connection
    _ -> Left TrackerDenied

mayUseConnection :: TrackerSettings -> AccessPrincipal -> ResourceScope -> Bool
mayUseConnection settings actor scope = settings.enabled == TrackersEnabled && either (const False) (elem actor . (.useGrants)) (connectionFor settings scope)

mayExportConnection :: TrackerSettings -> AccessPrincipal -> ResourceScope -> Bool
mayExportConnection settings actor scope = mayUseConnection settings actor scope && either (const False) (elem actor . (.exportGrants)) (connectionFor settings scope)

connectionDigestFor :: Connection -> TrackerDigest "connection-target"
connectionDigestFor connection = trackerDigest "shikigami.tracker-connection-target/1" (toJSON (connection.connectionId, connection.incarnation, connection.provider, connection.endpoint, connection.account))

matchesConnection :: TrackerSettings -> ResourceScope -> TrackerDigest "connection-target" -> Bool
matchesConnection settings scope expected = either (const False) ((== expected) . connectionDigestFor) (connectionFor settings scope)

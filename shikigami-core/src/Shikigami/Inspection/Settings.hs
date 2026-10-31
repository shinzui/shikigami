-- | Secret, explicitly enabled operational configuration. Settei owns its source.
module Shikigami.Inspection.Settings (InspectionSettings (..), InspectionCredential, revealInspectionCredential) where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), withObject, withText, (.!=), (.:), (.:?))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Network.URI (URI (..), URIAuth (..), parseURI)

-- The constructor and automatic renderings stay private.
newtype InspectionCredential = InspectionCredential Text deriving stock (Eq)

revealInspectionCredential :: InspectionCredential -> Text
revealInspectionCredential (InspectionCredential value) = value

instance FromJSON InspectionCredential where
  parseJSON = withText "inspection credential" \value ->
    if Text.length value >= 32 && Text.length value <= 4096 && Text.all (\c -> c > ' ' && c < '\DEL') value
      then pure (InspectionCredential value)
      else fail "inspection credentials require 32..4096 printable non-space ASCII characters"

-- No Show/ToJSON instance: the whole Settei setting is secret. The two tokens
-- grant separate read and mutation authority and must never be interchangeable.
data InspectionSettings = InspectionSettings
  { host :: !Text,
    port :: !Int,
    readToken :: !InspectionCredential,
    writeToken :: !(Maybe InspectionCredential),
    mutationsEnabled :: !Bool,
    allowedOrigins :: ![Text],
    maxConcurrentReads :: !Int,
    readDeadlineSeconds :: !Int,
    mutationDeadlineSeconds :: !Int,
    deliveryDeadlineSeconds :: !Int,
    statementTimeoutMillis :: !Int,
    maxResponseBytes :: !Int,
    maxRequestBytes :: !Int,
    maxConnections :: !Int,
    maxViews :: !Int,
    maxFrameBytes :: !Int,
    maxQueuedBytes :: !Int,
    maxQueuedFrames :: !Int,
    refreshMillis :: !Int
  }
  deriving stock (Generic, Eq)

instance FromJSON InspectionSettings where
  parseJSON = withObject "inspection" \fields -> do
    unless (all (`elem` accepted) (KeyMap.keys fields)) (fail "unknown inspection setting")
    settings <-
      InspectionSettings
        <$> fields .:? "host" .!= "127.0.0.1"
        <*> fields .:? "port" .!= 9092
        <*> fields .: "readToken"
        <*> fields .:? "writeToken"
        <*> fields .:? "mutationsEnabled" .!= False
        <*> fields .:? "allowedOrigins" .!= []
        <*> fields .:? "maxConcurrentReads" .!= 4
        <*> fields .:? "readDeadlineSeconds" .!= 5
        <*> fields .:? "mutationDeadlineSeconds" .!= 30
        <*> fields .:? "deliveryDeadlineSeconds" .!= 5
        <*> fields .:? "statementTimeoutMillis" .!= 2000
        <*> fields .:? "maxResponseBytes" .!= 1048576
        <*> fields .:? "maxRequestBytes" .!= 16384
        <*> fields .:? "maxConnections" .!= 16
        <*> fields .:? "maxViews" .!= 16
        <*> fields .:? "maxFrameBytes" .!= 262144
        <*> fields .:? "maxQueuedBytes" .!= 524288
        <*> fields .:? "maxQueuedFrames" .!= 16
        <*> fields .:? "refreshMillis" .!= 1000
    unless (not (Text.null settings.host) && settings.port >= 0 && settings.port <= 65535) (fail "invalid inspection listener")
    unless (maybe True (/= settings.readToken) settings.writeToken) (fail "inspection credentials require distinct tokens of 32..4096 characters")
    unless (not settings.mutationsEnabled || maybe False (const True) settings.writeToken) (fail "inspection mutations require a separate writeToken")
    unless (all positive [settings.maxConcurrentReads, settings.readDeadlineSeconds, settings.mutationDeadlineSeconds, settings.deliveryDeadlineSeconds, settings.statementTimeoutMillis, settings.maxResponseBytes, settings.maxRequestBytes, settings.maxConnections, settings.maxViews, settings.maxFrameBytes, settings.maxQueuedBytes, settings.maxQueuedFrames, settings.refreshMillis]) (fail "inspection limits must be in 1..16777216")
    unless (settings.maxFrameBytes >= 256 && settings.maxQueuedBytes >= settings.maxFrameBytes && settings.maxQueuedFrames >= 2 && settings.maxResponseBytes >= settings.maxFrameBytes && all (<= 300) [settings.readDeadlineSeconds, settings.mutationDeadlineSeconds, settings.deliveryDeadlineSeconds] && settings.statementTimeoutMillis <= settings.readDeadlineSeconds * 1000) (fail "inspection byte or deadline limits are inconsistent")
    unless (all validOrigin settings.allowedOrigins) (fail "inspection origins must be explicit serialized HTTP(S) origins")
    pure settings
    where
      positive n = n > 0 && n <= 16777216
      accepted = ["host", "port", "readToken", "writeToken", "mutationsEnabled", "allowedOrigins", "maxConcurrentReads", "readDeadlineSeconds", "mutationDeadlineSeconds", "deliveryDeadlineSeconds", "statementTimeoutMillis", "maxResponseBytes", "maxRequestBytes", "maxConnections", "maxViews", "maxFrameBytes", "maxQueuedBytes", "maxQueuedFrames", "refreshMillis"]

validOrigin :: Text -> Bool
validOrigin value = case parseURI (Text.unpack value) of
  Just URI {uriScheme, uriAuthority = Just URIAuth {uriUserInfo, uriRegName, uriPort}, uriPath, uriQuery, uriFragment} ->
    uriScheme `elem` ["http:", "https:"] && null uriUserInfo && not (null uriRegName) && '*' `notElem` uriRegName && null uriPath && null uriQuery && null uriFragment && validPort uriPort
  _ -> False
  where
    validPort "" = True
    validPort (':' : digits) = not (null digits) && length digits <= 5 && all (\c -> c >= '0' && c <= '9') digits && (read digits :: Int) <= 65535
    validPort _ = False

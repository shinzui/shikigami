{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Secret, explicitly enabled operational configuration. Settei owns its source.
module Shikigami.Inspection.Settings (InspectionSettings (..), InspectionCredential, revealInspectionCredential, InspectionLimit, parseInspectionLimit, inspectionLimitInt, InspectionHost, inspectionHostText, InspectionPort, inspectionPortInt, InspectionOrigin, inspectionOriginText, MutationAccess (..)) where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), withObject, withText, (.!=), (.:), (.:?))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import GHC.TypeLits (Symbol)
import Network.URI (URI (..), URIAuth (..), parseURI)

-- The constructor and automatic renderings stay private.
type role InspectionCredential nominal

newtype InspectionCredential (scope :: Symbol) = InspectionCredential Text deriving stock (Eq)

revealInspectionCredential :: InspectionCredential scope -> Text
revealInspectionCredential (InspectionCredential value) = value

instance FromJSON (InspectionCredential scope) where
  parseJSON = withText "inspection credential" \value ->
    if Text.length value >= 32 && Text.length value <= 4096 && Text.all (\c -> c > ' ' && c < '\DEL') value
      then pure (InspectionCredential value)
      else fail "inspection credentials require 32..4096 printable non-space ASCII characters"

-- No Show/ToJSON instance: the whole Settei setting is secret. The two tokens
-- grant separate read and mutation authority and must never be interchangeable.
data InspectionSettings = InspectionSettings
  { host :: !InspectionHost,
    port :: !InspectionPort,
    readToken :: !(InspectionCredential "read"),
    writeToken :: !(Maybe (InspectionCredential "write")),
    mutationsEnabled :: !MutationAccess,
    allowedOrigins :: ![InspectionOrigin],
    maxConcurrentReads :: !(InspectionLimit "maxConcurrentReads"),
    readDeadlineSeconds :: !(InspectionLimit "readDeadlineSeconds"),
    mutationDeadlineSeconds :: !(InspectionLimit "mutationDeadlineSeconds"),
    deliveryDeadlineSeconds :: !(InspectionLimit "deliveryDeadlineSeconds"),
    statementTimeoutMillis :: !(InspectionLimit "statementTimeoutMillis"),
    maxResponseBytes :: !(InspectionLimit "maxResponseBytes"),
    maxRequestBytes :: !(InspectionLimit "maxRequestBytes"),
    maxConnections :: !(InspectionLimit "maxConnections"),
    maxViews :: !(InspectionLimit "maxViews"),
    maxFrameBytes :: !(InspectionLimit "maxFrameBytes"),
    maxQueuedBytes :: !(InspectionLimit "maxQueuedBytes"),
    maxQueuedFrames :: !(InspectionLimit "maxQueuedFrames"),
    refreshMillis :: !(InspectionLimit "refreshMillis")
  }
  deriving stock (Generic, Eq)

instance FromJSON InspectionSettings where
  parseJSON = withObject "inspection" \fields -> do
    unless (all (`elem` accepted) (KeyMap.keys fields)) (fail "unknown inspection setting")
    settings <-
      InspectionSettings
        <$> fields .:? "host" .!= InspectionHost "127.0.0.1"
        <*> fields .:? "port" .!= InspectionPort 9092
        <*> fields .: "readToken"
        <*> fields .:? "writeToken"
        <*> fields .:? "mutationsEnabled" .!= InspectionReadOnly
        <*> fields .:? "allowedOrigins" .!= []
        <*> fields .:? "maxConcurrentReads" .!= (InspectionLimit 4)
        <*> fields .:? "readDeadlineSeconds" .!= (InspectionLimit 5)
        <*> fields .:? "mutationDeadlineSeconds" .!= (InspectionLimit 30)
        <*> fields .:? "deliveryDeadlineSeconds" .!= (InspectionLimit 5)
        <*> fields .:? "statementTimeoutMillis" .!= (InspectionLimit 2000)
        <*> fields .:? "maxResponseBytes" .!= (InspectionLimit 1048576)
        <*> fields .:? "maxRequestBytes" .!= (InspectionLimit 16384)
        <*> fields .:? "maxConnections" .!= (InspectionLimit 16)
        <*> fields .:? "maxViews" .!= (InspectionLimit 16)
        <*> fields .:? "maxFrameBytes" .!= (InspectionLimit 262144)
        <*> fields .:? "maxQueuedBytes" .!= (InspectionLimit 524288)
        <*> fields .:? "maxQueuedFrames" .!= (InspectionLimit 16)
        <*> fields .:? "refreshMillis" .!= (InspectionLimit 1000)
    unless (maybe True ((/= revealInspectionCredential settings.readToken) . revealInspectionCredential) settings.writeToken) (fail "inspection credentials require distinct tokens of 32..4096 characters")
    unless (settings.mutationsEnabled == InspectionReadOnly || maybe False (const True) settings.writeToken) (fail "inspection mutations require a separate writeToken")
    unless ((inspectionLimitInt settings.maxFrameBytes) >= 256 && (inspectionLimitInt settings.maxQueuedBytes) >= (inspectionLimitInt settings.maxFrameBytes) && (inspectionLimitInt settings.maxQueuedFrames) >= 2 && (inspectionLimitInt settings.maxResponseBytes) >= (inspectionLimitInt settings.maxFrameBytes) && all (<= 300) [(inspectionLimitInt settings.readDeadlineSeconds), (inspectionLimitInt settings.mutationDeadlineSeconds), (inspectionLimitInt settings.deliveryDeadlineSeconds)] && (inspectionLimitInt settings.statementTimeoutMillis) <= (inspectionLimitInt settings.readDeadlineSeconds) * 1000) (fail "inspection byte or deadline limits are inconsistent")
    pure settings
    where
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

-- Scope roles keep quantities with different policy meanings non-interchangeable.
type role InspectionLimit nominal

newtype InspectionLimit (scope :: Symbol) = InspectionLimit Int
  deriving stock (Eq, Ord)

inspectionLimitInt :: InspectionLimit scope -> Int
inspectionLimitInt (InspectionLimit value) = value

parseInspectionLimit :: Int -> Either Text (InspectionLimit scope)
parseInspectionLimit number
  | number > 0 && number <= 16777216 = Right (InspectionLimit number)
  | otherwise = Left "inspection limits must be in 1..16777216"

instance FromJSON (InspectionLimit scope) where
  parseJSON value = parseJSON @Int value >>= either (fail . Text.unpack) pure . parseInspectionLimit

newtype InspectionHost = InspectionHost Text
  deriving stock (Eq)

inspectionHostText :: InspectionHost -> Text
inspectionHostText (InspectionHost value) = value

instance FromJSON InspectionHost where
  parseJSON = withText "inspection host" \value ->
    if Text.null value then fail "invalid inspection listener" else pure (InspectionHost value)

newtype InspectionPort = InspectionPort Int
  deriving stock (Eq)

inspectionPortInt :: InspectionPort -> Int
inspectionPortInt (InspectionPort value) = value

instance FromJSON InspectionPort where
  parseJSON value = do
    number <- parseJSON @Int value
    if number >= 0 && number <= 65535
      then pure (InspectionPort number)
      else fail "invalid inspection listener"

newtype InspectionOrigin = InspectionOrigin Text
  deriving stock (Eq)

inspectionOriginText :: InspectionOrigin -> Text
inspectionOriginText (InspectionOrigin value) = value

instance FromJSON InspectionOrigin where
  parseJSON = withText "inspection origin" \value ->
    if validOrigin value then pure (InspectionOrigin value) else fail "inspection origins must be explicit serialized HTTP(S) origins"

data MutationAccess = InspectionReadOnly | InspectionMutable
  deriving stock (Eq, Show)

instance FromJSON MutationAccess where
  parseJSON value = (\allowed -> if allowed then InspectionMutable else InspectionReadOnly) <$> parseJSON @Bool value

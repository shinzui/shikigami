{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

-- | The @stub-kawa@ server: a @warp@/@wai@ app imitating the real kawa C2 ingest
-- doorway. It serves @POST /v1/sources/{source}/events@, enforces idempotency on
-- @(source, source_event_id)@ in an in-memory map, logs each envelope, and returns
-- @{activity_id, deduplicated}@. With a 'Republisher' it re-publishes each accepted
-- envelope onto the fixture Kafka topic (M3). When configured with a bearer
-- token, authentication is checked before the request body is read.
module Shikigami.Sink.KawaStub
  ( StubKawaOptions (..),
    Republisher,
    stubKawaApplication,
    runStubKawa,
  )
where

import Data.Aeson (eitherDecode, encode)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.KindID (genKindID, toText)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types (Status, hAuthorization, hContentType, status200, status400, status404)
import Network.Wai (Application, Response, pathInfo, requestHeaders, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp qualified as Warp
import Shikigami.Api.Problem (ProblemCode (Unauthorized))
import Shikigami.Prelude
import Shikigami.Server.App (problemResponse)
import Shikigami.Sink.Auth (BearerToken, matchesBearerHeader)
import Shikigami.Sink.KawaStub.Republish (mkRepublisher)
import Shikigami.Sink.Wire (IngestRequest (..), IngestResponse (..))
import System.IO (hPutStrLn, stderr)

-- | A hook invoked on each accepted (non-deduplicated) envelope: republish it. Without
-- @--republish-topic@ the stub passes 'Nothing'.
type Republisher = IngestRequest -> Text -> IO ()

data StubKawaOptions = StubKawaOptions
  { port :: !Int,
    republishTopic :: !(Maybe Text),
    broker :: !(Maybe Text),
    requireToken :: !(Maybe BearerToken)
  }

-- | The doorway WAI app. The in-memory map keys @(source, source_event_id)@ to the
-- minted @activity_id@.
stubKawaApplication :: IORef (Map (Text, Text) Text) -> Maybe Republisher -> Maybe BearerToken -> Application
stubKawaApplication ref mRepub requiredToken req respond =
  case (requestMethod req, pathInfo req) of
    ("POST", ["v1", "sources", source, "events"])
      | not (authorized requiredToken (lookup hAuthorization (requestHeaders req))) -> do
          hPutStrLn stderr "[stub-kawa] rejected: missing/invalid token"
          respond (problemResponse Unauthorized "A valid bearer token is required.")
      | otherwise -> do
          body <- strictRequestBody req
          case eitherDecode body of
            Left e -> respond (textResp status400 ("invalid IngestRequest: " <> Text.pack e))
            Right ingest@(IngestRequest {sourceEventId = sevid})
              | Text.null sevid -> respond (textResp status400 "empty source_event_id")
              | otherwise -> do
                  candidate <- toText <$> genKindID @"act"
                  (actId, dedup) <- atomicModifyIORef' ref $ \m ->
                    case Map.lookup (source, sevid) m of
                      Just existing -> (m, (existing, True))
                      Nothing -> (Map.insert (source, sevid) candidate m, (candidate, False))
                  hPutStrLn
                    stderr
                    ( "[stub-kawa] "
                        <> (if dedup then "deduplicated" else "accepted")
                        <> " source="
                        <> Text.unpack source
                        <> " source_event_id="
                        <> Text.unpack sevid
                        <> " activity_id="
                        <> Text.unpack actId
                    )
                  unless dedup (maybe (pure ()) (\rep -> rep ingest actId) mRepub)
                  respond (jsonResp status200 (IngestResponse {activityId = actId, deduplicated = dedup}))
    _ -> respond (textResp status404 "not found")

authorized :: Maybe BearerToken -> Maybe ByteString -> Bool
authorized Nothing _ = True
authorized (Just expected) received = maybe False (matchesBearerHeader expected) received

jsonResp :: Status -> IngestResponse -> Response
jsonResp status val = responseLBS status [(hContentType, "application/json")] (encode val)

textResp :: Status -> Text -> Response
textResp status t = responseLBS status [(hContentType, "text/plain; charset=utf-8")] (LBS.fromStrict (TE.encodeUtf8 t))

-- | Start the stub server (and, if both flags are set, a republisher).
runStubKawa :: StubKawaOptions -> IO ()
runStubKawa opts = do
  ref <- newIORef Map.empty
  mRepub <- case (republishTopic opts, broker opts) of
    (Just topic, Just broker) -> do
      hPutStrLn stderr ("[stub-kawa] republishing accepted envelopes to topic " <> Text.unpack topic <> " on broker " <> Text.unpack broker)
      pure (Just (mkRepublisher broker topic))
    _ -> pure Nothing
  hPutStrLn stderr ("stub-kawa listening on :" <> show (port opts) <> " (doorway POST /v1/sources/{source}/events)")
  Warp.run (port opts) (stubKawaApplication ref mRepub (requireToken opts))

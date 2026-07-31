-- | A minimal stand-in for the kawa ingest doorway, for testing the kawa sink client.
--
-- The real @stub-kawa@ server — the one an operator runs, with Kafka
-- re-publishing — belongs to @shikigami-server@, which owns every production
-- listener. @shikigami-core@ may not depend on that package, and does not need
-- to: what "Shikigami.Sink.KawaClient" has to be tested against is a doorway
-- that accepts @POST \/v1\/sources\/{source}\/events@ and deduplicates on
-- @(source, source_event_id)@. That is what this fixture is, and nothing more.
--
-- Activity ids are a counter rather than minted TypeIDs so the fixture has no
-- dependencies beyond the test suite's own, and so a failing assertion prints
-- @act_1@ instead of a random string.
module Shikigami.Fixture.KawaStub
  ( kawaDoorwayApplication,
  )
where

import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, atomicModifyIORef')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types (Status, hContentType, status200, status400, status404)
import Network.Wai (Application, Response, pathInfo, requestMethod, responseLBS, strictRequestBody)
import Shikigami.Sink.Wire (IngestRequest (..), IngestResponse (..))

-- | The doorway. The 'IORef' maps @(source, source_event_id)@ to the activity id
-- that was minted for it, which is what makes a repeated POST deduplicate
-- instead of creating a second activity.
kawaDoorwayApplication :: IORef (Map (Text, Text) Text) -> Application
kawaDoorwayApplication ref request respond =
  case (requestMethod request, pathInfo request) of
    ("POST", ["v1", "sources", source, "events"]) -> do
      body <- strictRequestBody request
      case eitherDecode body of
        Left err -> respond (textResponse status400 ("invalid IngestRequest: " <> Text.pack err))
        Right IngestRequest {sourceEventId}
          | Text.null sourceEventId -> respond (textResponse status400 "empty source_event_id")
          | otherwise -> do
              (activityId, deduplicated) <- atomicModifyIORef' ref \seen ->
                case Map.lookup (source, sourceEventId) seen of
                  Just existing -> (seen, (existing, True))
                  Nothing ->
                    let minted = "act_" <> Text.pack (show (Map.size seen + 1))
                     in (Map.insert (source, sourceEventId) minted seen, (minted, False))
              respond (jsonResponse status200 IngestResponse {activityId, deduplicated})
    _ -> respond (textResponse status404 "not found")

jsonResponse :: Status -> IngestResponse -> Response
jsonResponse status body =
  responseLBS status [(hContentType, "application/json")] (encode body)

textResponse :: Status -> Text -> Response
textResponse status body =
  responseLBS status [(hContentType, "text/plain; charset=utf-8")] (LBS.fromStrict (TE.encodeUtf8 body))

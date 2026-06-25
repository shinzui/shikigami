-- | A tiny JSON-over-HTTP POST helper for the sink clients (kizashi, kawa). Uses
-- @http-client@ directly — no servant — so the dependency surface stays small.
module Shikigami.Sink.Http
  ( postJSON,
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson (ToJSON, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Network.HTTP.Client
  ( Request,
    RequestBody (RequestBodyLBS),
    Response,
    defaultManagerSettings,
    httpLbs,
    method,
    newManager,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types.Status (statusCode)
import Shikigami.Prelude

-- | POST a JSON body to a URL. Returns the raw response body on a 2xx, or a typed
-- error string (connection failure, non-2xx) otherwise. Never throws.
postJSON :: (ToJSON a) => Text -> a -> IO (Either Text LBS.ByteString)
postJSON url body = do
  ereq <- try (parseRequest (Text.unpack url)) :: IO (Either SomeException Request)
  case ereq of
    Left err -> pure (Left ("bad URL " <> url <> ": " <> Text.pack (show err)))
    Right req0 -> do
      manager <- newManager defaultManagerSettings
      let req =
            req0
              { method = "POST",
                requestBody = RequestBodyLBS (encode body),
                requestHeaders = [("content-type", "application/json")]
              }
      eresp <- try (httpLbs req manager) :: IO (Either SomeException (Response LBS.ByteString))
      case eresp of
        Left err -> pure (Left ("POST " <> url <> " failed: " <> Text.pack (show err)))
        Right resp ->
          let sc = statusCode (responseStatus resp)
           in if sc >= 200 && sc < 300
                then pure (Right (responseBody resp))
                else pure (Left ("POST " <> url <> " returned HTTP " <> Text.pack (show sc)))

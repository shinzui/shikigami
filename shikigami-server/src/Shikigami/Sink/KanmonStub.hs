{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

-- | A production-shaped, in-memory stand-in for Kanmon's guarded channel
-- egress route. It deliberately accepts only the proof destination and keeps
-- provider credentials outside Shikigami, just as the real service does.
module Shikigami.Sink.KanmonStub
  ( StubKanmonOptions (..),
    StubKanmonState (..),
    newStubKanmonState,
    stubKanmonApplication,
    runStubKanmon,
  )
where

import Data.Aeson (eitherDecode, encode)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.KindID (genKindID, toText)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Types (Status, hAuthorization, hContentType, status200, status400, status403, status404)
import Network.Wai (Application, Response, pathInfo, requestHeaders, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp qualified as Warp
import Shikigami.Api.Problem (ProblemCode (Unauthorized))
import Shikigami.Prelude
import Shikigami.Server.App (problemResponse)
import Shikigami.Sink.Auth (BearerToken, matchesBearerHeader)
import Shikigami.Sink.Wire (EgressActionRequest (..), EgressActionResponse (..))
import System.IO (hPutStrLn, stderr)

data StubKanmonOptions = StubKanmonOptions
  { port :: !Int,
    requireToken :: !(Maybe BearerToken),
    allowedConversations :: !(Set Text)
  }

-- | Inspectable state for hermetic tests. It intentionally retains no request
-- content, conversation key, or credential.
data StubKanmonState = StubKanmonState
  { idempotency :: !(Map (Text, Text) Text),
    acceptedEffects :: !Int
  }
  deriving stock (Eq, Show, Generic)

newStubKanmonState :: IO (IORef StubKanmonState)
newStubKanmonState =
  newIORef
    StubKanmonState
      { idempotency = Map.empty,
        acceptedEffects = 0
      }

-- | Serve only @POST /channels/intercom/actions/reply_to_conversation@.
-- Authentication happens before body parsing for that route. The in-memory
-- idempotency store is intentionally cleared whenever the process restarts.
stubKanmonApplication :: IORef StubKanmonState -> Maybe BearerToken -> Set Text -> Application
stubKanmonApplication state requiredToken allowed request respond =
  case (requestMethod request, pathInfo request) of
    ("POST", ["channels", channel, "actions", action])
      | channel /= "intercom" || action /= "reply_to_conversation" ->
          respond (textResponse status404 "not found")
      | not (authorized requiredToken (lookup hAuthorization (requestHeaders request))) -> do
          hPutStrLn stderr "[stub-kanmon] rejected: missing/invalid token"
          respond (problemResponse Unauthorized "A valid bearer token is required.")
      | otherwise -> do
          body <- strictRequestBody request
          case eitherDecode body of
            Left _ -> respond (textResponse status400 "invalid EgressActionRequest")
            Right actionRequest@EgressActionRequest {conversationKey}
              | not (Set.member conversationKey allowed) ->
                  respond (textResponse status403 "conversation is not allowed")
              | otherwise -> do
                  (activityId, deduplicated) <- acceptEffect state channel actionRequest
                  hPutStrLn
                    stderr
                    ( "[stub-kanmon] "
                        <> (if deduplicated then "deduplicated" else "accepted")
                        <> " channel="
                        <> Text.unpack channel
                        <> " action="
                        <> Text.unpack action
                        <> " activity_id="
                        <> Text.unpack activityId
                    )
                  respond (jsonResponse status200 (EgressActionResponse activityId "conversation.reply_sent"))
    _ -> respond (textResponse status404 "not found")

acceptEffect :: IORef StubKanmonState -> Text -> EgressActionRequest -> IO (Text, Bool)
acceptEffect state channel EgressActionRequest {idempotencyKey} = do
  candidate <- toText <$> genKindID @"act"
  atomicModifyIORef' state \current ->
    case idempotencyKey >>= (\key -> Map.lookup (channel, key) ((.idempotency) current)) of
      Just existing -> (current, (existing, True))
      Nothing ->
        let updatedIdempotency = case idempotencyKey of
              Nothing -> (.idempotency) current
              Just key -> Map.insert (channel, key) candidate ((.idempotency) current)
            updated =
              (current & #idempotency .~ (updatedIdempotency) & #acceptedEffects .~ ((.acceptedEffects) current + 1))
         in (updated, (candidate, False))

authorized :: Maybe BearerToken -> Maybe ByteString -> Bool
authorized Nothing _ = True
authorized (Just expected) received = maybe False (matchesBearerHeader expected) received

jsonResponse :: Status -> EgressActionResponse -> Response
jsonResponse status value = responseLBS status [(hContentType, "application/json")] (encode value)

textResponse :: Status -> Text -> Response
textResponse status value =
  responseLBS status [(hContentType, "text/plain; charset=utf-8")] (LBS.fromStrict (TextEncoding.encodeUtf8 value))

runStubKanmon :: StubKanmonOptions -> IO ()
runStubKanmon StubKanmonOptions {port, requireToken, allowedConversations} = do
  state <- newStubKanmonState
  hPutStrLn stderr ("stub-kanmon listening on :" <> show port <> " (POST /channels/intercom/actions/reply_to_conversation)")
  Warp.run port (stubKanmonApplication state requireToken allowedConversations)

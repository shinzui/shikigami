{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

-- | The @KawaDigest@ sink handler: build the nine-field C1 Activity Envelope (minting a
-- UUIDv7 @act_@ id the way kawa does) and POST it to the C2 doorway as an
-- @IngestRequest@. Built against the stub-kawa server; the real kawa base URL needs no
-- code change.
module Shikigami.Sink.KawaClient
  ( KawaError (..),
    buildEnvelope,
    postEnvelope,
    postEnvelopeWithHeaders,
    projectIngest,
    renderKawaError,
  )
where

import Data.Aeson (Value (..), eitherDecode)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Foldable (traverse_)
import Data.KindID (genKindID, toText)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601Show)
import Network.HTTP.Types.Header (Header)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), ContextRef (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Agent.Principal (identityText)
import Shikigami.Prelude
import Shikigami.Sink.Config (KawaConfig (..))
import Shikigami.Sink.Http (HttpEnv, HttpFailure, postJSONWithHeaders, renderHttpFailure)
import Shikigami.Sink.Types (SinkContext (..), mkSourceEventId)
import Shikigami.Sink.Wire (IngestRequest (..), IngestResponse (..))

data KawaError = KawaHttpError !HttpFailure | KawaDecodeError !Text | KawaPayloadError !Text
  deriving stock (Eq, Show)

renderKawaError :: KawaError -> Text
renderKawaError (KawaHttpError failure) = renderHttpFailure failure
renderKawaError (KawaDecodeError t) = "decode IngestResponse: " <> t
renderKawaError (KawaPayloadError t) = "invalid Kawa payload: " <> t

-- | Build the nine-field C1 envelope for a @KawaDigest@ sink: mint the @act_@ id,
-- @actor.kind = "agent"@, @source = activityCoordinate "shinzui/shikigami"@, @idempotency_key@ = the
-- deterministic @source_event_id@.
buildEnvelope :: SinkContext -> Sink -> Value -> IO (Either KawaError ActivityEnvelope)
buildEnvelope ctx@SinkContext {identity = ctxIdentity, occurredAt = ctxOccurredAt} sink output =
  case sink of
    KawaDigest {subjectType = sty, verb = vb} -> do
      case contextRefsFromOutput output of
        Left problem -> pure (Left (KawaPayloadError problem))
        Right contextRefs -> do
          actId <- genKindID @"act"
          now <- maybe getCurrentTime pure ctxOccurredAt
          let nm = either (const "unresolved-legacy") (\value -> value) (identityText ctxIdentity)
          pure
            ( Right
                ActivityEnvelope
                  { activityId = activityCoordinate (toText actId),
                    occurredAt = activityCoordinate (Text.pack (iso8601Show now)),
                    source = activityCoordinate "shinzui/shikigami",
                    actor = Actor {kind = AgentActor, id = activityCoordinate nm, session = Nothing},
                    subject = Subject {kind = sty, subjectId = activityCoordinate (subjectIdFromOutput output nm)},
                    verb = vb,
                    payload = output,
                    contextRefs,
                    idempotencyKey = activityCoordinate (mkSourceEventId ctx)
                  }
            )
    _ -> error "Shikigami.Sink.KawaClient.buildEnvelope: not a KawaDigest sink"

contextRefsFromOutput :: Value -> Either Text [ContextRef]
contextRefsFromOutput (Object objectValue) =
  case KeyMap.lookup "context_refs" objectValue of
    Nothing -> Right []
    Just raw -> do
      refs <- firstText (parseEither Aeson.parseJSON raw)
      whenEither (length refs <= maximumContextRefs) ("context_refs exceeds " <> Text.pack (show maximumContextRefs) <> " entries")
      pure (dedupeContextRefs refs)
  where
    firstText = either (Left . Text.pack) Right
contextRefsFromOutput _ = Right []

dedupeContextRefs :: [ContextRef] -> [ContextRef]
dedupeContextRefs = reverse . snd . foldl add (Set.empty, [])
  where
    add (seen, retained) value@ContextRef {scheme, ref}
      | Set.member (scheme, ref) seen = (seen, retained)
      | otherwise = (Set.insert (scheme, ref) seen, value : retained)

kawaContextRefSchemes :: [Text]
kawaContextRefSchemes = ["mori://", "rei://", "plan://", "signal://", "conversation://", "activity://"]

maximumContextRefs :: Int
maximumContextRefs = 32

maximumContextRefLength :: Int
maximumContextRefLength = 512

whenEither :: Bool -> Text -> Either Text ()
whenEither True _ = Right ()
whenEither False problem = Left problem

-- | The subject id from the output's @subject_id@ field, falling back to the agent name.
subjectIdFromOutput :: Value -> Text -> Text
subjectIdFromOutput (Object o) fallback =
  case KeyMap.lookup "subject_id" o of
    Just (String s) -> s
    _ -> fallback
subjectIdFromOutput _ fallback = fallback

-- | Project the doorway request from the built envelope (drop @activity_id@/
-- @idempotency_key@; carry @source_event_id@).
projectIngest :: ActivityEnvelope -> IngestRequest
projectIngest (ActivityEnvelope {verb = vb, actor = ac, subject = sj, payload = pl, contextRefs = crs, occurredAt = oat, idempotencyKey = ik}) =
  IngestRequest
    { verb = activityCoordinateText vb,
      actor = ac,
      subject = sj,
      payload = pl,
      contextRefs = crs,
      sourceEventId = activityCoordinateText ik,
      occurredAt = activityCoordinateText oat
    }

-- | POST the envelope (projected to an @IngestRequest@) to @/v1/sources/{source}/events@
-- and return the canonical activity id.
postEnvelope :: HttpEnv -> KawaConfig -> ActivityEnvelope -> IO (Either KawaError Text)
postEnvelope http = postEnvelopeWithHeaders http []

-- | 'postEnvelope' with dispatch-scoped propagation headers.
postEnvelopeWithHeaders :: HttpEnv -> [Header] -> KawaConfig -> ActivityEnvelope -> IO (Either KawaError Text)
postEnvelopeWithHeaders http headers KawaConfig {baseUrl = cfgBaseUrl, sourceSegment = cfgSourceSegment} env = do
  let req = projectIngest env
      url = cfgBaseUrl <> "/v1/sources/" <> Text.replace "/" "%2F" (activityCoordinateText cfgSourceSegment) <> "/events"
  respE <- postJSONWithHeaders http headers url req
  pure $ case respE of
    Left e -> Left (KawaHttpError e)
    Right body -> case eitherDecode body of
      Left de -> Left (KawaDecodeError (Text.pack de))
      Right (IngestResponse {activityId = aid}) -> Right aid

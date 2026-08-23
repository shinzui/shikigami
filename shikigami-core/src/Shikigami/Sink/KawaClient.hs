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
    projectIngest,
    renderKawaError,
  )
where

import Data.Aeson (Value (..), eitherDecode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.KindID (genKindID, toText)
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601Show)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Prelude
import Shikigami.Sink.Config (KawaConfig (..))
import Shikigami.Sink.Http (HttpEnv, HttpFailure, postJSON, renderHttpFailure)
import Shikigami.Sink.Permission (AgentIdentity (..))
import Shikigami.Sink.Types (SinkContext (..), mkSourceEventId)
import Shikigami.Sink.Wire (IngestRequest (..), IngestResponse (..))

data KawaError = KawaHttpError !HttpFailure | KawaDecodeError !Text
  deriving stock (Eq, Show)

renderKawaError :: KawaError -> Text
renderKawaError (KawaHttpError failure) = renderHttpFailure failure
renderKawaError (KawaDecodeError t) = "decode IngestResponse: " <> t

-- | Build the nine-field C1 envelope for a @KawaDigest@ sink: mint the @act_@ id,
-- @actor.kind = "agent"@, @source = "shinzui/shikigami"@, @idempotency_key@ = the
-- deterministic @source_event_id@.
buildEnvelope :: SinkContext -> Sink -> Value -> IO ActivityEnvelope
buildEnvelope ctx@SinkContext {identity = ctxIdentity, occurredAt = ctxOccurredAt} sink output =
  case sink of
    KawaDigest {subjectType = sty, verb = vb} -> do
      actId <- genKindID @"act"
      now <- maybe getCurrentTime pure ctxOccurredAt
      let nm = agentName ctxIdentity
      pure
        ActivityEnvelope
          { activityId = toText actId,
            occurredAt = Text.pack (iso8601Show now),
            source = "shinzui/shikigami",
            actor = Actor {kind = "agent", id = nm, session = Nothing},
            subject = Subject {subjectType = sty, subjectId = subjectIdFromOutput output nm},
            verb = vb,
            payload = output,
            contextRefs = [],
            idempotencyKey = mkSourceEventId ctx
          }
    _ -> error "Shikigami.Sink.KawaClient.buildEnvelope: not a KawaDigest sink"

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
    { verb = vb,
      actor = ac,
      subject = sj,
      payload = pl,
      contextRefs = crs,
      sourceEventId = ik,
      occurredAt = oat
    }

-- | POST the envelope (projected to an @IngestRequest@) to @/v1/sources/{source}/events@
-- and return the canonical activity id.
postEnvelope :: HttpEnv -> KawaConfig -> ActivityEnvelope -> IO (Either KawaError Text)
postEnvelope http KawaConfig {baseUrl = cfgBaseUrl, sourceSegment = cfgSourceSegment} env = do
  let req = projectIngest env
      url = cfgBaseUrl <> "/v1/sources/" <> Text.replace "/" "%2F" cfgSourceSegment <> "/events"
  respE <- postJSON http url req
  pure $ case respE of
    Left e -> Left (KawaHttpError e)
    Right body -> case eitherDecode body of
      Left de -> Left (KawaDecodeError (Text.pack de))
      Right (IngestResponse {activityId = aid}) -> Right aid

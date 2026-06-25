-- | Local mirrors of the downstream C2 (kawa doorway) and C4 (kizashi signal) wire
-- DTOs. shikigami does not depend on kawa/kizashi; these records reproduce their JSON
-- shapes (verified against the real sources) so the stub server and the clients agree
-- and a real client can be swapped in later with no schema change. Reuses EP-1's
-- @Actor@/@Subject@/@ContextRef@ and @SignalType@/@Priority@.
module Shikigami.Sink.Wire
  ( -- * kawa C2 doorway
    IngestRequest (..),
    IngestResponse (..),

    -- * kizashi C4 signal
    CreateSignalReq (..),
    SignalResponse (..),
  )
where

import Data.Aeson (Value, genericParseJSON, genericToJSON)
import Shikigami.Api.Activity (Actor, ContextRef, Subject)
import Shikigami.Api.Agent (Priority, SignalType)
import Shikigami.Prelude

-- aeson options matching kawa's @apiAesonOptions = camelTo2 '_'@.
ingestOptions :: Options
ingestOptions = defaultOptions {fieldLabelModifier = camelTo2 '_'}

-- | The C2 doorway request body: the envelope minus @activity_id@/@idempotency_key@,
-- plus @source_event_id@. JSON keys are snake_case.
data IngestRequest = IngestRequest
  { verb :: !Text,
    actor :: !Actor,
    subject :: !Subject,
    payload :: !Value,
    contextRefs :: ![ContextRef],
    sourceEventId :: !Text,
    occurredAt :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON IngestRequest where toJSON = genericToJSON ingestOptions

instance FromJSON IngestRequest where parseJSON = genericParseJSON ingestOptions

-- | The C2 doorway response: the canonical activity id and the dedup flag.
data IngestResponse = IngestResponse
  { activityId :: !Text,
    deduplicated :: !Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON IngestResponse where toJSON = genericToJSON ingestOptions

instance FromJSON IngestResponse where parseJSON = genericParseJSON ingestOptions

-- | The C4 kizashi @POST /v1/signals@ body. kizashi uses the default generic encoding
-- (field names verbatim; @SignalType@/@Priority@ as bare enum strings).
data CreateSignalReq = CreateSignalReq
  { actor :: !Text,
    recipient :: !Text,
    source :: !Text,
    signalType :: !SignalType,
    intent :: !Text,
    priority :: !Priority,
    importance :: !Int,
    contextTags :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The C4 kizashi response.
data SignalResponse = SignalResponse
  { signalId :: !Text,
    lifecycleState :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

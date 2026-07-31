-- | The dispatcher's shared value types (split out so the per-sink client modules can
-- reference @SinkContext@ without importing the dispatcher — avoids an import cycle).
module Shikigami.Sink.Types
  ( SinkContext (..),
    DanwaTarget (..),
    SinkOutcome (..),
    SinkResult (..),
    mkSourceEventId,
  )
where

import Data.Text qualified as Text
import Shikigami.Prelude
import Shikigami.Sink.Config (DanwaConfig, KawaConfig, KizashiConfig, ReiConfig)
import Shikigami.Sink.Permission (AgentIdentity (..), SinkKind)

-- | A concrete danwa thread target. A parent message id means "reply under that message";
-- absent parent means "post a top-level message in the conversation".
data DanwaTarget = DanwaTarget
  { conversationId :: !Text,
    parentMessageId :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Everything one sink dispatch needs: the agent identity, the run id and the sink's
-- ordinal (for the deterministic @source_event_id@), the endpoint configs, and the
-- run timestamp.
data SinkContext = SinkContext
  { identity :: !AgentIdentity,
    runId :: !Text,
    ordinal :: !Int,
    kizashi :: !KizashiConfig,
    kawa :: !KawaConfig,
    danwa :: !DanwaConfig,
    rei :: !ReiConfig,
    danwaTarget :: !(Maybe DanwaTarget),
    occurredAt :: !(Maybe UTCTime)
  }

-- | The outcome of one sink dispatch. @DeniedOutcome@ is distinct from the permission
-- gate's @Denied@ newtype.
data SinkOutcome
  = Delivered !Text -- a detail string (e.g. the returned id)
  | -- | __Deprecated: never produced.__ A stub handler ran and the dispatch was
    -- counted as a success, which is the lie
    -- @docs\/plans\/16-honest-sink-handlers-real-reiaction-and-honored-declaration-fields.md@
    -- removed: anything not 'Failed' is published forever by the outbox, so a
    -- stubbed sink reported delivery of something that went nowhere.
    --
    -- The constructor stays because 'SinkResult' values are journaled and
    -- replayed by 'Data.Aeson.FromJSON'; removing it would make historical
    -- journals undecodable. Retiring it belongs to a journal-migration plan
    -- under MasterPlan 5. Nothing in this repository constructs it — see
    -- @Shikigami.WireCompatSpec@, which pins that it still /decodes/.
    Stubbed
  | DeniedOutcome !Text -- permission denied; the reason (no send)
  | Failed !Text -- the send errored (the worker decides retry)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SinkResult = SinkResult
  { kind :: !SinkKind,
    outcome :: !SinkOutcome
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The deterministic doorway dedup key: @"<agentName>:<runId>:<sinkOrdinal>"@. A retry
-- of the same run re-POSTs the same key, so the doorway dedups it.
mkSourceEventId :: SinkContext -> Text
mkSourceEventId ctx =
  agentName (identity ctx) <> ":" <> runId ctx <> ":" <> Text.pack (show (ordinal ctx))

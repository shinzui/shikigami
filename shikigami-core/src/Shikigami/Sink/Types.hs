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
import Shikigami.Sink.Config (DanwaConfig, KawaConfig, KizashiConfig)
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
    danwaTarget :: !(Maybe DanwaTarget),
    occurredAt :: !(Maybe UTCTime)
  }

-- | The outcome of one sink dispatch. @DeniedOutcome@ is distinct from the permission
-- gate's @Denied@ newtype.
data SinkOutcome
  = Delivered !Text -- a detail string (e.g. the returned id)
  | Stubbed -- a thin stub handler ran (ReiAction/Danwa)
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

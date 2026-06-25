-- | The dispatcher's shared value types (split out so the per-sink client modules can
-- reference @SinkContext@ without importing the dispatcher — avoids an import cycle).
module Shikigami.Sink.Types
  ( SinkContext (..),
    SinkOutcome (..),
    SinkResult (..),
    mkSourceEventId,
  )
where

import Data.Text qualified as Text
import Shikigami.Prelude
import Shikigami.Sink.Config (KawaConfig, KizashiConfig)
import Shikigami.Sink.Permission (AgentIdentity (..), SinkKind)

-- | Everything one sink dispatch needs: the agent identity, the run id and the sink's
-- ordinal (for the deterministic @source_event_id@), the endpoint configs, and the
-- run timestamp.
data SinkContext = SinkContext
  { sinkCtxIdentity :: !AgentIdentity,
    sinkCtxRunId :: !Text,
    sinkCtxOrdinal :: !Int,
    sinkCtxKizashi :: !KizashiConfig,
    sinkCtxKawa :: !KawaConfig,
    sinkCtxOccurredAt :: !(Maybe UTCTime)
  }

-- | The outcome of one sink dispatch. @DeniedOutcome@ is distinct from the permission
-- gate's @Denied@ newtype.
data SinkOutcome
  = Delivered !Text -- a detail string (e.g. the returned id)
  | Stubbed -- a thin stub handler ran (ReiAction/Danwa)
  | DeniedOutcome !Text -- permission denied; the reason (no send)
  | Failed !Text -- the send errored (the worker decides retry)
  deriving stock (Eq, Show)

data SinkResult = SinkResult
  { sinkResultKind :: !SinkKind,
    sinkResultOutcome :: !SinkOutcome
  }
  deriving stock (Eq, Show)

-- | The deterministic doorway dedup key: @"<agentName>:<runId>:<sinkOrdinal>"@. A retry
-- of the same run re-POSTs the same key, so the doorway dedups it.
mkSourceEventId :: SinkContext -> Text
mkSourceEventId ctx =
  agentName (sinkCtxIdentity ctx) <> ":" <> sinkCtxRunId ctx <> ":" <> Text.pack (show (sinkCtxOrdinal ctx))

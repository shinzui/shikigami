-- | Per-sink endpoint configuration shared by the dispatcher and the clients.
module Shikigami.Sink.Config
  ( KizashiConfig (..),
    KawaConfig (..),
    DanwaConfig (..),
  )
where

import Shikigami.Prelude

-- | Where to POST kizashi signals, plus a fallback recipient.
data KizashiConfig = KizashiConfig
  { kizashiBaseUrl :: !Text, -- e.g. "http://localhost:8089"
    kizashiDefaultRecipient :: !Text -- fallback when a sink names none
  }
  deriving stock (Eq, Show)

-- | Where to POST kawa activities, plus the @{source}@ path segment.
data KawaConfig = KawaConfig
  { kawaBaseUrl :: !Text, -- e.g. "http://localhost:8088"
    kawaSourceSegment :: !Text -- the {source} segment, e.g. "shinzui/shikigami"
  }
  deriving stock (Eq, Show)

-- | Where to POST danwa messages, plus the agent participant id used as author.
data DanwaConfig = DanwaConfig
  { danwaBaseUrl :: !Text, -- e.g. "http://localhost:8080"
    danwaAgentParticipant :: !Text -- e.g. "part_..."
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

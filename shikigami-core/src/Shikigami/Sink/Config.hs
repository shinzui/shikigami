-- | Per-sink endpoint configuration shared by the dispatcher and the clients.
module Shikigami.Sink.Config
  ( KizashiConfig (..),
    KawaConfig (..),
  )
where

import Data.Text (Text)

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

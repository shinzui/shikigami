-- | Per-sink endpoint configuration shared by the dispatcher and the clients.
module Shikigami.Sink.Config
  ( KizashiConfig (..),
    KawaConfig (..),
    DanwaConfig (..),
    KanmonConfig (..),
    ReiConfig (..),
  )
where

import Shikigami.Prelude

-- | Where to POST kizashi signals, plus a fallback recipient.
data KizashiConfig = KizashiConfig
  { baseUrl :: !Text, -- e.g. "http://localhost:8089"
    defaultRecipient :: !Text -- fallback when a sink names none
  }
  deriving stock (Eq, Show)

-- | Where to POST kawa activities, plus the @{source}@ path segment.
data KawaConfig = KawaConfig
  { baseUrl :: !Text, -- e.g. "http://localhost:8088"
    sourceSegment :: !Text -- the {source} segment, e.g. "shinzui/shikigami"
  }
  deriving stock (Eq, Show)

-- | Where to POST danwa messages, plus the agent participant id used as author.
data DanwaConfig = DanwaConfig
  { baseUrl :: !Text, -- e.g. "http://localhost:8080"
    agentParticipant :: !Text -- e.g. "part_..."
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Where to POST guarded channel actions. Provider credentials remain owned
-- by Kanmon; this process carries only its own opaque bearer credential in
-- 'Shikigami.Sink.Http.SinkHttp'.
newtype KanmonConfig = KanmonConfig
  { baseUrl :: Text
  }
  deriving stock (Eq, Show)

-- | Where to hand an agent finding to @shinzui/rei@, if anywhere.
--
-- The only sink config whose base URL is optional, and the reason is not a
-- preference: rei is a CLI application with no HTTP server, so there is nothing
-- to call today. 'Nothing' is therefore the honest default, and it makes a
-- @ReiAction@ dispatch fail into the outbox's retry path rather than report a
-- delivery that never happened. The day rei grows an endpoint, enabling this is
-- configuration rather than code.
newtype ReiConfig = ReiConfig
  { baseUrl :: Maybe Text
  }
  deriving stock (Eq, Show)

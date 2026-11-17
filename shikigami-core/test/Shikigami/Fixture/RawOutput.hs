-- | Outputs as the kernel sees them: a kind and its JSON configuration.
--
-- Kernel tests name outputs this way rather than through a pack's typed
-- builders, because no stock test may depend on a pack (plan 135, M3).
module Shikigami.Fixture.RawOutput
  ( rawOutput,
    fixtureKind,
    kawaDigest,
    kizashiSignal,
    kawaDigestKind,
    kizashiSignalKind,
    danwaConversationKind,
    reiActionKind,
    channelEgressKind,
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson.Types (Pair)
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Authority (OutputKind, mkOutputKind)
import Shikigami.Output (OutputDecl (..))

-- | An output of this kind with this configuration.
rawOutput :: Text -> [Pair] -> OutputDecl
rawOutput kind fields = OutputDecl {kind = fixtureKind kind, config = object fields}

-- | A kind spelled as a declaration spells it; a malformed name is a test bug.
fixtureKind :: Text -> OutputKind
fixtureKind = either (error . Text.unpack) id . mkOutputKind

-- | A Kawa digest of this subject type and verb.
kawaDigest :: Text -> Text -> OutputDecl
kawaDigest subjectType verb = rawOutput "kawa.digest" ["subjectType" .= subjectType, "verb" .= verb]

-- | A Kizashi signal with these fields; the declaration spells the rest.
kizashiSignal :: [Pair] -> OutputDecl
kizashiSignal = rawOutput "kizashi.signal"

kawaDigestKind, kizashiSignalKind, danwaConversationKind, reiActionKind, channelEgressKind :: OutputKind
kawaDigestKind = fixtureKind "kawa.digest"
kizashiSignalKind = fixtureKind "kizashi.signal"
danwaConversationKind = fixtureKind "danwa.conversation"
reiActionKind = fixtureKind "rei.action"
channelEgressKind = fixtureKind "channel.egress"

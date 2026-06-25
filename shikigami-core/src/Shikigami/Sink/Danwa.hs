-- | Thin stub handler for the @DanwaConversation@ sink (open a conversation). It logs
-- a single structured line and no-ops; EP-7 completes it. Returns the detail string the
-- dispatcher records as a @Stubbed@ outcome.
module Shikigami.Sink.Danwa
  ( runDanwaStub,
  )
where

import Data.Aeson (Value)
import Data.Text qualified as Text
import Shikigami.Api.Agent (Sink (..))
import Shikigami.Prelude
import Shikigami.Sink.Permission (AgentIdentity (..))
import System.IO (hPutStrLn, stderr)

runDanwaStub :: AgentIdentity -> Sink -> Value -> IO Text
runDanwaStub (AgentIdentity nm) sink _output =
  case sink of
    DanwaConversation {topic = tp} -> do
      hPutStrLn stderr ("[sink] DanwaConversation stubbed for agent " <> Text.unpack nm <> " (topic " <> Text.unpack tp <> ")")
      pure ("danwa conversation stubbed for topic " <> tp)
    _ -> pure "danwa stub: non-Danwa sink"

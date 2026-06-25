-- | Thin stub handler for the @ReiAction@ sink (hand a finding into @shinzui/rei@). It
-- logs a single structured line and no-ops; rei's own plan completes it. Returns the
-- detail string the dispatcher records as a @Stubbed@ outcome.
module Shikigami.Sink.ReiAction
  ( runReiActionStub,
  )
where

import Data.Aeson (Value)
import Data.Text qualified as Text
import Shikigami.Api.Agent (Sink (..))
import Shikigami.Prelude
import Shikigami.Sink.Permission (AgentIdentity (..))
import System.IO (hPutStrLn, stderr)

runReiActionStub :: AgentIdentity -> Sink -> Value -> IO Text
runReiActionStub (AgentIdentity nm) sink _output =
  case sink of
    ReiAction {intentionId = iid, note = nt} -> do
      hPutStrLn stderr ("[sink] ReiAction stubbed for agent " <> Text.unpack nm <> " (intention " <> Text.unpack iid <> "): " <> Text.unpack nt)
      pure ("rei-action stubbed for intention " <> iid)
    _ -> pure "rei-action stub: non-ReiAction sink"

-- | The sink dispatcher (IP-5). @dispatch@ computes a sink's kind, gates it on the C11
-- permission check, and on grant routes to the per-variant handler — a denied sink is
-- logged, skipped, and recorded (never crashes the run). The worker (EP-5) calls
-- @dispatch@ once per sink in the agent's list and maps a @Failed@ outcome to a retry.
module Shikigami.Sink
  ( -- * Re-exports
    module Shikigami.Sink.Types,
    module Shikigami.Sink.Permission,
    module Shikigami.Sink.Config,

    -- * Dispatch
    sinkKindOf,
    dispatch,
  )
where

import Data.Aeson (Value)
import Data.Text qualified as Text
import Shikigami.Api.Agent (Sink (..))
import Shikigami.Prelude
import Shikigami.Sink.Config
import Shikigami.Sink.Danwa (runDanwaStub)
import Shikigami.Sink.KawaClient (buildEnvelope, postEnvelope, renderKawaError)
import Shikigami.Sink.KizashiClient (buildSignalReq, postSignal)
import Shikigami.Sink.Permission
import Shikigami.Sink.ReiAction (runReiActionStub)
import Shikigami.Sink.Types
import Shikigami.Sink.Wire (SignalResponse (..))
import System.IO (hPutStrLn, stderr)

-- | Map a sink to its permission kind.
sinkKindOf :: Sink -> SinkKind
sinkKindOf = \case
  KawaDigest {} -> SKawaDigest
  KizashiSignal {} -> SKizashiSignal
  ReiAction {} -> SReiAction
  DanwaConversation {} -> SDanwaConversation

-- | Dispatch one sink: gate on @checkGrant@, then route. Always returns a 'SinkResult'.
dispatch :: SinkContext -> Sink -> Value -> IO SinkResult
dispatch ctx sink output = do
  let kind = sinkKindOf sink
  grant <- checkGrant (sinkCtxIdentity ctx) kind
  case grant of
    Left (Denied reason) -> do
      hPutStrLn stderr ("[sink] skipped (denied): " <> Text.unpack reason)
      pure (SinkResult kind (DeniedOutcome reason))
    Right () -> SinkResult kind <$> runSink ctx sink output

-- | Route a granted sink to its handler, wrapping the outcome.
runSink :: SinkContext -> Sink -> Value -> IO SinkOutcome
runSink ctx sink output = case sink of
  KawaDigest {} -> do
    env <- buildEnvelope ctx sink output
    r <- postEnvelope (sinkCtxKawa ctx) env
    pure (either (Failed . renderKawaError) Delivered r)
  KizashiSignal {} ->
    case buildSignalReq (sinkCtxKizashi ctx) sink (sinkCtxIdentity ctx) output of
      Left e -> pure (Failed e)
      Right req -> do
        r <- postSignal (sinkCtxKizashi ctx) req
        pure (either Failed (Delivered . signalId) r)
  ReiAction {} -> Stubbed <$ runReiActionStub (sinkCtxIdentity ctx) sink output
  DanwaConversation {} -> Stubbed <$ runDanwaStub (sinkCtxIdentity ctx) sink output

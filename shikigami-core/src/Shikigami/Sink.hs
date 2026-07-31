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
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Sink.Config
import Shikigami.Sink.Danwa (runDanwa)
import Shikigami.Sink.KawaClient (buildEnvelope, postEnvelope, renderKawaError)
import Shikigami.Sink.KizashiClient (buildSignalReq, postSignal)
import Shikigami.Sink.Permission
import Shikigami.Sink.Recipient (unresolvableRecipientWarning)
import Shikigami.Sink.ReiAction (runReiAction)
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
  grant <- checkGrant (identity ctx) kind
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
    r <- postEnvelope (kawa ctx) env
    pure (either (Failed . renderKawaError) Delivered r)
  KizashiSignal {} -> do
    -- A strategy that was declared and could not be honored is said out loud;
    -- the alternative is a signal quietly reaching whoever the fallback names.
    traverse_
      (hPutStrLn stderr . Text.unpack)
      (unresolvableRecipientWarning sink (recipientOverride ctx))
    case buildSignalReq (kizashi ctx) (recipientOverride ctx) sink (identity ctx) output of
      Left e -> pure (Failed e)
      Right req -> do
        r <- postSignal (kizashi ctx) req
        pure (either Failed (Delivered . signalId) r)
  ReiAction {} -> do
    r <- runReiAction (rei ctx) ctx sink output
    pure (either Failed Delivered r)
  DanwaConversation {} -> do
    r <- runDanwa (danwa ctx) (identity ctx) (danwaTarget ctx) sink output
    pure (either Failed Delivered r)

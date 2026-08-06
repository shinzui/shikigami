-- | The sink dispatcher (IP-5). @dispatch@ computes a sink's kind, gates it on the C11
-- permission check, and on grant routes to the per-variant handler — a denied sink is
-- logged, skipped, and recorded (never crashes the run). The worker (EP-5) calls
-- @dispatch@ once per sink in the agent's list and maps a @Failed@ outcome to a retry.
module Shikigami.Sink
  ( -- * Re-exports
    module Shikigami.Sink.Types,
    module Shikigami.Sink.Permission,
    module Shikigami.Sink.Config,

    -- * The gate

    -- | Re-exported from "Shikigami.Sink.GrantStore" so the four gate call sites
    -- need one import. The row and paging types are deliberately /not/ re-exported:
    -- their @agentName@ field would collide with 'AgentIdentity''s in every module
    -- that imports this one. The CLI and tests import the store directly.
    GrantSource (..),
    checkGrant,

    -- * Dispatch
    sinkKindOf,
    dispatch,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Log qualified as Log
import Shikigami.Sink.Config
import Shikigami.Sink.Danwa (runDanwa)
import Shikigami.Sink.GrantStore (GrantSource (..), checkGrant)
import Shikigami.Sink.KawaClient (buildEnvelope, postEnvelope, renderKawaError)
import Shikigami.Sink.KizashiClient (buildSignalReq, postSignal)
import Shikigami.Sink.Permission
import Shikigami.Sink.Recipient (unresolvableRecipientWarning)
import Shikigami.Sink.ReiAction (runReiAction)
import Shikigami.Sink.Types
import Shikigami.Sink.Wire (SignalResponse (..))

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
  grant <- checkGrant (grants ctx) (identity ctx) kind
  case grant of
    Left (Denied reason) -> do
      Log.logWarn
        (logger ctx)
        "sink.denied"
        [ "agent" Aeson..= agentName (identity ctx),
          Log.runIdKey Aeson..= runId ctx,
          "sink_kind" Aeson..= sinkKindText kind,
          "reason" Aeson..= reason
        ]
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
      ( \warning ->
          Log.logWarn
            (logger ctx)
            "sink.recipient.unresolved"
            [ "agent" Aeson..= agentName (identity ctx),
              Log.runIdKey Aeson..= runId ctx,
              "sink_kind" Aeson..= sinkKindText SKizashiSignal,
              "detail" Aeson..= warning
            ]
      )
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

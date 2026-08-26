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
import Data.Generics.Labels ()
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Agent.Principal (identityText)
import Shikigami.Directory qualified as Directory
import Shikigami.Log qualified as Log
import Shikigami.Prelude (Text, (^.))
import Shikigami.Sink.Config
import Shikigami.Sink.Danwa (DanwaError (..), renderDanwaError, runDanwaWithHeaders)
import Shikigami.Sink.GrantStore (GrantSource (..), checkGrant)
import Shikigami.Sink.Http (HttpFailure)
import Shikigami.Sink.Http qualified as Http
import Shikigami.Sink.KanmonClient (KanmonError (..), buildEgressRequest, postEgressWithHeaders, renderKanmonError)
import Shikigami.Sink.KawaClient (KawaError (..), buildEnvelope, postEnvelopeWithHeaders, renderKawaError)
import Shikigami.Sink.KizashiClient (KizashiError (..), buildSignalReq, postSignalWithHeaders, renderKizashiError)
import Shikigami.Sink.Permission
import Shikigami.Sink.Recipient (unresolvableRecipientWarning)
import Shikigami.Sink.ReiAction (runReiAction)
import Shikigami.Sink.Types
import Shikigami.Sink.Wire (EgressActionResponse (..), SignalResponse (..))

-- | Map a sink to its permission kind.
sinkKindOf :: Sink -> SinkKind
sinkKindOf = \case
  KawaDigest {} -> SKawaDigest
  KizashiSignal {} -> SKizashiSignal
  ReiAction {} -> SReiAction
  DanwaConversation {} -> SDanwaConversation
  ChannelEgress {} -> SChannelEgress

-- | Dispatch one sink: gate on @checkGrant@, then route. Always returns a 'SinkResult'.
dispatch :: SinkContext -> Sink -> Value -> IO SinkResult
dispatch ctx sink output = do
  let kind = sinkKindOf sink
      agent = sinkIdentityText ctx
  lifecycle <- Directory.identityLifecycleAdmission (directory ctx) (identity ctx)
  case lifecycle of
    Left reason -> do
      Log.logWarn
        (logger ctx)
        "sink.lifecycle_skipped"
        [ "agent" Aeson..= agent,
          Log.runIdKey Aeson..= runId ctx,
          "sink_kind" Aeson..= sinkKindText kind,
          "reason" Aeson..= reason
        ]
      pure (SinkResult kind (SkippedLifecycle reason))
    Right _ -> do
      grant <- checkGrant (grants ctx) (identity ctx) kind
      case grant of
        Left (Denied reason) -> do
          Log.logWarn
            (logger ctx)
            "sink.denied"
            [ "agent" Aeson..= sinkIdentityText ctx,
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
    r <- postEnvelopeWithHeaders (http ctx ^. #kawa) (traceHeaders ctx) (kawa ctx) env
    pure (either kawaFailure Delivered r)
  KizashiSignal {} -> do
    -- A strategy that was declared and could not be honored is said out loud;
    -- the alternative is a signal quietly reaching whoever the fallback names.
    traverse_
      ( \warning ->
          Log.logWarn
            (logger ctx)
            "sink.recipient.unresolved"
            [ "agent" Aeson..= sinkIdentityText ctx,
              Log.runIdKey Aeson..= runId ctx,
              "sink_kind" Aeson..= sinkKindText SKizashiSignal,
              "detail" Aeson..= warning
            ]
      )
      (unresolvableRecipientWarning sink (recipientOverride ctx))
    case buildSignalReq (kizashi ctx) (recipientOverride ctx) sink (identity ctx) output of
      Left e -> pure (Failed e)
      Right req -> do
        r <- postSignalWithHeaders (http ctx ^. #kizashi) (traceHeaders ctx) (kizashi ctx) req
        pure (either kizashiFailure (Delivered . signalId) r)
  ReiAction {} -> do
    r <- runReiAction (Http.unauthenticatedHttpEnv (http ctx ^. #kawa)) (rei ctx) ctx sink output
    pure (either Failed Delivered r)
  DanwaConversation {} -> do
    r <- runDanwaWithHeaders (http ctx ^. #danwa) (traceHeaders ctx) (danwa ctx) (identity ctx) (receipts ctx) (danwaTarget ctx) sink output
    pure (either danwaFailure Delivered r)
  ChannelEgress {channel, action} ->
    case buildEgressRequest ctx output of
      Left failure -> pure (PermanentFailure failure)
      Right request -> do
        result <- postEgressWithHeaders (http ctx ^. #kanmon) (traceHeaders ctx) (kanmon ctx) channel action request
        pure (either kanmonFailure (Delivered . activityId) result)

sinkIdentityText :: SinkContext -> Text
sinkIdentityText ctx = either (const "unresolved-legacy") (\value -> value) (identityText (identity ctx))

kawaFailure :: KawaError -> SinkOutcome
kawaFailure failure = case failure of
  KawaHttpError httpFailure -> classifiedFailure httpFailure
  KawaDecodeError _ -> PermanentFailure (renderKawaError failure)

kizashiFailure :: KizashiError -> SinkOutcome
kizashiFailure failure = case failure of
  KizashiHttpError httpFailure -> classifiedFailure httpFailure
  KizashiDecodeError _ -> PermanentFailure (renderKizashiError failure)

danwaFailure :: DanwaError -> SinkOutcome
danwaFailure failure = case failure of
  DanwaHttpError httpFailure -> classifiedFailure httpFailure
  DanwaReceiptFailure _ -> Failed (renderDanwaError failure)
  DanwaUsageError _ -> PermanentFailure (renderDanwaError failure)

kanmonFailure :: KanmonError -> SinkOutcome
kanmonFailure failure = case failure of
  KanmonHttpError httpFailure -> classifiedFailure httpFailure
  KanmonDecodeError _ -> PermanentFailure (renderKanmonError failure)
  KanmonUsageError _ -> PermanentFailure (renderKanmonError failure)

classifiedFailure :: HttpFailure -> SinkOutcome
classifiedFailure failure
  | Http.httpFailureIsPermanent failure = PermanentFailure (Http.renderHttpFailure failure)
  | otherwise = Failed (Http.renderHttpFailure failure)

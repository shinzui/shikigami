-- | The outbox dispatcher (IP-5, reshaped by plan 135 M3).
--
-- 'dispatchOutbox' runs when the publisher delivers one sink intent. It
-- checks the principal's lifecycle, the C11 grant for the output kind and a
-- fresh C13 decision of the adapter-named target, and only then calls the
-- adapter. A refusal is logged and returned as an outcome; it never crashes
-- the publisher.
module Shikigami.Sink
  ( -- * Re-exports
    module Shikigami.Sink.Types,
    module Shikigami.Sink.Permission,

    -- * The gate

    -- | Re-exported from "Shikigami.Sink.GrantStore" so the gate call sites
    -- need one import. The row and paging types are deliberately /not/
    -- re-exported: their @agentName@ field would collide with
    -- 'AgentIdentity''s in every module that imports this one.
    GrantSource (..),
    checkGrant,

    -- * Dispatch
    dispatchOutbox,
  )
where

import Data.Aeson ((.=))
import Shikigami.Authority (AuthorityFailure (..), authorityFailureDetail, outputKindText)
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Directory qualified as Directory
import Shikigami.Log qualified as Log
import Shikigami.Sink.Authorization (authorizeOutput)
import Shikigami.Sink.GrantStore (GrantSource (..), authorityFor, checkGrant)
import Shikigami.Sink.Permission
import Shikigami.Sink.Types

-- | Dispatch one intent through its adapter's route, after the gates.
dispatchOutbox :: DirectoryHandle -> GrantSource -> OutboxRoute -> OutboxDelivery -> IO SinkResult
dispatchOutbox directory grants route delivery = do
  let kind = delivery.kind
      refused event reason = do
        Log.logWarn delivery.logger event (fields reason)
        pure (SinkResult kind (DeniedOutcome reason))
      fields reason = ["agent" .= deliverySubjectText delivery, Log.runIdKey .= delivery.runId, "sink_kind" .= outputKindText kind, "reason" .= reason]
  lifecycle <- Directory.identityLifecycleAdmission directory delivery.identity
  case lifecycle of
    Left reason -> do
      Log.logWarn delivery.logger "sink.lifecycle_skipped" (fields reason)
      pure (SinkResult kind (SkippedLifecycle reason))
    Right _ ->
      checkGrant grants delivery.identity kind >>= \case
        Left (Denied reason) -> refused "sink.denied" reason
        Right () ->
          authorizeOutput (authorityFor grants) delivery.identity kind (route.target delivery.config delivery.address) >>= \case
            Left failure@PolicyDenied {} -> refused "sink.action_denied" (authorityFailureDetail failure)
            Left failure -> do
              let reason = authorityFailureDetail failure
              Log.logError delivery.logger "sink.authorization_failed" (fields reason)
              pure (SinkResult kind (AuthorizationFailed reason))
            Right _ -> SinkResult kind <$> route.dispatch delivery

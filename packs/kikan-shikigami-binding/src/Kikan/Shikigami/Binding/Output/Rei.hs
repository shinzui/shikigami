-- | The @rei.action@ output client: hand an agent finding to @shinzui/rei@ as an
-- action against one of its intentions.
--
-- This legacy protocol still addresses /v1/agent-actions. Rei now serves a
-- typed /api/v2 contract, consumed separately by Objective.Tracker.Rei. Existing
-- durable sink messages retain their original protocol and require an explicitly
-- configured compatible ingestion endpoint; they are never silently rerouted.
module Kikan.Shikigami.Binding.Output.Rei
  ( runReiAction,
    reiActionPath,
    unconfiguredMessage,
  )
where

import Data.Aeson (Value)
import Data.Text qualified as Text
import Kikan.Shikigami.Binding.Output.Config (ReiConfig (..))
import Kikan.Shikigami.Binding.Output.Wire (ReiActionReq (..))
import Kikan.Shikigami.Binding.Outputs (ReiActionOutput (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Prelude
import Shikigami.Sink.Http (HttpEnv, postJSONWithHeaders, renderHttpFailure)
import Shikigami.Sink.Types (OutboxDelivery (..), mkSourceEventId)

-- | The path an agent action is posted to, appended to the configured base URL.
reiActionPath :: Text
reiActionPath = "/v1/agent-actions"

-- | Deliver the finding, or say why it was not delivered.
--
-- @Left@ becomes a @Failed@ outcome and therefore a failed outbox publish. Both
-- branches are real: unconfigured is a genuine non-delivery, and a configured
-- endpoint that refuses the request is a genuine transport failure.
runReiAction :: HttpEnv -> ReiConfig -> OutboxDelivery -> ReiActionOutput -> IO (Either Text Text)
runReiAction http ReiConfig {baseUrl} delivery ReiActionOutput {intentionId = iid, note = nt} =
  case baseUrl of
    Nothing -> pure (Left (unconfiguredMessage (declarationCoordinateText iid)))
    Just url -> do
      let req =
            ReiActionReq
              { intentionId = declarationCoordinateText iid,
                note = nt,
                output = delivery.result,
                sourceEventId = mkSourceEventId delivery
              }
      result <- postJSONWithHeaders http delivery.traceHeaders (url <> reiActionPath) req
      pure (either (Left . renderHttpFailure) (const (Right ("rei-action recorded for intention " <> declarationCoordinateText iid))) result)

-- | The retained legacy ingestion protocol requires explicit configuration.
unconfiguredMessage :: Text -> Text
unconfiguredMessage intentionId =
  Text.concat
    [ "ReiAction sink 'intention ",
      intentionId,
      "' not delivered: no rei endpoint is configured ",
      "(set sinks.rei.base_url to a compatible legacy ingestion service; objective trackers use the Rei v2 API separately)"
    ]

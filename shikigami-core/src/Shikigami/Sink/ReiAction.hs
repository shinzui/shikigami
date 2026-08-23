-- | The @ReiAction@ sink handler: hand an agent finding to @shinzui/rei@ as an
-- action against one of its intentions.
--
-- == Why this handler can fail on purpose
--
-- rei is a CLI application — @rei-cli@ and @rei-core@, event-sourced over
-- hasql\/pgmq — with no HTTP server. There is nothing to call over the network
-- today, and this module is honest about that rather than pretending otherwise.
--
-- It used to pretend. The previous implementation logged one line, returned a
-- @Stubbed@ outcome, and the outbox publisher counted anything that was not
-- @Failed@ as published — so every finding destined for rei was dropped while
-- the ledger said \"delivered\", permanently, with no retry and nothing to
-- notice. Failing instead leaves the outbox row unpublished: the failure is
-- visible on every publisher pass, and the day an endpoint exists and
-- @sinks.rei.base_url@ is set, the backlog drains by itself.
--
-- The alternative was rejecting @ReiAction@ at validate time. Failing loudly was
-- chosen because it keeps existing declarations deployable and self-healing; the
-- reject-at-validate treatment is applied where a declaration can /never/ become
-- resolvable — see "Shikigami.Sink.Validate".
module Shikigami.Sink.ReiAction
  ( runReiAction,
    reiActionPath,
    unconfiguredMessage,
  )
where

import Data.Aeson (Value)
import Data.Text qualified as Text
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Prelude
import Shikigami.Sink.Config (ReiConfig (..))
import Shikigami.Sink.Http (HttpEnv, postJSON, renderHttpFailure)
import Shikigami.Sink.Types (SinkContext, mkSourceEventId)
import Shikigami.Sink.Wire (ReiActionReq (..))

-- | The path an agent action is posted to, appended to the configured base URL.
reiActionPath :: Text
reiActionPath = "/v1/agent-actions"

-- | Deliver the finding, or say why it was not delivered.
--
-- @Left@ becomes a @Failed@ outcome and therefore a failed outbox publish. Both
-- branches are real: unconfigured is a genuine non-delivery, and a configured
-- endpoint that refuses the request is a genuine transport failure.
runReiAction :: HttpEnv -> ReiConfig -> SinkContext -> Sink -> Value -> IO (Either Text Text)
runReiAction http ReiConfig {baseUrl} ctx sink output =
  case sink of
    ReiAction {intentionId = iid, note = nt} ->
      case baseUrl of
        Nothing -> pure (Left (unconfiguredMessage iid))
        Just url -> do
          let req =
                ReiActionReq
                  { intentionId = iid,
                    note = nt,
                    output,
                    sourceEventId = mkSourceEventId ctx
                  }
          result <- postJSON http (url <> reiActionPath) req
          pure (either (Left . renderHttpFailure) (const (Right ("rei-action recorded for intention " <> iid))) result)
    _ -> pure (Left "runReiAction: not a ReiAction sink")

-- | What an operator reads when a finding could not be handed to rei because no
-- endpoint exists.
--
-- It names the intention that was not updated, states the reason as a fact about
-- rei rather than as a local mistake, and names the key that will fix it — the
-- most likely reader is someone watching this line repeat in the outbox
-- publisher's log and wondering what they broke.
unconfiguredMessage :: Text -> Text
unconfiguredMessage intentionId =
  Text.concat
    [ "ReiAction sink 'intention ",
      intentionId,
      "' not delivered: no rei endpoint is configured ",
      "(rei exposes no callable API yet; set sinks.rei.base_url when one exists)"
    ]

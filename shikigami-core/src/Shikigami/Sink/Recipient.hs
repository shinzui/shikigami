-- | Who a @KizashiSignal@ is actually addressed to.
--
-- A declaration says @recipientFrom = Actor@ or @SubjectOwner@ or @AreaOwner@ —
-- a /strategy/ for finding a person — while kizashi's contract takes a concrete
-- recipient string. Something has to turn one into the other, and until this
-- module existed nothing did: 'Shikigami.Agent.Decl.recipientFrom' was parsed,
-- type-checked, and then never read, so every signal went to the declared
-- default or the configured fallback no matter what the manifest asked for.
--
-- == Why resolution happens upstream of the client
--
-- Only one of the three strategies is resolvable, and the data it needs is not
-- where the sending happens. 'Shikigami.Sink.KizashiClient.buildSignalReq' sees
-- the sink, the agent identity, and the behavior output; the /actor who
-- triggered the run/ lives on the trigger activity, which only the workflow
-- holds. So the workflow resolves and the client consumes, with the answer
-- travelling between them on the journaled sink intent.
--
-- @SubjectOwner@ and @AreaOwner@ are not resolved, here or anywhere, because
-- there is no ownership directory in the platform to resolve them against.
-- Inventing a recipient would be a new silent lie in place of the one this plan
-- removes, so the two unresolvable strategies are handled at the ends instead:
-- "Shikigami.Sink.Validate" rejects a declaration that uses one without a
-- @defaultRecipient@ to fall back to, and 'unresolvableRecipientWarning' says
-- out loud, at dispatch, that the strategy was not honored.
module Shikigami.Sink.Recipient
  ( resolveRecipient,
    resolveSinkRecipient,
    recipientFor,
    unresolvableRecipientWarning,
  )
where

import Data.Text qualified as Text

-- Qualified: @Actor@ is both an activity's actor record and the name of the
-- routing strategy that reads it.
import Shikigami.Activity qualified as Activity
import Shikigami.Agent.Decl (RecipientFrom (..), Sink (..))
import Shikigami.Prelude

-- | Turn a routing strategy into a concrete recipient, when the data allows it.
--
-- 'Nothing' means \"this strategy cannot be answered\", which is a different
-- thing from \"no recipient\": the caller still falls back to the declaration's
-- own default.
resolveRecipient :: RecipientFrom -> Maybe Activity.ActivityEnvelope -> Maybe Text
resolveRecipient strategy activity =
  case strategy of
    Actor -> fmap actorIdOf activity
    SubjectOwner -> Nothing
    AreaOwner -> Nothing
  where
    actorIdOf Activity.ActivityEnvelope {Activity.actor = Activity.Actor {Activity.id = actorId}} = actorId

-- | 'resolveRecipient' for a whole sink: a non-signal sink has no recipient to
-- resolve, so it contributes nothing to the intent.
resolveSinkRecipient :: Sink -> Maybe Activity.ActivityEnvelope -> Maybe Text
resolveSinkRecipient sink activity =
  case sink of
    KizashiSignal {recipientFrom} -> resolveRecipient recipientFrom activity
    _ -> Nothing

-- | The recipient a signal is sent to, in precedence order.
--
-- A resolved strategy wins, because it is the most specific thing anyone said.
-- The declaration's own @defaultRecipient@ comes next, because a manifest author
-- chose it for this signal. The deployment-wide fallback is last, because it
-- knows nothing about either.
recipientFor ::
  -- | The deployment-wide fallback, from @sinks.kizashi.default_recipient@.
  Text ->
  -- | What the strategy resolved to, if anything.
  Maybe Text ->
  -- | The declaration's own @defaultRecipient@.
  Maybe Text ->
  Text
recipientFor fallback resolved declared =
  fromMaybe fallback (resolved <|> declared)

-- | One line naming a routing strategy that was asked for and not honored.
--
-- Emitted at dispatch rather than swallowed, because the alternative is a signal
-- quietly reaching the wrong person. Validation already refuses the case where
-- there is nothing to fall back to; this covers the case where the fallback is
-- legitimate but the operator should still know the strategy did nothing.
unresolvableRecipientWarning :: Sink -> Maybe Text -> Maybe Text
unresolvableRecipientWarning sink resolved =
  case sink of
    KizashiSignal {recipientFrom}
      | isNothing resolved,
        strategyNeedsDirectory recipientFrom ->
          Just
            ( "[sink] KizashiSignal recipientFrom="
                <> renderRecipientFrom recipientFrom
                <> " is not resolvable (no ownership directory); using declared defaultRecipient"
            )
    _ -> Nothing

strategyNeedsDirectory :: RecipientFrom -> Bool
strategyNeedsDirectory = \case
  SubjectOwner -> True
  AreaOwner -> True
  Actor -> False

renderRecipientFrom :: RecipientFrom -> Text
renderRecipientFrom = Text.pack . show

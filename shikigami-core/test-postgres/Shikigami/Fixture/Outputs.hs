-- | Output adapters for the kernel's workflow tests (plan 135, M3).
--
-- The kernel's tests exercise its output port — resolution, approval, the
-- enqueue-time and publish-time gates, receipts — not any service. These
-- adapters are registered under the kinds the fixture declarations name and
-- deliver nowhere: 'unreachableOutputs' fails every delivery, and
-- 'capturingOutputs' records each delivery it is handed. The Kikan adapters'
-- own delivery is qualified by the binding's and the distribution's suites.
module Shikigami.Fixture.Outputs
  ( fixtureOutputKinds,
    unreachableOutputs,
    capturingOutputs,
    capturingApprovalChannel,
  )
where

import Data.Aeson (Value (Null))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Workflow.Awakeable (AwakeableId)
import Shikigami.Agent.Approval (ApprovalRequest, ReviewRequestId)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Approval.Channel (ApprovalChannelAdapter (..))
import Shikigami.Fixture.RawOutput (fixtureKind)
import Shikigami.Output (DefaultOutput (NoDefaultOutput), OutputAdapter (..), OutputRegistry, OutputRoute (..), mkOutputRegistry)
import Shikigami.Sink.Types (OutboxDelivery (..), OutboxRoute (..), SinkOutcome (..))

-- | The kinds the fixture declarations name.
fixtureOutputKinds :: [Text]
fixtureOutputKinds = ["kawa.digest", "kizashi.signal", "danwa.conversation", "rei.action", "channel.egress"]

-- | Every delivery fails; a test that reaches one fails loudly.
unreachableOutputs :: OutputRegistry
unreachableOutputs = registryOf (\_ -> pure (Failed "the fixture output is unreachable"))

-- | Each delivery is recorded and acknowledged with an id naming its order.
capturingOutputs :: IO (OutputRegistry, IO [OutboxDelivery])
capturingOutputs = do
  seen <- newIORef []
  pure (registryOf (capture seen), reverse <$> readIORef seen)
  where
    capture :: IORef [OutboxDelivery] -> OutboxDelivery -> IO SinkOutcome
    capture seen delivery = do
      count <- atomicModifyIORef' seen (\deliveries -> (delivery : deliveries, length deliveries + 1))
      pure (Delivered (declarationCoordinate ("fixture-" <> Text.pack (show count))))

-- | An approval channel recording each ask it posts.
capturingApprovalChannel :: IO (ApprovalChannelAdapter, IO [(ReviewRequestId, AwakeableId, ApprovalRequest)])
capturingApprovalChannel = do
  asks <- newIORef []
  pure
    ( ApprovalChannelAdapter \reviewId awakeableId _deadline request ->
        Right () <$ atomicModifyIORef' asks (\posted -> ((reviewId, awakeableId, request) : posted, ())),
      reverse <$> readIORef asks
    )

registryOf :: (OutboxDelivery -> IO SinkOutcome) -> OutputRegistry
registryOf dispatch =
  either (error . Text.unpack) id (mkOutputRegistry (adapter <$> fixtureOutputKinds) NoDefaultOutput)
  where
    adapter kind =
      OutputAdapter
        { kind = fixtureKind kind,
          validate = const (Right ()),
          route =
            DeliverByOutbox
              OutboxRoute
                { address = const Null,
                  target = \_ _ -> Right ("fixture" :| []),
                  dispatch
                }
        }

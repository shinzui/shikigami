-- | One bracketed Shibuya application owned by a consumer connection.
module Shikigami.Workers.ConsumerApp
  ( withConsumerApp,
    withConsumerAppAcquisition,
    consumerAppConfig,
    ConsumerProcessorFailure (..),
  )
where

import Control.Exception (Exception)
import Control.Monad (when)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Exception qualified as Exception
import Shibuya.App qualified as Shibuya
import Shibuya.Metrics.Health qualified as Health
import Shibuya.Telemetry.Effect (Tracing)

data ConsumerProcessorFailure = ConsumerProcessorFailure
  deriving stock (Show)

instance Exception ConsumerProcessorFailure

consumerAppConfig :: Shibuya.AppConfig
consumerAppConfig =
  Shibuya.defaultAppConfig
    { Shibuya.strategy = Shibuya.StopAllOnFailure,
      Shibuya.inboxSize = 1
    }

withConsumerApp :: (IOE :> es, Tracing :> es) => Shibuya.AppConfig -> [(Shibuya.ProcessorId, Shibuya.QueueProcessor es)] -> (Shibuya.AppHandle es -> Eff es a) -> Eff es (Either Shibuya.AppError a)
withConsumerApp config processors = withConsumerAppAcquisition (Shibuya.runApp config processors)

-- | Adopt the public runtime's allocator without allocating another supervisor.
-- Mask the ownership transfer; restore cancellation only after cleanup is armed.
-- Keep adapters alive through stop, including callback failure and cancellation.
-- Inspect retained lifecycle before stop unregisters live metrics: a failed
-- processor must reach process supervision rather than reconnect as a graceful
-- ordered halt. This also accepts Keiro's supported runJobWorkers allocator.
withConsumerAppAcquisition :: (IOE :> es) => Eff es (Either Shibuya.AppError (Shibuya.AppHandle es)) -> (Shibuya.AppHandle es -> Eff es a) -> Eff es (Either Shibuya.AppError a)
withConsumerAppAcquisition acquire action = Exception.mask \restore -> do
  allocated <- acquire
  traverse
    ( \app ->
        restore
          ( do
              value <- action app
              health <- liftIO (Health.checkReadiness Health.defaultHealthConfig (Shibuya.getAppMaster app) [])
              when (health.application == Health.ApplicationFailed) (Exception.throwIO ConsumerProcessorFailure)
              pure value
          )
          `Exception.finally` Shibuya.stopApp app
    )
    allocated

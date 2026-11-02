-- | Bounded scheduling only. All admissions, imports, claims and delivery state
-- transitions remain in the shared tracker command owner and executor.
module Shikigami.Objective.Tracker.Worker (runTrackerWorker, trackerLoopRegistration) where

import Control.Concurrent (threadDelay)
import Data.Maybe (listToMaybe)
import Shikigami.App (runAppIO)
import Shikigami.Health.Worker (LoopName (ObjectiveTrackerLoop), LoopStaleness, beat, loopStaleness)
import Shikigami.Log qualified as Log
import Shikigami.Objective.Tracker.Config
import Shikigami.Objective.Tracker.Dispatch qualified as Dispatch
import Shikigami.Objective.Tracker.Store qualified as Store
import Shikigami.Objective.Tracker.Types
import Shikigami.Prelude
import Shikigami.Workers.Config (WorkerEnv (..))

trackerLoopRegistration :: TrackerSettings -> [(LoopName, LoopStaleness)]
trackerLoopRegistration settings
  | settings.enabled == TrackersDisabled = []
  | otherwise = [(ObjectiveTrackerLoop, loopStaleness (fromIntegral (settings.pollSeconds + 45 * settings.batchSize + 30)))]

runTrackerWorker :: WorkerEnv -> Store.TrackerHost -> IO ()
runTrackerWorker env host = loop Nothing
  where
    loop after = do
      result <- runAppIO env.appEnv (Store.scheduledBindings host after)
      next <- case result of
        Right (Right keys) -> do
          forM_ keys \(objective, identifier) -> do
            outcome <- runAppIO env.appEnv do
              binding <- Store.inspectBinding host objective identifier
              case binding of
                Right current | current.state == Active -> void (Store.observe host objective identifier)
                _ -> pure ()
              pending <- Store.nextPublication host objective identifier
              case pending of
                Right (Just (intent, receipt)) | receipt.state == Unknown -> void (Dispatch.reconcile host objective intent.publicationId)
                Right (Just (intent, _)) -> void (Dispatch.dispatch host objective intent.publicationId)
                _ -> pure ()
            case outcome of Left _ -> Log.logWarn env.logger "worker.objective_tracker.binding_unavailable" []; _ -> pure ()
          pure (if length keys < host.settings.batchSize then Nothing else snd <$> listToMaybe (reverse keys))
        _ -> Log.logWarn env.logger "worker.objective_tracker.scan_unavailable" [] >> pure after
      beat env.heartbeats ObjectiveTrackerLoop
      threadDelay (host.settings.pollSeconds * 1_000_000)
      loop next

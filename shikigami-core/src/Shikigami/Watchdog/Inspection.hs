{-# LANGUAGE DataKinds #-}

-- | Read-only operator views. Missing coverage is distinct from an empty pass.
module Shikigami.Watchdog.Inspection (InspectionView (..), EpisodeFilter (..), OverdueVerdict (..), overdueVerdict) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime, addUTCTime)
import GHC.Generics (Generic)
import Shikigami.Duration (Duration, durationTime)
import Shikigami.Objective.Types (ObjectiveId)
import Shikigami.Trigger.Schedule (CronSchedule, nextDue)
import Shikigami.Watchdog.Ledger (Coverage, SweepView (..))

data InspectionView = InspectionView
  { latestAttempt :: !(Maybe SweepView),
    lastCompletedSweep :: !(Maybe SweepView),
    coverage :: !(Maybe Coverage),
    openEpisodes :: !Word,
    inspectedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data EpisodeFilter = EpisodeFilter {openOnly :: !Bool, objective :: !(Maybe ObjectiveId)}
  deriving stock (Eq, Show, Generic)

data OverdueVerdict = SweepFresh | SweepOverdue {expectedBy :: !UTCTime} | NoSweepYet | ScheduleUnknown
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

overdueVerdict :: CronSchedule -> Duration "watchdog-grace" -> UTCTime -> Maybe SweepView -> OverdueVerdict
overdueVerdict cron grace now completed = case completed >>= (.completedAt) of
  Nothing -> NoSweepYet
  Just at -> case nextDue cron at of
    Nothing -> ScheduleUnknown
    Just due
      | now > addUTCTime (durationTime grace) due -> SweepOverdue (addUTCTime (durationTime grace) due)
      | otherwise -> SweepFresh

-- | The schedule trigger evaluator (C3, class 1). Wraps the Hackage @cron@ package so
-- a declared agent's free-text five-field cron string can be answered with a pure
-- @isDue cron now@. (rei's enum-based evaluator cannot express arbitrary cron strings
-- and is not a library — see the Decision Log.)
module Shikigami.Trigger.Schedule
  ( CronSchedule,
    parseCron,
    isDue,
  )
where

import Data.Text qualified as Text
import Shikigami.Prelude
import System.Cron qualified as Cron

-- | A parsed cron schedule (opaque; construct via 'parseCron').
newtype CronSchedule = CronSchedule Cron.CronSchedule
  deriving stock (Eq, Show)

-- | Parse a standard five-field cron expression ("min hour day-of-month month day-of-week").
parseCron :: Text -> Either Text CronSchedule
parseCron t = bimap Text.pack CronSchedule (Cron.parseCronSchedule t)

-- | True when the cron expression matches the given instant (to the minute).
isDue :: CronSchedule -> UTCTime -> Bool
isDue (CronSchedule s) = Cron.scheduleMatches s

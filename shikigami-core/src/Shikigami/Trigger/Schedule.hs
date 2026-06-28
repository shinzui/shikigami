-- | The schedule trigger evaluator (C3, class 1). Wraps the Hackage @cron@ package so
-- a declared agent's free-text five-field cron string can be answered with a pure
-- @isDue cron now@. (rei's enum-based evaluator cannot express arbitrary cron strings
-- and is not a library — see the Decision Log.)
module Shikigami.Trigger.Schedule
  ( CronSchedule,
    parseCron,
    isDue,
    nextDue,
  )
where

import Data.Text qualified as Text
import Data.Time.Clock (addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
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

-- | The next matching minute strictly after @now@, bounded to one leap year.
nextDue :: CronSchedule -> UTCTime -> Maybe UTCTime
nextDue cron now = go 0 (nextWholeMinute now)
  where
    maxMinutes = 366 * 24 * 60 :: Int

    go n candidate
      | n > maxMinutes = Nothing
      | isDue cron candidate = Just candidate
      | otherwise = go (n + 1) (addUTCTime 60 candidate)

nextWholeMinute :: UTCTime -> UTCTime
nextWholeMinute now =
  posixSecondsToUTCTime (fromInteger nextMinute)
  where
    seconds = floor (utcTimeToPOSIXSeconds now) :: Integer
    nextMinute = ((seconds `div` 60) + 1) * 60

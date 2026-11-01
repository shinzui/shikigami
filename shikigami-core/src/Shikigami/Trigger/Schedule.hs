-- | The schedule trigger evaluator (C3, class 1). Wraps the Hackage @cron@ package so
-- a declared agent's free-text five-field cron string can be answered with a pure
-- @isDue cron now@. (rei's enum-based evaluator cannot express arbitrary cron strings
-- and is not a library — see the Decision Log.)
module Shikigami.Trigger.Schedule
  ( CronExpressionClaim,
    cronExpressionClaim,
    cronExpressionText,
    CronSchedule,
    parseCron,
    isDue,
    nextDue,
    CatchUpPolicy (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text qualified as Text
import Data.Time.Clock (addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Dhall (FromDhall (..))
import Dhall qualified
import Shikigami.Prelude
import System.Cron qualified as Cron

-- | An exact operator declaration. The scheduler owns parsing and its existing
-- strict/lenient diagnostics before a claim becomes an admitted timer schedule.
newtype CronExpressionClaim = CronExpressionClaim Text
  deriving stock (Eq, Show)
  deriving newtype (ToJSON, FromJSON)

cronExpressionClaim :: Text -> CronExpressionClaim
cronExpressionClaim = CronExpressionClaim

cronExpressionText :: CronExpressionClaim -> Text
cronExpressionText (CronExpressionClaim value) = value

instance FromDhall CronExpressionClaim where autoWith _ = CronExpressionClaim <$> Dhall.strictText

-- | A parsed cron schedule (opaque; construct via 'parseCron').
newtype CronSchedule = CronSchedule Cron.CronSchedule
  deriving stock (Eq, Show)

-- | Parse a standard five-field cron expression ("min hour day-of-month month day-of-week").
parseCron :: Text -> Either Text CronSchedule
parseCron t = bimap Text.pack CronSchedule (Cron.parseCronSchedule t)

-- | True when the cron expression matches the given instant (to the minute).
isDue :: CronSchedule -> UTCTime -> Bool
isDue (CronSchedule s) = Cron.scheduleMatches s

-- | What the scheduler does about cron minutes that passed while it was down.
--
-- The scheduler arms one durable timer at a time and re-arms after each firing.
-- The policy is the choice of what instant it re-arms /from/: the tick that just
-- fired, or the moment it is running now.
data CatchUpPolicy
  = -- | Arm the first tick strictly after now. Waking a day late produces the
    -- one run for the timer that was already due, then the normal cadence.
    SkipMissed
  | -- | Arm from the tick that just fired, so every missed minute runs. This is
    -- the pre-policy behavior: a @* * * * *@ agent that was offline for a day
    -- drains 1440 stale runs, each with its own idempotency key.
    FireAll
  deriving stock (Eq, Show)

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

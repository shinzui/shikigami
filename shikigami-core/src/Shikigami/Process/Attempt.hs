-- | One durable attempt of an external process that must outlive the worker.
--
-- An attempt directory holds what the attempt is: an intent written before
-- the spawn, a launch record (pid and start time) written after it, and the
-- result file the launched process writes atomically when it exits. After a
-- restart the attempt is recovered from those facts alone, by the pure
-- 'recoverAttempt': a complete result is collected, a live launcher is
-- reattached, and anything else whose fate cannot be established gives up as
-- uncertain. An attempt is never launched twice automatically (ADR-60).
--
-- Nothing here knows about coding agents. EP-2's coding-agent runner is the
-- first instance; EP-3's durable declared-tool steps are the second.
module Shikigami.Process.Attempt
  ( AttemptIntent (..),
    LaunchRecord (..),
    EnvelopeState (..),
    LauncherState (..),
    AttemptFacts (..),
    RecoveryDecision (..),
    recoverAttempt,
    reattachGrace,
    AttemptResult (..),
    UncertainReason (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import GHC.Generics (Generic)
import Shikigami.CodingAgent.Types (UncertainReason (..))

-- | Written before the spawn, so a crash between the two is visible.
newtype AttemptIntent = AttemptIntent {at :: UTCTime}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Written after the spawn. The start time distinguishes a reused pid.
data LaunchRecord = LaunchRecord
  { pid :: !Int,
    startedAt :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data EnvelopeState r
  = NoEnvelope
  | -- | A result file exists but does not parse.
    PartialEnvelope
  | Envelope !r
  deriving stock (Eq, Show)

data LauncherState
  = LauncherAbsent
  | LauncherRunning
  | -- | The recorded pid is gone, or now names another process.
    LauncherGone
  deriving stock (Eq, Show)

data AttemptFacts r = AttemptFacts
  { intent :: !(Maybe AttemptIntent),
    launch :: !(Maybe LaunchRecord),
    envelope :: !(EnvelopeState r),
    launcher :: !LauncherState,
    now :: !UTCTime,
    deadline :: !UTCTime
  }

data RecoveryDecision r
  = -- | Nothing was ever attempted.
    LaunchFresh
  | -- | A complete result exists: use it, never relaunch.
    Collect !r
  | -- | The launcher is alive: wait for it.
    Reattach !LaunchRecord
  | GiveUp !UncertainReason
  deriving stock (Eq, Show)

-- | How long past its deadline a live launcher is still waited for.
reattachGrace :: NominalDiffTime
reattachGrace = 60

-- | The recovery rules, in order: a complete result is collected; a live
-- launcher inside the deadline plus grace is reattached, and past it gives up
-- as overrun (it is not killed); an intent without a launch record, or a gone
-- launcher without a complete result, gives up; otherwise launch fresh.
recoverAttempt :: AttemptFacts r -> RecoveryDecision r
recoverAttempt AttemptFacts {intent, launch, envelope, launcher, now, deadline} = case envelope of
  Envelope result -> Collect result
  _ -> case (launcher, launch) of
    (LauncherRunning, Just record)
      | now <= addUTCTime reattachGrace deadline -> Reattach record
      | otherwise -> GiveUp LauncherOverran
    _ -> case (intent, launch, envelope) of
      (Just _, Nothing, _) -> GiveUp IntentWithoutLaunch
      (_, Just _, PartialEnvelope) -> GiveUp UnreadableResult
      (_, Just _, _) -> GiveUp LauncherGoneWithoutResult
      (Nothing, Nothing, PartialEnvelope) -> GiveUp UnreadableResult
      (Nothing, Nothing, _) -> LaunchFresh

-- | What the journaled @attempt@ step returns.
data AttemptResult r
  = Collected !r
  | GaveUp !UncertainReason
  | -- | The spawn itself failed, so nothing ran.
    NotLaunched !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

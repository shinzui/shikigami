{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

-- | Journaled read authority and advisory ledger writes, as the sweep's own
-- capability. No owner commands. The interpreter is in the pack library.
module FlowPack.Watchdog.Capability
  ( Observe (..),
    Granted (..),
    SweepOpened (..),
    ObservedPage (..),
    resolveGrant,
    openSweep,
    observeActive,
    recordPage,
    recordDrift,
    closeSweep,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import FlowPack.Watchdog.Classify (Observed (..), PriorMark)
import FlowPack.Watchdog.Drift qualified as Drift
import FlowPack.Watchdog.Grant
import FlowPack.Watchdog.Ledger qualified as Ledger
import FlowPack.Watchdog.Observation
import FlowPack.Watchdog.Types
import GHC.Generics (Generic)
import Shikigami.Objective.Observation qualified as Objective

data Granted = Granted {grant :: !GrantSnapshot, delivery :: !(Maybe DeliveryPolicy), driftEnabled :: !Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SweepOpened = SweepOpened {sweepId :: !SweepId, cursor :: !CoverageCursor, openedAt :: !UTCTime}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ObservedPage = ObservedPage
  { page :: !ObservationPage,
    priors :: !(Map SubjectKey PriorMark),
    checks :: !(Map SubjectKey Drift.DriftCheck),
    objectives :: ![Objective.ObjectiveObservation]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ObservedPage where
  toJSON value = object ["page" .= value.page, "priors" .= Map.toList value.priors, "checks" .= Map.toList value.checks, "objectives" .= value.objectives]

instance FromJSON ObservedPage where
  parseJSON = withObject "ObservedPage" \fields -> ObservedPage <$> fields .: "page" <*> (Map.fromList <$> fields .: "priors") <*> (Map.fromList <$> fields .: "checks") <*> fields .: "objectives"

data Observe :: Effect where
  ResolveGrant :: Observe m (Either GrantRefusal Granted)
  OpenSweep :: Granted -> Observe m (Either Ledger.WatchdogError SweepOpened)
  ObserveActive :: Granted -> CoverageCursor -> Observe m (Either ObservationError ObservedPage)
  RecordPage :: SweepId -> ObservedPage -> [Observed] -> Observe m (Either Ledger.WatchdogError Ledger.PageOutcomeView)
  RecordDrift :: SweepId -> UTCTime -> [Observed] -> NonEmpty Drift.DriftCheck -> Observe m (Either Ledger.WatchdogError Ledger.PageOutcomeView)
  CloseSweep :: SweepId -> Ledger.SweepSummary -> Observe m (Either Ledger.WatchdogError UTCTime)

type instance DispatchOf Observe = Dynamic

resolveGrant :: (Observe :> es) => Eff es (Either GrantRefusal Granted)
resolveGrant = send ResolveGrant

openSweep :: (Observe :> es) => Granted -> Eff es (Either Ledger.WatchdogError SweepOpened)
openSweep = send . OpenSweep

observeActive :: (Observe :> es) => Granted -> CoverageCursor -> Eff es (Either ObservationError ObservedPage)
observeActive grant = send . ObserveActive grant

recordPage :: (Observe :> es) => SweepId -> ObservedPage -> [Observed] -> Eff es (Either Ledger.WatchdogError Ledger.PageOutcomeView)
recordPage sweep page = send . RecordPage sweep page

recordDrift :: (Observe :> es) => SweepId -> UTCTime -> [Observed] -> NonEmpty Drift.DriftCheck -> Eff es (Either Ledger.WatchdogError Ledger.PageOutcomeView)
recordDrift sweep at outcomes = send . RecordDrift sweep at outcomes

closeSweep :: (Observe :> es) => SweepId -> Ledger.SweepSummary -> Eff es (Either Ledger.WatchdogError UTCTime)
closeSweep sweep = send . CloseSweep sweep

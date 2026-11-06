{-# LANGUAGE DataKinds #-}

-- | A grant is read authority, never objective membership or command authority.
-- Snapshots have no principal and must pass the identity gate again on replay.
module Shikigami.Watchdog.Grant
  ( ObservationGrant,
    resolveObservationGrant,
    restoreGrant,
    grantPrincipal,
    grantScope,
    grantWindows,
    grantBudget,
    GrantSnapshot (..),
    snapshotGrant,
    GrantRefusal (..),
    module Shikigami.Watchdog.Settings,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikigami.Agent.Principal (AgentIdentity (..))
import Shikigami.Duration (durationTime, parseDuration)
import Shikigami.Watchdog.Settings
import Shikigami.Watchdog.Types (WatchdogLimit, Windows (..))

-- Positional private fields prevent public record updates. No Generic or decoder.
data ObservationGrant = ObservationGrant !AgentIdentity !ObservationScope !Windows !(WatchdogLimit "subjects")

grantPrincipal :: ObservationGrant -> AgentIdentity
grantPrincipal (ObservationGrant principal _ _ _) = principal

grantScope :: ObservationGrant -> ObservationScope
grantScope (ObservationGrant _ scope _ _) = scope

grantWindows :: ObservationGrant -> Windows
grantWindows (ObservationGrant _ _ windows _) = windows

grantBudget :: ObservationGrant -> WatchdogLimit "subjects"
grantBudget (ObservationGrant _ _ _ budget) = budget

data GrantSnapshot = GrantSnapshot
  { scope :: !ObservationScope,
    windows :: !Windows,
    budget :: !(WatchdogLimit "subjects")
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON GrantSnapshot where
  toJSON value = object ["scope" .= value.scope, "windows" .= value.windows, "budget" .= value.budget]

instance FromJSON GrantSnapshot where
  parseJSON = withObject "GrantSnapshot" \fields -> GrantSnapshot <$> fields .: "scope" <*> fields .: "windows" <*> fields .: "budget"

snapshotGrant :: ObservationGrant -> GrantSnapshot
snapshotGrant (ObservationGrant _ scope windows budget) = GrantSnapshot scope windows budget

data GrantRefusal = NotTheWatchdogPrincipal | WatchdogDisabled | UnresolvedIdentity
  deriving stock (Eq, Show)

instance ToJSON GrantRefusal where
  toJSON =
    toJSON . \case
      NotTheWatchdogPrincipal -> ("not-the-watchdog-principal" :: Text)
      WatchdogDisabled -> "watchdog-disabled"
      UnresolvedIdentity -> "unresolved-identity"

instance FromJSON GrantRefusal where
  parseJSON = withText "GrantRefusal" \case
    "not-the-watchdog-principal" -> pure NotTheWatchdogPrincipal
    "watchdog-disabled" -> pure WatchdogDisabled
    "unresolved-identity" -> pure UnresolvedIdentity
    _ -> fail "unknown watchdog grant refusal"

checkIdentity :: Maybe WatchdogSettings -> AgentIdentity -> Either GrantRefusal WatchdogSettings
checkIdentity Nothing _ = Left WatchdogDisabled
checkIdentity (Just _) UnresolvedLegacyIdentity = Left UnresolvedIdentity
checkIdentity (Just settings) identity
  | identity == settings.principal = Right settings
  | otherwise = Left NotTheWatchdogPrincipal

resolveObservationGrant :: Maybe WatchdogSettings -> AgentIdentity -> Either GrantRefusal ObservationGrant
resolveObservationGrant settings identity = do
  admitted <- checkIdentity settings identity
  -- Drift is disabled until the cadence owner adds its explicit setting. Its
  -- positive placeholder is never used for a model call by this observation slice.
  drift <- either (const (Left WatchdogDisabled)) Right (parseDuration (durationTime admitted.stuckWindowSeconds))
  pure (ObservationGrant identity admitted.scope (Windows admitted.stuckWindowSeconds admitted.parkedWindowSeconds admitted.coordinatorWindowSeconds drift) admitted.subjectsPerSweep)

restoreGrant :: GrantSnapshot -> AgentIdentity -> Maybe WatchdogSettings -> Either GrantRefusal ObservationGrant
restoreGrant snapshot identity settings = do
  _ <- checkIdentity settings identity
  pure (ObservationGrant identity snapshot.scope snapshot.windows snapshot.budget)

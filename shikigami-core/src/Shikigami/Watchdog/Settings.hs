{-# LANGUAGE DataKinds #-}

-- | Operator-owned read policy. Omission from AppConfig disables observation.
module Shikigami.Watchdog.Settings (WatchdogSettings (..), ObservationScope (..)) where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (String), object, withObject, withText, (.:), (.:?), (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Shikigami.Agent.Name (agentNameText, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (..), mkAgentPrincipal, principalText)
import Shikigami.Duration (Duration, durationTime)
import Shikigami.Objective.Types (ObjectiveId)
import Shikigami.Watchdog.Types (WatchdogLimit, limitValue)

data ObservationScope = AllObjectives | SelectedObjectives !(NonEmpty ObjectiveId)
  deriving stock (Eq, Show, Generic)

instance ToJSON ObservationScope where
  toJSON AllObjectives = String "all"
  toJSON (SelectedObjectives values) = object ["objectives" .= values]

instance FromJSON ObservationScope where
  parseJSON (String "all") = pure AllObjectives
  parseJSON value =
    withObject
      "watchdog scope"
      ( \fields -> do
          unless (KeyMap.keys fields == ["objectives"]) (fail "scope requires only objectives")
          SelectedObjectives <$> fields .: "objectives"
      )
      value

data WatchdogSettings = WatchdogSettings
  { principal :: !AgentIdentity,
    scope :: !ObservationScope,
    stuckWindowSeconds :: !(Duration "watchdog-stuck"),
    parkedWindowSeconds :: !(Duration "watchdog-parked"),
    coordinatorWindowSeconds :: !(Duration "watchdog-coordinator"),
    subjectsPerSweep :: !(WatchdogLimit "subjects"),
    driftIntervalSeconds :: !(Maybe (Duration "watchdog-drift")),
    driftSubjectsPerSweep :: !(Maybe (WatchdogLimit "drift-subjects"))
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON WatchdogSettings where
  parseJSON = withObject "watchdog" \fields -> do
    unless (all (`elem` ["principal", "scope", "stuckWindowSeconds", "parkedWindowSeconds", "coordinatorWindowSeconds", "subjectsPerSweep", "driftIntervalSeconds", "driftSubjectsPerSweep"]) (KeyMap.keys fields)) (fail "unknown watchdog setting")
    principal <-
      fields .: "principal"
        >>= withText
          "watchdog principal"
          ( \value ->
              either
                (fail . Text.unpack)
                pure
                ( if "agent_" `Text.isPrefixOf` value
                    then VerifiedIdentity <$> mkAgentPrincipal value
                    else CompatibilityIdentity <$> mkAgentName value
                )
          )
    settings <- WatchdogSettings principal <$> fields .: "scope" <*> fields .: "stuckWindowSeconds" <*> fields .: "parkedWindowSeconds" <*> fields .: "coordinatorWindowSeconds" <*> fields .: "subjectsPerSweep" <*> fields .:? "driftIntervalSeconds" <*> fields .:? "driftSubjectsPerSweep"
    unless (durationTime settings.stuckWindowSeconds > 0 && durationTime settings.parkedWindowSeconds > 0 && durationTime settings.coordinatorWindowSeconds > 0) (fail "watchdog windows must be positive")
    unless (isJust settings.driftIntervalSeconds == isJust settings.driftSubjectsPerSweep && maybe True ((> 0) . durationTime) settings.driftIntervalSeconds && maybe True ((<= 16) . limitValue) settings.driftSubjectsPerSweep) (fail "drift needs a positive interval and a subject limit in 1..16 together")
    pure settings

instance ToJSON WatchdogSettings where
  toJSON value =
    object
      [ "principal" .= case value.principal of
          VerifiedIdentity principal -> principalText principal
          CompatibilityIdentity name -> agentNameText name
          UnresolvedLegacyIdentity -> ("unresolved-legacy" :: Text),
        "scope" .= value.scope,
        "stuckWindowSeconds" .= value.stuckWindowSeconds,
        "parkedWindowSeconds" .= value.parkedWindowSeconds,
        "coordinatorWindowSeconds" .= value.coordinatorWindowSeconds,
        "subjectsPerSweep" .= value.subjectsPerSweep,
        "driftIntervalSeconds" .= value.driftIntervalSeconds,
        "driftSubjectsPerSweep" .= value.driftSubjectsPerSweep
      ]

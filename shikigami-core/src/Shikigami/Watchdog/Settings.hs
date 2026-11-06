{-# LANGUAGE DataKinds #-}

-- | Operator-owned read policy. Omission from AppConfig disables observation.
module Shikigami.Watchdog.Settings (WatchdogSettings (..), DeliveryPolicy (..), WatchdogAllowance (..), ObservationScope (..)) where

import Control.Monad (forM, unless)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, withText, (.:), (.:?), (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, declarationCoordinate)
import Shikigami.Agent.Name (agentNameText, mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity (..), AgentPrincipal, mkAgentPrincipal, principalText)
import Shikigami.Duration (Duration, durationTime)
import Shikigami.Execution.Quantity (amountUnits)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Objective.Types (ObjectiveId)
import Shikigami.Sink.Validate (sinkErrors)
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

-- | Installing a declaration cannot allocate spend. This policy is operator owned.
data WatchdogAllowance = WatchdogAllowance
  { principal :: !AgentPrincipal,
    flow :: !(DeclarationCoordinate "flow"),
    cutoffSeconds :: !(Duration "watchdog-run"),
    limits :: !Resources.Limits
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON WatchdogAllowance where
  toJSON value = object ["principal" .= principalText value.principal, "flow" .= value.flow, "cutoffSeconds" .= value.cutoffSeconds, "limits" .= Map.fromList [(Text.pack (show dimension), encodeLimit limit) | (dimension, limit) <- Map.toList value.limits]]
    where
      encodeLimit (Resources.Limited amount) = toJSON amount
      encodeLimit Resources.ExplicitlyUnbounded = String "unbounded"

instance FromJSON WatchdogAllowance where
  parseJSON = withObject "watchdog allowance" \fields -> do
    principal <- fields .: "principal" >>= withText "watchdog allowance principal" (either (fail . Text.unpack) pure . mkAgentPrincipal)
    rawLimits <- fields .: "limits"
    limits <-
      Map.fromList
        <$> forM
          (Map.toList (rawLimits :: Map.Map Text Value))
          ( \(key, value) -> do
              dimension <- parseJSON (String key)
              limit <- case value of String "unbounded" -> pure Resources.ExplicitlyUnbounded; _ -> Resources.Limited <$> parseJSON value
              pure (dimension, limit)
          )
    allowance <- WatchdogAllowance principal <$> fields .: "flow" <*> fields .: "cutoffSeconds" <*> pure limits
    unless (allowance.flow == declarationCoordinate "watchdog-sweep") (fail "watchdog allowance names another Flow")
    unless (all (\(dimension, limit) -> dimension == Resources.CostMicroUsd || case limit of Resources.Limited _ -> True; _ -> False) (Map.toList allowance.limits)) (fail "watchdog dimensions other than cost must be bounded")
    unless (durationTime allowance.cutoffSeconds > 0) (fail "watchdog cutoff must be positive")
    unless (all (bounded allowance.limits) [Resources.ActiveWork, Resources.ModelAttempts, Resources.Tokens] && Map.lookup Resources.CostMicroUsd allowance.limits == Just Resources.ExplicitlyUnbounded) (fail "watchdog needs bounded positive active work, attempts and tokens, and explicit unbounded cost")
    pure allowance
    where
      bounded limits dimension = case Map.lookup dimension limits of Just (Resources.Limited amount) -> amountUnits amount > 0; _ -> False

data DeliveryPolicy = DeliveryPolicy
  { operatorRecipient :: !(DeclarationCoordinate "recipient"),
    operatorSink :: !Sink,
    conversationSink :: !Sink
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON DeliveryPolicy where
  parseJSON = withObject "watchdog delivery" \fields -> do
    policy <- DeliveryPolicy <$> fields .: "operatorRecipient" <*> fields .: "operatorSink" <*> fields .: "conversationSink"
    unless (null (sinkErrors policy.operatorSink <> sinkErrors policy.conversationSink)) (fail "invalid watchdog sink")
    case policy.conversationSink of DanwaConversation {} -> pure (); _ -> fail "watchdog conversationSink must be DanwaConversation"
    pure policy

data WatchdogSettings = WatchdogSettings
  { principal :: !AgentIdentity,
    scope :: !ObservationScope,
    stuckWindowSeconds :: !(Duration "watchdog-stuck"),
    parkedWindowSeconds :: !(Duration "watchdog-parked"),
    coordinatorWindowSeconds :: !(Duration "watchdog-coordinator"),
    subjectsPerSweep :: !(WatchdogLimit "subjects"),
    driftIntervalSeconds :: !(Maybe (Duration "watchdog-drift")),
    driftSubjectsPerSweep :: !(Maybe (WatchdogLimit "drift-subjects")),
    delivery :: !(Maybe DeliveryPolicy),
    allowance :: !(Maybe WatchdogAllowance)
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON WatchdogSettings where
  parseJSON = withObject "watchdog" \fields -> do
    unless (all (`elem` ["principal", "scope", "stuckWindowSeconds", "parkedWindowSeconds", "coordinatorWindowSeconds", "subjectsPerSweep", "driftIntervalSeconds", "driftSubjectsPerSweep", "delivery", "allowance"]) (KeyMap.keys fields)) (fail "unknown watchdog setting")
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
    settings <- WatchdogSettings principal <$> fields .: "scope" <*> fields .: "stuckWindowSeconds" <*> fields .: "parkedWindowSeconds" <*> fields .: "coordinatorWindowSeconds" <*> fields .: "subjectsPerSweep" <*> fields .:? "driftIntervalSeconds" <*> fields .:? "driftSubjectsPerSweep" <*> fields .:? "delivery" <*> fields .:? "allowance"
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
        "driftSubjectsPerSweep" .= value.driftSubjectsPerSweep,
        "delivery" .= value.delivery,
        "allowance" .= value.allowance
      ]

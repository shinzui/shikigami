{-# LANGUAGE DataKinds #-}

module Shikigami.Execution.Policy.Types where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.List (nub)
import Data.Text qualified as Text
import Dhall (FromDhall)
import Numeric.Natural (Natural)
import Shikigami.Execution.Coordinate
import Shikigami.Execution.Policy.Limits
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Prelude

data RecoveryClass = RepeatableObservation | IdempotentEffect | UncertainEffect
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Only a trusted factory for a local, non-invoiced operation can declare
-- zero invoice cost. Other tools retain unknown billing and cannot satisfy a
-- finite invoice ceiling through an inferred zero.
data ToolInvoiceCost = NoInvoiceCost | UnreportedInvoiceCost
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data OutputRequirement = AnyReply | NonemptyReply | JsonFields ![ExecutionCoordinate "json-field"]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON, FromDhall)

data HarnessOverrides = HarnessOverrides
  { maxModelTurns :: !(Maybe Natural),
    outputRepairs :: !(Maybe Natural),
    contextBytes :: !(Maybe Natural),
    keepRecentMessages :: !(Maybe Natural),
    deniedTools :: ![ExecutionCoordinate "tool-name"],
    humanTools :: ![ExecutionCoordinate "tool-name"],
    permissionSeconds :: !(Maybe Natural),
    output :: !(Maybe OutputRequirement),
    recoveryAttempts :: !(Maybe Natural),
    summaryTokens :: !(Maybe Natural)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromDhall)

instance FromJSON HarnessOverrides where
  parseJSON = Aeson.withObject "HarnessOverrides" \fields -> do
    unless (all (`elem` ["maxModelTurns", "outputRepairs", "contextBytes", "keepRecentMessages", "deniedTools", "humanTools", "permissionSeconds", "output", "recoveryAttempts", "summaryTokens"]) (KeyMap.keys fields)) (fail "unsupported harness option")
    let defaults = foldr (\key current -> if KeyMap.member key current then current else KeyMap.insert key (toJSON ([] :: [Text])) current) fields ["deniedTools", "humanTools"]
    Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object defaults)

emptyHarnessOverrides :: HarnessOverrides
emptyHarnessOverrides = HarnessOverrides Nothing Nothing Nothing Nothing [] [] Nothing Nothing Nothing Nothing

data HarnessPolicy = HarnessPolicy
  { format :: !(FormatVersion "harness-policy"),
    maxModelTurns :: !ModelTurnLimit,
    outputRepairs :: !RepairLimit,
    contextBytes :: !ContextByteLimit,
    keepRecentMessages :: !RecentMessageMinimum,
    deniedTools :: ![ExecutionCoordinate "tool-name"],
    humanTools :: ![ExecutionCoordinate "tool-name"],
    permissionSeconds :: !PermissionLifetime,
    output :: !OutputRequirement,
    recoveryAttempts :: !RecoveryAttemptLimit,
    summaryTokens :: !(Maybe SummaryTokenLimit)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON HarnessPolicy where
  toJSON policy = case Aeson.genericToJSON Aeson.defaultOptions policy of
    Aeson.Object fields -> Aeson.Object ((if policyNumber policy.recoveryAttempts == 0 then KeyMap.delete "recoveryAttempts" else id) ((if isNothing policy.summaryTokens then KeyMap.delete "summaryTokens" else id) fields))
    value -> value

instance FromJSON HarnessPolicy where
  parseJSON = Aeson.withObject "HarnessPolicy" \fields -> do
    policy <- Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object ((if KeyMap.member "recoveryAttempts" fields then id else KeyMap.insert "recoveryAttempts" (toJSON (0 :: Int))) (if KeyMap.member "summaryTokens" fields then fields else KeyMap.insert "summaryTokens" Aeson.Null fields)))
    either (fail . Text.unpack) (const (pure policy)) (validateHarnessPolicy policy)

defaultHarnessPolicy :: HarnessPolicy
defaultHarnessPolicy = HarnessPolicy V1 defaultModelTurns defaultRepairs defaultContextBytes defaultRecentMessages [] [] defaultPermissionLifetime AnyReply defaultRecoveryAttempts Nothing

validateHarnessPolicy :: HarnessPolicy -> Either Text ()
validateHarnessPolicy policy = do
  unless (policy.format == V1) (Left "unsupported harness policy version")
  unless (all validNames [policy.deniedTools, policy.humanTools]) (Left "invalid tool permission list")
  case policy.output of
    JsonFields names -> unless (validNames names) (Left "invalid output field list")
    _ -> Right ()
  where
    validNames names = length names <= 128 && all (\name -> not (Text.null (executionCoordinateText name)) && Text.length (executionCoordinateText name) <= 256) names

-- Operator options establish ceilings; declaration overrides narrow those
-- ceilings and add restrictions. Neither path grants a tool or model binding.
applyHarnessOptions :: HarnessPolicy -> HarnessOverrides -> Either Text HarnessPolicy
applyHarnessOptions base options = do
  turns <- overridePolicyNumber base.maxModelTurns options.maxModelTurns
  recovery <- overridePolicyNumber base.recoveryAttempts options.recoveryAttempts
  repairs <- overridePolicyNumber base.outputRepairs options.outputRepairs
  context <- overridePolicyNumber base.contextBytes options.contextBytes
  recent <- overridePolicyNumber base.keepRecentMessages options.keepRecentMessages
  seconds <- overridePolicyNumber base.permissionSeconds options.permissionSeconds
  summary <- case options.summaryTokens of Nothing -> Right base.summaryTokens; Just 0 -> Right Nothing; Just n -> Just <$> parsePolicyNumber (toInteger n)
  let policy = base & #maxModelTurns .~ turns & #outputRepairs .~ repairs & #recoveryAttempts .~ recovery & #contextBytes .~ context & #keepRecentMessages .~ recent & #permissionSeconds .~ seconds & #deniedTools .~ nub (base.deniedTools <> options.deniedTools) & #humanTools .~ nub (base.humanTools <> options.humanTools) & #output .~ fromMaybe base.output options.output & #summaryTokens .~ summary
  validateHarnessPolicy policy
  pure policy

narrowHarnessPolicy :: HarnessPolicy -> Maybe HarnessOverrides -> Either Text HarnessPolicy
narrowHarnessPolicy base Nothing = validateHarnessPolicy base >> Right base
narrowHarnessPolicy base (Just overrides) = do
  proposed <- applyHarnessOptions base overrides
  let output = case (base.output, proposed.output) of
        (AnyReply, requirement) -> requirement
        (requirement, AnyReply) -> requirement
        (NonemptyReply, requirement) -> requirement
        (requirement, NonemptyReply) -> requirement
        (JsonFields a, JsonFields b) -> JsonFields (nub (a <> b))
      summary = case (base.summaryTokens, proposed.summaryTokens) of
        (Just maximumValue, Just wanted) -> Just (min maximumValue wanted)
        _ -> Nothing
      policy = proposed & #maxModelTurns .~ min base.maxModelTurns proposed.maxModelTurns & #outputRepairs .~ min base.outputRepairs proposed.outputRepairs & #recoveryAttempts .~ min base.recoveryAttempts proposed.recoveryAttempts & #contextBytes .~ min base.contextBytes proposed.contextBytes & #keepRecentMessages .~ max base.keepRecentMessages proposed.keepRecentMessages & #permissionSeconds .~ min base.permissionSeconds proposed.permissionSeconds & #output .~ output & #summaryTokens .~ summary
  validateHarnessPolicy policy
  pure policy

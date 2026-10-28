module Shikigami.Execution.Policy.Types where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.List (nub)
import Data.Text qualified as Text
import Dhall (FromDhall)
import Numeric.Natural (Natural)
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

data OutputRequirement = AnyReply | NonemptyReply | JsonFields ![Text]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON, FromDhall)

data HarnessOverrides = HarnessOverrides
  { maxModelTurns :: !(Maybe Natural),
    outputRepairs :: !(Maybe Natural),
    contextBytes :: !(Maybe Natural),
    keepRecentMessages :: !(Maybe Natural),
    deniedTools :: ![Text],
    humanTools :: ![Text],
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
  { format :: !Int,
    maxModelTurns :: !Int,
    outputRepairs :: !Int,
    contextBytes :: !Int,
    keepRecentMessages :: !Int,
    deniedTools :: ![Text],
    humanTools :: ![Text],
    permissionSeconds :: !Int,
    output :: !OutputRequirement,
    recoveryAttempts :: !Int,
    summaryTokens :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON HarnessPolicy where
  toJSON policy = case Aeson.genericToJSON Aeson.defaultOptions policy of
    Aeson.Object fields -> Aeson.Object ((if policy.recoveryAttempts == 0 then KeyMap.delete "recoveryAttempts" else id) ((if isNothing policy.summaryTokens then KeyMap.delete "summaryTokens" else id) fields))
    value -> value

instance FromJSON HarnessPolicy where
  parseJSON = Aeson.withObject "HarnessPolicy" \fields -> do
    policy <- Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object ((if KeyMap.member "recoveryAttempts" fields then id else KeyMap.insert "recoveryAttempts" (toJSON (0 :: Int))) (if KeyMap.member "summaryTokens" fields then fields else KeyMap.insert "summaryTokens" Aeson.Null fields)))
    either (fail . Text.unpack) (const (pure policy)) (validateHarnessPolicy policy)

defaultHarnessPolicy :: HarnessPolicy
defaultHarnessPolicy = HarnessPolicy 1 8 0 262144 4 [] [] 900 AnyReply 2 Nothing

validateHarnessPolicy :: HarnessPolicy -> Either Text ()
validateHarnessPolicy policy = do
  unless (policy.format == 1) (Left "unsupported harness policy version")
  unless (policy.maxModelTurns >= 1 && policy.maxModelTurns <= 10000 && policy.outputRepairs >= 0 && policy.outputRepairs <= 10) (Left "invalid model/repair ceiling")
  unless (policy.contextBytes >= 1024 && policy.contextBytes <= 1048576 && policy.keepRecentMessages >= 1 && policy.keepRecentMessages <= 1000) (Left "invalid context policy")
  unless (policy.recoveryAttempts >= 0 && policy.recoveryAttempts <= 100) (Left "invalid recovery attempt ceiling")
  unless (policy.permissionSeconds >= 1 && policy.permissionSeconds <= 86400) (Left "invalid permission duration")
  unless (maybe True (\n -> n >= 1 && n <= 32768) policy.summaryTokens) (Left "invalid summary output ceiling")
  unless (all validNames [policy.deniedTools, policy.humanTools]) (Left "invalid tool permission list")
  case policy.output of
    JsonFields names -> unless (validNames names) (Left "invalid output field list")
    _ -> Right ()
  where
    validNames names = length names <= 128 && all (\name -> not (Text.null name) && Text.length name <= 256) names

-- Operator options establish ceilings; declaration overrides narrow those
-- ceilings and add restrictions. Neither path grants a tool or model binding.
applyHarnessOptions :: HarnessPolicy -> HarnessOverrides -> Either Text HarnessPolicy
applyHarnessOptions base options = do
  turns <- number 10000 base.maxModelTurns options.maxModelTurns
  recovery <- number 100 base.recoveryAttempts options.recoveryAttempts
  repairs <- number 10 base.outputRepairs options.outputRepairs
  context <- number 1048576 base.contextBytes options.contextBytes
  recent <- number 1000 base.keepRecentMessages options.keepRecentMessages
  seconds <- number 86400 base.permissionSeconds options.permissionSeconds
  summary <- case options.summaryTokens of Nothing -> Right base.summaryTokens; Just 0 -> Right Nothing; Just n -> Just <$> number 32768 1 (Just n)
  let policy = base & #maxModelTurns .~ turns & #outputRepairs .~ repairs & #recoveryAttempts .~ recovery & #contextBytes .~ context & #keepRecentMessages .~ recent & #permissionSeconds .~ seconds & #deniedTools .~ nub (base.deniedTools <> options.deniedTools) & #humanTools .~ nub (base.humanTools <> options.humanTools) & #output .~ fromMaybe base.output options.output & #summaryTokens .~ summary
  validateHarnessPolicy policy
  pure policy
  where
    number :: Int -> Int -> Maybe Natural -> Either Text Int
    number maximumValue fallback = \case
      Nothing -> Right fallback
      Just value | value <= fromIntegral maximumValue -> Right (fromIntegral value)
      _ -> Left "harness option exceeds the supported ceiling"

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

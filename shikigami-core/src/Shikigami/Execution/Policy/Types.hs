module Shikigami.Execution.Policy.Types where

import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Shikigami.Prelude

data RecoveryClass = RepeatableObservation | IdempotentEffect | UncertainEffect
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data OutputRequirement = AnyReply | NonemptyReply | JsonFields ![Text]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data HarnessPolicy = HarnessPolicy
  { format :: !Int,
    maxModelTurns :: !Int,
    outputRepairs :: !Int,
    contextBytes :: !Int,
    keepRecentMessages :: !Int,
    deniedTools :: ![Text],
    humanTools :: ![Text],
    permissionSeconds :: !Int,
    output :: !OutputRequirement
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON HarnessPolicy where
  parseJSON value = do
    policy <- Aeson.genericParseJSON Aeson.defaultOptions value
    either (fail . Text.unpack) (const (pure policy)) (validateHarnessPolicy policy)

defaultHarnessPolicy :: HarnessPolicy
defaultHarnessPolicy = HarnessPolicy 1 8 0 262144 4 [] [] 900 AnyReply

validateHarnessPolicy :: HarnessPolicy -> Either Text ()
validateHarnessPolicy policy = do
  unless (policy.format == 1) (Left "unsupported harness policy version")
  unless (policy.maxModelTurns >= 1 && policy.maxModelTurns <= 10000 && policy.outputRepairs >= 0 && policy.outputRepairs <= 10) (Left "invalid model/repair ceiling")
  unless (policy.contextBytes >= 1024 && policy.contextBytes <= 1048576 && policy.keepRecentMessages >= 1 && policy.keepRecentMessages <= 1000) (Left "invalid context policy")
  unless (policy.permissionSeconds >= 1 && policy.permissionSeconds <= 86400) (Left "invalid permission duration")
  unless (all validNames [policy.deniedTools, policy.humanTools]) (Left "invalid tool permission list")
  case policy.output of
    JsonFields names -> unless (validNames names) (Left "invalid output field list")
    _ -> Right ()
  where
    validNames names = length names <= 128 && all (\name -> not (Text.null name) && Text.length name <= 256) names

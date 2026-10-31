-- | Checked operational policy values. Configuration numbers refine once;
-- unrelated ceilings cannot substitute for one another or expose Num arithmetic.
module Shikigami.Execution.Policy.Limits
  ( PolicyNumber (..),
    overridePolicyNumber,
    ModelTurnLimit,
    RepairLimit,
    ContextByteLimit,
    RecentMessageMinimum,
    PermissionLifetime,
    RecoveryAttemptLimit,
    SummaryTokenLimit,
    defaultModelTurns,
    defaultRepairs,
    defaultContextBytes,
    defaultRecentMessages,
    defaultPermissionLifetime,
    defaultRecoveryAttempts,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

class PolicyNumber a where
  policyNumber :: a -> Int
  parsePolicyNumber :: Integer -> Either Text a

overridePolicyNumber :: (PolicyNumber a) => a -> Maybe Natural -> Either Text a
overridePolicyNumber fallback Nothing = Right fallback
overridePolicyNumber _ (Just number) = parsePolicyNumber (toInteger number)

bounded :: Text -> (Int -> a) -> Int -> Int -> Integer -> Either Text a
bounded name constructor lower upper number
  | number >= toInteger lower && number <= toInteger upper && number <= toInteger (maxBound :: Int) = Right (constructor (fromInteger number))
  | otherwise = Left (name <> " must be within " <> Text.pack (show lower) <> ".." <> Text.pack (show upper))

newtype ModelTurnLimit = ModelTurnLimit Int
  deriving stock (Eq, Ord, Show)

instance PolicyNumber ModelTurnLimit where
  policyNumber (ModelTurnLimit number) = number
  parsePolicyNumber = bounded "model turn limit" ModelTurnLimit 1 10000

instance ToJSON ModelTurnLimit where
  toJSON = toJSON . policyNumber
  toEncoding = toEncoding . policyNumber

instance FromJSON ModelTurnLimit where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parsePolicyNumber

defaultModelTurns :: ModelTurnLimit
defaultModelTurns = ModelTurnLimit 8

newtype RepairLimit = RepairLimit Int
  deriving stock (Eq, Ord, Show)

instance PolicyNumber RepairLimit where
  policyNumber (RepairLimit number) = number
  parsePolicyNumber = bounded "repair limit" RepairLimit 0 10

instance ToJSON RepairLimit where
  toJSON = toJSON . policyNumber
  toEncoding = toEncoding . policyNumber

instance FromJSON RepairLimit where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parsePolicyNumber

defaultRepairs :: RepairLimit
defaultRepairs = RepairLimit 0

newtype ContextByteLimit = ContextByteLimit Int
  deriving stock (Eq, Ord, Show)

instance PolicyNumber ContextByteLimit where
  policyNumber (ContextByteLimit number) = number
  parsePolicyNumber = bounded "context byte limit" ContextByteLimit 1024 1048576

instance ToJSON ContextByteLimit where
  toJSON = toJSON . policyNumber
  toEncoding = toEncoding . policyNumber

instance FromJSON ContextByteLimit where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parsePolicyNumber

defaultContextBytes :: ContextByteLimit
defaultContextBytes = ContextByteLimit 262144

newtype RecentMessageMinimum = RecentMessageMinimum Int
  deriving stock (Eq, Ord, Show)

instance PolicyNumber RecentMessageMinimum where
  policyNumber (RecentMessageMinimum number) = number
  parsePolicyNumber = bounded "recent message minimum" RecentMessageMinimum 1 1000

instance ToJSON RecentMessageMinimum where
  toJSON = toJSON . policyNumber
  toEncoding = toEncoding . policyNumber

instance FromJSON RecentMessageMinimum where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parsePolicyNumber

defaultRecentMessages :: RecentMessageMinimum
defaultRecentMessages = RecentMessageMinimum 4

newtype PermissionLifetime = PermissionLifetime Int
  deriving stock (Eq, Ord, Show)

instance PolicyNumber PermissionLifetime where
  policyNumber (PermissionLifetime number) = number
  parsePolicyNumber = bounded "permission lifetime" PermissionLifetime 1 86400

instance ToJSON PermissionLifetime where
  toJSON = toJSON . policyNumber
  toEncoding = toEncoding . policyNumber

instance FromJSON PermissionLifetime where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parsePolicyNumber

defaultPermissionLifetime :: PermissionLifetime
defaultPermissionLifetime = PermissionLifetime 900

newtype RecoveryAttemptLimit = RecoveryAttemptLimit Int
  deriving stock (Eq, Ord, Show)

instance PolicyNumber RecoveryAttemptLimit where
  policyNumber (RecoveryAttemptLimit number) = number
  parsePolicyNumber = bounded "recovery attempt limit" RecoveryAttemptLimit 0 100

instance ToJSON RecoveryAttemptLimit where
  toJSON = toJSON . policyNumber
  toEncoding = toEncoding . policyNumber

instance FromJSON RecoveryAttemptLimit where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parsePolicyNumber

defaultRecoveryAttempts :: RecoveryAttemptLimit
defaultRecoveryAttempts = RecoveryAttemptLimit 2

newtype SummaryTokenLimit = SummaryTokenLimit Int
  deriving stock (Eq, Ord, Show)

instance PolicyNumber SummaryTokenLimit where
  policyNumber (SummaryTokenLimit number) = number
  parsePolicyNumber = bounded "summary token limit" SummaryTokenLimit 1 32768

instance ToJSON SummaryTokenLimit where
  toJSON = toJSON . policyNumber
  toEncoding = toEncoding . policyNumber

instance FromJSON SummaryTokenLimit where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parsePolicyNumber

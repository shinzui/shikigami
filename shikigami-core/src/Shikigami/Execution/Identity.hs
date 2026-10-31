{-# LANGUAGE DataKinds #-}

-- | Accounting entity identities survive workflow collection. Logical operation
-- coordinates remain distinct from actual attempts and allocated resource roots.
module Shikigami.Execution.Identity
  ( ExecutionRootId,
    parseExecutionRootId,
    executionRootIdText,
    newExecutionRootId,
    AttemptId,
    parseAttemptId,
    attemptIdText,
    newAttemptId,
    AllocationId,
    parseAllocationId,
    allocationIdText,
    newAllocationId,
    OperationId (..),
  )
where

import Data.Aeson (withText)
import Data.Bifunctor (first)
import Data.KindID.V7 qualified as KindID
import Data.Text qualified as Text
import Shikigami.Prelude

newtype OperationId = OperationId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

newtype ExecutionRootId = ExecutionRootId (KindID.KindID "shikigami_execution_root")
  deriving stock (Eq, Ord, Show)

parseExecutionRootId :: Text -> Either Text ExecutionRootId
parseExecutionRootId input = do
  value <- first (const "invalid ExecutionRootId encoding or prefix") (KindID.parseText @"shikigami_execution_root" input)
  case KindID.checkKindID value of
    Just _ -> Left "ExecutionRootId requires UUIDv7"
    Nothing
      | KindID.toText value == input -> Right (ExecutionRootId value)
      | otherwise -> Left "ExecutionRootId requires canonical encoding"

executionRootIdText :: ExecutionRootId -> Text
executionRootIdText (ExecutionRootId value) = KindID.toText value

newExecutionRootId :: IO ExecutionRootId
newExecutionRootId = ExecutionRootId <$> KindID.genKindID @"shikigami_execution_root"

instance ToJSON ExecutionRootId where
  toJSON = toJSON . executionRootIdText
  toEncoding = toEncoding . executionRootIdText

instance FromJSON ExecutionRootId where
  parseJSON = withText "ExecutionRootId" (either (fail . Text.unpack) pure . parseExecutionRootId)

newtype AttemptId = AttemptId (KindID.KindID "shikigami_execution_attempt")
  deriving stock (Eq, Ord, Show)

parseAttemptId :: Text -> Either Text AttemptId
parseAttemptId input = do
  value <- first (const "invalid AttemptId encoding or prefix") (KindID.parseText @"shikigami_execution_attempt" input)
  case KindID.checkKindID value of
    Just _ -> Left "AttemptId requires UUIDv7"
    Nothing
      | KindID.toText value == input -> Right (AttemptId value)
      | otherwise -> Left "AttemptId requires canonical encoding"

attemptIdText :: AttemptId -> Text
attemptIdText (AttemptId value) = KindID.toText value

newAttemptId :: IO AttemptId
newAttemptId = AttemptId <$> KindID.genKindID @"shikigami_execution_attempt"

instance ToJSON AttemptId where
  toJSON = toJSON . attemptIdText
  toEncoding = toEncoding . attemptIdText

instance FromJSON AttemptId where
  parseJSON = withText "AttemptId" (either (fail . Text.unpack) pure . parseAttemptId)

newtype AllocationId = AllocationId (KindID.KindID "shikigami_execution_allocation")
  deriving stock (Eq, Ord, Show)

parseAllocationId :: Text -> Either Text AllocationId
parseAllocationId input = do
  value <- first (const "invalid AllocationId encoding or prefix") (KindID.parseText @"shikigami_execution_allocation" input)
  case KindID.checkKindID value of
    Just _ -> Left "AllocationId requires UUIDv7"
    Nothing
      | KindID.toText value == input -> Right (AllocationId value)
      | otherwise -> Left "AllocationId requires canonical encoding"

allocationIdText :: AllocationId -> Text
allocationIdText (AllocationId value) = KindID.toText value

newAllocationId :: IO AllocationId
newAllocationId = AllocationId <$> KindID.genKindID @"shikigami_execution_allocation"

instance ToJSON AllocationId where
  toJSON = toJSON . allocationIdText
  toEncoding = toEncoding . allocationIdText

instance FromJSON AllocationId where
  parseJSON = withText "AllocationId" (either (fail . Text.unpack) pure . parseAllocationId)

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Exact workspace protocol claims and bounded scalar units. The existing
-- catalog, admission, profile and receipt owners retain grammar, binding and
-- authority checks; nominal capture does not normalize or invent identities.
module Shikigami.Workspace.Value
  ( WorkspaceCoordinate,
    workspaceCoordinate,
    workspaceCoordinateText,
    WorkspaceLocator,
    workspaceLocator,
    workspaceLocatorPath,
    ProcessSeconds,
    parseProcessSeconds,
    processSecondsNumber,
    ProcessOutputBytes,
    parseProcessOutputBytes,
    processOutputBytesNumber,
    WorkspaceIdentity,
    parseWorkspaceIdentity,
    workspaceIdentityNumber,
    CleanupIdentity,
    parseCleanupIdentity,
    cleanupIdentityNumber,
    RpcConcurrency,
    parseRpcConcurrency,
    rpcConcurrencyNumber,
    RpcRequestSeconds,
    parseRpcRequestSeconds,
    rpcRequestSecondsNumber,
    RpcWaitSeconds,
    parseRpcWaitSeconds,
    rpcWaitSecondsNumber,
    ProcessExitStatus,
    parseProcessExitStatus,
    processExitStatusNumber,
    RpcPeerUserId,
    parseRpcPeerUserId,
    rpcPeerUserIdNumber,
    CapturedBytes,
    parseCapturedBytes,
    capturedBytesNumber,
    OutputTruncation (..),
    outputTruncation,
    outputTruncated,
    DescendantSettlement (..),
    descendantSettlement,
    descendantsSettled,
    OutputCompleteness (..),
    outputCompleteness,
    outputCollected,
    ProvisionReadiness (..),
    provisionReadiness,
    provisionReady,
    FilePolicy (..),
    filePolicyText,
    GitMode (..),
    gitModeText,
    parseGitMode,
  )
where

import Data.Aeson (FromJSON (..), FromJSONKey, ToJSON (..), ToJSONKey, Value)
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.TypeLits (Symbol)

type role WorkspaceCoordinate nominal

newtype WorkspaceCoordinate (scope :: Symbol) = WorkspaceCoordinate Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

workspaceCoordinate :: Text -> WorkspaceCoordinate scope
workspaceCoordinate = WorkspaceCoordinate

workspaceCoordinateText :: WorkspaceCoordinate scope -> Text
workspaceCoordinateText (WorkspaceCoordinate value) = value

type role WorkspaceLocator nominal

newtype WorkspaceLocator (scope :: Symbol) = WorkspaceLocator FilePath
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

workspaceLocator :: FilePath -> WorkspaceLocator scope
workspaceLocator = WorkspaceLocator

workspaceLocatorPath :: WorkspaceLocator scope -> FilePath
workspaceLocatorPath (WorkspaceLocator value) = value

boundedInteger :: Text -> Integer -> Maybe Integer -> Integer -> Either Text Integer
boundedInteger label lower upper value
  | value >= lower && maybe True (value <=) upper = Right value
  | otherwise = Left (label <> " is outside its admitted range")

intJSON :: (Int -> Either Text value) -> Value -> Parser value
intJSON parse value = do
  number <- parseJSON @Integer value
  if number < toInteger (minBound :: Int) || number > toInteger (maxBound :: Int)
    then fail "workspace scalar does not fit an Int"
    else either (fail . Text.unpack) pure (parse (fromInteger number))

newtype ProcessSeconds = ProcessSeconds Int
  deriving stock (Eq, Ord)
  deriving newtype (Show)

parseProcessSeconds :: Int -> Either Text ProcessSeconds
parseProcessSeconds value = ProcessSeconds value <$ boundedInteger "processSeconds" 1 (Just 3600) (toInteger value)

processSecondsNumber :: ProcessSeconds -> Int
processSecondsNumber (ProcessSeconds value) = value

instance ToJSON ProcessSeconds where
  toJSON = toJSON . processSecondsNumber
  toEncoding = toEncoding . processSecondsNumber

instance FromJSON ProcessSeconds where parseJSON = intJSON parseProcessSeconds

newtype ProcessOutputBytes = ProcessOutputBytes Int
  deriving stock (Eq, Ord)
  deriving newtype (Show)

parseProcessOutputBytes :: Int -> Either Text ProcessOutputBytes
parseProcessOutputBytes value = ProcessOutputBytes value <$ boundedInteger "processOutputBytes" 1 (Just 1048576) (toInteger value)

processOutputBytesNumber :: ProcessOutputBytes -> Int
processOutputBytesNumber (ProcessOutputBytes value) = value

instance ToJSON ProcessOutputBytes where
  toJSON = toJSON . processOutputBytesNumber
  toEncoding = toEncoding . processOutputBytesNumber

instance FromJSON ProcessOutputBytes where parseJSON = intJSON parseProcessOutputBytes

newtype WorkspaceIdentity = WorkspaceIdentity Int
  deriving stock (Eq, Ord)
  deriving newtype (Show)

parseWorkspaceIdentity :: Int -> Either Text WorkspaceIdentity
parseWorkspaceIdentity value = WorkspaceIdentity value <$ boundedInteger "workspaceIdentity" 1000 (Just 2147483647) (toInteger value)

workspaceIdentityNumber :: WorkspaceIdentity -> Int
workspaceIdentityNumber (WorkspaceIdentity value) = value

instance ToJSON WorkspaceIdentity where
  toJSON = toJSON . workspaceIdentityNumber
  toEncoding = toEncoding . workspaceIdentityNumber

instance FromJSON WorkspaceIdentity where parseJSON = intJSON parseWorkspaceIdentity

newtype CleanupIdentity = CleanupIdentity Int
  deriving stock (Eq, Ord)
  deriving newtype (Show)

parseCleanupIdentity :: Int -> Either Text CleanupIdentity
parseCleanupIdentity value = CleanupIdentity value <$ boundedInteger "cleanupIdentity" 0 (Just 2147483647) (toInteger value)

cleanupIdentityNumber :: CleanupIdentity -> Int
cleanupIdentityNumber (CleanupIdentity value) = value

instance ToJSON CleanupIdentity where
  toJSON = toJSON . cleanupIdentityNumber
  toEncoding = toEncoding . cleanupIdentityNumber

instance FromJSON CleanupIdentity where parseJSON = intJSON parseCleanupIdentity

newtype RpcConcurrency = RpcConcurrency Int
  deriving stock (Eq, Ord)
  deriving newtype (Show)

parseRpcConcurrency :: Int -> Either Text RpcConcurrency
parseRpcConcurrency value = RpcConcurrency value <$ boundedInteger "rpcConcurrency" 1 (Just 16) (toInteger value)

rpcConcurrencyNumber :: RpcConcurrency -> Int
rpcConcurrencyNumber (RpcConcurrency value) = value

instance ToJSON RpcConcurrency where
  toJSON = toJSON . rpcConcurrencyNumber
  toEncoding = toEncoding . rpcConcurrencyNumber

instance FromJSON RpcConcurrency where parseJSON = intJSON parseRpcConcurrency

newtype RpcRequestSeconds = RpcRequestSeconds Int
  deriving stock (Eq, Ord)
  deriving newtype (Show)

parseRpcRequestSeconds :: Int -> Either Text RpcRequestSeconds
parseRpcRequestSeconds value = RpcRequestSeconds value <$ boundedInteger "rpcRequestSeconds" 1 (Just 120) (toInteger value)

rpcRequestSecondsNumber :: RpcRequestSeconds -> Int
rpcRequestSecondsNumber (RpcRequestSeconds value) = value

instance ToJSON RpcRequestSeconds where
  toJSON = toJSON . rpcRequestSecondsNumber
  toEncoding = toEncoding . rpcRequestSecondsNumber

instance FromJSON RpcRequestSeconds where parseJSON = intJSON parseRpcRequestSeconds

newtype RpcWaitSeconds = RpcWaitSeconds Int
  deriving stock (Eq, Ord)
  deriving newtype (Show)

parseRpcWaitSeconds :: Int -> Either Text RpcWaitSeconds
parseRpcWaitSeconds value = RpcWaitSeconds value <$ boundedInteger "rpcWaitSeconds" 1 (Just 3600) (toInteger value)

rpcWaitSecondsNumber :: RpcWaitSeconds -> Int
rpcWaitSecondsNumber (RpcWaitSeconds value) = value

instance ToJSON RpcWaitSeconds where
  toJSON = toJSON . rpcWaitSecondsNumber
  toEncoding = toEncoding . rpcWaitSecondsNumber

instance FromJSON RpcWaitSeconds where parseJSON = intJSON parseRpcWaitSeconds

newtype ProcessExitStatus = ProcessExitStatus Int
  deriving stock (Eq, Ord)
  deriving newtype (Show)

parseProcessExitStatus :: Int -> Either Text ProcessExitStatus
parseProcessExitStatus value = ProcessExitStatus value <$ boundedInteger "processExitStatus" 0 (Just 255) (toInteger value)

processExitStatusNumber :: ProcessExitStatus -> Int
processExitStatusNumber (ProcessExitStatus value) = value

instance ToJSON ProcessExitStatus where
  toJSON = toJSON . processExitStatusNumber
  toEncoding = toEncoding . processExitStatusNumber

instance FromJSON ProcessExitStatus where parseJSON = intJSON parseProcessExitStatus

newtype RpcPeerUserId = RpcPeerUserId Integer
  deriving stock (Eq, Ord)
  deriving newtype (Show)

parseRpcPeerUserId :: Integer -> Either Text RpcPeerUserId
parseRpcPeerUserId value = RpcPeerUserId <$> boundedInteger "rpcPeerUserId" 0 (Just 4294967295) value

rpcPeerUserIdNumber :: RpcPeerUserId -> Integer
rpcPeerUserIdNumber (RpcPeerUserId value) = value

instance ToJSON RpcPeerUserId where
  toJSON = toJSON . rpcPeerUserIdNumber
  toEncoding = toEncoding . rpcPeerUserIdNumber

instance FromJSON RpcPeerUserId where parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseRpcPeerUserId

newtype CapturedBytes = CapturedBytes Integer
  deriving stock (Eq, Ord)
  deriving newtype (Show)

parseCapturedBytes :: Integer -> Either Text CapturedBytes
parseCapturedBytes value = CapturedBytes <$> boundedInteger "capturedBytes" 0 Nothing value

capturedBytesNumber :: CapturedBytes -> Integer
capturedBytesNumber (CapturedBytes value) = value

instance ToJSON CapturedBytes where
  toJSON = toJSON . capturedBytesNumber
  toEncoding = toEncoding . capturedBytesNumber

instance FromJSON CapturedBytes where parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseCapturedBytes

data OutputTruncation = OutputTruncated | OutputUntruncated deriving stock (Eq, Show)

outputTruncation :: Bool -> OutputTruncation
outputTruncation value = if value then OutputTruncated else OutputUntruncated

outputTruncated :: OutputTruncation -> Bool
outputTruncated value = value == OutputTruncated

instance ToJSON OutputTruncation where
  toJSON = toJSON . outputTruncated
  toEncoding = toEncoding . outputTruncated

instance FromJSON OutputTruncation where parseJSON value = outputTruncation <$> parseJSON value

data DescendantSettlement = DescendantsSettled | DescendantsRemain deriving stock (Eq, Show)

descendantSettlement :: Bool -> DescendantSettlement
descendantSettlement value = if value then DescendantsSettled else DescendantsRemain

descendantsSettled :: DescendantSettlement -> Bool
descendantsSettled value = value == DescendantsSettled

instance ToJSON DescendantSettlement where
  toJSON = toJSON . descendantsSettled
  toEncoding = toEncoding . descendantsSettled

instance FromJSON DescendantSettlement where parseJSON value = descendantSettlement <$> parseJSON value

data OutputCompleteness = OutputCollected | OutputIncomplete deriving stock (Eq, Show)

outputCompleteness :: Bool -> OutputCompleteness
outputCompleteness value = if value then OutputCollected else OutputIncomplete

outputCollected :: OutputCompleteness -> Bool
outputCollected value = value == OutputCollected

instance ToJSON OutputCompleteness where
  toJSON = toJSON . outputCollected
  toEncoding = toEncoding . outputCollected

instance FromJSON OutputCompleteness where parseJSON value = outputCompleteness <$> parseJSON value

data ProvisionReadiness = ProvisionReady | ProvisionPending deriving stock (Eq, Show)

provisionReadiness :: Bool -> ProvisionReadiness
provisionReadiness value = if value then ProvisionReady else ProvisionPending

provisionReady :: ProvisionReadiness -> Bool
provisionReady value = value == ProvisionReady

instance ToJSON ProvisionReadiness where
  toJSON = toJSON . provisionReady
  toEncoding = toEncoding . provisionReady

instance FromJSON ProvisionReadiness where parseJSON value = provisionReadiness <$> parseJSON value

data FilePolicy = NativeFilesV1 | SupervisedFilesV1 | TransferFilesV1 deriving stock (Eq, Ord, Show)

filePolicyText :: FilePolicy -> Text
filePolicyText NativeFilesV1 = "ascii-exact-v1"
filePolicyText SupervisedFilesV1 = "ascii-exact-process-v1"
filePolicyText TransferFilesV1 = "ascii-exact-transfer-v1"

instance ToJSON FilePolicy where
  toJSON = toJSON . filePolicyText
  toEncoding = toEncoding . filePolicyText

instance FromJSON FilePolicy where
  parseJSON value =
    parseJSON @Text value >>= \case
      "ascii-exact-v1" -> pure NativeFilesV1
      "ascii-exact-process-v1" -> pure SupervisedFilesV1
      "ascii-exact-transfer-v1" -> pure TransferFilesV1
      _ -> fail "unsupported workspace file policy"

data GitMode = GitRegular | GitExecutable | GitTree deriving stock (Eq, Ord, Show)

gitModeText :: GitMode -> Text
gitModeText GitRegular = "100644"
gitModeText GitExecutable = "100755"
gitModeText GitTree = "040000"

parseGitMode :: Text -> Either Text GitMode
parseGitMode "100644" = Right GitRegular
parseGitMode "100755" = Right GitExecutable
parseGitMode "040000" = Right GitTree
parseGitMode _ = Left "unsupported workspace Git mode"

instance ToJSON GitMode where
  toJSON = toJSON . gitModeText
  toEncoding = toEncoding . gitModeText

instance FromJSON GitMode where parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseGitMode

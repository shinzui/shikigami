{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeApplications #-}

-- | Retained operator rules and private Unix identities. Policy changes produce
-- a new workspace binding; current configuration cannot reinterpret old work.
module Shikigami.Workspace.ProcessPolicy
  ( ProcessPolicyFormat (..),
    ProfileState (..),
    strictOptions,
    processPolicyIdentity,
    validProcessPolicy,
    validProcessProfile,
    validIdentityRange,
    validProcessImage,
    validCommandRule,
    safeAbsolute,
    immutableHelper,
    commandFor,
    processPolicyCommand,
    processFileAllowed,
    ProcessImage,
    ProcessImageInput (..),
    mkProcessImage,
    processImageInput,
    CommandRule,
    CommandRuleInput (..),
    mkCommandRule,
    commandRuleInput,
    ProcessPolicy,
    ProcessPolicyInput (..),
    mkProcessPolicy,
    processPolicyInput,
    ProcessProfile,
    ProcessProfileInput (..),
    mkProcessProfile,
    processProfileInput,
    IdentityRange,
    IdentityRangeInput (..),
    mkIdentityRange,
    identityRangeInput,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Bytes
import Data.List (nub, sort, sortOn)
import Data.Map.Strict (Map)
import Data.Text qualified as Text
import GHC.Records (HasField (..))
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Prelude
import Shikigami.Workspace.Instructions (validWorkspacePath)
import Shikigami.Workspace.Process
import Shikigami.Workspace.Value
import System.FilePath (isAbsolute, normalise)

-- | The retained policy protocol has one admitted version. Keep its JSON
-- number while preventing arbitrary numeric or unrelated format substitution.
data ProcessPolicyFormat = ProcessPolicyV1
  deriving stock (Eq, Show)

instance ToJSON ProcessPolicyFormat where
  toJSON ProcessPolicyV1 = toJSON (1 :: Int)
  toEncoding ProcessPolicyV1 = toEncoding (1 :: Int)

instance FromJSON ProcessPolicyFormat where
  parseJSON value = do
    number <- parseJSON @Integer value
    if number == 1 then pure ProcessPolicyV1 else fail "unsupported workspace process policy format"

data ProcessImageInput = ProcessImageInput
  { rootDirectory :: !(WorkspaceLocator "image-root"),
    rootIdentity :: !(WorkspaceCoordinate "image-digest"),
    environmentExecutable :: !(WorkspaceLocator "environment-executable"),
    deadlineExecutable :: !(WorkspaceLocator "deadline-executable"),
    collectorExecutable :: !(WorkspaceLocator "collector-executable")
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

data CommandRuleInput = CommandRuleInput
  { rule :: !(WorkspaceCoordinate "process-rule"),
    executable :: !(WorkspaceCoordinate "process-executable"),
    arguments :: !([WorkspaceCoordinate "argument"]),
    directory :: !(WorkspaceCoordinate "path-prefix"),
    environment :: !(Map (WorkspaceCoordinate "environment-name") (WorkspaceCoordinate "environment-value")),
    timeoutSeconds :: !(ProcessSeconds),
    outputBytes :: !(ProcessOutputBytes)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

data ProcessPolicyInput = ProcessPolicyInput
  { format :: !ProcessPolicyFormat,
    image :: !ProcessImage,
    propertiesDigest :: !(WorkspaceCoordinate "process-properties"),
    rules :: ![CommandRule],
    readPaths :: !([WorkspaceCoordinate "path-prefix"]),
    writePaths :: !([WorkspaceCoordinate "path-prefix"])
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

data ProcessProfileInput = ProcessProfileInput
  { bindingDigest :: !(WorkspaceCoordinate "binding-digest"),
    instructionDigest :: !(WorkspaceCoordinate "instructions-digest"),
    policy :: !ProcessPolicy,
    userId :: !(WorkspaceIdentity),
    groupId :: !(WorkspaceIdentity)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

data IdentityRangeInput = IdentityRangeInput {firstId :: !(WorkspaceIdentity), lastId :: !(WorkspaceIdentity)}
  deriving stock (Eq, Show, Generic)

instance FromJSON IdentityRange where
  parseJSON value = Aeson.genericParseJSON strictOptions value >>= either (fail . Text.unpack) pure . mkIdentityRange

newtype ProcessImage = ProcessImage ProcessImageInput
  deriving newtype (Eq)

processImageInput :: ProcessImage -> ProcessImageInput
processImageInput (ProcessImage input) = input

instance HasField "rootDirectory" ProcessImage (WorkspaceLocator "image-root") where
  getField (ProcessImage input) = input.rootDirectory

instance HasField "rootIdentity" ProcessImage (WorkspaceCoordinate "image-digest") where
  getField (ProcessImage input) = input.rootIdentity

instance HasField "environmentExecutable" ProcessImage (WorkspaceLocator "environment-executable") where
  getField (ProcessImage input) = input.environmentExecutable

instance HasField "deadlineExecutable" ProcessImage (WorkspaceLocator "deadline-executable") where
  getField (ProcessImage input) = input.deadlineExecutable

instance HasField "collectorExecutable" ProcessImage (WorkspaceLocator "collector-executable") where
  getField (ProcessImage input) = input.collectorExecutable

mkProcessImage :: ProcessImageInput -> Either Text ProcessImage
mkProcessImage input =
  let candidate = ProcessImage input
   in if validProcessImage candidate then Right candidate else Left "invalid workspace ProcessImage"

instance ToJSON ProcessImage where
  toJSON = toJSON . processImageInput
  toEncoding = toEncoding . processImageInput

newtype CommandRule = CommandRule CommandRuleInput
  deriving newtype (Eq)

commandRuleInput :: CommandRule -> CommandRuleInput
commandRuleInput (CommandRule input) = input

instance HasField "rule" CommandRule (WorkspaceCoordinate "process-rule") where
  getField (CommandRule input) = input.rule

instance HasField "executable" CommandRule (WorkspaceCoordinate "process-executable") where
  getField (CommandRule input) = input.executable

instance HasField "arguments" CommandRule ([WorkspaceCoordinate "argument"]) where
  getField (CommandRule input) = input.arguments

instance HasField "directory" CommandRule (WorkspaceCoordinate "path-prefix") where
  getField (CommandRule input) = input.directory

instance HasField "environment" CommandRule (Map (WorkspaceCoordinate "environment-name") (WorkspaceCoordinate "environment-value")) where
  getField (CommandRule input) = input.environment

instance HasField "timeoutSeconds" CommandRule (ProcessSeconds) where
  getField (CommandRule input) = input.timeoutSeconds

instance HasField "outputBytes" CommandRule (ProcessOutputBytes) where
  getField (CommandRule input) = input.outputBytes

mkCommandRule :: CommandRuleInput -> Either Text CommandRule
mkCommandRule input =
  let candidate = CommandRule input
   in if validCommandRule candidate then Right candidate else Left "invalid workspace CommandRule"

instance ToJSON CommandRule where
  toJSON = toJSON . commandRuleInput
  toEncoding = toEncoding . commandRuleInput

newtype ProcessPolicy = ProcessPolicy ProcessPolicyInput
  deriving newtype (Eq)

processPolicyInput :: ProcessPolicy -> ProcessPolicyInput
processPolicyInput (ProcessPolicy input) = input

instance HasField "format" ProcessPolicy (ProcessPolicyFormat) where
  getField (ProcessPolicy input) = input.format

instance HasField "image" ProcessPolicy (ProcessImage) where
  getField (ProcessPolicy input) = input.image

instance HasField "propertiesDigest" ProcessPolicy (WorkspaceCoordinate "process-properties") where
  getField (ProcessPolicy input) = input.propertiesDigest

instance HasField "rules" ProcessPolicy ([CommandRule]) where
  getField (ProcessPolicy input) = input.rules

instance HasField "readPaths" ProcessPolicy ([WorkspaceCoordinate "path-prefix"]) where
  getField (ProcessPolicy input) = input.readPaths

instance HasField "writePaths" ProcessPolicy ([WorkspaceCoordinate "path-prefix"]) where
  getField (ProcessPolicy input) = input.writePaths

mkProcessPolicy :: ProcessPolicyInput -> Either Text ProcessPolicy
mkProcessPolicy input =
  let candidate = ProcessPolicy input
   in if validProcessPolicy candidate then Right candidate else Left "invalid workspace ProcessPolicy"

instance ToJSON ProcessPolicy where
  toJSON = toJSON . processPolicyInput
  toEncoding = toEncoding . processPolicyInput

newtype ProcessProfile = ProcessProfile ProcessProfileInput
  deriving newtype (Eq)

processProfileInput :: ProcessProfile -> ProcessProfileInput
processProfileInput (ProcessProfile input) = input

instance HasField "bindingDigest" ProcessProfile (WorkspaceCoordinate "binding-digest") where
  getField (ProcessProfile input) = input.bindingDigest

instance HasField "instructionDigest" ProcessProfile (WorkspaceCoordinate "instructions-digest") where
  getField (ProcessProfile input) = input.instructionDigest

instance HasField "policy" ProcessProfile (ProcessPolicy) where
  getField (ProcessProfile input) = input.policy

instance HasField "userId" ProcessProfile (WorkspaceIdentity) where
  getField (ProcessProfile input) = input.userId

instance HasField "groupId" ProcessProfile (WorkspaceIdentity) where
  getField (ProcessProfile input) = input.groupId

mkProcessProfile :: ProcessProfileInput -> Either Text ProcessProfile
mkProcessProfile input =
  let candidate = ProcessProfile input
   in if validProcessProfile candidate then Right candidate else Left "invalid workspace ProcessProfile"

instance ToJSON ProcessProfile where
  toJSON = toJSON . processProfileInput
  toEncoding = toEncoding . processProfileInput

newtype IdentityRange = IdentityRange IdentityRangeInput
  deriving newtype (Eq)

identityRangeInput :: IdentityRange -> IdentityRangeInput
identityRangeInput (IdentityRange input) = input

instance HasField "firstId" IdentityRange (WorkspaceIdentity) where
  getField (IdentityRange input) = input.firstId

instance HasField "lastId" IdentityRange (WorkspaceIdentity) where
  getField (IdentityRange input) = input.lastId

mkIdentityRange :: IdentityRangeInput -> Either Text IdentityRange
mkIdentityRange input =
  let candidate = IdentityRange input
   in if validIdentityRange candidate then Right candidate else Left "invalid workspace IdentityRange"

data ProfileState = ProfileReserved | ProfileReady deriving stock (Eq, Show)

instance Show IdentityRange where
  show value = "IdentityRange {firstId = " <> show value.firstId <> ", lastId = " <> show value.lastId <> "}"

instance Show ProcessImage where show _ = "ProcessImage <protected>"

instance Show CommandRule where show _ = "CommandRule <protected>"

instance Show ProcessPolicy where show _ = "ProcessPolicy <protected>"

instance Show ProcessProfile where show _ = "ProcessProfile <protected>"

strictOptions :: Aeson.Options
strictOptions = Aeson.defaultOptions {Aeson.rejectUnknownFields = True}

instance FromJSON ProcessImage where
  parseJSON value = Aeson.genericParseJSON strictOptions value >>= either (fail . Text.unpack) pure . mkProcessImage

instance FromJSON CommandRule where
  parseJSON value = Aeson.genericParseJSON strictOptions value >>= either (fail . Text.unpack) pure . mkCommandRule

instance FromJSON ProcessPolicy where
  parseJSON value = Aeson.genericParseJSON strictOptions value >>= either (fail . Text.unpack) pure . mkProcessPolicy

instance FromJSON ProcessProfile where
  parseJSON value = Aeson.genericParseJSON strictOptions value >>= either (fail . Text.unpack) pure . mkProcessProfile

processPolicyIdentity :: ProcessPolicy -> WorkspaceCoordinate "policy-identity"
processPolicyIdentity policy = workspaceCoordinate ("policy2-" <> Text.drop 7 (versionedDigest "shikigami.workspace-supervised-policy/1" (toJSON (policy.format, policy.image, policy.propertiesDigest, sortOn (.rule) policy.rules, sort policy.readPaths, sort policy.writePaths))))

validProcessPolicy :: ProcessPolicy -> Bool
validProcessPolicy policy = policy.format == ProcessPolicyV1 && digestText (workspaceCoordinateText policy.propertiesDigest) && validProcessImage policy.image && not (null policy.rules) && length policy.rules <= 64 && length (nub (map (.rule) policy.rules)) == length policy.rules && all (validProcessCommand . commandFor digest) policy.rules && all validPrefixes [policy.readPaths, policy.writePaths] && Bytes.length (Aeson.encode policy) <= 262144
  where
    digest = workspaceCoordinate (versionedDigest "shikigami.workspace-rule-validation/1" Aeson.Null)
    validPrefixes paths = length paths <= 64 && length (nub paths) == length paths && all (\path -> Text.null (workspaceCoordinateText path) || (validWorkspacePath (workspaceCoordinateText path) && Text.all (< '\DEL') (workspaceCoordinateText path))) paths

validProcessImage :: ProcessImage -> Bool
validProcessImage image = digestText (workspaceCoordinateText image.rootIdentity) && and [safeAbsolute (workspaceLocatorPath image.rootDirectory), safeAbsolute (workspaceLocatorPath image.environmentExecutable), safeAbsolute (workspaceLocatorPath image.deadlineExecutable), safeAbsolute (workspaceLocatorPath image.collectorExecutable)] && and [immutableHelper (Text.pack (workspaceLocatorPath image.environmentExecutable)), immutableHelper (Text.pack (workspaceLocatorPath image.deadlineExecutable))]

validCommandRule :: CommandRule -> Bool
validCommandRule = validProcessCommand . commandFor (workspaceCoordinate (versionedDigest "shikigami.workspace-rule-validation/1" Aeson.Null))

safeAbsolute :: FilePath -> Bool
safeAbsolute path = isAbsolute path && path /= "/" && normalise path == path && validWorkspacePath (Text.drop 1 (Text.pack path)) && Text.all (\c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c `elem` ("/._-" :: String)) (Text.pack path)

immutableHelper :: Text -> Bool
immutableHelper path = all (\prefix -> path /= prefix && not ((prefix <> "/") `Text.isPrefixOf` path)) ["/workspace", "/scratch"]

validIdentityRange :: IdentityRange -> Bool
validIdentityRange range = (workspaceIdentityNumber range.firstId) >= 1000 && (workspaceIdentityNumber range.lastId) >= (workspaceIdentityNumber range.firstId) && (workspaceIdentityNumber range.lastId) <= 2147483647 && (workspaceIdentityNumber range.lastId) - (workspaceIdentityNumber range.firstId) < 65536

validProcessProfile :: ProcessProfile -> Bool
validProcessProfile profile = digestText (workspaceCoordinateText profile.bindingDigest) && digestText (workspaceCoordinateText profile.instructionDigest) && validProcessPolicy profile.policy && workspaceIdentityNumber profile.userId >= 1000 && workspaceIdentityNumber profile.userId <= 2147483647 && profile.groupId == profile.userId

commandFor :: WorkspaceCoordinate "process-profile" -> CommandRule -> ProcessCommand
commandFor profile rule = ProcessCommand rule.rule profile rule.executable rule.arguments rule.directory rule.environment rule.timeoutSeconds rule.outputBytes

processPolicyCommand :: ProcessPolicy -> WorkspaceCoordinate "process-profile" -> WorkspaceCoordinate "process-rule" -> Maybe ProcessCommand
processPolicyCommand policy profile selected
  | validProcessPolicy policy && digestText (workspaceCoordinateText profile) = case filter ((== selected) . (.rule)) policy.rules of
      [rule] -> Just (commandFor profile rule)
      _ -> Nothing
  | otherwise = Nothing

processFileAllowed :: ProcessPolicy -> Text -> WorkspaceCoordinate "relative-path" -> Bool
processFileAllowed policy kind path = validProcessPolicy policy && validWorkspacePath (workspaceCoordinateText path) && any includesPath prefixes
  where
    prefixes = case kind of "read" -> policy.readPaths; "replace" -> policy.writePaths; _ -> []
    includesPath prefix = Text.null (workspaceCoordinateText prefix) || workspaceCoordinateText path == workspaceCoordinateText prefix || (workspaceCoordinateText prefix <> "/") `Text.isPrefixOf` workspaceCoordinateText path

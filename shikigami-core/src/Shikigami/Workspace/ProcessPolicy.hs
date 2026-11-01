{-# LANGUAGE DataKinds #-}

-- | Retained operator rules and private Unix identities. Policy changes produce
-- a new workspace binding; current configuration cannot reinterpret old work.
module Shikigami.Workspace.ProcessPolicy where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Bytes
import Data.List (nub, sort, sortOn)
import Data.Map.Strict (Map)
import Data.Text qualified as Text
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

data ProcessImage = ProcessImage
  { rootDirectory :: !(WorkspaceLocator "image-root"),
    rootIdentity :: !(WorkspaceCoordinate "image-digest"),
    environmentExecutable :: !(WorkspaceLocator "environment-executable"),
    deadlineExecutable :: !(WorkspaceLocator "deadline-executable"),
    collectorExecutable :: !(WorkspaceLocator "collector-executable")
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

data CommandRule = CommandRule
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

data ProcessPolicy = ProcessPolicy
  { format :: !ProcessPolicyFormat,
    image :: !ProcessImage,
    propertiesDigest :: !(WorkspaceCoordinate "process-properties"),
    rules :: ![CommandRule],
    readPaths :: !([WorkspaceCoordinate "path-prefix"]),
    writePaths :: !([WorkspaceCoordinate "path-prefix"])
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

data ProcessProfile = ProcessProfile
  { bindingDigest :: !(WorkspaceCoordinate "binding-digest"),
    instructionDigest :: !(WorkspaceCoordinate "instructions-digest"),
    policy :: !ProcessPolicy,
    userId :: !(WorkspaceIdentity),
    groupId :: !(WorkspaceIdentity)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

data IdentityRange = IdentityRange {firstId :: !(WorkspaceIdentity), lastId :: !(WorkspaceIdentity)}
  deriving stock (Eq, Show, Generic)

instance FromJSON IdentityRange where parseJSON = Aeson.genericParseJSON strictOptions

data ProfileState = ProfileReserved | ProfileReady deriving stock (Eq, Show)

instance Show ProcessImage where show _ = "ProcessImage <protected>"

instance Show CommandRule where show _ = "CommandRule <protected>"

instance Show ProcessPolicy where show _ = "ProcessPolicy <protected>"

instance Show ProcessProfile where show _ = "ProcessProfile <protected>"

strictOptions :: Aeson.Options
strictOptions = Aeson.defaultOptions {Aeson.rejectUnknownFields = True}

instance FromJSON ProcessImage where parseJSON = Aeson.genericParseJSON strictOptions

instance FromJSON CommandRule where parseJSON = Aeson.genericParseJSON strictOptions

instance FromJSON ProcessPolicy where parseJSON = Aeson.genericParseJSON strictOptions

instance FromJSON ProcessProfile where parseJSON = Aeson.genericParseJSON strictOptions

processPolicyIdentity :: ProcessPolicy -> WorkspaceCoordinate "policy-identity"
processPolicyIdentity policy = workspaceCoordinate ("policy2-" <> Text.drop 7 (versionedDigest "shikigami.workspace-supervised-policy/1" (toJSON (policy.format, policy.image, policy.propertiesDigest, sortOn (.rule) policy.rules, sort policy.readPaths, sort policy.writePaths))))

validProcessPolicy :: ProcessPolicy -> Bool
validProcessPolicy policy = policy.format == ProcessPolicyV1 && digestText (workspaceCoordinateText policy.propertiesDigest) && validImage && not (null policy.rules) && length policy.rules <= 64 && length (nub (map (.rule) policy.rules)) == length policy.rules && all (validProcessCommand . commandFor digest) policy.rules && all validPrefixes [policy.readPaths, policy.writePaths] && Bytes.length (Aeson.encode policy) <= 262144
  where
    digest = workspaceCoordinate (versionedDigest "shikigami.workspace-rule-validation/1" Aeson.Null)
    image = policy.image
    validImage = digestText (workspaceCoordinateText image.rootIdentity) && and [safeAbsolute (workspaceLocatorPath image.rootDirectory), safeAbsolute (workspaceLocatorPath image.environmentExecutable), safeAbsolute (workspaceLocatorPath image.deadlineExecutable), safeAbsolute (workspaceLocatorPath image.collectorExecutable)] && and [immutableHelper (Text.pack (workspaceLocatorPath image.environmentExecutable)), immutableHelper (Text.pack (workspaceLocatorPath image.deadlineExecutable))]
    validPrefixes paths = length paths <= 64 && length (nub paths) == length paths && all (\path -> Text.null (workspaceCoordinateText path) || (validWorkspacePath (workspaceCoordinateText path) && Text.all (< '\DEL') (workspaceCoordinateText path))) paths

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

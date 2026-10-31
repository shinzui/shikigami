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
  { rootDirectory :: !FilePath,
    rootIdentity :: !Text,
    environmentExecutable :: !Text,
    deadlineExecutable :: !Text,
    collectorExecutable :: !FilePath
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

data CommandRule = CommandRule
  { rule :: !Text,
    executable :: !Text,
    arguments :: ![Text],
    directory :: !Text,
    environment :: !(Map Text Text),
    timeoutSeconds :: !Int,
    outputBytes :: !Int
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

data ProcessPolicy = ProcessPolicy
  { format :: !ProcessPolicyFormat,
    image :: !ProcessImage,
    propertiesDigest :: !Text,
    rules :: ![CommandRule],
    readPaths :: ![Text],
    writePaths :: ![Text]
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

data ProcessProfile = ProcessProfile
  { bindingDigest :: !Text,
    instructionDigest :: !Text,
    policy :: !ProcessPolicy,
    userId :: !Int,
    groupId :: !Int
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

data IdentityRange = IdentityRange {firstId :: !Int, lastId :: !Int}
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

processPolicyIdentity :: ProcessPolicy -> Text
processPolicyIdentity policy = "policy2-" <> Text.drop 7 (versionedDigest "shikigami.workspace-supervised-policy/1" (toJSON (policy.format, policy.image, policy.propertiesDigest, sortOn (.rule) policy.rules, sort policy.readPaths, sort policy.writePaths)))

validProcessPolicy :: ProcessPolicy -> Bool
validProcessPolicy policy = policy.format == ProcessPolicyV1 && digestText policy.propertiesDigest && validImage && not (null policy.rules) && length policy.rules <= 64 && length (nub (map (.rule) policy.rules)) == length policy.rules && all (validProcessCommand . commandFor digest) policy.rules && all validPrefixes [policy.readPaths, policy.writePaths] && Bytes.length (Aeson.encode policy) <= 262144
  where
    digest = versionedDigest "shikigami.workspace-rule-validation/1" Aeson.Null
    image = policy.image
    validImage = digestText image.rootIdentity && all safeAbsolute [image.rootDirectory, Text.unpack image.environmentExecutable, Text.unpack image.deadlineExecutable, image.collectorExecutable] && all immutableHelper [image.environmentExecutable, image.deadlineExecutable]
    validPrefixes paths = length paths <= 64 && length (nub paths) == length paths && all (\path -> Text.null path || (validWorkspacePath path && Text.all (< '\DEL') path)) paths

safeAbsolute :: FilePath -> Bool
safeAbsolute path = isAbsolute path && path /= "/" && normalise path == path && validWorkspacePath (Text.drop 1 (Text.pack path)) && Text.all (\c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c `elem` ("/._-" :: String)) (Text.pack path)

immutableHelper :: Text -> Bool
immutableHelper path = all (\prefix -> path /= prefix && not ((prefix <> "/") `Text.isPrefixOf` path)) ["/workspace", "/scratch"]

validIdentityRange :: IdentityRange -> Bool
validIdentityRange range = range.firstId >= 1000 && range.lastId >= range.firstId && range.lastId <= 2147483647 && range.lastId - range.firstId < 65536

validProcessProfile :: ProcessProfile -> Bool
validProcessProfile profile = digestText profile.bindingDigest && digestText profile.instructionDigest && validProcessPolicy profile.policy && profile.userId >= 1000 && profile.userId <= 2147483647 && profile.groupId == profile.userId

commandFor :: Text -> CommandRule -> ProcessCommand
commandFor profile rule = ProcessCommand rule.rule profile rule.executable rule.arguments rule.directory rule.environment rule.timeoutSeconds rule.outputBytes

processPolicyCommand :: ProcessPolicy -> Text -> Text -> Maybe ProcessCommand
processPolicyCommand policy profile selected
  | validProcessPolicy policy && digestText profile = case filter ((== selected) . (.rule)) policy.rules of
      [rule] -> Just (commandFor profile rule)
      _ -> Nothing
  | otherwise = Nothing

processFileAllowed :: ProcessPolicy -> Text -> Text -> Bool
processFileAllowed policy kind path = validProcessPolicy policy && validWorkspacePath path && any includesPath prefixes
  where
    prefixes = case kind of "read" -> policy.readPaths; "replace" -> policy.writePaths; _ -> []
    includesPath prefix = Text.null prefix || path == prefix || (prefix <> "/") `Text.isPrefixOf` path

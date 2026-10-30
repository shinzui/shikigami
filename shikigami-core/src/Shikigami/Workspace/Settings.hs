-- | Bounded operator configuration, never accepted model input. Local source
-- paths have no public rendering and are not copied into model context.
module Shikigami.Workspace.Settings where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.List (nub, sort)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Prelude
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.Instructions (validWorkspacePath)
import System.FilePath (isAbsolute, normalise, splitDirectories)

data WorkspaceSettings = WorkspaceSettings
  {storageRoot :: !FilePath, repositories :: ![WorkspaceRepository], grants :: ![WorkspaceGrant]}
  deriving stock (Eq, Generic)

data WorkspaceRepository = WorkspaceRepository
  { identity :: !Text,
    source :: !FilePath,
    revisions :: ![WorkspaceRevision],
    defaultRevision :: !Text,
    policyRevision :: !Text,
    readPaths :: ![Text],
    writePaths :: ![Text]
  }
  deriving stock (Eq, Generic)

data WorkspaceRevision = WorkspaceRevision {base :: !Text, instructionDigest :: !Text}
  deriving stock (Eq, Generic)

data WorkspaceGrant = WorkspaceGrant {agent :: !Text, principal :: !Text, repository :: !Text, base :: !(Maybe Text)}
  deriving stock (Eq, Generic)

instance FromJSON WorkspaceSettings where
  parseJSON value = do
    settings <- Aeson.genericParseJSON strictOptions value
    either (fail . Text.unpack) (const (pure settings)) (validateWorkspaceSettings settings)

instance FromJSON WorkspaceRepository where parseJSON = Aeson.genericParseJSON strictOptions

instance FromJSON WorkspaceRevision where parseJSON = Aeson.genericParseJSON strictOptions

instance FromJSON WorkspaceGrant where parseJSON = Aeson.genericParseJSON strictOptions

strictOptions :: Aeson.Options
strictOptions = Aeson.defaultOptions {Aeson.rejectUnknownFields = True}

validateWorkspaceSettings :: WorkspaceSettings -> Either Text WorkspaceCatalog
validateWorkspaceSettings settings = do
  unless (settings.storageRoot /= "/" && isAbsolute settings.storageRoot && normalise settings.storageRoot == settings.storageRoot && ".." `notElem` splitDirectories settings.storageRoot && length settings.storageRoot <= 4096 && '\0' `notElem` settings.storageRoot) refused
  unless (not (null settings.repositories) && length settings.repositories <= 64 && not (null settings.grants) && length settings.grants <= 256) refused
  mapM_ validateRepository settings.repositories
  catalog <- either (const (Left "invalid workspace repository catalog")) Right (mkWorkspaceCatalog [RepositoryPolicy entry.identity entry.source (map (.base) entry.revisions) entry.defaultRevision (workspacePolicyIdentity entry) | entry <- settings.repositories])
  unless (length (nub (map (.agent) settings.grants)) == length settings.grants) refused
  forM_ settings.grants \grant -> do
    unless (bounded grant.agent && bounded grant.principal) refused
    either (const refused) (const (Right ())) (resolveRepository catalog grant.repository grant.base)
  pure catalog
  where
    refused = Left "invalid workspace settings"
    bounded value = not (Text.null value) && Text.length value <= 256 && not (Text.any (< ' ') value)
    validateRepository entry = do
      unless (not (Text.null entry.policyRevision) && Text.length entry.policyRevision <= 128 && not (Text.any (< ' ') entry.policyRevision)) refused
      unless (not (null entry.revisions) && length entry.revisions <= 64 && length (nub (map (.base) entry.revisions)) == length entry.revisions && length entry.source <= 4096) refused
      unless (all (validDigest . (.instructionDigest)) entry.revisions) refused
      unless (all validPrefixes [entry.readPaths, entry.writePaths]) refused
    validPrefixes paths = length paths <= 64 && length (nub paths) == length paths && all (\path -> Text.null path || (validWorkspacePath path && Text.all (< '\DEL') path)) paths
    validDigest value = Text.length value == 71 && "sha256:" `Text.isPrefixOf` value && Text.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) (Text.drop 7 value)

-- Empty prefixes explicitly admit the complete tree. Empty lists admit no path.
pathAdmitted :: [Text] -> Text -> Bool
pathAdmitted prefixes target = any (\prefix -> Text.null prefix || target == prefix || (prefix <> "/") `Text.isPrefixOf` target) prefixes

-- A human revision label cannot silently reinterpret an already admitted
-- restriction set. Adding bases does not change the policy for existing bases;
-- their reviewed instruction identities are checked separately.
workspacePolicyIdentity :: WorkspaceRepository -> Text
workspacePolicyIdentity entry = "policy1-" <> Text.drop 7 (versionedDigest "shikigami.workspace-operator-policy/1" (Aeson.object ["revision" Aeson..= entry.policyRevision, "readPaths" Aeson..= sort entry.readPaths, "writePaths" Aeson..= sort entry.writePaths]))

-- The daemon selects commands from retained profiles. This configuration only
-- identifies its manager-owned socket and bounds authenticated RPC intake.
data WorkspaceSupervisorSettings = WorkspaceSupervisorSettings
  {socketPath :: !FilePath, users :: ![Integer], workers :: !Int, timeoutSeconds :: !Int}
  deriving stock (Eq, Generic)

instance FromJSON WorkspaceSupervisorSettings where
  parseJSON value = do
    settings <- Aeson.genericParseJSON strictOptions value
    unless (isAbsolute settings.socketPath && settings.socketPath /= "/" && normalise settings.socketPath == settings.socketPath && '\0' `notElem` settings.socketPath && ".." `notElem` splitDirectories settings.socketPath && Bytes.length (Encoding.encodeUtf8 (Text.pack settings.socketPath)) <= 100 && not (null settings.users) && length settings.users <= 32 && length (nub settings.users) == length settings.users && all (\uid -> uid >= 0 && uid <= 4294967295) settings.users && settings.workers >= 1 && settings.workers <= 16 && settings.timeoutSeconds >= 1 && settings.timeoutSeconds <= 120) (fail "invalid workspace supervisor configuration")
    pure settings

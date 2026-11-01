{-# LANGUAGE DataKinds #-}

-- | Bounded operator configuration, never accepted model input. Local source
-- paths have no public rendering and are not copied into model context.
module Shikigami.Workspace.Settings where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, declarationCoordinateText)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Prelude hiding ((.=))
import Shikigami.Repository (RepositoryId, repositoryId, repositoryIdText)
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.Instructions (validWorkspacePath)
import Shikigami.Workspace.ProcessPolicy (IdentityRange, ProcessPolicy (..), processPolicyIdentity, validIdentityRange, validProcessPolicy)
import Shikigami.Workspace.Value
import System.FilePath (isAbsolute, normalise, splitDirectories)

data WorkspaceSettings = WorkspaceSettings
  {storageRoot :: !(WorkspaceLocator "storage-root"), repositories :: ![WorkspaceRepository], grants :: ![WorkspaceGrant], process :: !(Maybe WorkspaceProcessSettings)}
  deriving stock (Eq, Generic)

-- Every repository in a process host has an explicit retained policy. There is
-- no implicit shell, default command or unsupervised execution fallback.
data WorkspaceProcessSettings = WorkspaceProcessSettings
  { socketPath :: !(WorkspaceLocator "rpc-socket"),
    serverUser :: !(RpcPeerUserId),
    requestSeconds :: !(RpcRequestSeconds),
    waitSeconds :: !(RpcWaitSeconds),
    identities :: !IdentityRange,
    policies :: !(Map RepositoryId ProcessPolicy)
  }
  deriving stock (Eq, Generic)

instance FromJSON WorkspaceProcessSettings where parseJSON = Aeson.genericParseJSON strictOptions

data WorkspaceRepository = WorkspaceRepository
  { identity :: !(RepositoryId),
    source :: !(WorkspaceLocator "repository-source"),
    revisions :: ![WorkspaceRevision],
    defaultRevision :: !(WorkspaceCoordinate "git-object"),
    policyRevision :: !(WorkspaceCoordinate "policy-label"),
    readPaths :: !([WorkspaceCoordinate "path-prefix"]),
    writePaths :: !([WorkspaceCoordinate "path-prefix"])
  }
  deriving stock (Eq, Generic)

data WorkspaceRevision = WorkspaceRevision {base :: !(WorkspaceCoordinate "git-object"), instructionDigest :: !(WorkspaceCoordinate "instructions-digest")}
  deriving stock (Eq, Generic)

data WorkspaceGrant = WorkspaceGrant {agent :: !(AgentName), principal :: !(DeclarationCoordinate "principal"), repository :: !(RepositoryId), base :: !(Maybe (WorkspaceCoordinate "git-object"))}
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
  unless (workspaceLocatorPath settings.storageRoot /= "/" && isAbsolute (workspaceLocatorPath settings.storageRoot) && normalise (workspaceLocatorPath settings.storageRoot) == workspaceLocatorPath settings.storageRoot && ".." `notElem` splitDirectories (workspaceLocatorPath settings.storageRoot) && length (workspaceLocatorPath settings.storageRoot) <= 4096 && '\0' `notElem` workspaceLocatorPath settings.storageRoot) refused
  unless (not (null settings.repositories) && length settings.repositories <= 64 && not (null settings.grants) && length settings.grants <= 256) refused
  mapM_ validateRepository settings.repositories
  forM_ settings.process \process -> do
    unless (validSocketPath process.socketPath && (rpcPeerUserIdNumber process.serverUser) >= 0 && (rpcPeerUserIdNumber process.serverUser) <= 4294967295 && (rpcRequestSecondsNumber process.requestSeconds) >= 1 && (rpcRequestSecondsNumber process.requestSeconds) <= 120 && (rpcWaitSecondsNumber process.waitSeconds) >= 1 && (rpcWaitSecondsNumber process.waitSeconds) <= 3600 && validIdentityRange process.identities) refused
    unless (Map.keysSet process.policies == Map.keysSet (Map.fromList [(entry.identity, ()) | entry <- settings.repositories])) refused
    forM_ settings.repositories \entry -> case Map.lookup entry.identity process.policies of
      Just policy | validProcessPolicy policy && sort policy.readPaths == sort entry.readPaths && sort policy.writePaths == sort entry.writePaths -> pure ()
      _ -> refused
  catalog <- either (const (Left "invalid workspace repository catalog")) Right (mkWorkspaceCatalog [RepositoryPolicy entry.identity entry.source (map (.base) entry.revisions) entry.defaultRevision (configuredPolicyIdentity settings entry) | entry <- settings.repositories])
  unless (length (nub (map (.agent) settings.grants)) == length settings.grants) refused
  forM_ settings.grants \grant -> do
    unless (bounded (agentNameText grant.agent) && bounded (declarationCoordinateText grant.principal)) refused
    either (const refused) (const (Right ())) (resolveRepository catalog grant.repository grant.base)
  pure catalog
  where
    refused = Left "invalid workspace settings"
    bounded value = not (Text.null value) && Text.length value <= 256 && not (Text.any (< ' ') value)
    validateRepository entry = do
      unless (not (Text.null (workspaceCoordinateText entry.policyRevision)) && Text.length (workspaceCoordinateText entry.policyRevision) <= 128 && not (Text.any (< ' ') (workspaceCoordinateText entry.policyRevision))) refused
      unless (not (null entry.revisions) && length entry.revisions <= 64 && length (nub (map (.base) entry.revisions)) == length entry.revisions && length (workspaceLocatorPath entry.source) <= 4096) refused
      unless (all (validDigest . workspaceCoordinateText . (.instructionDigest)) entry.revisions) refused
      unless (all validPrefixes [entry.readPaths, entry.writePaths]) refused
    validPrefixes paths = length paths <= 64 && length (nub paths) == length paths && all (\path -> Text.null (workspaceCoordinateText path) || (validWorkspacePath (workspaceCoordinateText path) && Text.all (< '\DEL') (workspaceCoordinateText path))) paths
    validDigest value = Text.length value == 71 && "sha256:" `Text.isPrefixOf` value && Text.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) (Text.drop 7 value)

-- Empty prefixes explicitly admit the complete tree. Empty lists admit no path.
pathAdmitted :: [WorkspaceCoordinate "path-prefix"] -> WorkspaceCoordinate "relative-path" -> Bool
pathAdmitted prefixes target = any (\prefix -> Text.null (workspaceCoordinateText prefix) || workspaceCoordinateText target == workspaceCoordinateText prefix || (workspaceCoordinateText prefix <> "/") `Text.isPrefixOf` workspaceCoordinateText target) prefixes

-- A human revision label cannot silently reinterpret an already admitted
-- restriction set. Adding bases does not change the policy for existing bases;
-- their reviewed instruction identities are checked separately.
workspacePolicyIdentity :: WorkspaceRepository -> WorkspaceCoordinate "policy-identity"
workspacePolicyIdentity entry = workspaceCoordinate ("policy1-" <> Text.drop 7 (versionedDigest "shikigami.workspace-operator-policy/1" (Aeson.object ["revision" .= entry.policyRevision, "readPaths" .= sort entry.readPaths, "writePaths" .= sort entry.writePaths])))

configuredPolicyIdentity :: WorkspaceSettings -> WorkspaceRepository -> WorkspaceCoordinate "policy-identity"
configuredPolicyIdentity settings entry = maybe (workspacePolicyIdentity entry) processPolicyIdentity (settings.process >>= Map.lookup entry.identity . (.policies))

validSocketPath :: WorkspaceLocator "rpc-socket" -> Bool
validSocketPath value =
  let path = workspaceLocatorPath value
   in isAbsolute path && path /= "/" && normalise path == path && '\0' `notElem` path && ".." `notElem` splitDirectories path && Bytes.length (Encoding.encodeUtf8 (Text.pack path)) <= 100

-- The daemon selects commands from retained profiles. This configuration only
-- identifies its manager-owned socket and bounds authenticated RPC intake.
data WorkspaceSupervisorSettings = WorkspaceSupervisorSettings
  {socketPath :: !(WorkspaceLocator "rpc-socket"), users :: !([RpcPeerUserId]), workers :: !(RpcConcurrency), timeoutSeconds :: !(RpcRequestSeconds)}
  deriving stock (Eq, Generic)

instance FromJSON WorkspaceSupervisorSettings where
  parseJSON value = do
    settings <- Aeson.genericParseJSON strictOptions value
    unless (validSocketPath settings.socketPath && not (null settings.users) && length settings.users <= 32 && length (nub settings.users) == length settings.users && all (\uid -> rpcPeerUserIdNumber uid >= 0 && rpcPeerUserIdNumber uid <= 4294967295) settings.users && rpcConcurrencyNumber settings.workers >= 1 && rpcConcurrencyNumber settings.workers <= 16 && rpcRequestSecondsNumber settings.timeoutSeconds >= 1 && rpcRequestSecondsNumber settings.timeoutSeconds <= 120) (fail "invalid workspace supervisor configuration")
    pure settings

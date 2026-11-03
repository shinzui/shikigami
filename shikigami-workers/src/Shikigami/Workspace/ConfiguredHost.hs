-- | Production composition of reviewed repository policy, exact agent grants,
-- current principal/profile authority and exact retained workspace adapters.
module Shikigami.Workspace.ConfiguredHost (configuredWorkspaceHost, configuredWorkspaceHostWithTransfers, configuredWorkspaceTransfers) where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Time (getCurrentTime)
import Hasql.Pool (Pool)
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Principal (identityText)
import Shikigami.App (AppEnv)
import Shikigami.Attestation.Resolve qualified as Profile
import Shikigami.Directory (DirectoryHandle, identityLifecycleAdmission)
import Shikigami.Execution.SelectionRuntime (currentExecutionAuthority)
import Shikigami.Execution.Start (SkillAssignment (..))
import Shikigami.Execution.Transcript (ExecutionSnapshot (..))
import Shikigami.Prelude
import Shikigami.Workspace.Admission (WorkspaceHost)
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.FileProvider
import Shikigami.Workspace.GitProvider (transferredWorkspaceGitAdapter, workspaceGitAdapter, workspaceIntegrationAdapter)
import Shikigami.Workspace.Host
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.ProcessProvider
import Shikigami.Workspace.Profile (retainedFileProfile)
import Shikigami.Workspace.Provision
import Shikigami.Workspace.Settings
import Shikigami.Workspace.Systemd qualified as Systemd
import Shikigami.Workspace.TransferClient (configuredWorkspaceTransfers)
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value

configuredWorkspaceHost :: AppEnv -> Pool -> DirectoryHandle -> ActionAuthorizer -> WorkspaceSettings -> Either Text WorkspaceHost
configuredWorkspaceHost = configuredWorkspaceHostFor False

-- Transfer-aware composition retains the exact historical adapters for
-- previously accepted snapshots alongside fresh successor-aware revisions.
configuredWorkspaceHostWithTransfers :: AppEnv -> Pool -> DirectoryHandle -> ActionAuthorizer -> WorkspaceSettings -> Either Text WorkspaceHost
configuredWorkspaceHostWithTransfers = configuredWorkspaceHostFor True

configuredWorkspaceHostFor :: Bool -> AppEnv -> Pool -> DirectoryHandle -> ActionAuthorizer -> WorkspaceSettings -> Either Text WorkspaceHost
configuredWorkspaceHostFor transferable appEnv pool directory authorizer settings = do
  catalog <- validateWorkspaceSettings settings
  let resolve agent identity = do
        principal <- either (const refused) Right (identityText identity)
        grant <- case filter (\grant -> grant.agent == agent && grant.principal == declarationCoordinate principal) settings.grants of
          [grant] -> Right grant
          _ -> refused
        either (const refused) Right (resolveRepository catalog grant.repository grant.base)
      resolveProfile profile version = getCurrentTime >>= \now -> Profile.resolveProfile (Profile.postgresProfileStore pool) now profile version
      authority identity profile = currentExecutionAuthority (identityLifecycleAdmission directory identity) profile resolveProfile
      activeSnapshot snapshot = case resolve snapshot.agent snapshot.identity of
        Left err -> pure (Left err)
        Right selected -> case snapshot.workspace of
          Just admission | bundleRepository admission.instructions == repositoryIdentity selected && bundleBase admission.instructions == repositoryBase selected -> authority snapshot.identity snapshot.sanctionedProfile
          _ -> pure refused
      runtime = FileRuntime appEnv authorizer activeSnapshot (identityLifecycleAdmission directory . (.identity)) targetPolicy
      select assignment = do
        supported <- case settings.process of
          Nothing -> pure (Right ())
          Just _ -> fmap (either (const refused) (const (Right ()))) Systemd.systemdBootIdentity
        pure (supported >> resolve assignment.agent assignment.identity)
      current assignment = case resolve assignment.agent assignment.identity of Left err -> pure (Left err); Right _ -> authority assignment.identity assignment.sanctionedProfile
  case settings.process of
    Nothing -> fileWorkspaceHost runtime (workspaceLocatorPath settings.storageRoot) select current
    Just process -> do
      let client = ProcessClient process.socketPath process.serverUser process.requestSeconds process.waitSeconds
          prepare assignment binding admission = case Map.lookup binding.repository process.policies of
            Nothing -> pure refused
            Just policy
              | admission.runId /= binding.request.runId -> do
                  retained <- retainedFileProfile appEnv binding admission
                  pure (either (const refused) (const (Right admission)) retained)
              | otherwise -> do
                  let provision = ProvisionRuntime appEnv authorizer (current assignment) nativeProvisionBackend
                      accepted = if transferable then admission else admission & #filePolicy .~ Just supervisedFilePolicy
                  result <- provisionWorkspaceProfile provision binding accepted policy process.identities
                  pure (either (const refused) (const (Right accepted)) result)
          selected = if transferable then [transferredWorkspaceEditAdapter runtime, transferredWorkspaceExecAdapter client, transferredWorkspaceGitAdapter runtime, workspaceIntegrationAdapter runtime] else [supervisedWorkspaceEditAdapter runtime, workspaceExecAdapter client, workspaceGitAdapter runtime]
          historical = if transferable then [workspaceEditAdapter runtime, supervisedWorkspaceEditAdapter runtime, workspaceExecAdapter client, workspaceGitAdapter runtime] else [workspaceEditAdapter runtime]
          host = if transferable then governedWorkspaceHostWithTransfers else governedWorkspaceHost
      host runtime selected historical prepare (workspaceLocatorPath settings.storageRoot) select current
  where
    refused = Left "workspace operator policy refused"
    targetPolicy binding admission _scoped kind path = pure do
      entry <- case filter (\entry -> entry.identity == binding.repository && binding.policyRevision `elem` [workspacePolicyIdentity entry, configuredPolicyIdentity settings entry] && entry.source == binding.source) settings.repositories of
        [entry] -> Right entry
        _ -> refused
      revision <- case filter (\revision -> revision.base == binding.base) entry.revisions of
        [revision] -> Right revision
        _ -> refused
      -- Approval covers the complete scope-labelled bundle, so explicit
      -- conflicts must be resolved by the operator before this digest is listed.
      unless (revision.instructionDigest == bundleDigest admission.instructions) refused
      case workspaceCoordinateText kind of
        "admit" -> Right ()
        "read" -> unless (pathAdmitted entry.readPaths path) refused
        "replace" -> unless (pathAdmitted entry.writePaths path) refused
        _ -> refused

-- | Production composition of reviewed repository policy, exact agent grants,
-- current principal/profile authority and the file-only native adapter.
module Shikigami.Workspace.ConfiguredHost (configuredWorkspaceHost) where

import Data.Time (getCurrentTime)
import Hasql.Pool (Pool)
import Kioku.App (AppEnv)
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Agent.Principal (identityText)
import Shikigami.Attestation.Resolve qualified as Profile
import Shikigami.Directory (DirectoryHandle, identityLifecycleAdmission)
import Shikigami.Execution.SelectionRuntime (currentExecutionAuthority)
import Shikigami.Execution.Start (SkillAssignment (..))
import Shikigami.Execution.Transcript (ExecutionSnapshot (..))
import Shikigami.Prelude
import Shikigami.Workspace.Admission (WorkspaceHost)
import Shikigami.Workspace.Catalog
import Shikigami.Workspace.FileProvider
import Shikigami.Workspace.Host
import Shikigami.Workspace.Instructions
import Shikigami.Workspace.Settings
import Shikigami.Workspace.Types

configuredWorkspaceHost :: AppEnv -> Pool -> DirectoryHandle -> ActionAuthorizer -> WorkspaceSettings -> Either Text WorkspaceHost
configuredWorkspaceHost appEnv pool directory authorizer settings = do
  catalog <- validateWorkspaceSettings settings
  let resolve agent identity = do
        principal <- either (const refused) Right (identityText identity)
        grant <- case filter (\grant -> grant.agent == agentNameText agent && grant.principal == principal) settings.grants of
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
  fileWorkspaceHost runtime settings.storageRoot (\assignment -> pure (resolve assignment.agent assignment.identity)) (\assignment -> case resolve assignment.agent assignment.identity of Left err -> pure (Left err); Right _ -> authority assignment.identity assignment.sanctionedProfile)
  where
    refused = Left "workspace operator policy refused"
    targetPolicy binding admission _scoped kind path = pure do
      entry <- case filter (\entry -> entry.identity == binding.repository && workspacePolicyIdentity entry == binding.policyRevision && entry.source == binding.source) settings.repositories of
        [entry] -> Right entry
        _ -> refused
      revision <- case filter (\revision -> revision.base == binding.base) entry.revisions of
        [revision] -> Right revision
        _ -> refused
      -- Approval covers the complete scope-labelled bundle, so explicit
      -- conflicts must be resolved by the operator before this digest is listed.
      unless (revision.instructionDigest == bundleDigest admission.instructions) refused
      case kind of
        "admit" -> Right ()
        "read" -> unless (pathAdmitted entry.readPaths path) refused
        "replace" -> unless (pathAdmitted entry.writePaths path) refused
        _ -> refused

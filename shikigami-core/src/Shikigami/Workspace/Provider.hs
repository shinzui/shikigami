-- | Shared, protected file-effect contracts. None of these values is a permit.
module Shikigami.Workspace.Provider where

import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Kikan.En.Action (AgentAction (InvokeCapabilityTool), mkCapabilityToolTarget)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (AttemptId, OperationId)
import Shikigami.Execution.Runner (DispatchContext (..), OperationContext (..))
import Shikigami.Prelude
import Shikigami.Workspace.GitTypes qualified as Git
import Shikigami.Workspace.Instructions (WorkspaceAdmission (..), bundleBase, bundleDigest, bundleRepository, nativeFilePolicy, supervisedFilePolicy, validWorkspacePath)
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.Types

-- Whole-file compare-and-replace, including creation in an existing directory.
-- A missing expected hash means absent, never an unconditional overwrite.
data Replacement = Replacement {path :: !Text, expected :: !(Maybe Text), content :: !Text}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show Replacement where show _ = "Replacement <protected>"

data FileEffectError = FileEffectRefused | FileEffectConflict | FileEffectUnavailable | FileEffectUnresolved | FileEffectTooLarge
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ReceiptState = EditPrepared | EditApplied | EditRefused
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data FileReceipt = FileReceipt
  { operationId :: !OperationId,
    attemptId :: !AttemptId,
    generation :: !Integer,
    fingerprint :: !Text,
    bindingDigest :: !Text,
    instructionDigest :: !Text,
    path :: !Text,
    target :: !Text,
    expected :: !(Maybe Text),
    result :: !Text,
    state :: !ReceiptState
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show FileReceipt where show _ = "FileReceipt <protected>"

contentDigest :: Text -> Text
contentDigest = versionedDigest "shikigami.workspace-content/1" . toJSON

-- Allocation is protected IO too. This action binds the reserved immutable
-- resource and execution assignment before reading the operator's source.
workspaceAllocationAction :: WorkspaceBinding -> Text -> Either FileEffectError AgentAction
workspaceAllocationAction binding assignment = do
  unless (not (Text.null assignment) && Text.length assignment <= 256) (Left FileEffectRefused)
  let digest = Text.replace ":" "-" (versionedDigest "shikigami.workspace-admission-action/1" (toJSON (workspaceBindingDigest binding, assignment)))
  either (const (Left FileEffectRefused)) (Right . InvokeCapabilityTool) (mkCapabilityToolTarget "shikigami.workspace" "1" ("admit-" <> digest))

-- Native provisioning precedes the first model request, so it has assignment
-- coordinates rather than a fabricated execution attempt. Bind the exact
-- reserved Unix identity, frozen policy and anchored roots into fresh C13.
workspaceProvisionAction :: WorkspaceBinding -> WorkspaceAdmission -> ProcessProfile -> Text -> Text -> Text -> Either FileEffectError AgentAction
workspaceProvisionAction binding admission profile boot filesTarget scratchTarget = do
  unless (admission.filePolicy == Just supervisedFilePolicy && admission.workspace == binding.workspace && admission.bindingDigest == workspaceBindingDigest binding && admission.runId == binding.request.runId && admission.rootId == binding.request.rootId && admission.owner == binding.request.owner && admission.epoch == binding.request.epoch && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base && bounded admission.assignmentId) (Left FileEffectRefused)
  unless (validProcessProfile profile && profile.bindingDigest == workspaceBindingDigest binding && profile.instructionDigest == bundleDigest admission.instructions && processPolicyIdentity profile.policy == binding.policyRevision && hostIdentity boot && all (\target -> bounded target && Text.length target <= 128) [filesTarget, scratchTarget]) (Left FileEffectRefused)
  let coordinates =
        Aeson.object
          [ "binding" Aeson..= workspaceBindingDigest binding,
            "filePolicy" Aeson..= admission.filePolicy,
            "assignment" Aeson..= admission.assignmentId,
            "owner" Aeson..= admission.owner,
            "epoch" Aeson..= admission.epoch,
            "profile" Aeson..= profile,
            "boot" Aeson..= boot,
            "filesTarget" Aeson..= filesTarget,
            "scratchTarget" Aeson..= scratchTarget
          ]
      digest = Text.replace ":" "-" (versionedDigest "shikigami.workspace-provision-action/1" coordinates)
      revision = "2-" <> Text.replace ":" "-" (workspaceBindingDigest binding)
  either (const (Left FileEffectRefused)) (Right . InvokeCapabilityTool) (mkCapabilityToolTarget "shikigami.workspace" revision ("provision-" <> digest))

-- Digest every accepted coordinate into the closed C13 capability-tool target.
-- The concrete provider obtains target from an anchored parent descriptor and
-- obtains binding/admission/dispatch from retained state, never model arguments.
workspaceFileAction :: WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> Text -> Text -> Text -> Text -> Either FileEffectError AgentAction
workspaceFileAction = workspaceFileActionFor Nothing

-- The complete retained profile, including its reserved Unix identity, belongs
-- to the revision-2 authority target. Revision 1 keeps its original encoding.
workspaceSupervisedFileAction :: ProcessProfile -> WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> Text -> Text -> Text -> Text -> Either FileEffectError AgentAction
workspaceSupervisedFileAction profile = workspaceFileActionFor (Just profile)

workspaceFileActionFor :: Maybe ProcessProfile -> WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> Text -> Text -> Text -> Text -> Either FileEffectError AgentAction
workspaceFileActionFor profile binding admission dispatch kind path target inputDigest = do
  unless (Text.all (< '\DEL') path) (Left FileEffectRefused)
  case profile of
    Nothing -> unless (admission.filePolicy == Just nativeFilePolicy) (Left FileEffectRefused)
    Just retained -> unless (admission.filePolicy == Just supervisedFilePolicy && validProcessProfile retained && retained.bindingDigest == workspaceBindingDigest binding && retained.instructionDigest == bundleDigest admission.instructions && processPolicyIdentity retained.policy == binding.policyRevision && processFileAllowed retained.policy kind path) (Left FileEffectRefused)
  unless (kind `elem` ["read", "replace"] && validWorkspacePath path && not (Text.null target) && Text.length target <= 128 && not (Text.null inputDigest) && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base && admission.workspace == binding.workspace && admission.bindingDigest == workspaceBindingDigest binding && admission.runId == binding.request.runId && admission.rootId == binding.request.rootId && admission.owner == binding.request.owner && admission.epoch == binding.request.epoch && dispatch.generation > 0 && not (Text.null dispatch.owner)) (Left FileEffectRefused)
  let coordinates =
        Aeson.object $
          [ "binding" Aeson..= workspaceBindingDigest binding,
            "instructions" Aeson..= bundleDigest admission.instructions,
            "filePolicy" Aeson..= admission.filePolicy,
            "assignment" Aeson..= admission.assignmentId,
            "owner" Aeson..= admission.owner,
            "epoch" Aeson..= admission.epoch,
            "operation" Aeson..= dispatch.operation,
            "attempt" Aeson..= dispatch.attemptId,
            "claimOwner" Aeson..= dispatch.owner,
            "generation" Aeson..= dispatch.generation,
            "kind" Aeson..= kind,
            "path" Aeson..= path,
            "target" Aeson..= target,
            "input" Aeson..= inputDigest
          ]
            <> maybe [] (\retained -> ["profile" Aeson..= retained]) profile
      digest = Text.replace ":" "-" (versionedDigest (if isJust profile then "shikigami.workspace-file-action/2" else "shikigami.workspace-file-action/1") coordinates)
      revision = (if isJust profile then "2-" else "1-") <> Text.replace ":" "-" (workspaceBindingDigest binding)
  either (const (Left FileEffectRefused)) (Right . InvokeCapabilityTool) (mkCapabilityToolTarget "shikigami.workspace" revision (kind <> "-" <> digest))

-- A process launch grant binds the complete retained rule, immutable root
-- profile, original actual attempt and absolute deadline. The resolved cwd
-- identity and host boot are trusted supervisor observations, never model input.
-- Phase is deliberately excluded from the hash so fresh authorization may be
-- checked before and after committing the single launch transition.
workspaceProcessAction :: WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> ProcessRecord -> Text -> Text -> Either FileEffectError AgentAction
workspaceProcessAction binding admission dispatch record boot target = do
  unless (admission.filePolicy == Just supervisedFilePolicy && admission.workspace == binding.workspace && admission.bindingDigest == workspaceBindingDigest binding && admission.runId == binding.request.runId && admission.rootId == binding.request.rootId && admission.owner == binding.request.owner && admission.epoch == binding.request.epoch && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base) (Left FileEffectRefused)
  unless (validProcessCommand record.command && record.phase `elem` [ProcessReserved, ProcessLaunchRequested] && record.operationId == dispatch.operation.operationId && record.attemptId == dispatch.attemptId && record.claimOwner == dispatch.owner && bounded dispatch.owner && record.generation == dispatch.generation && dispatch.generation > 0 && record.bindingDigest == workspaceBindingDigest binding && record.instructionDigest == bundleDigest admission.instructions && record.fingerprint == processFingerprint binding record.instructionDigest dispatch.operation record.command && record.unit == processUnit record.operationId record.fingerprint && hostIdentity boot && maybe True (== boot) record.bootId && isNothing record.invocationId && isNothing record.receipt && bounded target && Text.length target <= 128) (Left FileEffectRefused)
  routing <- maybe (Left FileEffectRefused) Right record.routing
  unless (validProcessRouting routing && routing.executionId == dispatch.operation.executionId && routing.identity == admission.owner) (Left FileEffectRefused)
  let coordinates =
        Aeson.object
          [ "binding" Aeson..= workspaceBindingDigest binding,
            "instructions" Aeson..= record.instructionDigest,
            "filePolicy" Aeson..= admission.filePolicy,
            "assignment" Aeson..= admission.assignmentId,
            "owner" Aeson..= admission.owner,
            "epoch" Aeson..= admission.epoch,
            "operation" Aeson..= dispatch.operation,
            "attempt" Aeson..= dispatch.attemptId,
            "claimOwner" Aeson..= dispatch.owner,
            "generation" Aeson..= dispatch.generation,
            "command" Aeson..= record.command,
            "fingerprint" Aeson..= record.fingerprint,
            "deadline" Aeson..= record.deadline,
            "routing" Aeson..= routing,
            "unit" Aeson..= record.unit,
            "boot" Aeson..= boot,
            "cwdTarget" Aeson..= target
          ]
      digest = Text.replace ":" "-" (versionedDigest "shikigami.workspace-process-action/1" coordinates)
      revision = "1-" <> Text.replace ":" "-" (workspaceBindingDigest binding)
  either (const (Left FileEffectRefused)) (Right . InvokeCapabilityTool) (mkCapabilityToolTarget "shikigami.workspace" revision ("exec-" <> digest))

-- Prepare can capture admitted bytes and create immutable objects; publish
-- additionally binds the exact parent/tree/commit and every changed path.
-- Neither proof can be reused by another actual claim or Unix profile.
workspaceGitAction :: WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> ProcessProfile -> Git.GitRecord -> Either FileEffectError AgentAction
workspaceGitAction binding admission dispatch profile record = do
  unless (admission.filePolicy == Just supervisedFilePolicy && admission.workspace == binding.workspace && admission.bindingDigest == workspaceBindingDigest binding && admission.runId == binding.request.runId && admission.rootId == binding.request.rootId && admission.owner == binding.request.owner && admission.epoch == binding.request.epoch && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base) (Left FileEffectRefused)
  unless (validProcessProfile profile && profile.bindingDigest == workspaceBindingDigest binding && profile.instructionDigest == bundleDigest admission.instructions && processPolicyIdentity profile.policy == binding.policyRevision && "" `elem` profile.policy.readPaths) (Left FileEffectRefused)
  unless (Git.validGitRecord record && record.phase `elem` [Git.GitReserved, Git.GitPrepared, Git.GitPublishRequested] && record.bindingDigest == workspaceBindingDigest binding && record.instructionDigest == bundleDigest admission.instructions && record.profileDigest == Git.gitProfileDigest profile && record.fingerprint == Git.gitFingerprint binding record && record.operation == dispatch.operation && record.attemptId == dispatch.attemptId && record.claimOwner == dispatch.owner && record.generation == dispatch.generation && record.routing.identity == admission.owner) (Left FileEffectRefused)
  forM_ record.candidate \candidate -> unless (all (processFileAllowed profile.policy "replace") candidate.paths) (Left FileEffectRefused)
  let coordinates = Aeson.object ["binding" Aeson..= workspaceBindingDigest binding, "instructions" Aeson..= bundleDigest admission.instructions, "filePolicy" Aeson..= admission.filePolicy, "assignment" Aeson..= admission.assignmentId, "owner" Aeson..= admission.owner, "epoch" Aeson..= admission.epoch, "profile" Aeson..= profile, "record" Aeson..= Git.gitActionIdentity record]
      digest = Text.replace ":" "-" (versionedDigest "shikigami.workspace-git-action/1" coordinates)
      revision = "git1-" <> Text.replace ":" "-" (workspaceBindingDigest binding)
  either (const (Left FileEffectRefused)) (Right . InvokeCapabilityTool) (mkCapabilityToolTarget "shikigami.workspace" revision ("commit-" <> digest))

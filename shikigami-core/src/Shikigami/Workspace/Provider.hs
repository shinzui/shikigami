{-# LANGUAGE DataKinds #-}

-- | Shared, protected file-effect contracts. None of these values is a permit.
module Shikigami.Workspace.Provider where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.List (nub)
import Data.Text qualified as Text
import Keiro.Workflow.Types (WorkflowId (..))
import Kikan.En.Action (AgentAction (InvokeCapabilityTool), mkCapabilityToolTarget)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.AssignmentKey (AssignmentKey)
import Shikigami.Execution.Claim
import Shikigami.Execution.Identity (AttemptId, OperationId)
import Shikigami.Execution.Payload (PayloadDigest)
import Shikigami.Execution.Runner (DispatchContext (..), OperationContext (..))
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Prelude hiding ((.=))
import Shikigami.StateRevision
import Shikigami.WorkerSession.Transfer (TransferIntent (..), WorkspaceRef (..))
import Shikigami.WorkerSession.Types (WorkerSessionId)
import Shikigami.Workspace.GitTypes qualified as Git
import Shikigami.Workspace.Instructions (WorkspaceAdmission (..), bundleBase, bundleDigest, bundleRepository, nativeFilePolicy, supervisedFilePolicy, transferableFilePolicy, validWorkspacePath)
import Shikigami.Workspace.Process
import Shikigami.Workspace.ProcessPolicy
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value

-- Whole-file compare-and-replace, including creation in an existing directory.
-- A missing expected hash means absent, never an unconditional overwrite.
data Replacement = Replacement {path :: !(WorkspaceCoordinate "relative-path"), expected :: !(Maybe (WorkspaceCoordinate "content-digest")), content :: !Text}
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
    generation :: !(StateRevision "execution-attempt"),
    fingerprint :: !(WorkspaceCoordinate "file-fingerprint"),
    bindingDigest :: !(WorkspaceCoordinate "binding-digest"),
    instructionDigest :: !(WorkspaceCoordinate "instructions-digest"),
    path :: !(WorkspaceCoordinate "relative-path"),
    target :: !(WorkspaceCoordinate "file-target"),
    expected :: !(Maybe (WorkspaceCoordinate "content-digest")),
    result :: !(WorkspaceCoordinate "content-digest"),
    state :: !ReceiptState
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show FileReceipt where show _ = "FileReceipt <protected>"

-- Separate from the historical receipt encoding. Retain the original dispatch
-- continuation before publication so an independent factual owner needs no
-- current replay authority or replacement worker to acknowledge the effect.
data FileRegistration = FileRegistration
  { operation :: !OperationContext,
    claimOwner :: !ClaimOwner,
    routing :: !ProcessRouting,
    receipt :: !FileReceipt
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show FileRegistration where show _ = "FileRegistration <protected>"

contentDigest :: Text -> WorkspaceCoordinate "content-digest"
contentDigest = workspaceCoordinate . versionedDigest "shikigami.workspace-content/1" . toJSON

workspaceTransferAction :: WorkspaceBinding -> TransferIntent -> Either FileEffectError AgentAction
workspaceTransferAction binding intent = do
  unless (intent.format == V1 && intent.workspace == binding.workspace && intent.rootId == binding.request.rootId && intent.oldEpoch >= binding.request.epoch && intent.newEpoch == advanceRevision intent.oldEpoch && revisionNumber intent.newEpoch < 9223372036854775808 && intent.oldOwner /= intent.newOwner && maybe False ((== intent.sessionId) . fst) binding.request.assignment) (Left FileEffectRefused)
  workspaceControlAction binding "fence" (toJSON intent)

workspaceWriteAdmissionAction :: WorkspaceBinding -> WorkspaceRef -> WorkerSessionId -> AgentIdentity -> StateRevision "worker-owner" -> OperationId -> Either FileEffectError AgentAction
workspaceWriteAdmissionAction binding workspace session owner epoch operation = do
  unless (workspace == binding.workspace && epoch >= binding.request.epoch && revisionNumber epoch < 9223372036854775808 && maybe False ((== session) . fst) binding.request.assignment) (Left FileEffectRefused)
  workspaceControlAction binding "write-admission" (toJSON (workspace, session, owner, epoch, operation))

workspaceSuccessorAdmissionAction :: WorkspaceBinding -> WorkspaceAdmission -> ProcessProfile -> Either FileEffectError AgentAction
workspaceSuccessorAdmissionAction binding admission profile = do
  unless (matchesWorkspaceAdmission binding admission && admission.filePolicy == Just transferableFilePolicy && admission.epoch > binding.request.epoch && validProcessProfile profile && profile.bindingDigest == workspaceBindingDigest binding && profile.instructionDigest == bundleDigest admission.instructions && processPolicyIdentity profile.policy == binding.policyRevision) (Left FileEffectRefused)
  workspaceControlAction binding "successor" (toJSON (versionedDigest "shikigami.workspace-successor-admission/1" (toJSON admission), profile))

workspaceFollowupAdmissionAction :: WorkspaceBinding -> WorkspaceAdmission -> ProcessProfile -> Either FileEffectError AgentAction
workspaceFollowupAdmissionAction binding admission profile = do
  unless (matchesWorkspaceAdmission binding admission && admission.filePolicy == Just transferableFilePolicy && admission.runId /= binding.request.runId && admission.owner == binding.request.owner && admission.epoch == binding.request.epoch && validProcessProfile profile && profile.bindingDigest == workspaceBindingDigest binding && profile.instructionDigest == bundleDigest admission.instructions && processPolicyIdentity profile.policy == binding.policyRevision) (Left FileEffectRefused)
  workspaceControlAction binding "followup" (toJSON (versionedDigest "shikigami.workspace-followup-admission/1" (toJSON admission), profile))

workspaceControlAction :: WorkspaceBinding -> Text -> Aeson.Value -> Either FileEffectError AgentAction
workspaceControlAction binding kind value = do
  let digest = Text.replace ":" "-" (versionedDigest "shikigami.workspace-control-action/1" (toJSON (workspaceBindingDigest binding, kind, value)))
      revision = "control1-" <> Text.replace ":" "-" (workspaceCoordinateText (workspaceBindingDigest binding))
  either (const (Left FileEffectRefused)) (Right . InvokeCapabilityTool) (mkCapabilityToolTarget "shikigami.workspace" revision (kind <> "-" <> digest))

-- Allocation is protected IO too. This action binds the reserved immutable
-- resource and execution assignment before reading the operator's source.
workspaceAllocationAction :: WorkspaceBinding -> AssignmentKey -> Either FileEffectError AgentAction
workspaceAllocationAction binding assignment = do
  let digest = Text.replace ":" "-" (versionedDigest "shikigami.workspace-admission-action/1" (toJSON (workspaceBindingDigest binding, assignment)))
  either (const (Left FileEffectRefused)) (Right . InvokeCapabilityTool) (mkCapabilityToolTarget "shikigami.workspace" "1" ("admit-" <> digest))

-- Native provisioning precedes the first model request, so it has assignment
-- coordinates rather than a fabricated execution attempt. Bind the exact
-- reserved Unix identity, frozen policy and anchored roots into fresh C13.
workspaceProvisionAction :: WorkspaceBinding -> WorkspaceAdmission -> ProcessProfile -> WorkspaceCoordinate "boot-id" -> WorkspaceCoordinate "file-target" -> WorkspaceCoordinate "file-target" -> Either FileEffectError AgentAction
workspaceProvisionAction binding admission profile boot filesTarget scratchTarget = do
  unless (admission.filePolicy `elem` map Just [supervisedFilePolicy, transferableFilePolicy] && matchesWorkspaceAdmission binding admission && admission.runId == binding.request.runId && admission.owner == binding.request.owner && admission.epoch == binding.request.epoch && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base) (Left FileEffectRefused)
  unless (validProcessProfile profile && profile.bindingDigest == workspaceBindingDigest binding && profile.instructionDigest == bundleDigest admission.instructions && processPolicyIdentity profile.policy == binding.policyRevision && hostIdentity (workspaceCoordinateText boot) && all (\target -> bounded (workspaceCoordinateText target) && Text.length (workspaceCoordinateText target) <= 128) [filesTarget, scratchTarget]) (Left FileEffectRefused)
  let coordinates =
        Aeson.object
          [ "binding" .= workspaceBindingDigest binding,
            "filePolicy" .= admission.filePolicy,
            "assignment" .= admission.assignmentId,
            "owner" .= admission.owner,
            "epoch" .= admission.epoch,
            "profile" .= profile,
            "boot" .= boot,
            "filesTarget" .= filesTarget,
            "scratchTarget" .= scratchTarget
          ]
      digest = Text.replace ":" "-" (versionedDigest (if admission.filePolicy == Just transferableFilePolicy then "shikigami.workspace-provision-action/2" else "shikigami.workspace-provision-action/1") coordinates)
      revision = (if admission.filePolicy == Just transferableFilePolicy then "3-" else "2-") <> Text.replace ":" "-" (workspaceCoordinateText (workspaceBindingDigest binding))
  either (const (Left FileEffectRefused)) (Right . InvokeCapabilityTool) (mkCapabilityToolTarget "shikigami.workspace" revision ("provision-" <> digest))

-- Digest every accepted coordinate into the closed C13 capability-tool target.
-- The concrete provider obtains target from an anchored parent descriptor and
-- obtains binding/admission/dispatch from retained state, never model arguments.
workspaceFileAction :: WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> Text -> WorkspaceCoordinate "relative-path" -> WorkspaceCoordinate "file-target" -> WorkspaceCoordinate "file-input" -> Either FileEffectError AgentAction
workspaceFileAction = workspaceFileActionFor False Nothing

-- The complete retained profile, including its reserved Unix identity, belongs
-- to the revision-2 authority target. Revision 1 keeps its original encoding.
workspaceSupervisedFileAction :: ProcessProfile -> WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> Text -> WorkspaceCoordinate "relative-path" -> WorkspaceCoordinate "file-target" -> WorkspaceCoordinate "file-input" -> Either FileEffectError AgentAction
workspaceSupervisedFileAction profile = workspaceFileActionFor False (Just profile)

workspaceTransferredFileAction :: ProcessProfile -> WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> Text -> WorkspaceCoordinate "relative-path" -> WorkspaceCoordinate "file-target" -> WorkspaceCoordinate "file-input" -> Either FileEffectError AgentAction
workspaceTransferredFileAction profile = workspaceFileActionFor True (Just profile)

workspaceFileActionFor :: Bool -> Maybe ProcessProfile -> WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> Text -> WorkspaceCoordinate "relative-path" -> WorkspaceCoordinate "file-target" -> WorkspaceCoordinate "file-input" -> Either FileEffectError AgentAction
workspaceFileActionFor transferable profile binding admission dispatch kind path target inputDigest = do
  unless (Text.all (< '\DEL') (workspaceCoordinateText path)) (Left FileEffectRefused)
  case profile of
    Nothing -> unless (not transferable && admission.filePolicy == Just nativeFilePolicy) (Left FileEffectRefused)
    Just retained -> unless (admission.filePolicy == Just (if transferable then transferableFilePolicy else supervisedFilePolicy) && validProcessProfile retained && retained.bindingDigest == workspaceBindingDigest binding && retained.instructionDigest == bundleDigest admission.instructions && processPolicyIdentity retained.policy == binding.policyRevision && processFileAllowed retained.policy kind path) (Left FileEffectRefused)
  unless (kind `elem` ["read", "replace"] && validWorkspacePath (workspaceCoordinateText path) && not (Text.null (workspaceCoordinateText target)) && Text.length (workspaceCoordinateText target) <= 128 && not (Text.null (workspaceCoordinateText inputDigest)) && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base && matchesWorkspaceAdmission binding admission && dispatch.generation > initialRevision) (Left FileEffectRefused)
  let coordinates =
        Aeson.object $
          [ "binding" .= workspaceBindingDigest binding,
            "instructions" .= bundleDigest admission.instructions,
            "filePolicy" .= admission.filePolicy,
            "assignment" .= admission.assignmentId,
            "owner" .= admission.owner,
            "epoch" .= admission.epoch,
            "operation" .= dispatch.operation,
            "attempt" .= dispatch.attemptId,
            "claimOwner" .= dispatch.owner,
            "generation" .= dispatch.generation,
            "kind" .= kind,
            "path" .= path,
            "target" .= target,
            "input" .= inputDigest
          ]
            <> maybe [] (\retained -> ["profile" .= retained]) profile
            <> ["run" .= admission.runId.unWorkflowId | transferable]
      digest = Text.replace ":" "-" (versionedDigest (if transferable then "shikigami.workspace-file-action/3" else if isJust profile then "shikigami.workspace-file-action/2" else "shikigami.workspace-file-action/1") coordinates)
      revision = (if transferable then "3-" else if isJust profile then "2-" else "1-") <> Text.replace ":" "-" (workspaceCoordinateText (workspaceBindingDigest binding))
  either (const (Left FileEffectRefused)) (Right . InvokeCapabilityTool) (mkCapabilityToolTarget "shikigami.workspace" revision (kind <> "-" <> digest))

-- A process launch grant binds the complete retained rule, immutable root
-- profile, original actual attempt and absolute deadline. The resolved cwd
-- identity and host boot are trusted supervisor observations, never model input.
-- Phase is deliberately excluded from the hash so fresh authorization may be
-- checked before and after committing the single launch transition.
workspaceProcessAction :: WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> ProcessRecord -> WorkspaceCoordinate "boot-id" -> WorkspaceCoordinate "file-target" -> Either FileEffectError AgentAction
workspaceProcessAction = workspaceProcessActionFor False

workspaceTransferredProcessAction :: WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> ProcessRecord -> WorkspaceCoordinate "boot-id" -> WorkspaceCoordinate "file-target" -> Either FileEffectError AgentAction
workspaceTransferredProcessAction = workspaceProcessActionFor True

workspaceProcessActionFor :: Bool -> WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> ProcessRecord -> WorkspaceCoordinate "boot-id" -> WorkspaceCoordinate "file-target" -> Either FileEffectError AgentAction
workspaceProcessActionFor transferable binding admission dispatch record boot target = do
  unless (admission.filePolicy == Just (if transferable then transferableFilePolicy else supervisedFilePolicy) && matchesWorkspaceAdmission binding admission && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base) (Left FileEffectRefused)
  unless (validProcessCommand record.command && record.phase `elem` [ProcessReserved, ProcessLaunchRequested] && record.operationId == dispatch.operation.operationId && record.attemptId == dispatch.attemptId && record.claimOwner == dispatch.owner && record.generation == dispatch.generation && dispatch.generation > initialRevision && record.bindingDigest == workspaceBindingDigest binding && record.instructionDigest == bundleDigest admission.instructions && record.fingerprint == processFingerprint binding record.instructionDigest dispatch.operation record.command && record.unit == processUnit record.operationId record.fingerprint && hostIdentity (workspaceCoordinateText boot) && maybe True (== boot) record.bootId && isNothing record.invocationId && isNothing record.receipt && bounded (workspaceCoordinateText target) && Text.length (workspaceCoordinateText target) <= 128) (Left FileEffectRefused)
  routing <- maybe (Left FileEffectRefused) Right record.routing
  unless (validProcessRouting routing && routing.executionId == dispatch.operation.executionId && routing.identity == admission.owner) (Left FileEffectRefused)
  let coordinates =
        Aeson.object $
          [ "binding" .= workspaceBindingDigest binding,
            "instructions" .= record.instructionDigest,
            "filePolicy" .= admission.filePolicy,
            "assignment" .= admission.assignmentId,
            "owner" .= admission.owner,
            "epoch" .= admission.epoch,
            "operation" .= dispatch.operation,
            "attempt" .= dispatch.attemptId,
            "claimOwner" .= dispatch.owner,
            "generation" .= dispatch.generation,
            "command" .= record.command,
            "fingerprint" .= record.fingerprint,
            "deadline" .= record.deadline,
            "routing" .= routing,
            "unit" .= record.unit,
            "boot" .= boot,
            "cwdTarget" .= target
          ]
            <> ["run" .= admission.runId.unWorkflowId | transferable]
      digest = Text.replace ":" "-" (versionedDigest (if transferable then "shikigami.workspace-process-action/2" else "shikigami.workspace-process-action/1") coordinates)
      revision = (if transferable then "2-" else "1-") <> Text.replace ":" "-" (workspaceCoordinateText (workspaceBindingDigest binding))
  either (const (Left FileEffectRefused)) (Right . InvokeCapabilityTool) (mkCapabilityToolTarget "shikigami.workspace" revision ("exec-" <> digest))

-- Prepare can capture admitted bytes and create immutable objects; publish
-- additionally binds the exact parent/tree/commit and every changed path.
-- Neither proof can be reused by another actual claim or Unix profile.
workspaceGitAction :: WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> ProcessProfile -> Git.GitRecord -> Either FileEffectError AgentAction
workspaceGitAction = workspaceGitActionFor False

workspaceTransferredGitAction :: WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> ProcessProfile -> Git.GitRecord -> Either FileEffectError AgentAction
workspaceTransferredGitAction = workspaceGitActionFor True

workspaceGitActionFor :: Bool -> WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> ProcessProfile -> Git.GitRecord -> Either FileEffectError AgentAction
workspaceGitActionFor transferable binding admission dispatch profile record = do
  unless (admission.filePolicy == Just (if transferable then transferableFilePolicy else supervisedFilePolicy) && matchesWorkspaceAdmission binding admission && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base) (Left FileEffectRefused)
  unless (validProcessProfile profile && profile.bindingDigest == workspaceBindingDigest binding && profile.instructionDigest == bundleDigest admission.instructions && processPolicyIdentity profile.policy == binding.policyRevision && workspaceCoordinate "" `elem` profile.policy.readPaths) (Left FileEffectRefused)
  unless (Git.validGitRecord record && record.phase `elem` [Git.GitReserved, Git.GitPrepared, Git.GitPublishRequested] && record.bindingDigest == workspaceBindingDigest binding && record.instructionDigest == bundleDigest admission.instructions && record.profileDigest == Git.gitProfileDigest profile && record.fingerprint == Git.gitFingerprint binding record && record.operation == dispatch.operation && record.attemptId == dispatch.attemptId && record.claimOwner == dispatch.owner && record.generation == dispatch.generation && record.routing.identity == admission.owner) (Left FileEffectRefused)
  forM_ record.candidate \candidate -> unless (all (processFileAllowed profile.policy "replace") candidate.paths) (Left FileEffectRefused)
  let coordinates = Aeson.object (["binding" .= workspaceBindingDigest binding, "instructions" .= bundleDigest admission.instructions, "filePolicy" .= admission.filePolicy, "assignment" .= admission.assignmentId, "owner" .= admission.owner, "epoch" .= admission.epoch, "profile" .= profile, "record" .= Git.gitActionIdentity record] <> ["run" .= admission.runId.unWorkflowId | transferable])
      digest = Text.replace ":" "-" (versionedDigest (if transferable then "shikigami.workspace-git-action/2" else "shikigami.workspace-git-action/1") coordinates)
      revision = (if transferable then "git2-" else "git1-") <> Text.replace ":" "-" (workspaceCoordinateText (workspaceBindingDigest binding))
  either (const (Left FileEffectRefused)) (Right . InvokeCapabilityTool) (mkCapabilityToolTarget "shikigami.workspace" revision ("commit-" <> digest))

workspaceGitObservationAction :: WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> ProcessProfile -> Text -> PayloadDigest -> WorkspaceCoordinate "file-target" -> Either FileEffectError AgentAction
workspaceGitObservationAction = workspaceGitObservationActionFor False

workspaceTransferredGitObservationAction :: WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> ProcessProfile -> Text -> PayloadDigest -> WorkspaceCoordinate "file-target" -> Either FileEffectError AgentAction
workspaceTransferredGitObservationAction = workspaceGitObservationActionFor True

workspaceGitObservationActionFor :: Bool -> WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> ProcessProfile -> Text -> PayloadDigest -> WorkspaceCoordinate "file-target" -> Either FileEffectError AgentAction
workspaceGitObservationActionFor transferable binding admission dispatch profile kind inputDigest target = do
  unless (admission.filePolicy == Just (if transferable then transferableFilePolicy else supervisedFilePolicy) && matchesWorkspaceAdmission binding admission && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base) (Left FileEffectRefused)
  unless (validProcessProfile profile && profile.bindingDigest == workspaceBindingDigest binding && profile.instructionDigest == bundleDigest admission.instructions && processPolicyIdentity profile.policy == binding.policyRevision && workspaceCoordinate "" `elem` profile.policy.readPaths && kind `elem` ["status", "diff"] && bounded (workspaceCoordinateText target) && Text.length (workspaceCoordinateText target) <= 128 && dispatch.generation > initialRevision) (Left FileEffectRefused)
  let coordinates = Aeson.object (["binding" .= workspaceBindingDigest binding, "instructions" .= bundleDigest admission.instructions, "filePolicy" .= admission.filePolicy, "assignment" .= admission.assignmentId, "owner" .= admission.owner, "epoch" .= admission.epoch, "profile" .= profile, "operation" .= dispatch.operation, "attempt" .= dispatch.attemptId, "claimOwner" .= dispatch.owner, "generation" .= dispatch.generation, "kind" .= kind, "input" .= inputDigest, "target" .= target] <> ["run" .= admission.runId.unWorkflowId | transferable])
      digest = Text.replace ":" "-" (versionedDigest (if transferable then "shikigami.workspace-git-observation/2" else "shikigami.workspace-git-observation/1") coordinates)
      revision = (if transferable then "git2-" else "git1-") <> Text.replace ":" "-" (workspaceCoordinateText (workspaceBindingDigest binding))
  either (const (Left FileEffectRefused)) (Right . InvokeCapabilityTool) (mkCapabilityToolTarget "shikigami.workspace" revision (kind <> "-" <> digest))

-- The exact source receipts are part of the grant, not caller-selected paths.
-- Reading artifacts grants no authority over their worktrees or HEADs.
workspaceIntegrationAction :: WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> ProcessProfile -> PayloadDigest -> WorkspaceCoordinate "file-target" -> [(WorkspaceBinding, Git.GitRecord)] -> Either FileEffectError AgentAction
workspaceIntegrationAction binding admission dispatch profile input target sources = do
  _ <- workspaceTransferredGitObservationAction binding admission dispatch profile "status" input target
  unless (length sources >= 2 && length sources <= 8 && length (nub (map (workspaceBindingDigest . fst) sources)) == length sources) (Left FileEffectRefused)
  forM_ sources \(source, record) -> do
    unless (source.workspace /= binding.workspace && source.repository == binding.repository && source.base == binding.base && source.request.rootId == admission.rootId && Git.validGitRecord record && record.bindingDigest == workspaceBindingDigest source && record.fingerprint == Git.gitFingerprint source record && record.phase == Git.GitApplied) (Left FileEffectRefused)
    candidate <- maybe (Left FileEffectRefused) Right record.candidate
    unless (candidate.parent == source.base) (Left FileEffectRefused)
  workspaceControlAction binding "integrate" (toJSON (admission, dispatch.operation, dispatch.attemptId, dispatch.owner, dispatch.generation, profile, input, target, sources))

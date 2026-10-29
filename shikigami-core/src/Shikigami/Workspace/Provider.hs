-- | Shared, protected file-effect contracts. None of these values is a permit.
module Shikigami.Workspace.Provider where

import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Kikan.En.Action (AgentAction (InvokeCapabilityTool), mkCapabilityToolTarget)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (AttemptId, OperationId)
import Shikigami.Execution.Runner (DispatchContext (..))
import Shikigami.Prelude
import Shikigami.Workspace.Instructions (WorkspaceAdmission (..), bundleBase, bundleDigest, bundleRepository, nativeFilePolicy, validWorkspacePath)
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

-- Digest every accepted coordinate into the closed C13 capability-tool target.
-- The concrete provider obtains target from an anchored parent descriptor and
-- obtains binding/admission/dispatch from retained state, never model arguments.
workspaceFileAction :: WorkspaceBinding -> WorkspaceAdmission -> DispatchContext -> Text -> Text -> Text -> Text -> Either FileEffectError AgentAction
workspaceFileAction binding admission dispatch kind path target inputDigest = do
  unless (admission.filePolicy == Just nativeFilePolicy && Text.all (< '\DEL') path) (Left FileEffectRefused)
  unless (kind `elem` ["read", "replace"] && validWorkspacePath path && not (Text.null target) && Text.length target <= 128 && not (Text.null inputDigest) && bundleRepository admission.instructions == binding.repository && bundleBase admission.instructions == binding.base && admission.workspace == binding.workspace && admission.bindingDigest == workspaceBindingDigest binding && admission.runId == binding.request.runId && admission.rootId == binding.request.rootId && admission.owner == binding.request.owner && admission.epoch == binding.request.epoch && dispatch.generation > 0 && not (Text.null dispatch.owner)) (Left FileEffectRefused)
  let coordinates =
        Aeson.object
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
      digest = Text.replace ":" "-" (versionedDigest "shikigami.workspace-file-action/1" coordinates)
      revision = "1-" <> Text.replace ":" "-" (workspaceBindingDigest binding)
  either (const (Left FileEffectRefused)) (Right . InvokeCapabilityTool) (mkCapabilityToolTarget "shikigami.workspace" revision (kind <> "-" <> digest))

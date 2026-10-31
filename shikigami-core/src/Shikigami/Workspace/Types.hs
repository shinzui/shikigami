{-# LANGUAGE DataKinds #-}

-- | Protected allocation metadata. These values are not workflow journal input
-- and confer no read, mutation, process or transfer authority.
module Shikigami.Workspace.Types
  ( WorkspaceId,
    parseWorkspaceId,
    workspaceIdFromUUID,
    workspaceIdText,
    newWorkspaceId,
    WorkspaceRequest (..),
    WorkspaceBinding (..),
    AllocationState (..),
    WorkspaceError (..),
    workspaceBindingDigest,
    matchesWorkspaceAdmission,
  )
where

import Data.Aeson (withText)
import Data.Bifunctor (first)
import Data.KindID.V7 qualified as KindID
import Data.Text qualified as Text
import Data.UUID (UUID)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Prelude
import Shikigami.StateRevision
import Shikigami.WorkerSession.Transfer (WorkspaceRef)
import Shikigami.WorkerSession.Types (AssignmentId, WorkerSessionId)
import Shikigami.Workspace.Instructions (WorkspaceAdmission (..), bundleBase, bundleRepository, transferableFilePolicy)

-- | The allocated workspace outlives its initial run/assignment and can retain
-- its physical locator through handoff. Its entity identity is separate.
newtype WorkspaceId = WorkspaceId (KindID.KindID "shikigami_workspace")
  deriving stock (Eq, Ord, Show)

parseWorkspaceId :: Text -> Either Text WorkspaceId
parseWorkspaceId input = do
  value <- first (const "invalid workspace ID encoding or prefix") (KindID.parseText @"shikigami_workspace" input)
  case KindID.checkKindID value of
    Just _ -> Left "workspace ID requires UUIDv7"
    Nothing
      | KindID.toText value == input -> Right (WorkspaceId value)
      | otherwise -> Left "workspace ID requires canonical encoding"

-- | Capture an allocator's UUID through the same version/variant contract.
workspaceIdFromUUID :: UUID -> Either Text WorkspaceId
workspaceIdFromUUID uuid =
  let value = KindID.decorateKindID @"shikigami_workspace" uuid
   in case KindID.checkKindID value of
        Just _ -> Left "workspace ID requires UUIDv7"
        Nothing -> Right (WorkspaceId value)

workspaceIdText :: WorkspaceId -> Text
workspaceIdText (WorkspaceId value) = KindID.toText value

newWorkspaceId :: IO WorkspaceId
newWorkspaceId = WorkspaceId <$> KindID.genKindID @"shikigami_workspace"

instance ToJSON WorkspaceId where
  toJSON = toJSON . workspaceIdText
  toEncoding = toEncoding . workspaceIdText

instance FromJSON WorkspaceId where
  parseJSON = withText "workspace ID" (either (fail . Text.unpack) pure . parseWorkspaceId)

data WorkspaceRequest = WorkspaceRequest
  { runId :: !Text,
    assignment :: !(Maybe (WorkerSessionId, AssignmentId)),
    rootId :: !ExecutionRootId,
    principal :: !AgentIdentity,
    owner :: !AgentIdentity,
    epoch :: !(StateRevision "worker-owner")
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show WorkspaceRequest where show _ = "WorkspaceRequest <protected>"

data WorkspaceBinding = WorkspaceBinding
  { id :: !WorkspaceId,
    request :: !WorkspaceRequest,
    workspace :: !WorkspaceRef,
    repository :: !Text,
    base :: !Text,
    policyRevision :: !Text,
    storageRoot :: !FilePath,
    source :: !FilePath
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show WorkspaceBinding where show _ = "WorkspaceBinding <protected>"

data AllocationState = Reserved | Ready
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data WorkspaceError = InvalidWorkspaceRequest | WorkspaceBindingConflict | WorkspaceMissing | WorkspaceAllocationRefused
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Protected snapshot correlation, distinct from an allocation completion marker.
workspaceBindingDigest :: WorkspaceBinding -> Text
workspaceBindingDigest = versionedDigest "shikigami.workspace-binding/1" . toJSON

-- Pure shape only. Successor authority additionally requires its exact retained
-- admission and current session/owner checks in TransferStore at the IO boundary.
matchesWorkspaceAdmission :: WorkspaceBinding -> WorkspaceAdmission -> Bool
matchesWorkspaceAdmission binding admission =
  admission.workspace == binding.workspace
    && admission.bindingDigest == workspaceBindingDigest binding
    && admission.rootId == binding.request.rootId
    && bundleRepository admission.instructions == binding.repository
    && bundleBase admission.instructions == binding.base
    && ( (admission.runId == binding.request.runId && admission.owner == binding.request.owner && admission.epoch == binding.request.epoch)
           || (admission.filePolicy == Just transferableFilePolicy && admission.epoch >= binding.request.epoch && (admission.epoch /= binding.request.epoch || admission.owner == binding.request.owner) && revisionNumber admission.epoch < 9223372036854775808 && admission.runId /= binding.request.runId && admission.runId /= "")
       )

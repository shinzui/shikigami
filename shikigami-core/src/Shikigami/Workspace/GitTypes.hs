{-# LANGUAGE DataKinds #-}

-- | Protected local-commit intent and factual recovery metadata. These values
-- grant no Git IO, filesystem access or accepted-attempt accounting authority.
module Shikigami.Workspace.GitTypes where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Bytes
import Data.List (nub, sort)
import Data.Text qualified as Text
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Claim
import Shikigami.Execution.Identity (AttemptId, OperationId, attemptIdText, operationIdText)
import Shikigami.Execution.Payload (PayloadDigest)
import Shikigami.Execution.Runner (OperationContext (..))
import Shikigami.Execution.ToolPosition
import Shikigami.Execution.Transcript (ExecutionId (..), NextWork (..))
import Shikigami.Prelude
import Shikigami.StateRevision
import Shikigami.Workspace.Instructions (validWorkspacePath)
import Shikigami.Workspace.Process (bounded, digestText)
import Shikigami.Workspace.ProcessPolicy (ProcessProfile)
import Shikigami.Workspace.Types (WorkspaceBinding, workspaceBindingDigest)

data GitCommitRequest = GitCommitRequest {expectedParent :: !Text, message :: !Text}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance Show GitCommitRequest where show _ = "GitCommitRequest <protected>"

instance FromJSON GitCommitRequest where
  parseJSON = Aeson.genericParseJSON Aeson.defaultOptions {Aeson.rejectUnknownFields = True}

data GitCandidate = GitCandidate {parent :: !Text, tree :: !Text, result :: !Text, paths :: ![Text]}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show GitCandidate where show _ = "GitCandidate <protected>"

data GitPhase = GitReserved | GitPrepared | GitPublishRequested | GitApplied | GitRefused | GitUnresolved
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data GitRouting = GitRouting {executionId :: !ExecutionId, identity :: !AgentIdentity, inputDigest :: !PayloadDigest, next :: !NextWork}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show GitRouting where show _ = "GitRouting <protected>"

data GitRecord = GitRecord
  { format :: !Int,
    operation :: !OperationContext,
    attemptId :: !AttemptId,
    claimOwner :: !ClaimOwner,
    generation :: !(StateRevision "execution-attempt"),
    bindingDigest :: !Text,
    instructionDigest :: !Text,
    profileDigest :: !Text,
    target :: !Text,
    expectedParent :: !Text,
    fingerprint :: !Text,
    createdAt :: !UTCTime,
    routing :: !GitRouting,
    phase :: !GitPhase,
    candidate :: !(Maybe GitCandidate)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show GitRecord where show _ = "GitRecord <protected>"

validGitObject :: Text -> Bool
validGitObject value = Text.length value `elem` [40, 64] && Text.all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') value

validGitCandidate :: GitCandidate -> Bool
validGitCandidate value = all validGitObject [value.parent, value.tree, value.result] && value.result /= value.parent && not (null value.paths) && length value.paths <= 256 && sort (nub value.paths) == value.paths && all (\path -> validWorkspacePath path && Text.all (< '\DEL') path) value.paths

validGitRecord :: GitRecord -> Bool
validGitRecord record = record.format == 1 && bounded operation && bounded execution && bounded attempt && record.operation.idempotencyKey == operation && digestText record.operation.fingerprint && digestText record.operation.scopeDigest && record.generation > initialRevision && all digestText [record.bindingDigest, record.instructionDigest, record.profileDigest, record.fingerprint] && bounded record.target && Text.length record.target <= 128 && validGitObject record.expectedParent && record.routing.executionId == record.operation.executionId && validRouting && validPhase && Bytes.length (Aeson.encode record) <= 65536
  where
    operation = operationIdText record.operation.operationId
    ExecutionId execution = record.operation.executionId
    attempt = attemptIdText record.attemptId
    validRouting = either (const False) bounded (identityText record.routing.identity) && validNext record.routing.next && Bytes.length (Aeson.encode record.routing) <= 4096
    validNext NeedModel = True
    validNext (NeedTool _ position) = position > firstToolPosition
    validNext _ = False
    validCandidate value = validGitCandidate value && value.parent == record.expectedParent
    validPhase = case record.phase of
      GitReserved -> isNothing record.candidate
      GitRefused -> maybe True validCandidate record.candidate
      _ -> maybe False validCandidate record.candidate

-- Actual claims remain independent of logical identity. Duplicate delivery
-- observes the original record; it never rewrites its attempt or creation time.
gitFingerprint :: WorkspaceBinding -> GitRecord -> Text
gitFingerprint binding record = versionedDigest "shikigami.workspace-git-effect/1" (toJSON (workspaceBindingDigest binding, record.instructionDigest, record.profileDigest, record.operation, record.target, record.expectedParent, record.routing))

gitProfileDigest :: ProcessProfile -> Text
gitProfileDigest = versionedDigest "shikigami.workspace-git-profile/1" . toJSON

-- Publication's phase transition consumes a grant, without changing the exact
-- proposed effect. Every other retained coordinate belongs to fresh authority.
gitActionIdentity :: GitRecord -> Text
gitActionIdentity record = versionedDigest "shikigami.workspace-git-authority-record/1" (case toJSON record of Aeson.Object fields -> Aeson.Object (KeyMap.delete "phase" fields); value -> value)

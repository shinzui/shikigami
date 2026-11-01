{-# LANGUAGE DataKinds #-}

-- | Protected process-owner contracts. Commands come from an immutable
-- operator rule; neither a model nor a queue delivery chooses executables.
module Shikigami.Workspace.Process where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Bytes
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Shikigami.Agent.Principal (AgentIdentity, identityText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Claim
import Shikigami.Execution.Identity (AttemptId, OperationId)
import Shikigami.Execution.Payload (PayloadDigest)
import Shikigami.Execution.Runner (OperationContext)
import Shikigami.Execution.ToolPosition
import Shikigami.Execution.Transcript (ExecutionId (..), NextWork (..))
import Shikigami.Prelude
import Shikigami.StateRevision
import Shikigami.Workspace.Instructions (validWorkspacePath)
import Shikigami.Workspace.Types
import Shikigami.Workspace.Value

data ProcessCommand = ProcessCommand
  { rule :: !(WorkspaceCoordinate "process-rule"),
    profile :: !(WorkspaceCoordinate "process-profile"),
    executable :: !(WorkspaceCoordinate "process-executable"),
    arguments :: !([WorkspaceCoordinate "argument"]),
    directory :: !(WorkspaceCoordinate "path-prefix"),
    environment :: !(Map.Map (WorkspaceCoordinate "environment-name") (WorkspaceCoordinate "environment-value")),
    timeoutSeconds :: !(ProcessSeconds),
    outputBytes :: !(ProcessOutputBytes)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ProcessCommand where show _ = "ProcessCommand <protected>"

data ProcessPhase = ProcessReserved | ProcessLaunchRequested | ProcessRunning | ProcessSettled | ProcessRefused | ProcessUnresolved
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ProcessTermination = ProcessExited | ProcessTimedOut | ProcessCancelled
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Identifiers name provider-private output artifacts, never model-selected paths.
data CapturedOutput = CapturedOutput
  {artifact :: !(WorkspaceCoordinate "output-artifact"), digest :: !(WorkspaceCoordinate "output-digest"), bytes :: !(CapturedBytes), truncated :: !(OutputTruncation)}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show CapturedOutput where show _ = "CapturedOutput <protected>"

data ProcessReceipt = ProcessReceipt
  { operationId :: !OperationId,
    attemptId :: !AttemptId,
    generation :: !(StateRevision "execution-attempt"),
    fingerprint :: !(WorkspaceCoordinate "process-fingerprint"),
    bindingDigest :: !(WorkspaceCoordinate "binding-digest"),
    unit :: !(WorkspaceCoordinate "process-unit"),
    bootId :: !(WorkspaceCoordinate "boot-id"),
    invocationId :: !(WorkspaceCoordinate "invocation-id"),
    -- systemd can retain a timeout/cancellation outcome without a numeric wait
    -- status. Preserve that absence; never manufacture a signal exit code.
    exitCode :: !(Maybe (ProcessExitStatus)),
    termination :: !ProcessTermination,
    stdout :: !CapturedOutput,
    stderr :: !CapturedOutput,
    descendantsEmpty :: !(DescendantSettlement),
    outputComplete :: !(OutputCompleteness)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ProcessReceipt where show _ = "ProcessReceipt <protected>"

-- Retain only accepted routing coordinates while replay access is live. A
-- restarted factual owner must not reread model bodies after revocation merely
-- to acknowledge the original attempt's independently retained receipt.
data ProcessRoutingFormat = ProcessRoutingV1
  deriving stock (Eq, Show)

instance ToJSON ProcessRoutingFormat where
  toJSON ProcessRoutingV1 = toJSON (1 :: Int)
  toEncoding ProcessRoutingV1 = toEncoding (1 :: Int)

instance FromJSON ProcessRoutingFormat where
  parseJSON value = do
    number <- parseJSON @Int value
    if number == 1 then pure ProcessRoutingV1 else fail "unsupported process routing format"

data ProcessRouting = ProcessRouting
  { format :: !ProcessRoutingFormat,
    executionId :: !ExecutionId,
    identity :: !AgentIdentity,
    inputDigest :: !PayloadDigest,
    next :: !NextWork
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ProcessRouting where show _ = "ProcessRouting <protected>"

validProcessRouting :: ProcessRouting -> Bool
validProcessRouting routing = bounded routing.executionId.value && either (const False) bounded (identityText routing.identity) && validNext routing.next && Bytes.length (Aeson.encode routing) <= 4096
  where
    validNext NeedModel = True
    validNext (NeedTool _ position) = position > firstToolPosition
    validNext _ = False

data ProcessRecord = ProcessRecord
  { operationId :: !OperationId,
    attemptId :: !AttemptId,
    claimOwner :: !ClaimOwner,
    generation :: !(StateRevision "execution-attempt"),
    bindingDigest :: !(WorkspaceCoordinate "binding-digest"),
    instructionDigest :: !(WorkspaceCoordinate "instructions-digest"),
    fingerprint :: !(WorkspaceCoordinate "process-fingerprint"),
    command :: !ProcessCommand,
    deadline :: !UTCTime,
    unit :: !(WorkspaceCoordinate "process-unit"),
    bootId :: !(Maybe (WorkspaceCoordinate "boot-id")),
    invocationId :: !(Maybe (WorkspaceCoordinate "invocation-id")),
    phase :: !ProcessPhase,
    receipt :: !(Maybe ProcessReceipt),
    routing :: !(Maybe ProcessRouting)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON)

-- Preserve historical JSON, including its existing explicit null fields.
instance ToJSON ProcessRecord where
  toJSON record = case Aeson.genericToJSON Aeson.defaultOptions record of
    Aeson.Object fields | isNothing record.routing -> Aeson.Object (KeyMap.delete "routing" fields)
    value -> value

instance Show ProcessRecord where show _ = "ProcessRecord <protected>"

processFingerprint :: WorkspaceBinding -> WorkspaceCoordinate "instructions-digest" -> OperationContext -> ProcessCommand -> WorkspaceCoordinate "process-fingerprint"
processFingerprint binding instructions operation command = workspaceCoordinate (versionedDigest "shikigami.workspace-process/1" (toJSON (workspaceBindingDigest binding, instructions, operation, command)))

processUnit :: OperationId -> WorkspaceCoordinate "process-fingerprint" -> WorkspaceCoordinate "process-unit"
processUnit operation fingerprint = workspaceCoordinate ("shikigami-workspace-" <> Text.drop 7 (versionedDigest "shikigami.workspace-unit/1" (toJSON (operation, fingerprint))) <> ".service")

validProcessCommand :: ProcessCommand -> Bool
validProcessCommand command = bounded (workspaceCoordinateText command.rule) && digestText (workspaceCoordinateText command.profile) && Text.isPrefixOf "/" (workspaceCoordinateText command.executable) && asciiPath (Text.drop 1 (workspaceCoordinateText command.executable)) && (Text.null (workspaceCoordinateText command.directory) || asciiPath (workspaceCoordinateText command.directory)) && length (map workspaceCoordinateText command.arguments) <= 64 && all (not . Text.any (== '\0')) (map workspaceCoordinateText command.arguments) && (map workspaceCoordinateText (Map.keys command.environment)) `isSubset` ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"] && all (not . Text.any (== '\0')) (map workspaceCoordinateText (Map.elems command.environment)) && (processSecondsNumber command.timeoutSeconds) >= 1 && (processSecondsNumber command.timeoutSeconds) <= 3600 && (processOutputBytesNumber command.outputBytes) >= 1 && (processOutputBytesNumber command.outputBytes) <= 1048576 && Bytes.length (Aeson.encode command) <= 65536
  where
    asciiPath path = validWorkspacePath path && Text.all (< '\DEL') path
    isSubset keys allowed = all (`elem` allowed) keys

digestText :: Text -> Bool
digestText value = Text.length value == 71 && "sha256:" `Text.isPrefixOf` value && Text.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) (Text.drop 7 value)

bounded :: Text -> Bool
bounded value = not (Text.null value) && Text.length value <= 256 && not (Text.any (< ' ') value)

hostIdentity :: Text -> Bool
hostIdentity value = maybe False (/= UUID.nil) (UUID.fromText value) || (Text.length value == 32 && Text.any (/= '0') value && Text.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) value)

validProcessReceipt :: ProcessRecord -> ProcessReceipt -> Bool
validProcessReceipt record receipt = receipt.operationId == record.operationId && receipt.attemptId == record.attemptId && receipt.generation == record.generation && receipt.fingerprint == record.fingerprint && receipt.bindingDigest == record.bindingDigest && receipt.unit == record.unit && Just receipt.bootId == record.bootId && Just receipt.invocationId == record.invocationId && hostIdentity (workspaceCoordinateText receipt.bootId) && hostIdentity (workspaceCoordinateText receipt.invocationId) && (descendantsSettled receipt.descendantsEmpty) && (outputCollected receipt.outputComplete) && validExit && all validOutput [receipt.stdout, receipt.stderr] && capturedBytesNumber receipt.stdout.bytes + capturedBytesNumber receipt.stderr.bytes <= toInteger (processOutputBytesNumber record.command.outputBytes)
  where
    validExit = maybe (receipt.termination /= ProcessExited) (\code -> processExitStatusNumber code >= 0 && processExitStatusNumber code <= 255) receipt.exitCode
    validOutput output = bounded (workspaceCoordinateText output.artifact) && (workspaceCoordinateText output.artifact) `notElem` [".", ".."] && Text.all (\c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c `elem` ("._-" :: String)) (workspaceCoordinateText output.artifact) && digestText (workspaceCoordinateText output.digest) && capturedBytesNumber output.bytes >= 0

processSucceeded :: ProcessReceipt -> Bool
processSucceeded receipt = receipt.termination == ProcessExited && fmap processExitStatusNumber receipt.exitCode == Just 0 && (descendantsSettled receipt.descendantsEmpty) && (outputCollected receipt.outputComplete)

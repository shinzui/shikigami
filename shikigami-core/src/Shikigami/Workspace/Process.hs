-- | Protected process-owner contracts. Commands come from an immutable
-- operator rule; neither a model nor a queue delivery chooses executables.
module Shikigami.Workspace.Process where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Bytes
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Identity (AttemptId, OperationId)
import Shikigami.Execution.Runner (OperationContext)
import Shikigami.Prelude
import Shikigami.Workspace.Instructions (validWorkspacePath)
import Shikigami.Workspace.Types

data ProcessCommand = ProcessCommand
  { rule :: !Text,
    profile :: !Text,
    executable :: !Text,
    arguments :: ![Text],
    directory :: !Text,
    environment :: !(Map.Map Text Text),
    timeoutSeconds :: !Int,
    outputBytes :: !Int
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
  {artifact :: !Text, digest :: !Text, bytes :: !Integer, truncated :: !Bool}
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show CapturedOutput where show _ = "CapturedOutput <protected>"

data ProcessReceipt = ProcessReceipt
  { operationId :: !OperationId,
    attemptId :: !AttemptId,
    generation :: !Integer,
    fingerprint :: !Text,
    bindingDigest :: !Text,
    unit :: !Text,
    bootId :: !Text,
    invocationId :: !Text,
    -- systemd can retain a timeout/cancellation outcome without a numeric wait
    -- status. Preserve that absence; never manufacture a signal exit code.
    exitCode :: !(Maybe Int),
    termination :: !ProcessTermination,
    stdout :: !CapturedOutput,
    stderr :: !CapturedOutput,
    descendantsEmpty :: !Bool,
    outputComplete :: !Bool
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ProcessReceipt where show _ = "ProcessReceipt <protected>"

data ProcessRecord = ProcessRecord
  { operationId :: !OperationId,
    attemptId :: !AttemptId,
    claimOwner :: !Text,
    generation :: !Integer,
    bindingDigest :: !Text,
    instructionDigest :: !Text,
    fingerprint :: !Text,
    command :: !ProcessCommand,
    deadline :: !UTCTime,
    unit :: !Text,
    bootId :: !(Maybe Text),
    invocationId :: !(Maybe Text),
    phase :: !ProcessPhase,
    receipt :: !(Maybe ProcessReceipt)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ProcessRecord where show _ = "ProcessRecord <protected>"

processFingerprint :: WorkspaceBinding -> Text -> OperationContext -> ProcessCommand -> Text
processFingerprint binding instructions operation command = versionedDigest "shikigami.workspace-process/1" (toJSON (workspaceBindingDigest binding, instructions, operation, command))

processUnit :: OperationId -> Text -> Text
processUnit operation fingerprint = "shikigami-workspace-" <> Text.drop 7 (versionedDigest "shikigami.workspace-unit/1" (toJSON (operation, fingerprint))) <> ".service"

validProcessCommand :: ProcessCommand -> Bool
validProcessCommand command = bounded command.rule && digestText command.profile && Text.isPrefixOf "/" command.executable && asciiPath (Text.drop 1 command.executable) && (Text.null command.directory || asciiPath command.directory) && length command.arguments <= 64 && all (not . Text.any (== '\0')) command.arguments && Map.keysSet command.environment `isSubset` ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"] && all (not . Text.any (== '\0')) (Map.elems command.environment) && command.timeoutSeconds >= 1 && command.timeoutSeconds <= 3600 && command.outputBytes >= 1 && command.outputBytes <= 1048576 && Bytes.length (Aeson.encode command) <= 65536
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
validProcessReceipt record receipt = receipt.operationId == record.operationId && receipt.attemptId == record.attemptId && receipt.generation == record.generation && receipt.fingerprint == record.fingerprint && receipt.bindingDigest == record.bindingDigest && receipt.unit == record.unit && Just receipt.bootId == record.bootId && Just receipt.invocationId == record.invocationId && hostIdentity receipt.bootId && hostIdentity receipt.invocationId && receipt.descendantsEmpty && receipt.outputComplete && validExit && all validOutput [receipt.stdout, receipt.stderr] && receipt.stdout.bytes + receipt.stderr.bytes <= toInteger record.command.outputBytes
  where
    validExit = maybe (receipt.termination /= ProcessExited) (\code -> code >= 0 && code <= 255) receipt.exitCode
    validOutput output = bounded output.artifact && output.artifact `notElem` [".", ".."] && Text.all (\c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c `elem` ("._-" :: String)) output.artifact && digestText output.digest && output.bytes >= 0

processSucceeded :: ProcessReceipt -> Bool
processSucceeded receipt = receipt.termination == ProcessExited && receipt.exitCode == Just 0 && receipt.descendantsEmpty && receipt.outputComplete

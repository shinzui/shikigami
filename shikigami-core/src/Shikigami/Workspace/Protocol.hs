{-# LANGUAGE DataKinds #-}

-- | One retained wire contract shared by supervisor and administrative clients.
module Shikigami.Workspace.Protocol where

import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text qualified as Text
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Execution.Claim (ClaimOwner)
import Shikigami.Execution.Identity (AttemptId, OperationId, attemptIdText, operationIdText)
import Shikigami.Execution.Transcript (ExecutionId)
import Shikigami.Prelude hiding ((.=))
import Shikigami.StateRevision
import Shikigami.WorkerSession.Transfer
import Shikigami.WorkerSession.Types (WorkerSessionId)
import Shikigami.Workspace.Process
import Shikigami.Workspace.Value

data SupervisorError = SupervisorRefused | SupervisorUnavailable | SupervisorUnresolved | SupervisorUnsupported
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SupervisorRequest = SupervisorRequest
  { executionId :: !ExecutionId,
    operationId :: !OperationId,
    attemptId :: !AttemptId,
    owner :: !ClaimOwner,
    generation :: !(StateRevision "execution-attempt")
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON)

instance FromJSON SupervisorRequest where
  parseJSON = Aeson.withObject "supervisor request" \fields -> do
    unless (length fields == 5 && all (`KeyMap.member` fields) ["executionId", "operationId", "attemptId", "owner", "generation"]) (fail "unsupported supervisor request")
    Aeson.genericParseJSON Aeson.defaultOptions (Aeson.Object fields)

instance Show SupervisorRequest where show _ = "SupervisorRequest <protected>"

data RpcError = RpcRefused | RpcUnavailable | RpcMalformed | RpcPeerDenied | RpcTimeout | RpcUnsupported
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data RpcRequest = RpcLaunch !SupervisorRequest | RpcObserve !OperationId | RpcFence !TransferIntent | RpcAdmitWrite !WorkspaceRef !WorkerSessionId !AgentIdentity !(StateRevision "worker-owner") !OperationId
  deriving stock (Eq)

instance Show RpcRequest where show _ = "RpcRequest <protected>"

data ProcessView = ProcessView
  { operationId :: !OperationId,
    attemptId :: !AttemptId,
    generation :: !(StateRevision "execution-attempt"),
    bindingDigest :: !(WorkspaceCoordinate "binding-digest"),
    phase :: !ProcessPhase,
    receipt :: !(Maybe ProcessReceipt)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ProcessView where show _ = "ProcessView <protected>"

-- An error carries no no-launch/completion proof.
data RpcReply = RpcFailure !SupervisorError | RpcView !ProcessView | RpcFenceResult !FenceOutcome | RpcWriteResult !Bool
  deriving stock (Eq)

instance Show RpcReply where show _ = "RpcReply <protected>"

instance ToJSON RpcRequest where
  toJSON request = case request of
    RpcLaunch value -> Aeson.object ["format" .= (1 :: Int), "action" .= ("launch" :: Text), "request" .= value]
    RpcObserve value -> Aeson.object ["format" .= (1 :: Int), "action" .= ("observe" :: Text), "operationId" .= value]
    RpcFence value -> Aeson.object ["format" .= (2 :: Int), "action" .= ("fence" :: Text), "intent" .= value]
    RpcAdmitWrite workspace session owner epoch operation -> Aeson.object ["format" .= (2 :: Int), "action" .= ("admitWrite" :: Text), "workspace" .= workspace, "sessionId" .= session, "owner" .= owner, "epoch" .= epoch, "operationId" .= operation]

instance FromJSON RpcRequest where
  parseJSON = Aeson.withObject "workspace request" \fields -> do
    format <- fields .: "format"
    action <- fields .: "action"
    case (format :: Int, action :: Text) of
      (1, "launch") | keys fields ["format", "action", "request"] -> RpcLaunch <$> fields .: "request"
      (1, "observe") | keys fields ["format", "action", "operationId"] -> do
        operation <- fields .: "operationId"
        let value = operationIdText operation
        unless (bounded value) (fail "invalid operation")
        pure (RpcObserve operation)
      (2, "fence") | keys fields ["format", "action", "intent"] -> RpcFence <$> fields .: "intent"
      (2, "admitWrite") | keys fields ["format", "action", "workspace", "sessionId", "owner", "epoch", "operationId"] -> RpcAdmitWrite <$> fields .: "workspace" <*> fields .: "sessionId" <*> fields .: "owner" <*> fields .: "epoch" <*> fields .: "operationId"
      _ -> fail "unsupported request"

instance ToJSON RpcReply where
  toJSON reply = case reply of
    RpcFailure err -> Aeson.object ["format" .= (1 :: Int), "error" .= err]
    RpcView value -> Aeson.object ["format" .= (1 :: Int), "view" .= value]
    RpcFenceResult value -> Aeson.object ["format" .= (2 :: Int), "fence" .= value]
    RpcWriteResult value -> Aeson.object ["format" .= (2 :: Int), "admitted" .= value]

instance FromJSON RpcReply where
  parseJSON = Aeson.withObject "workspace reply" \fields -> do
    format <- fields .: "format"
    case (format :: Int) of
      1 | keys fields ["format", "error"] -> RpcFailure <$> fields .: "error"
      1 | keys fields ["format", "view"] -> RpcView <$> fields .: "view"
      2 | keys fields ["format", "fence"] -> RpcFenceResult <$> fields .: "fence"
      2 | keys fields ["format", "admitted"] -> RpcWriteResult <$> fields .: "admitted"
      _ -> fail "unsupported reply"

keys :: Aeson.Object -> [Key] -> Bool
keys fields expected = length fields == length expected && all (`KeyMap.member` fields) expected

requestOperation :: RpcRequest -> OperationId
requestOperation (RpcLaunch request) = request.operationId
requestOperation (RpcObserve operation) = operation
requestOperation (RpcFence intent) = intent.operationId
requestOperation (RpcAdmitWrite _ _ _ _ operation) = operation

validView :: ProcessView -> Bool
validView value =
  bounded operation && bounded attempt && value.generation > initialRevision && revisionNumber value.generation < 9223372036854775808 && digestText (workspaceCoordinateText value.bindingDigest) && case value.receipt of
    Nothing -> value.phase /= ProcessSettled
    Just receipt -> value.phase == ProcessSettled && receipt.operationId == value.operationId && receipt.attemptId == value.attemptId && receipt.generation == value.generation && receipt.bindingDigest == value.bindingDigest && digestText (workspaceCoordinateText receipt.fingerprint) && receipt.unit == processUnit value.operationId receipt.fingerprint && hostIdentity (workspaceCoordinateText receipt.bootId) && hostIdentity (workspaceCoordinateText receipt.invocationId) && descendantsSettled receipt.descendantsEmpty && outputCollected receipt.outputComplete && maybe (receipt.termination /= ProcessExited) (\code -> processExitStatusNumber code >= 0 && processExitStatusNumber code <= 255) receipt.exitCode && all validOutput [receipt.stdout, receipt.stderr] && capturedBytesNumber receipt.stdout.bytes + capturedBytesNumber receipt.stderr.bytes <= 1048576
  where
    operation = operationIdText value.operationId
    attempt = attemptIdText value.attemptId
    validOutput output = bounded (workspaceCoordinateText output.artifact) && workspaceCoordinateText output.artifact `notElem` [".", ".."] && Text.all (\c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c `elem` ("._-" :: String)) (workspaceCoordinateText output.artifact) && digestText (workspaceCoordinateText output.digest) && capturedBytesNumber output.bytes >= 0

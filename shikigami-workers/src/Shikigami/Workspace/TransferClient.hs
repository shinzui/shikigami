-- | Peer-checked client for the independent workspace fencing owner. This is
-- the workspace half of session transfer services; objective ownership remains
-- a separately supplied provider.
module Shikigami.Workspace.TransferClient (workspaceTransferClient) where

import Shikigami.Prelude
import Shikigami.WorkerSession.Transfer
import Shikigami.Workspace.ProcessProvider (ProcessClient (..))
import Shikigami.Workspace.Rpc

workspaceTransferClient :: ProcessClient -> WorkspaceProvider
workspaceTransferClient client =
  WorkspaceProvider
    (\intent -> call (RpcFence intent) <&> \case Right (RpcFenceResult outcome) -> outcome; _ -> FenceUnavailable)
    (\workspace session owner epoch operation -> call (RpcAdmitWrite workspace session owner epoch operation) <&> \case Right (RpcWriteResult True) -> Right (); _ -> Left "workspace write admission refused")
  where
    call = callRpc client.socketPath client.serverUser client.requestSeconds

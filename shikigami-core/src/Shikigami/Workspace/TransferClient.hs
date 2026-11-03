-- | Peer-checked client for the independent workspace fencing owner. This is
-- the workspace half of session transfer services; objective ownership remains
-- a separately supplied provider.
module Shikigami.Workspace.TransferClient (workspaceTransferClient, configuredWorkspaceTransfers) where

import Shikigami.Prelude
import Shikigami.WorkerSession.Transfer
import Shikigami.Workspace.Protocol
import Shikigami.Workspace.RpcClient
import Shikigami.Workspace.Settings (WorkspaceProcessSettings (..), WorkspaceSettings (..))

workspaceTransferClient :: ProcessClient -> WorkspaceProvider
workspaceTransferClient client =
  WorkspaceProvider
    (\intent -> call (RpcFence intent) <&> \case Right (RpcFenceResult outcome) -> outcome; _ -> FenceUnavailable)
    (\workspace session owner epoch operation -> call (RpcAdmitWrite workspace session owner epoch operation) <&> \case Right (RpcWriteResult True) -> Right (); _ -> Left "workspace write admission refused")
  where
    call = callRpc client.socketPath client.serverUser client.requestSeconds

-- File-only configuration supplies no process fence. Both roles select the
-- same trusted endpoint, peer identity and request bound from validated settings.
configuredWorkspaceTransfers :: WorkspaceSettings -> Maybe WorkspaceProvider
configuredWorkspaceTransfers settings = do
  process <- settings.process
  pure (workspaceTransferClient (ProcessClient process.socketPath process.serverUser process.requestSeconds process.waitSeconds))

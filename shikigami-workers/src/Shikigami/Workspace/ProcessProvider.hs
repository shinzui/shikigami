-- | Client for the independently supervised process owner. Installation is
-- gated on Linux qualification; description/preparation perform no socket IO.
module Shikigami.Workspace.ProcessProvider (ProcessClient (..), workspaceExecAdapter) where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Data.Aeson qualified as Aeson
import Effectful.Dispatch.Static (unsafeEff_)
import Shikigami.Capability.Provider (DurableAdapter (..), DurableToolContract (..))
import Shikigami.Execution.Policy.Types (RecoveryClass (UncertainEffect), ToolInvoiceCost (NoInvoiceCost))
import Shikigami.Execution.Runner (DispatchContext (..), OperationContext (..))
import Shikigami.Execution.Transcript (ExecutionSnapshot (..))
import Shikigami.Prelude
import Shikigami.Workspace.Instructions (WorkspaceAdmission (..), supervisedFilePolicy)
import Shikigami.Workspace.Rpc
import Shikigami.Workspace.Supervisor
import Shikumi.Tool (mkDynTool)
import System.Timeout (timeout)

-- Trusted endpoint, kernel server identity and bounded caller waiting policy.
-- None of these values is a tool argument or grants command authority.
data ProcessClient = ProcessClient
  { socketPath :: !FilePath,
    serverUser :: !Integer,
    requestSeconds :: !Int,
    waitSeconds :: !Int
  }

workspaceExecAdapter :: ProcessClient -> DurableAdapter
workspaceExecAdapter client = DurableAdapter
  workspaceExecDescriptor
  [DurableToolContract "validate" "Validate one reviewed rule." workspaceExecSchema UncertainEffect NoInvoiceCost]
  \snapshot dispatch name -> pure $
    Right $
      mkDynTool name "Validate one reviewed rule." workspaceExecSchema \(_input :: Aeson.Value) -> unsafeEff_ do
        -- The server reads the accepted arguments from its store. A caller can
        -- supply only the retained actual-attempt coordinates, never argv.
        unless (name == "validate" && dispatch.operation.executionId == snapshot.executionId && maybe False ((== Just supervisedFilePolicy) . (.filePolicy)) snapshot.workspace && workspaceExecBinding `elem` snapshot.toolBindings && client.waitSeconds >= 1 && client.waitSeconds <= 3600) uncertain
        let actual = SupervisorRequest snapshot.executionId dispatch.operation.operationId dispatch.attemptId dispatch.owner dispatch.generation
            call = callRpc client.socketPath client.serverUser client.requestSeconds
            consume result = case result of
              Right (RpcView value) | value.attemptId == actual.attemptId && value.generation == actual.generation && maybe False ((== value.bindingDigest) . (.bindingDigest)) snapshot.workspace ->
                case processViewResult value of
                  Just output -> pure output
                  Nothing -> do
                    threadDelay 250000
                    consume =<< call (RpcObserve actual.operationId)
              _ -> uncertain
        result <- timeout (client.waitSeconds * 1000000) (consume =<< call (RpcLaunch actual))
        maybe uncertain pure result
  where
    -- A failed connection or a supervisor error is never a no-launch proof.
    -- Throw so the executor keeps this actual uncertain-effect reservation.
    uncertain :: IO a
    uncertain = throwIO (userError "workspace process requires independent reconciliation")

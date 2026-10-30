-- | The independent receipt owner and peer-checked intake share a supervised
-- lifetime, separate from every queue worker. Factual scans never launch.
module Shikigami.Workspace.Service (ProcessScan (..), GitScan (..), scanProcessReceipts, scanGitReceipts, serveSupervisor) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Data.Maybe (listToMaybe)
import Kioku.App (AppEnv, runAppIO)
import Kiroku.Store.Transaction (runTransaction)
import Network.Socket qualified as Socket
import Shikigami.Execution.Identity (OperationId)
import Shikigami.Prelude
import Shikigami.Workspace.GitProvider (GitPublication (..), publishGitReceipt)
import Shikigami.Workspace.GitStore (inspectGitPageTx)
import Shikigami.Workspace.ProcessStore (inspectProcessPageTx)
import Shikigami.Workspace.Provider (FileEffectError (..))
import Shikigami.Workspace.Rpc
import Shikigami.Workspace.Supervisor
import System.Timeout (timeout)

data ProcessScan = ProcessScan
  {cursor :: !(Maybe OperationId), inspected :: !Int, acknowledged :: !Int, pending :: !Int}
  deriving stock (Eq, Generic)

data GitScan = GitScan {cursor :: !(Maybe OperationId), inspected :: !Int, acknowledged :: !Int, pending :: !Int}
  deriving stock (Eq, Generic)

scanGitReceipts :: AppEnv -> Maybe OperationId -> IO (Either FileEffectError GitScan)
scanGitReceipts env cursor = do
  page <- runAppIO env (runTransaction (inspectGitPageTx cursor))
  case page of
    Left _ -> pure (Left FileEffectUnavailable)
    Right operations -> do
      results <- forM operations \operation -> timeout 5000000 (publishGitReceipt env operation)
      let complete = length (filter (== Just (Right GitReceiptAcknowledged)) results)
      pure (Right (GitScan (listToMaybe (reverse operations)) (length operations) complete (length operations - complete)))

-- Five seconds per item bounds a page even if external evidence stalls. An
-- interrupted acknowledgement is retried against the same original attempt.
scanProcessReceipts :: SupervisorRuntime -> Maybe OperationId -> IO (Either SupervisorError ProcessScan)
scanProcessReceipts runtime cursor = do
  page <- runAppIO runtime.appEnv (runTransaction (inspectProcessPageTx cursor))
  case page of
    Left _ -> pure (Left SupervisorUnavailable)
    Right operations -> do
      results <- forM operations \operation -> timeout 5000000 (publishProcessReceipt runtime operation)
      let complete = length (filter (== Just (Right ProcessReceiptAcknowledged)) results)
      pure (Right (ProcessScan (listToMaybe (reverse operations)) (length operations) complete (length operations - complete)))

serveSupervisor :: RpcPolicy -> Socket.Socket -> SupervisorRuntime -> IO (Either RpcError ())
serveSupervisor policy listener runtime = do
  result <- race (serveRpc policy listener (dispatchSupervisorRpc runtime)) (recover Nothing Nothing)
  pure (either id (const (Left RpcUnavailable)) result)
  where
    recover cursor gitCursor = do
      scanned <- scanProcessReceipts runtime cursor
      git <- scanGitReceipts runtime.appEnv gitCursor
      threadDelay 250000
      recover (either (const cursor) (.cursor) scanned) (either (const gitCursor) (.cursor) git)

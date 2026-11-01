-- | Authenticated run acceptance over the shared producer and atomic ledger.
module Shikigami.AgentRun.Handler (agentRunServer) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Keiro.Workflow.Types (WorkflowId (..))
import Network.HTTP.Types.URI (encodePathSegments)
import Relay.Pagination (Direction (..), PageRequest (..))
import Relay.Pagination.Servant qualified as Relay
import Servant.Server.Generic (AsServerT)
import Shikigami.Agent.Catalog qualified as Catalog
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..))
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.RunJob (RunRouteKind (..))
import Shikigami.AgentRun.Api
import Shikigami.AgentRun.Ledger qualified as Ledger
import Shikigami.AgentRun.RequestKey (requestKeyText)
import Shikigami.AgentRun.Status qualified as Status
import Shikigami.Api.Problem
import Shikigami.Caller.Api
import Shikigami.Directory qualified as Directory
import Shikigami.Log qualified as Log
import Shikigami.Prelude hiding ((.=))
import Shikigami.Server.Seam
import Shikigami.Trigger.Enqueue (addressedRunJob)

agentRunServer :: ServerEnv -> ApiCaller -> AgentName -> AgentRunApi (AsServerT ServerM)
agentRunServer env caller agent = AgentRunApi {request = requestRun, show = showRun, list = listRuns}
  where
    showRun runId
      | isNothing (Catalog.lookupAgent env.catalog agent) = pure (RunShowAgentMissing missingAgent)
      | not (validRunKey runId) = pure (RunMissing missingRun)
      | otherwise =
          liftIO (env.readRunStatus agent (WorkflowId runId)) >>= \case
            Left Status.RunStatusStoreUnavailable -> pure (RunShowUnavailable unavailable)
            Left Status.RunStatusHistoryInvalid -> pure (RunShowInternal (problem Internal "The stored run history cannot be interpreted."))
            Right Nothing -> pure (RunMissing missingRun)
            Right (Just view) -> pure (RunFound (statusView view))
    listRuns page
      | isNothing (Catalog.lookupAgent env.catalog agent) = pure (RunListAgentMissing missingAgent)
      | page.pageSize == 0 = pure (RunPageInvalid (invalidPage page))
      | otherwise =
          liftIO (Ledger.listRunRequests env.pool agent page) >>= \case
            Left (Ledger.InvalidRunCursor _) -> pure (RunPageInvalid (invalidPage page))
            Left (Ledger.RunListUnavailable _) -> pure (RunListUnavailable unavailable)
            Right connection -> pure (RunPage (fmap requestView connection))
    missingAgent = problem AgentNotFound "No declared agent has this name."
    missingRun = problem RunNotFound "No run for this agent has this identifier."
    invalidPage page = Relay.RelayPageError {Relay.code = if page.pageSize == 0 then "invalid_page_size" else "invalid_cursor", Relay.message = "Use a positive page size and a cursor issued by this route.", Relay.retryable = False, Relay.parameter = Just (if page.pageSize == 0 then (if page.direction == Forward then "first" else "last") else (if page.direction == Forward then "after" else "before"))}
    requestRun body = case Catalog.lookupAgent env.catalog agent of
      Nothing -> pure (RunAgentMissing (problem AgentNotFound "No declared agent has this name."))
      Just decl | not decl.enabled -> pure (RunAgentNotRunnable (problem AgentNotRunnable "The agent is disabled in its declaration."))
      Just decl -> do
        admission <- liftIO (Directory.identityAdmission env.directory ((.principal) <$> decl.identity) agent)
        case admission of
          Left reason
            | "directory unavailable" `Text.isPrefixOf` reason -> pure (RunRequestUnavailable unavailable)
            | otherwise -> pure (RunAgentNotRunnable (problem AgentNotRunnable "The agent's identity or lifecycle does not permit a run."))
          Right identity
            | LBS.length (Aeson.encode body.payload) > 65536 -> pure (RunPayloadTooLarge (problem PayloadTooLarge "The encoded payload exceeds 65536 bytes."))
            | otherwise -> do
                now <- liftIO getCurrentTime
                let job = addressedRunJob now identity agent AgentWorkflowRoute body.payload (Ledger.httpRunKey agent body.idempotencyKey)
                outcome <- liftIO (Ledger.acceptRunRequest env.pool job body.idempotencyKey (Ledger.callerAttribution caller.callerId))
                case outcome of
                  Left _ -> pure (RunRequestUnavailable unavailable)
                  Right (Ledger.Accepted row) -> logOutcome "server.run.accepted" row >> pure (RunAccepted (accepted row, location row))
                  Right (Ledger.Replayed row) -> logOutcome "server.run.replayed" row >> pure (RunReplayed (accepted row, location row))
                  Right (Ledger.Conflicting row) -> logOutcome "server.run.conflict" row >> pure (RunConflict (problem IdempotencyKeyConflict "This key was already accepted with a different payload."))
    unavailable = problem Unavailable "The run store or lifecycle directory is unavailable."
    logOutcome event row = Log.logInfo env.logger event ["agent" .= row.agentName, "run_id" .= row.runId.unWorkflowId, "caller" .= caller.callerId]
    accepted row = AgentRunAccepted row.runId.unWorkflowId (agentNameText row.agentName) (requestKeyText row.idempotencyKey) "accepted" row.acceptedAt
    location row = Text.decodeUtf8 . LBS.toStrict . toLazyByteString $ encodePathSegments ["agents", agentNameText row.agentName, "runs", row.runId.unWorkflowId]

statusView :: Status.RunStatusView -> AgentRunStatus
statusView view =
  AgentRunStatus
    view.runId
    view.agentName
    (Status.lifecycleText view.lifecycle)
    view.trigger
    view.acceptedAt
    view.startedAt
    view.completedAt
    view.sessionId
    view.summary
    (fmap (\failure -> RunFailureView (Status.failureKindText failure.kind) failure.reason) view.failure)

requestView :: Ledger.RunRequestRow -> RunRequestView
requestView row = RunRequestView row.runId.unWorkflowId (requestKeyText row.idempotencyKey) row.acceptedAt (Ledger.callerAttributionText row.requestedBy) (Ledger.renderRunDisposition row.disposition)

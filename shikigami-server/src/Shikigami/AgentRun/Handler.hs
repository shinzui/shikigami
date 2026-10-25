-- | Authenticated run acceptance over the shared producer and atomic ledger.
module Shikigami.AgentRun.Handler (agentRunServer) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Types.URI (encodePathSegments)
import Servant.Server.Generic (AsServerT)
import Shikigami.Agent.Catalog qualified as Catalog
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..))
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.RunJob (RunRouteKind (..))
import Shikigami.AgentRun.Api
import Shikigami.AgentRun.Ledger qualified as Ledger
import Shikigami.Api.Problem
import Shikigami.Caller.Api
import Shikigami.Directory qualified as Directory
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.Server.Seam
import Shikigami.Trigger.Enqueue (addressedRunJob)

agentRunServer :: ServerEnv -> ApiCaller -> AgentName -> AgentRunApi (AsServerT ServerM)
agentRunServer env caller agent = AgentRunApi {request = requestRun}
  where
    requestRun body = case Catalog.lookupAgent env.catalog agent of
      Nothing -> pure (RunAgentMissing (problem AgentNotFound "No declared agent has this name."))
      Just decl | not decl.enabled -> pure (RunAgentNotRunnable (problem AgentNotRunnable "The agent is disabled in its declaration."))
      Just decl -> do
        admission <- liftIO (Directory.identityAdmission env.directory ((.principal) <$> decl.identity) (agentNameText agent))
        case admission of
          Left reason
            | "directory unavailable" `Text.isPrefixOf` reason -> pure (RunRequestUnavailable unavailable)
            | otherwise -> pure (RunAgentNotRunnable (problem AgentNotRunnable "The agent's identity or lifecycle does not permit a run."))
          Right identity
            | LBS.length (Aeson.encode body.payload) > 65536 -> pure (RunPayloadTooLarge (problem PayloadTooLarge "The encoded payload exceeds 65536 bytes."))
            | otherwise -> do
                now <- liftIO getCurrentTime
                let job = addressedRunJob now identity (agentNameText agent) AgentWorkflowRoute body.payload (Ledger.httpRunKey agent body.idempotencyKey)
                outcome <- liftIO (Ledger.acceptRunRequest env.pool job caller.callerId)
                case outcome of
                  Left _ -> pure (RunRequestUnavailable unavailable)
                  Right (Ledger.Accepted row) -> logOutcome "server.run.accepted" row >> pure (RunAccepted (accepted row, location row))
                  Right (Ledger.Replayed row) -> logOutcome "server.run.replayed" row >> pure (RunReplayed (accepted row, location row))
                  Right (Ledger.Conflicting row) -> logOutcome "server.run.conflict" row >> pure (RunConflict (problem IdempotencyKeyConflict "This key was already accepted with a different payload."))
    unavailable = problem Unavailable "The run store or lifecycle directory is unavailable."
    logOutcome event row = Log.logInfo env.logger event ["agent" Aeson..= row.agentName, "run_id" Aeson..= row.runId, "caller" Aeson..= caller.callerId]
    accepted row = AgentRunAccepted row.runId row.agentName row.idempotencyKey "accepted" row.acceptedAt
    location row = Text.decodeUtf8 . LBS.toStrict . toLazyByteString $ encodePathSegments ["agents", row.agentName, "runs", row.runId]

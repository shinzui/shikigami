-- | Addressed runs: the public resource starts at durable acceptance.
module Shikigami.AgentRun.Api
  ( AgentRunApi (..),
    AgentRunRequest (..),
    AgentRunAccepted (..),
    RunRequestResponses,
    RunRequestResult (..),
    validRunKey,
    AgentRunStatus (..),
    RunFailureView (..),
    RunRequestView (..),
    RunShowResponses,
    RunShowResult (..),
    RunListResponses,
    RunListResult (..),
  )
where

import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Char (isControl)
import Data.HashMap.Strict.InsOrd.Compat qualified as Map
import Data.OpenApi (ToSchema (..), fromAesonOptions, genericDeclareNamedSchema)
import Data.OpenApi qualified as O
import Data.SOP (I (..), NS (..))
import Data.Text qualified as Text
import Relay.Pagination (Connection)
import Relay.Pagination.Servant (RelayPage, RelayPageError)
import Servant.API
import Servant.API.MultiVerb
import Shikigami.Api.Problem
import Shikigami.Prelude

validRunKey :: Text -> Bool
validRunKey key = not (Text.null key) && Text.length key <= 200 && not (Text.any isControl key)

data AgentRunRequest = AgentRunRequest {idempotencyKey :: !Text, payload :: !Aeson.Value}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON AgentRunRequest where
  parseJSON = Aeson.withObject "AgentRunRequest" \object -> do
    key <- object .: "idempotencyKey"
    payload <- object .: "payload"
    unless (validRunKey key) (fail "invalid idempotency key")
    case payload of
      Aeson.Object _ -> pure (AgentRunRequest key payload)
      _ -> fail "payload must be a JSON object"

instance ToSchema AgentRunRequest where
  declareNamedSchema _ =
    pure $
      O.NamedSchema
        (Just "AgentRunRequest")
        ( mempty
            & O.type_
            ?~ O.OpenApiTypeSingle O.OpenApiObject
            & O.required
            .~ ["idempotencyKey", "payload"]
            & O.properties
            .~ Map.fromList
              [ ("idempotencyKey", O.Inline (mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiString & O.minLength ?~ 1 & O.maxLength ?~ 200)),
                ("payload", O.Inline (mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiObject & O.additionalProperties ?~ O.AdditionalPropertiesAllowed True))
              ]
        )

data AgentRunAccepted = AgentRunAccepted
  { runId :: !Text,
    agentName :: !Text,
    idempotencyKey :: !Text,
    status :: !Text,
    acceptedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance ToSchema AgentRunAccepted where
  declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

type RunRequestResponses =
  '[ WithHeaders '[Header "Location" Text] (AgentRunAccepted, Text) (Respond 202 "Run accepted" AgentRunAccepted),
     WithHeaders '[Header "Location" Text] (AgentRunAccepted, Text) (Respond 200 "Run already accepted" AgentRunAccepted),
     RespondAs ProblemJSON 404 "Agent not found" ProblemDetails,
     RespondAs ProblemJSON 409 "Agent not runnable" ProblemDetails,
     RespondAs ProblemJSON 409 "Idempotency key conflict" ProblemDetails,
     RespondAs ProblemJSON 413 "Payload too large" ProblemDetails,
     RespondAs ProblemJSON 503 "Store or directory unavailable" ProblemDetails,
     RespondAs ProblemJSON 400 "Invalid request body" ProblemDetails
   ]

data RunRequestResult
  = RunAccepted !(AgentRunAccepted, Text)
  | RunReplayed !(AgentRunAccepted, Text)
  | RunAgentMissing !ProblemDetails
  | RunAgentNotRunnable !ProblemDetails
  | RunConflict !ProblemDetails
  | RunPayloadTooLarge !ProblemDetails
  | RunRequestUnavailable !ProblemDetails
  | RunRequestInvalid !ProblemDetails
  deriving stock (Eq, Show)

instance AsUnion RunRequestResponses RunRequestResult where
  toUnion = \case
    RunAccepted body -> Z (I body)
    RunReplayed body -> S (Z (I body))
    RunAgentMissing body -> S (S (Z (I body)))
    RunAgentNotRunnable body -> S (S (S (Z (I body))))
    RunConflict body -> S (S (S (S (Z (I body)))))
    RunPayloadTooLarge body -> S (S (S (S (S (Z (I body))))))
    RunRequestUnavailable body -> S (S (S (S (S (S (Z (I body)))))))
    RunRequestInvalid body -> S (S (S (S (S (S (S (Z (I body))))))))
  fromUnion = \case
    Z (I body) -> RunAccepted body
    S (Z (I body)) -> RunReplayed body
    S (S (Z (I body))) -> RunAgentMissing body
    S (S (S (Z (I body)))) -> RunAgentNotRunnable body
    S (S (S (S (Z (I body))))) -> RunConflict body
    S (S (S (S (S (Z (I body)))))) -> RunPayloadTooLarge body
    S (S (S (S (S (S (Z (I body))))))) -> RunRequestUnavailable body
    S (S (S (S (S (S (S (Z (I body)))))))) -> RunRequestInvalid body
    S (S (S (S (S (S (S (S impossible))))))) -> case impossible of {}

data AgentRunApi mode = AgentRunApi
  { show :: mode :- Capture "runId" Text :> MultiVerb 'GET '[JSON] RunShowResponses RunShowResult,
    list :: mode :- RelayPage 50 200 :> MultiVerb 'GET '[JSON] RunListResponses RunListResult,
    request :: mode :- ReqBody '[JSON] AgentRunRequest :> MultiVerb 'POST '[JSON] RunRequestResponses RunRequestResult
  }
  deriving stock (Generic)

data AgentRunStatus = AgentRunStatus
  { runId :: !Text,
    agentName :: !Text,
    status :: !Text,
    trigger :: !(Maybe Text),
    acceptedAt :: !(Maybe UTCTime),
    startedAt :: !(Maybe UTCTime),
    completedAt :: !(Maybe UTCTime),
    sessionId :: !(Maybe Text),
    summary :: !(Maybe Text),
    failure :: !(Maybe RunFailureView)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data RunFailureView = RunFailureView {kind :: !Text, reason :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data RunRequestView = RunRequestView
  { runId :: !Text,
    idempotencyKey :: !Text,
    acceptedAt :: !UTCTime,
    requestedBy :: !Text,
    disposition :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance ToSchema RunRequestView where
  declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

instance ToSchema AgentRunStatus where
  declareNamedSchema proxy = do
    O.NamedSchema name schema <- genericDeclareNamedSchema (fromAesonOptions defaultOptions) proxy
    pure (O.NamedSchema name (schema & O.properties . ix "status" . O._Inline . O.enum_ ?~ fmap Aeson.String ["accepted", "running", "succeeded", "failed", "cancelled"]))

instance ToSchema RunFailureView where
  declareNamedSchema proxy = do
    O.NamedSchema name schema <- genericDeclareNamedSchema (fromAesonOptions defaultOptions) proxy
    pure (O.NamedSchema name (schema & O.properties . ix "kind" . O._Inline . O.enum_ ?~ fmap Aeson.String ["refused", "dead_lettered", "behavior_failed", "workflow_failed"]))

type RunShowResponses =
  '[ Respond 200 "The run lifecycle" (AgentRunStatus),
     RespondAs ProblemJSON 404 "Agent not found" ProblemDetails,
     RespondAs ProblemJSON 404 "Run not found" ProblemDetails,
     RespondAs ProblemJSON 503 "Store unavailable" ProblemDetails,
     RespondAs ProblemJSON 500 "Stored history invalid" ProblemDetails
   ]

data RunShowResult = RunFound !(AgentRunStatus) | RunShowAgentMissing !(ProblemDetails) | RunMissing !(ProblemDetails) | RunShowUnavailable !(ProblemDetails) | RunShowInternal !ProblemDetails
  deriving stock (Eq, Show)

instance AsUnion RunShowResponses RunShowResult where
  toUnion = \case
    RunFound body -> Z (I body)
    RunShowAgentMissing body -> S (Z (I body))
    RunMissing body -> S (S (Z (I body)))
    RunShowUnavailable body -> S (S (S (Z (I body))))
    RunShowInternal body -> S (S (S (S (Z (I body)))))
  fromUnion = \case
    Z (I body) -> RunFound body
    S (Z (I body)) -> RunShowAgentMissing body
    S (S (Z (I body))) -> RunMissing body
    S (S (S (Z (I body)))) -> RunShowUnavailable body
    S (S (S (S (Z (I body))))) -> RunShowInternal body
    S (S (S (S (S impossible)))) -> case impossible of {}

type RunListResponses =
  '[ Respond 200 "A page of accepted run requests" (Connection RunRequestView),
     Respond 400 "Invalid pagination cursor or size" RelayPageError,
     RespondAs ProblemJSON 404 "Agent not found" ProblemDetails,
     RespondAs ProblemJSON 503 "Store unavailable" ProblemDetails
   ]

data RunListResult = RunPage !(Connection RunRequestView) | RunPageInvalid !RelayPageError | RunListAgentMissing !(ProblemDetails) | RunListUnavailable !(ProblemDetails)
  deriving stock (Eq, Show)

instance AsUnion RunListResponses RunListResult where
  toUnion = \case
    RunPage body -> Z (I body)
    RunPageInvalid body -> S (Z (I body))
    RunListAgentMissing body -> S (S (Z (I body)))
    RunListUnavailable body -> S (S (S (Z (I body))))
  fromUnion = \case
    Z (I body) -> RunPage body
    S (Z (I body)) -> RunPageInvalid body
    S (S (Z (I body))) -> RunListAgentMissing body
    S (S (S (Z (I body)))) -> RunListUnavailable body
    S (S (S (S (impossible)))) -> case impossible of {}

-- | Addressed runs: the public resource starts at durable acceptance.
module Shikigami.AgentRun.Api
  ( AgentRunApi (..),
    AgentRunRequest (..),
    AgentRunAccepted (..),
    RunRequestResponses,
    RunRequestResult (..),
    validRunKey,
  )
where

import Data.Aeson qualified as Aeson
import Data.Char (isControl)
import Data.HashMap.Strict.InsOrd.Compat qualified as Map
import Data.OpenApi (ToSchema (..), fromAesonOptions, genericDeclareNamedSchema)
import Data.OpenApi qualified as O
import Data.SOP (I (..), NS (..))
import Data.Text qualified as Text
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
    key <- object Aeson..: "idempotencyKey"
    payload <- object Aeson..: "payload"
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
     RespondAs ProblemJSON 503 "Store or directory unavailable" ProblemDetails
   ]

data RunRequestResult
  = RunAccepted !(AgentRunAccepted, Text)
  | RunReplayed !(AgentRunAccepted, Text)
  | RunAgentMissing !ProblemDetails
  | RunAgentNotRunnable !ProblemDetails
  | RunConflict !ProblemDetails
  | RunPayloadTooLarge !ProblemDetails
  | RunRequestUnavailable !ProblemDetails
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
  fromUnion = \case
    Z (I body) -> RunAccepted body
    S (Z (I body)) -> RunReplayed body
    S (S (Z (I body))) -> RunAgentMissing body
    S (S (S (Z (I body)))) -> RunAgentNotRunnable body
    S (S (S (S (Z (I body))))) -> RunConflict body
    S (S (S (S (S (Z (I body)))))) -> RunPayloadTooLarge body
    S (S (S (S (S (S (Z (I body))))))) -> RunRequestUnavailable body
    S (S (S (S (S (S (S impossible)))))) -> case impossible of {}

data AgentRunApi mode = AgentRunApi
  { request :: mode :- ReqBody '[JSON] AgentRunRequest :> MultiVerb 'POST '[JSON] RunRequestResponses RunRequestResult
  }
  deriving stock (Generic)

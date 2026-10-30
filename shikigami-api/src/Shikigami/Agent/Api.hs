{-# LANGUAGE DataKinds #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | The declaration catalog's HTTP contract. AgentName's HTTP instances live
-- here to keep HTTP dependencies out of the domain package.
module Shikigami.Agent.Api
  ( AgentApi (..),
    AgentView (..),
    AgentPageResponses,
    AgentPageResult (..),
    AgentShowResponses,
    AgentShowResult (..),
  )
where

import Data.OpenApi (ToParamSchema (..), ToSchema (..), fromAesonOptions, genericDeclareNamedSchema)
import Data.SOP.BasicFunctors (I (..))
import Data.SOP.NS (NS (..))
import Data.Text qualified as Text
import Relay.Pagination (Connection)
import Relay.Pagination.Servant (RelayPage, RelayPageError)
import Servant.API
import Servant.API.Generic ((:-))
import Servant.API.MultiVerb
import Shikigami.Agent.Name (AgentName (..), agentNameText)
import Shikigami.AgentRun.Api (AgentRunApi)
import Shikigami.Api.Problem
import Shikigami.Prelude

data AgentView = AgentView
  { name :: !Text,
    description :: !Text,
    enabled :: !Bool,
    trigger :: !Text,
    behavior :: !Text,
    sinks :: ![Text],
    delegates :: ![Text],
    principalId :: !(Maybe Text),
    lifecycle :: !Text,
    runnable :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance ToSchema AgentView where
  declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions defaultOptions)

instance FromHttpApiData AgentName where
  parseUrlPiece value
    | Text.null value = Left "agent name must not be empty"
    | otherwise = Right (AgentName value)

instance ToHttpApiData AgentName where
  toUrlPiece = agentNameText

instance ToParamSchema AgentName where
  toParamSchema _ = toParamSchema (Proxy @Text)

type AgentPageResponses =
  '[ Respond 200 "A page of declared agents" (Connection AgentView),
     Respond 400 "Invalid pagination cursor or size" RelayPageError,
     RespondAs ProblemJSON 503 "The lifecycle directory is unavailable" ProblemDetails
   ]

data AgentPageResult = AgentPage !(Connection AgentView) | AgentPageInvalid !RelayPageError | AgentPageUnavailable !ProblemDetails
  deriving stock (Eq, Show)

instance AsUnion AgentPageResponses AgentPageResult where
  toUnion = \case
    AgentPage body -> Z (I body)
    AgentPageInvalid body -> S (Z (I body))
    AgentPageUnavailable body -> S (S (Z (I body)))
  fromUnion = \case
    Z (I body) -> AgentPage body
    S (Z (I body)) -> AgentPageInvalid body
    S (S (Z (I body))) -> AgentPageUnavailable body
    S (S (S impossible)) -> case impossible of {}

type AgentShowResponses =
  '[ Respond 200 "The declared agent" AgentView,
     RespondAs ProblemJSON 404 "No such agent" ProblemDetails,
     RespondAs ProblemJSON 503 "The lifecycle directory is unavailable" ProblemDetails
   ]

data AgentShowResult = AgentFound !AgentView | AgentMissing !ProblemDetails | AgentUnavailable !ProblemDetails
  deriving stock (Eq, Show)

instance AsUnion AgentShowResponses AgentShowResult where
  toUnion = \case
    AgentFound body -> Z (I body)
    AgentMissing body -> S (Z (I body))
    AgentUnavailable body -> S (S (Z (I body)))
  fromUnion = \case
    Z (I body) -> AgentFound body
    S (Z (I body)) -> AgentMissing body
    S (S (Z (I body))) -> AgentUnavailable body
    S (S (S impossible)) -> case impossible of {}

data AgentApi mode = AgentApi
  { list :: mode :- RelayPage 50 200 :> MultiVerb 'GET '[JSON] AgentPageResponses AgentPageResult,
    runs :: mode :- Capture "agentName" AgentName :> "runs" :> NamedRoutes AgentRunApi,
    show :: mode :- Capture "agentName" AgentName :> MultiVerb 'GET '[JSON] AgentShowResponses AgentShowResult
  }
  deriving stock (Generic)

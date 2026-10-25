{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Authentication at each protected vertical mount. The OpenAPI orphan fills
-- the missing AuthProtect instance in servant-openapi-hs.
module Shikigami.Caller.Api (Authenticated, ApiCaller (..), bearerSchemeName) where

import Data.HashMap.Strict.InsOrd.Compat qualified as Map
import Data.OpenApi qualified as O
import Servant.API (StdMethod (GET), (:>))
import Servant.API.Experimental.Auth (AuthProtect)
import Servant.API.MultiVerb (MultiVerb, RespondAs)
import Servant.OpenApi (HasOpenApi (..))
import Shikigami.Api.Problem
import Shikigami.Prelude

type Authenticated = AuthProtect "shikigami-bearer"

newtype ApiCaller = ApiCaller {callerId :: Text}
  deriving stock (Eq, Show, Generic)

bearerSchemeName :: Text
bearerSchemeName = "bearer"

instance (HasOpenApi api) => HasOpenApi (AuthProtect "shikigami-bearer" :> api) where
  toOpenApi _ =
    toOpenApi (Proxy @api)
      & O.components
      . O.securitySchemes
      .~ O.SecurityDefinitions (Map.singleton bearerSchemeName (O.SecurityScheme (O.SecuritySchemeHttp (O.HttpSchemeBearer Nothing)) Nothing))
      & O.allOperations
      . O.security
      .~ [O.SecurityRequirement (Map.singleton bearerSchemeName [])]
      & O.allOperations
      . O.responses
      %~ (<> refusal)
      & O.components
      . O.schemas
      %~ (<> (unauthorizedDoc ^. O.components . O.schemas))
    where
      unauthorizedDoc = toOpenApi (Proxy @(MultiVerb 'GET '[ProblemJSON] '[RespondAs ProblemJSON 401 "Missing or invalid bearer credential" ProblemDetails] ProblemDetails))
      refusal = fromMaybe mempty (unauthorizedDoc ^? O.allOperations . O.responses)

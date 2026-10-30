{-# LANGUAGE DataKinds #-}

-- | The umbrella route record: the single type that says what Shikigami serves.
--
-- Everything downstream is derived from this one value. @shikigami-server@
-- serves it, @shikigami-client@ derives a typed client from it, and
-- @shikigami-openapi@ generates @docs\/api\/openapi.json@ from it. Because all
-- three read the same type, a route cannot be served without appearing in the
-- document, and a client cannot call a route the server does not have.
--
-- \"NamedRoutes\" means the API is described by a record whose fields are
-- endpoints, rather than by a chain of @:\<|\>@ operators. Each field's type
-- mentions @mode@, a placeholder that Servant fills in differently depending on
-- what is being derived: handlers on the server, functions on the client, an
-- API description for documentation. Naming removes positional wiring errors; same-typed handlers still require
-- dispatch tests because a named transposition also compiles.
--
-- Adding a vertical means adding one field here whose type is
-- @mode :- \"segment\" :\> NamedRoutes SomeApi@, and defining @SomeApi@ in that
-- vertical's own module. Terminal routes must use @MultiVerb@ so every status
-- code, media type, and body is part of the type, and error alternatives must be
-- declared with @RespondAs ProblemJSON@ so they render the one problem body
-- defined in "Shikigami.Api.Problem".
module Shikigami.Api
  ( ShikigamiApi (..),
    ShikigamiRoutes,
    shikigamiApi,
  )
where

import Data.Aeson (Value)
import Servant.API (Get, JSON, NamedRoutes, (:>))
import Servant.API.Generic ((:-))
import Shikigami.Agent.Api (AgentApi)
import Shikigami.Caller.Api (Authenticated)
import Shikigami.Health.Api (HealthApi)
import Shikigami.Prelude

-- | Every public HTTP surface Shikigami exposes.
--
-- Declared with @data@ rather than @newtype@ even though it currently holds one
-- field, because the next vertical adds a second and a newtype would have to be
-- rewritten.
data ShikigamiApi mode = ShikigamiApi
  { health :: mode :- "health" :> NamedRoutes HealthApi,
    agents :: mode :- Authenticated :> "agents" :> NamedRoutes AgentApi,
    -- Pure build metadata; the named single-status exemption has no dependency.
    openapi :: mode :- "openapi" :> Get '[JSON] Value
  }
  deriving stock (Generic)

-- | The API as a Servant type, for the places that need a type rather than a
-- record: @serve@, @client@, and OpenAPI generation.
type ShikigamiRoutes = NamedRoutes ShikigamiApi

-- | The one proxy the server, the client, and the document generator all use.
--
-- Sharing it is what makes \"the document describes what is actually served\" a
-- structural property rather than a review convention.
shikigamiApi :: Proxy ShikigamiRoutes
shikigamiApi = Proxy

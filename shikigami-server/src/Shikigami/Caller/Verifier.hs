{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | The inbound credential verifier, replaceable without changing routes.
module Shikigami.Caller.Verifier (newCallerVerifier) where

import Control.Monad.Except (throwError)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Network.Wai (Request, requestHeaders)
import Servant.Server (ServerError (..))
import Servant.Server.Experimental.Auth
import Shikigami.Agent.DeclarationValue (declarationCoordinateText)
import Shikigami.Api.Problem (ProblemCode (Unauthorized))
import Shikigami.App.Config (HttpAuthSettings (..))
import Shikigami.Caller.Api
import Shikigami.Log qualified as Log
import Shikigami.Prelude hiding ((.=))
import Shikigami.Server.Seam (problemServerError)
import Shikigami.Sink.Auth (credentialToken, matchesBearerHeader)

type instance AuthServerData Authenticated = ApiCaller

newCallerVerifier :: Log.Logger -> HttpAuthSettings -> AuthHandler Request ApiCaller
newCallerVerifier logger settings = mkAuthHandler \request -> case settings of
  AuthDisabled -> pure (ApiCaller "anonymous")
  AuthBearer {token, caller} ->
    let headers = [value | (name, value) <- requestHeaders request, name == "Authorization"]
     in case headers of
          [value] | matchesBearerHeader (credentialToken token) value -> pure (ApiCaller (declarationCoordinateText caller))
          _ -> do
            liftIO (Log.logInfo logger "server.auth.rejected" ["reason" .= (if null headers then "missing" else "invalid" :: Text)])
            let refusal = problemServerError Unauthorized "A valid bearer token is required."
            throwError refusal {errHeaders = ("WWW-Authenticate", "Bearer realm=\"shikigami\"") : refusal.errHeaders}

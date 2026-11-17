-- | The binding's settings resolved as a composition resolves them: through
-- the kernel's configuration with the binding's settings declared, from an
-- injected environment.
module Kikan.Shikigami.Binding.Fixture.Settings
  ( endpointsFromEnvironment,
    tokenFromEnvironment,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Kikan.Shikigami.Binding.Settings (ServiceEndpoints (..), loadServiceEndpoints, serviceSettings)
import Settei (answer, defaultResolveOptions, resolve)
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.App.Config (AppConfig (..), appConfigWith, environmentBindingsWith)
import Shikigami.Pack.Setting (PackSecret)
import Shikigami.Sink.Auth (BearerToken, packSecretToken)

-- | The endpoints and tokens these variables configure.
endpointsFromEnvironment :: [(Text, Text)] -> ServiceEndpoints
endpointsFromEnvironment variables =
  case answer (resolve defaultResolveOptions [source] (appConfigWith serviceSettings)) of
    Left failure -> error ("the binding's settings did not resolve: " <> show failure)
    Right config -> either (error . Text.unpack) id (loadServiceEndpoints config.packSettings)
  where
    bindings = either (error . Text.unpack) id (environmentBindingsWith serviceSettings)
    source = environmentSource bindings (envSnapshot variables)

-- | The token one of the binding's secret settings takes from this variable.
tokenFromEnvironment :: (ServiceEndpoints -> Maybe PackSecret) -> Text -> Text -> BearerToken
tokenFromEnvironment field variable value =
  case field (endpointsFromEnvironment [(variable, value)]) of
    Just secret -> packSecretToken secret
    Nothing -> error ("the binding read no token from " <> Text.unpack variable)

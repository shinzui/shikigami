-- | The process-lifetime HTTP clients of the Kikan outputs and channels.
--
-- Kawa, Kizashi and Kanmon share one bounded manager and keep separate token
-- sources; Danwa owns a dedicated typed-client manager behind its
-- 'ClientEnv', so its request hook cannot authenticate another host.
module Kikan.Shikigami.Binding.Output.Http
  ( KikanHttp (..),
    newKikanHttp,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Kikan.Shikigami.Binding.Output.Config (DanwaConfig (..))
import Kikan.Shikigami.Binding.Settings (ServiceEndpoints (..))
import Servant.Client (ClientEnv, mkClientEnv, parseBaseUrl)
import Shikigami.Sink.Auth (packSecretToken, staticTokenSource)
import Shikigami.Sink.Http (HttpEnv (..), HttpLimits, newSinkManager, newTypedClientManager)

data KikanHttp = KikanHttp
  { kawa :: !HttpEnv,
    kizashi :: !HttpEnv,
    kanmon :: !HttpEnv,
    danwa :: !ClientEnv
  }

-- | Build the clients once, at start. Refuses an unparseable Danwa base URL.
newKikanHttp :: HttpLimits -> ServiceEndpoints -> IO (Either Text KikanHttp)
newKikanHttp limits endpoints =
  case parseBaseUrl (Text.unpack endpoints.danwa.baseUrl) of
    Nothing -> pure (Left "sinks.danwa.base_url is not a valid base URL")
    Just danwaBase -> do
      shared <- newSinkManager
      danwaManager <- newTypedClientManager limits (source endpoints.danwaToken)
      pure
        ( Right
            KikanHttp
              { kawa = HttpEnv {manager = shared, token = source endpoints.kawaToken, limits},
                kizashi = HttpEnv {manager = shared, token = source endpoints.kizashiToken, limits},
                kanmon = HttpEnv {manager = shared, token = source endpoints.kanmonToken, limits},
                danwa = mkClientEnv danwaManager danwaBase
              }
        )
  where
    source = fmap (staticTokenSource . packSecretToken)

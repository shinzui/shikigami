-- | Worker and operator commands use the same configured C13 verifier.
module Shikigami.Action.Authorization.Config (buildConfiguredActionAuthorizer) where

import Data.Text qualified as Text
import Kikan.En.Client (newActionProofVerifier, newKikanEnClient)
import Network.HTTP.Client.TLS (newTlsManager)
import Servant.Client (mkClientEnv, parseBaseUrl)
import Shikigami.Action.Authorization
import Shikigami.App.Config (ActionAuthorizationConfig (..), AppConfig (..), revealSecretText)
import Shikigami.Log qualified as Log
import Shikigami.Prelude

buildConfiguredActionAuthorizer :: Log.Logger -> AppConfig -> IO (Either Text ActionAuthorizer)
buildConfiguredActionAuthorizer logger config = case config.actionAuthorization of
  ActionAuthorizationDisabled -> pure (Right denyAllActionAuthorizer)
  KikanActionAuthorization {kikanBaseUrl, shomeiBaseUrl, shomeiClientId, shomeiClientSecret, issuerPublicKeys, acceptedSchemaHashes, callerId} ->
    case (parseBaseUrl (Text.unpack kikanBaseUrl), parseBaseUrl (Text.unpack shomeiBaseUrl)) of
      (Right kikanBase, Right shomeiBase) -> do
        manager <- newTlsManager
        let verifier = newActionProofVerifier issuerPublicKeys acceptedSchemaHashes (const (pure False))
            client = newKikanEnClient (mkClientEnv manager kikanBase) verifier
            tokenSource = shomeiClientCredentialsToken (mkClientEnv manager shomeiBase) shomeiClientId (revealSecretText shomeiClientSecret)
        pure (Right (newKikanActionAuthorizer logger callerId config.kawaSourceSegment client tokenSource))
      _ -> pure (Left "invalid Kikan-En or Shomei authorization base URL")

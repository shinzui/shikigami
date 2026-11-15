-- | Worker and operator commands build the same configured authority from
-- the setting @authorization.actions.mode@: @disabled@ composes 'denyAll',
-- and @kikan@ composes the Kikan-En adapter.
module Shikigami.Authority.KikanEn.Config (buildConfiguredAuthority) where

import Data.Text qualified as Text
import Kikan.En.Client (newActionProofVerifier, newKikanEnClient)
import Network.HTTP.Client.TLS (newTlsManager)
import Servant.Client (mkClientEnv, parseBaseUrl)
import Shikigami.App.Config (ActionAuthorizationConfig (..), AppConfig (..), revealSecretText)
import Shikigami.Authority (Authority, denyAll)
import Shikigami.Authority.KikanEn (KikanEnMapping (..), kikanEnAuthority, shomeiClientCredentialsToken)
import Shikigami.Log qualified as Log
import Shikigami.Prelude

buildConfiguredAuthority :: Log.Logger -> AppConfig -> IO (Either Text Authority)
buildConfiguredAuthority logger config = case config.actionAuthorization of
  ActionAuthorizationDisabled -> pure (Right denyAll)
  KikanActionAuthorization {kikanBaseUrl, shomeiBaseUrl, shomeiClientId, shomeiClientSecret, issuerPublicKeys, acceptedSchemaHashes, callerId} ->
    case (parseBaseUrl (Text.unpack kikanBaseUrl), parseBaseUrl (Text.unpack shomeiBaseUrl)) of
      (Right kikanBase, Right shomeiBase) -> do
        manager <- newTlsManager
        let verifier = newActionProofVerifier issuerPublicKeys acceptedSchemaHashes (const (pure False))
            client = newKikanEnClient (mkClientEnv manager kikanBase) verifier
            tokenSource = shomeiClientCredentialsToken (mkClientEnv manager shomeiBase) shomeiClientId (revealSecretText shomeiClientSecret)
        pure (Right (kikanEnAuthority logger callerId KikanEnMapping {kawaSource = config.kawaSourceSegment} client tokenSource))
      _ -> pure (Left "invalid Kikan-En or Shomei authorization base URL")

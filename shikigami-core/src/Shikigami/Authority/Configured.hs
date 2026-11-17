-- | The authority a role runs under the deployment tiers, selected by
-- @authorization.actions.mode@ from the authorities its packs register.
--
-- @disabled@ composes 'denyAll'. Any other mode must be registered by a
-- composed pack; an executable that composes none refuses to start and says
-- which distribution would. The stock executables compose no authority pack.
module Shikigami.Authority.Configured
  ( buildConfiguredAuthority,
    missingAuthorityMessage,
  )
where

import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.App.Config (ActionAuthorizationConfig (..), AppConfig (..))
import Shikigami.Authority (Authority, denyAll)
import Shikigami.Authority.Adapter (AuthorityAdapter (..), AuthorityContext (..))
import Shikigami.Log qualified as Log

buildConfiguredAuthority :: [AuthorityAdapter] -> Log.Logger -> AppConfig -> IO (Either Text Authority)
buildConfiguredAuthority adapters logger config = case config.actionAuthorization of
  ActionAuthorizationDisabled -> pure (Right denyAll)
  ActionAuthorizationBy requested -> case find (\adapter -> adapter.mode == requested) adapters of
    Nothing -> pure (Left (missingAuthorityMessage requested ((.mode) <$> adapters)))
    Just adapter ->
      either (\problem -> Left ("authorization.actions.mode=" <> requested <> ": " <> problem)) Right
        <$> adapter.build AuthorityContext {logger, settings = config.packSettings}

-- | Why a mode cannot be honoured here, and where it can.
missingAuthorityMessage :: Text -> [Text] -> Text
missingAuthorityMessage requested registered =
  "authorization.actions.mode="
    <> requested
    <> " names an authority this executable does not compose (registered: "
    <> (if null registered then "none" else Text.intercalate ", " registered)
    <> ")"
    <> if requested == "kikan"
      then "; the Kikan-En authority is composed by the Kikan distribution: run kikan-shikigami-worker (or the kikan-shikigami executable for this role) instead"
      else ""

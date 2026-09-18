{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Build identity shared by Shikigami's operational executables.
--
-- Local Cabal builds read the revision from Git at compile time. Reproducible
-- builds have no @.git@ directory, so Nix injects the same value as @GIT_HASH@.
-- Source archives have neither and report the package version alone.
module Shikigami.App.Version
  ( appVersion,
    appVersionWithGit,
    gitCommitShort,
    versionOption,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Version (showVersion)
import GitHash (GitInfo, giHash, tGitInfoCwdTry)
import Options.Applicative (Parser)
import Options.Applicative qualified as Options
import Paths_shikigami_core (version)

-- | Version declared by @shikigami-core.cabal@.
appVersion :: Text
appVersion = Text.pack (showVersion version)

gitInfo :: Either String GitInfo
gitInfo = $$tGitInfoCwdTry

nixGitHash :: Maybe Text
#ifdef GIT_HASH
nixGitHash = Just (Text.pack GIT_HASH)
#else
nixGitHash = Nothing
#endif

-- | Seven-character revision, preferring the local Git checkout to Nix's
-- injected fallback.
gitCommitShort :: Maybe Text
gitCommitShort =
  case gitInfo of
    Right info -> Just (Text.pack (take 7 (giHash info)))
    Left _ -> Text.take 7 <$> nixGitHash

-- | Version text for one installed executable.
appVersionWithGit :: String -> String
appVersionWithGit binaryName =
  binaryName
    <> " v"
    <> Text.unpack appVersion
    <> maybe "" (\commit -> " (" <> Text.unpack commit <> ")") gitCommitShort

-- | Add the offline @--version@ action to an optparse-applicative parser.
versionOption :: String -> Parser (a -> a)
versionOption binaryName =
  Options.infoOption
    (appVersionWithGit binaryName)
    (Options.long "version" <> Options.help "Show version")

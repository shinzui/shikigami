{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Build identity stays in the client package so it needs no runtime-core edge.
module Shikigami.Client.Version (versionOption) where

import Data.Version (showVersion)
import GitHash (GitInfo, giHash, tGitInfoCwdTry)
import Options.Applicative (Parser, help, infoOption, long)
import Paths_shikigami_client (version)

gitInfo :: Either String GitInfo
gitInfo = $$tGitInfoCwdTry

injectedRevision :: Maybe String
#ifdef GIT_HASH
injectedRevision = Just GIT_HASH
#else
injectedRevision = Nothing
#endif

versionOption :: Parser (a -> a)
versionOption = infoOption rendered (long "version" <> help "Show version and build revision")
  where
    revision = either (const injectedRevision) (Just . giHash) gitInfo
    rendered = "shikigami-client v" <> showVersion version <> maybe "" (\value -> " (" <> take 7 value <> ")") revision

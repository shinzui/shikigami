-- | What every Shikigami executable has in common: a name, a configuration
-- role, and a parser that resolves settings before it acts.
--
-- This lives in @shikigami-core@ rather than in one of the executable-owning
-- packages because more than one package now ships executables that must
-- resolve configuration identically. 'runRole' /is/ the configuration
-- resolution — parse, resolve, act, in that order — and duplicating it would
-- let two packages disagree about when @--check-config@ runs relative to the
-- action opening a database or joining a consumer group.
--
-- The type is deliberately thin. It carries no behavior: each package builds
-- its own 'RoleInfo' values from its own parsers, and 'Shikigami.App.Config'
-- owns the 'Role' vocabulary that decides which keys a given binary requires.
module Shikigami.App.Role
  ( RoleInfo (..),
    runRole,
  )
where

import Options.Applicative (ParserInfo, execParser)
import Shikigami.App.Config (AppConfig, Role)
import Shikigami.App.Config.Load (ConfigOptions, runAppConfig)

-- | One executable: what it is installed as, which role it plays for the
-- purpose of required-key checking, and how its command line parses.
--
-- Every parser has the same result type, which is exactly why a dropped or
-- misrouted flag is invisible to the type checker. Each package therefore keeps
-- a list of its own 'RoleInfo' values so a test can drive every parser without
-- listing them a second time.
data RoleInfo = RoleInfo
  { binaryName :: !String,
    role :: !Role,
    parserInfo :: !(ParserInfo (AppConfig -> IO (), ConfigOptions))
  }

-- | An executable's @main@: parse the command line, resolve configuration, then
-- act.
--
-- The ordering is what makes @--check-config@ honest: configuration is fully
-- resolved and the role's required keys are checked before the action opens a
-- database, joins a consumer group, or registers a processor.
runRole :: RoleInfo -> IO ()
runRole info = do
  (action, options) <- execParser ((.parserInfo) info)
  config <- runAppConfig ((.role) info) options
  action config

module Shikigami.Agent.Loader
  ( LoadError (..),
    loadAgent,
    loadAgentsIn,
  )
where

import Control.Exception (SomeException, try)
import Data.List (isSuffixOf, sort)
import Data.Text qualified as Text
import Dhall (auto, inputFile)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Prelude
import System.Directory (listDirectory)
import System.FilePath ((</>))

-- | A typed loader error. The Text carries Dhall's own (already very precise)
-- type-error / parse-error message.
newtype LoadError = LoadError Text
  deriving stock (Eq, Show)

-- | Parse and type-check a Dhall agent manifest into an AgentDecl. Returns Left
-- with a typed error if the file does not exist, fails to parse, or does not
-- type-check against the AgentDecl shape.
loadAgent :: FilePath -> IO (Either LoadError AgentDecl)
loadAgent path = do
  result <- try (inputFile auto path) :: IO (Either SomeException AgentDecl)
  pure $ case result of
    Left err -> Left (LoadError (Text.pack (show err)))
    Right decl -> Right decl

-- | Load every @*.dhall@ manifest in a directory, in filename order.
--
-- A manifest that fails to load is skipped rather than failing the call. That is
-- the behavior every worker entry point already had, duplicated four times; it
-- is centralized here so there is one place for
-- @docs\/plans\/20-explicit-trigger-routing-scheduler-catch-up-policy-and-loud-failures.md@
-- to make the skip loud, and one place for
-- @docs\/plans\/33-agent-schema-evolution-identity-memory-policy-and-enablement.md@
-- to filter by enablement, instead of four.
--
-- Silently skipping a broken manifest means an agent can stop running because of
-- a typo with nothing said about it. Do not build on that; it is preserved only
-- so this refactor changes no behavior.
loadAgentsIn :: FilePath -> IO [AgentDecl]
loadAgentsIn dir = do
  entries <- listDirectory dir
  loaded <- mapM loadAgent [dir </> entry | entry <- sort entries, ".dhall" `isSuffixOf` entry]
  pure [decl | Right decl <- loaded]

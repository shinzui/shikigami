module Shikigami.Agent.Loader
  ( LoadError (..),
    AgentLoadEntry (..),
    AgentLoadReport (..),
    loadAgent,
    loadAgentsReport,
    loadAgentsLoud,
    loadedAgents,
    enabledAgentsFromReport,
    loadAgentsIn,
  )
where

import Control.Exception (SomeException, try)
import Data.Foldable (traverse_)
import Data.List (isSuffixOf, sort)
import Data.Text qualified as Text
import Dhall (auto, inputFile)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Prelude
import System.Directory (listDirectory)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

-- | A typed loader error. The Text carries Dhall's own (already very precise)
-- type-error / parse-error message.
newtype LoadError = LoadError Text
  deriving stock (Eq, Show)

data AgentLoadEntry
  = AgentLoaded {path :: !FilePath, declaration :: !AgentDecl}
  | AgentLoadFailed {path :: !FilePath, error :: !LoadError}
  deriving stock (Eq, Show)

newtype AgentLoadReport = AgentLoadReport {entries :: [AgentLoadEntry]}
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

-- | Load every manifest once, preserving both successes and failures in
-- filename order so callers can inspect, report, or persist the complete view.
loadAgentsReport :: FilePath -> IO AgentLoadReport
loadAgentsReport dir = do
  names <- listDirectory dir
  let paths = [dir </> name | name <- sort names, ".dhall" `isSuffixOf` name]
  entries <-
    traverse
      ( \path ->
          loadAgent path <&> \case
            Left err -> AgentLoadFailed {path, error = err}
            Right declaration -> AgentLoaded {path, declaration}
      )
      paths
  pure (AgentLoadReport entries)

-- | Report every failed manifest and a summary to stderr. Strict mode refuses
-- startup after reporting; lenient mode returns the same complete report.
loadAgentsLoud :: FilePath -> Bool -> IO AgentLoadReport
loadAgentsLoud dir strictMode = do
  report@AgentLoadReport {entries} <- loadAgentsReport dir
  traverse_ reportFailure entries
  let loadedCount = length [() | AgentLoaded {} <- entries]
      failedCount = length entries - loadedCount
  hPutStrLn
    stderr
    ( "[load] loaded "
        <> show loadedCount
        <> " of "
        <> show (length entries)
        <> " agent manifests ("
        <> show failedCount
        <> " failed)"
    )
  when (strictMode && failedCount > 0) exitFailure
  pure report
  where
    reportFailure = \case
      AgentLoaded {} -> pure ()
      AgentLoadFailed {path, error = LoadError message} ->
        hPutStrLn stderr ("[load] FAILED " <> path <> ": " <> Text.unpack message)

loadedAgents :: AgentLoadReport -> [AgentDecl]
loadedAgents AgentLoadReport {entries} =
  [declaration | AgentLoaded {declaration} <- entries]

-- | Select runnable declarations while retaining single-file load behavior for
-- validation and operator commands. Every explicit disable is visible.
enabledAgentsFromReport :: AgentLoadReport -> IO [AgentDecl]
enabledAgentsFromReport AgentLoadReport {entries} = do
  traverse_ reportDisabled entries
  pure
    [ declaration
    | AgentLoaded {declaration = declaration@AgentDecl {enabled = True}} <- entries
    ]
  where
    reportDisabled = \case
      AgentLoaded {path, declaration = AgentDecl {name, enabled = False}} ->
        hPutStrLn
          stderr
          ( "[loader] skipping disabled agent '"
              <> Text.unpack name
              <> "' ("
              <> path
              <> ")"
          )
      _ -> pure ()

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
loadAgentsIn dir = loadedAgents <$> loadAgentsReport dir

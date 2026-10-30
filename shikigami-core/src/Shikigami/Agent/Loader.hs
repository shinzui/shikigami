module Shikigami.Agent.Loader
  ( LoadError (..),
    AgentLoadEntry (..),
    AgentLoadReport (..),
    loadAgent,
    loadAgentsReport,
    loadAgentsLoud,
    loadedAgents,
    enabledAgentsFromReport,
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.List (isSuffixOf, sort)
import Data.Text qualified as Text
import Dhall (auto, inputFile)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Log qualified as Log
import Shikigami.Prelude hiding ((.=))
import System.Directory (listDirectory)
import System.Exit (exitFailure)
import System.FilePath ((</>))

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

-- | Report every failed manifest and a summary, then optionally refuse to start.
--
-- Every failure is reported /before/ the refusal, so an operator running a
-- strict process sees all of them in one go rather than fixing one manifest per
-- restart. The default is lenient (@agents.strict = false@) so that upgrading
-- does not turn a deployment that has been tolerating a broken manifest into a
-- failed deploy without an explicit configuration change.
--
-- The logger is a parameter rather than a bare @stderr@ write because these are
-- lines a long-running process emits, and plan 28's rule is that every one of
-- those is a single JSON object an operator can filter with @jq@.
loadAgentsLoud :: Log.Logger -> FilePath -> Bool -> (AgentLoadReport -> IO ()) -> IO AgentLoadReport
loadAgentsLoud logger dir strictMode afterReport = do
  report@AgentLoadReport {entries} <- loadAgentsReport dir
  traverse_ reportFailure entries
  let loadedCount = length [() | AgentLoaded {} <- entries]
      failedCount = length entries - loadedCount
      summary =
        [ "directory" .= dir,
          "loaded" .= loadedCount,
          "total" .= length entries,
          "failed" .= failedCount
        ]
  if failedCount > 0
    then Log.logError logger "agents.manifest.loaded" summary
    else Log.logInfo logger "agents.manifest.loaded" summary
  -- Persistence and other whole-report effects belong here: after every entry
  -- has been logged, but before strict mode can terminate the process. The
  -- callback receives the same report callers later select from, so no second
  -- directory traversal can observe a different set of files.
  afterReport report
  when (strictMode && failedCount > 0) do
    Log.logError
      logger
      "agents.manifest.strict_refused"
      ["directory" .= dir, "failed" .= failedCount]
    exitFailure
  pure report
  where
    reportFailure = \case
      AgentLoaded {} -> pure ()
      AgentLoadFailed {path, error = LoadError message} ->
        Log.logError
          logger
          "agents.manifest.load_failed"
          ["path" .= path, "error" .= message]

loadedAgents :: AgentLoadReport -> [AgentDecl]
loadedAgents AgentLoadReport {entries} =
  [declaration | AgentLoaded {declaration} <- entries]

-- | Select runnable declarations while retaining single-file load behavior for
-- validation and operator commands. Every explicit disable is visible.
enabledAgentsFromReport :: Log.Logger -> AgentLoadReport -> IO [AgentDecl]
enabledAgentsFromReport logger AgentLoadReport {entries} = do
  traverse_ reportDisabled entries
  pure
    [ declaration
    | AgentLoaded {declaration = declaration@AgentDecl {enabled = True}} <- entries
    ]
  where
    reportDisabled = \case
      AgentLoaded {path, declaration = AgentDecl {name, enabled = False}} ->
        Log.logInfo
          logger
          "agents.manifest.disabled"
          ["agent" .= name, "path" .= path]
      _ -> pure ()

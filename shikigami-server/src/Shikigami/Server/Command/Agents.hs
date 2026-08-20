-- | @shikigami agents list@: the declared-agent inventory.
--
-- Before this command there was no way to ask what this deployment believes it
-- has been told to run. @validate@ answers for one manifest at a time and exits
-- non-zero, which is a gate rather than an inventory; the long-running roles
-- load every manifest at boot but only say so in their own logs. An operator
-- looking at an agent that is not firing had no way to distinguish the three
-- reasons it might not be: the manifest never parsed, it parsed but declares
-- @enabled = False@, or it is loaded and enabled and the problem is elsewhere.
-- This command renders that distinction as a column.
--
-- It reads the filesystem and nothing else — no database, no socket — so it
-- answers on a deployment whose PostgreSQL is down, which is exactly when the
-- question gets asked.
--
-- == Why this does not walk @agents/@ itself
--
-- The traversal and the load report belong to "Shikigami.Agent.Loader", and
-- every long-running role already goes through it. A second traversal here
-- would be a second answer to \"which manifests exist\", and the two would
-- disagree the first time either changed. What this module owns is
-- presentation.
--
-- The report is the reason a failed manifest can be shown at all:
-- 'loadAgentsReport' preserves parse failures as entries rather than skipping
-- them, so @agents/broken.dhall@ appears here instead of silently not existing.
--
-- == The @NAME@ column means two things, and @STATE@ says which
--
-- For a loaded agent it is the declared @name@ field, which is what every other
-- surface — logs, @enqueue-run@, grants — calls that agent, and which need not
-- match its filename. For a failed manifest there is no declared name to print,
-- because nothing parsed, so it is the file's base name. @STATE@ distinguishes
-- the two on every row, and the failure detail below the table names the full
-- path.
module Shikigami.Server.Command.Agents
  ( runAgentsList,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.List (transpose)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    StreamMatch (..),
    Trigger (..),
  )
import Shikigami.Agent.Loader
  ( AgentLoadEntry (..),
    AgentLoadReport (..),
    LoadError (..),
    loadAgentsReport,
  )
import Shikigami.Agent.Run (behaviorKindText)
import Shikigami.App.Config (AppConfig, agentsDirectory)
import System.FilePath (takeBaseName)

-- | @shikigami agents list [--json]@.
--
-- Renders every manifest under the configured agents directory, loaded and
-- failed alike. Exits zero even when a manifest failed to load: this is an
-- inventory, and reporting that something is broken is the command succeeding
-- at its job. @validate@ is the verb that refuses.
runAgentsList :: Bool -> AppConfig -> IO ()
runAgentsList asJson config = do
  AgentLoadReport {entries} <- loadAgentsReport (agentsDirectory config)
  if asJson
    then LazyChar8.putStrLn (Aeson.encode (map entryJson entries))
    else renderTable entries

-- | The human-readable form: one aligned table, then the failure detail.
--
-- Diagnostics are printed below the table rather than in a cell because Dhall's
-- errors are multi-line and precise, and truncating one into a column would
-- destroy the part that says what to fix.
renderTable :: [AgentLoadEntry] -> IO ()
renderTable [] = putStrLn "no manifests found"
renderTable entries = do
  mapM_ (TextIO.putStrLn . padRow widths) rows
  case failures of
    [] -> pure ()
    _ -> do
      putStrLn ""
      mapM_ renderFailure failures
  where
    rows = headerRow : map entryRow entries
    widths = columnWidths rows
    failures = [(path, err) | AgentLoadFailed {path, error = err} <- entries]

    renderFailure (path, LoadError detail) = do
      putStrLn (path <> ":")
      TextIO.putStrLn (indent detail)

    indent = Text.unlines . map ("  " <>) . Text.lines . Text.stripEnd

headerRow :: [Text]
headerRow = ["NAME", "BEHAVIOR", "TRIGGER", "ENABLED", "STATE"]

-- | One row per manifest. A failed manifest has nothing to say in the three
-- middle columns, and says so with @-@ rather than with a blank that reads like
-- a rendering bug.
entryRow :: AgentLoadEntry -> [Text]
entryRow = \case
  AgentLoaded {declaration = decl} ->
    [ name decl,
      behaviorKindText (behavior decl),
      triggerSummary (trigger decl),
      if enabled decl then "yes" else "no",
      "loaded"
    ]
  AgentLoadFailed {path} ->
    [Text.pack (takeBaseName path), "-", "-", "-", "failed"]

-- | A one-line rendering of what makes this agent run.
--
-- Each arm names its kind first, so the column sorts and greps by kind even
-- though the detail after it has a different shape in each case.
triggerSummary :: Trigger -> Text
triggerSummary = \case
  Schedule {cron} -> "schedule " <> cron
  Event {eventType} -> "event " <> eventType
  Stream {match} -> Text.unwords ("stream" : streamMatchParts match)

-- | The constraints a stream match actually sets, in declaration order.
--
-- An unconstrained match renders as @stream *@ rather than as a bare @stream@,
-- because "matches every record" is a real and consequential declaration and
-- should not look like a truncated cell.
streamMatchParts :: StreamMatch -> [Text]
streamMatchParts StreamMatch {verb, source, subjectType, verbs} =
  case parts of
    [] -> ["*"]
    _ -> parts
  where
    parts =
      catMaybes
        [ ("source=" <>) <$> source,
          ("subject=" <>) <$> subjectType,
          ("verb=" <>) <$> verb,
          case verbs of
            [] -> Nothing
            _ -> Just ("verbs=" <> Text.intercalate "," verbs)
        ]

-- | The machine-readable form.
--
-- @state@ is present on every object and is the field a consumer branches on,
-- so a failed entry is a first-class result rather than an absence to be
-- inferred from a missing key.
entryJson :: AgentLoadEntry -> Value
entryJson = \case
  AgentLoaded {path, declaration = decl} ->
    object
      [ "state" .= ("loaded" :: Text),
        "path" .= path,
        "name" .= name decl,
        "behavior" .= behaviorKindText (behavior decl),
        "trigger" .= triggerSummary (trigger decl),
        "enabled" .= enabled decl
      ]
  AgentLoadFailed {path, error = LoadError detail} ->
    object
      [ "state" .= ("failed" :: Text),
        "path" .= path,
        "error" .= detail
      ]

-- | The width each column needs, from the widest cell in it.
--
-- 'transpose' is safe on a ragged list here and every row has the same arity
-- anyway; @maximum@ is total because 'transpose' emits no empty column.
columnWidths :: [[Text]] -> [Int]
columnWidths = map (maximum . map Text.length) . transpose

-- | Pad every cell but the last, so the final column has no trailing spaces.
padRow :: [Int] -> [Text] -> Text
padRow widths cells =
  Text.stripEnd (Text.intercalate "  " (zipWith pad widths cells))
  where
    pad width cell = cell <> Text.replicate (width - Text.length cell) " "

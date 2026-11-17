-- | @shikigami record list@ and @shikigami record check@: the operator's view
-- of the kernel action record.
--
-- Every authority decision and every external effect a run performs is one
-- row in @shikigami.action_record@ (ADR-123). @list@ prints the most recent
-- matching rows, oldest first, either as one greppable line per event or as
-- JSON Lines for scripts. @check@ reads one run's whole record and reports
-- which kernel invariants it shows broken ('checkRun').
module Shikigami.Server.Command.Record
  ( RecordListOptions (..),
    runRecordList,
    RecordCheckOptions (..),
    runRecordCheck,
  )
where

import Control.Monad (unless, when)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Aeson.Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Keiro.Workflow (WorkflowId (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.RunRecord (admittedKind)
import Shikigami.App.Config (AppConfig, revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Record
  ( KindFilter (..),
    RecordEvent (..),
    RecordQuery (..),
    defaultRecordLimit,
    maxRunEvents,
    mkRecordLimit,
    readRecord,
    readRunEvents,
    readRunsWithPayload,
    recordEntry,
    recordErrorText,
    recordKindText,
    renderRecordEvent,
  )
import Shikigami.Record.Invariant (InvariantViolation, RunCheck (..), RunFacts (..), checkRun, invariantOf, renderViolation)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)

data RecordListOptions = RecordListOptions
  { run :: !(Maybe Text),
    refusals :: !Bool,
    kindPrefix :: !(Maybe Text),
    limit :: !(Maybe Int),
    json :: !Bool
  }

-- | @record list [--run ID] [--refusals] [--kind PREFIX] [--limit N] [--json]@.
runRecordList :: RecordListOptions -> AppConfig -> IO ()
runRecordList RecordListOptions {run, refusals, kindPrefix, limit, json} config = do
  recordLimit <- either (die "record list") pure (maybe (Right defaultRecordLimit) mkRecordLimit limit)
  kinds <- case (refusals, kindPrefix) of
    (True, Just _) -> die "record list" "--refusals and --kind are exclusive"
    (True, Nothing) -> pure RefusalsOnly
    (False, Just prefix) -> pure (KindPrefix prefix)
    (False, Nothing) -> pure AllKinds
  connStr <- revealSecretText <$> requireDatabaseUrl "record list" config
  verifyShikigamiMigrations connStr
  withStore (defaultConnectionSettings connStr) \KirokuStore {pool} ->
    readRecord pool RecordQuery {run = WorkflowId <$> run, kinds, limit = recordLimit} >>= \case
      Left failure -> die "record list" (recordErrorText failure)
      Right [] | not json -> putStrLn "no record events"
      Right events
        | json -> mapM_ (LazyChar8.putStrLn . Aeson.encode) events
        | otherwise -> mapM_ (TextIO.putStrLn . renderRecordEvent) events

data RecordCheckOptions = RecordCheckOptions
  { run :: !Text,
    json :: !Bool
  }

-- | @record check --run ID [--json]@: exit 0 when the run's record shows no
-- violation, 1 when it shows one, 2 when the record cannot be read whole.
runRecordCheck :: RecordCheckOptions -> AppConfig -> IO ()
runRecordCheck RecordCheckOptions {run, json} config = do
  connStr <- revealSecretText <$> requireDatabaseUrl "record check" config
  verifyShikigamiMigrations connStr
  withStore (defaultConnectionSettings connStr) \KirokuStore {pool} -> do
    let runId = WorkflowId run
    (events, truncated) <- readRunEvents pool runId >>= either (die "record check" . recordErrorText) pure
    when truncated (dieWith 2 "record check" ("the run has more than " <> Text.pack (show maxRunEvents) <> " events; refusing to check a partial record"))
    when (null events) (dieWith 2 "record check" ("no record events for run " <> run))
    keyAdmissions <- case [key | event <- events, let (kind, payload) = recordEntry event.entry, kind == admittedKind, Just key <- [stringField "idempotencyKey" payload]] of
      key : _ -> readRunsWithPayload pool admittedKind "idempotencyKey" key >>= either (die "record check" . recordErrorText) pure
      [] -> pure [runId]
    let RunCheck {events = count, linkedEffects, unlinkedEffects, violations} = checkRun RunFacts {run = runId, keyAdmissions} events
        held = [label | label <- ["K1", "K2/K3", "K4", "K5", "K6", "K8"], label `notElem` (invariantOf <$> violations)]
    if json
      then
        LazyChar8.putStrLn
          ( Aeson.encode
              ( Aeson.object
                  [ "run" .= run,
                    "events" .= count,
                    "kinds" .= (recordKindText . fst . recordEntry . (.entry) <$> events),
                    "linkedEffects" .= linkedEffects,
                    "unlinkedEffects" .= Aeson.object [(Aeson.Key.fromText kind, Aeson.toJSON n) | (kind, n) <- unlinkedEffects],
                    "held" .= held,
                    "violations" .= (violationValue <$> violations),
                    "k7" .= ("by construction" :: Text)
                  ]
              )
          )
      else do
        TextIO.putStrLn
          ( "record check: "
              <> Text.pack (show count)
              <> " events, "
              <> Text.pack (show linkedEffects)
              <> " effects paired with a decision and a step; "
              <> (if null held then "no invariant holds" else Text.unwords held <> " hold")
              <> " (K7 by construction)"
          )
        mapM_ (\(kind, n) -> TextIO.putStrLn ("  unchecked: " <> Text.pack (show n) <> " " <> kind <> " entries name no action")) unlinkedEffects
        mapM_ (TextIO.putStrLn . ("  violation " <>) . renderViolation) violations
    unless (null violations) exitFailure
  where
    violationValue :: InvariantViolation -> Aeson.Value
    violationValue violation = Aeson.object ["invariant" .= invariantOf violation, "detail" .= renderViolation violation]
    stringField name = \case
      Aeson.Object object | Just (Aeson.String value) <- KeyMap.lookup (Aeson.Key.fromText name) object -> Just value
      _ -> Nothing

dieWith :: Int -> String -> Text -> IO a
dieWith code ctx msg = do
  hPutStrLn stderr (ctx <> ": " <> Text.unpack msg)
  exitWith (ExitFailure code)

die :: String -> Text -> IO a
die ctx msg = do
  hPutStrLn stderr (ctx <> ": " <> Text.unpack msg)
  exitFailure

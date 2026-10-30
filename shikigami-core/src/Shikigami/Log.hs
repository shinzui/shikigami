-- | One JSON object per log line, so that an operator can filter the runtime
-- with @jq@ instead of with @grep@ and a guess.
--
-- Before this module every log line in the runtime was a bare
-- @hPutStrLn stderr@ with an ad-hoc bracket prefix — @[shikigami.worker] ...@,
-- @[stream] ...@, @[sink] ...@ — which cannot be filtered or aggregated by
-- field. This module replaces that with a single structured line:
--
-- > {"ts":"2026-08-05T21:00:00Z","level":"info","event":"worker.job.completed","agent":"heartbeat","run_id":"heartbeat:1"}
--
-- so that @jq -r 'select(.event == "worker.job.completed") | .agent'@ answers a
-- question that previously required reading prose.
--
-- == The vocabulary
--
-- This module owns the observability vocabulary that the rest of the runtime
-- emits against. Plans across several MasterPlans log through it, so drift here
-- is drift everywhere.
--
-- An __event name__ is @component.subject.verb@, all lowercase, dot-separated:
-- @worker.job.dead_lettered@, @stream.record.matched@, @sink.result@. The
-- component says which loop produced the line, the subject says what the line
-- is about, and the verb is past tense because a log line records something
-- that already happened.
--
-- Three __reserved keys__ are written on every line and may not be supplied by
-- the caller: @ts@ (ISO-8601 UTC), @level@, and @event@. A field with one of
-- those names is ignored rather than allowed to overwrite the line's shape,
-- because @jq -r .event@ over the log must never fail or lie.
--
-- The __standard field keys__, used whenever the value is in scope, are:
--
--   * @agent@ — the declared agent's name.
--   * @run_id@ — see "Shikigami.Log.Correlation"; re-exported here.
--   * @call_id@ — likewise, for one call inside a run.
--   * @workflow_id@ — the keiro workflow id, when it is not the run id.
--   * @sink_kind@ — as @Shikigami.Sink.Permission.sinkKindText@ renders it:
--     @KawaDigest@, @KizashiSignal@, @ReiAction@, @DanwaConversation@, or
--     @ChannelEgress@. That renderer already existed and already appears in
--     denial reasons, so log lines reuse it rather than introducing a second
--     spelling of the same five values.
--   * @outcome@ — @delivered@, @denied@, @stubbed@, or @failed@.
--   * @topic@ — the Kafka topic a consumer line is about.
--   * @error@ — a rendered error, when the line reports a failure.
--
-- == Why there is no logging framework here
--
-- The surrounding libraries this runtime is built on — keiro, shibuya, kioku,
-- kiroku — use plain stderr lines plus OpenTelemetry spans for deep
-- diagnostics; none of them uses katip, co-log, or monad-logger. What was
-- missing was /structure/, not a framework, and structure is about a hundred
-- lines over @aeson@, which is already a dependency. Adding a framework would
-- have introduced effect-system friction for no gain. That decision is recorded
-- in @docs\/plans\/28-structured-logging-metrics-and-trace-propagation.md@.
--
-- == A note on @(Aeson..=)@
--
-- Field lists below are written with the qualified operator @Aeson..=@ rather
-- than a bare @(.=)@. "Shikigami.Prelude" re-exports @Control.Lens@, whose own
-- @(.=)@ would otherwise be ambiguous with @aeson@'s at every call site.
module Shikigami.Log
  ( -- * Severity
    Level (..),
    renderLevel,
    parseLevel,

    -- * The logger
    Logger (..),
    newStderrLogger,
    newHandleLogger,
    silentLogger,

    -- * Emitting
    logEvent,
    logDebug,
    logInfo,
    logWarn,
    logError,

    -- * Correlation
    module Shikigami.Log.Correlation,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601Show)
import Shikigami.Log.Correlation

-- 'Level' is hidden because "Shikigami.Prelude" re-exports @Control.Lens@,
-- which has an unrelated internal type of the same name. Call sites normally
-- name a constructor ('Info', 'Warn', …) rather than the type, so this
-- collision stops here.
import Shikigami.Prelude hiding (Level)
import System.IO (BufferMode (LineBuffering), Handle, hSetBuffering, stderr)

-- | How severe a line is. Ordered, so that a logger built with a minimum level
-- drops everything below it.
--
-- The constructor names are the obvious ones. They are data constructors, which
-- occupy a different namespace from types, so @Error@ here does not clash with
-- the @Error@ /type/ that @effectful@ exports. Even so, prefer the 'logInfo',
-- 'logWarn', 'logError', and 'logDebug' helpers at call sites: they keep the
-- constructor out of modules that would rather not think about it.
data Level = Debug | Info | Warn | Error
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The lowercase spelling that appears in the @level@ field.
renderLevel :: Level -> Text
renderLevel = \case
  Debug -> "debug"
  Info -> "info"
  Warn -> "warn"
  Error -> "error"

-- | Read a level from its rendered spelling, case-insensitively. Returns
-- 'Nothing' for anything unrecognized, so a caller reading a level out of
-- configuration can report a bad value rather than silently defaulting.
parseLevel :: Text -> Maybe Level
parseLevel t = case Text.toLower (Text.strip t) of
  "debug" -> Just Debug
  "info" -> Just Info
  "warn" -> Just Warn
  "warning" -> Just Warn
  "error" -> Just Error
  _ -> Nothing

-- | Where lines go, and which ones are worth writing.
--
-- The sink receives one complete line, newline already appended, and is
-- expected to write it in a single operation. That is what keeps two threads
-- logging at once from interleaving half a line each. 'newHandleLogger' honors
-- that; a hand-rolled sink must too.
data Logger = Logger
  { minLevel :: !Level,
    sink :: !(ByteString -> IO ())
  }

-- | A logger writing to standard error, dropping anything below the given
-- level. Standard error is set line-buffered so that a line is not stuck in a
-- buffer when an operator is watching a worker start up.
newStderrLogger :: Level -> IO Logger
newStderrLogger = newHandleLogger stderr

-- | A logger writing to an arbitrary handle. Useful in tests, which point one
-- at a temporary file and then parse what came out.
--
-- Lines are written with 'BS.hPut', which emits the already-UTF-8 bytes
-- @aeson@ produced and holds the handle's lock for the whole write.
newHandleLogger :: Handle -> Level -> IO Logger
newHandleLogger handle level = do
  hSetBuffering handle LineBuffering
  pure Logger {minLevel = level, sink = BS.hPut handle}

-- | A logger that writes nothing, for tests and for the rare caller that has no
-- sensible place to send lines. It still type-checks every call site, so a
-- module wired with it is one field away from being observable.
silentLogger :: Logger
silentLogger = Logger {minLevel = Error, sink = \_ -> pure ()}

-- | Emit one structured line, unless the level is below the logger's minimum.
--
-- The reserved keys @ts@, @level@, and @event@ are written last and therefore
-- win over anything of the same name in @fields@; see the module header.
logEvent :: (MonadIO m) => Logger -> Level -> Text -> [Pair] -> m ()
logEvent logger level event fields
  | level < (.minLevel) logger = pure ()
  | otherwise = liftIO do
      now <- getCurrentTime
      let line =
            Aeson.object
              ( fields
                  <> [ "ts" Aeson..= iso8601Show now,
                       "level" Aeson..= renderLevel level,
                       "event" Aeson..= event
                     ]
              )
      (.sink) logger (LBS.toStrict (Aeson.encode line) <> "\n")

-- | 'logEvent' at 'Debug'.
logDebug :: (MonadIO m) => Logger -> Text -> [Pair] -> m ()
logDebug logger = logEvent logger Debug

-- | 'logEvent' at 'Info'.
logInfo :: (MonadIO m) => Logger -> Text -> [Pair] -> m ()
logInfo logger = logEvent logger Info

-- | 'logEvent' at 'Warn'.
logWarn :: (MonadIO m) => Logger -> Text -> [Pair] -> m ()
logWarn logger = logEvent logger Warn

-- | 'logEvent' at 'Error'.
logError :: (MonadIO m) => Logger -> Text -> [Pair] -> m ()
logError logger = logEvent logger Error

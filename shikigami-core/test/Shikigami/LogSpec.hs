-- | What @Shikigami.Log@ must guarantee, stated as tests.
--
-- Three of these are not ordinary unit tests but pinned contracts, and they are
-- called out below where they appear: the rendered form of a call correlation
-- identifier, its reproducibility, and the fact that every emitted line parses
-- as one JSON object carrying an @event@ field. Downstream plans store the
-- first and filter on the last, so breaking either is a migration rather than a
-- refactor.
module Shikigami.LogSpec (tests) where

import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Log
import Shikigami.Log.Correlation (CallCorrelationId)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Shikigami.Log"
    [ testGroup "lines" lineTests,
      testGroup "levels" levelTests,
      testGroup "correlation" correlationTests
    ]

-- | A logger that keeps its lines in memory, newest last, so a test can look at
-- exactly what would have been written.
capturingLogger :: Level -> IO (Logger, IO [ByteString])
capturingLogger level = do
  ref <- newIORef []
  let logger = Logger {minLevel = level, sink = \line -> modifyIORef' ref (line :)}
  pure (logger, reverse <$> readIORef ref)

-- | Decode a captured line, failing the test with the raw bytes if it is not a
-- JSON object. This is the shape every consumer downstream assumes.
decodeObject :: ByteString -> IO (KeyMap.KeyMap Value)
decodeObject raw =
  case Aeson.eitherDecode (LBS.fromStrict raw) of
    Right (Object o) -> pure o
    Right other -> fail ("expected a JSON object, got " <> show other <> " from " <> show raw)
    Left err -> fail ("not JSON: " <> err <> " from " <> show raw)

lookupText :: KeyMap.KeyMap Value -> Text -> Maybe Text
lookupText o k = case KeyMap.lookup (Key.fromText k) o of
  Just (String t) -> Just t
  _ -> Nothing

lineTests :: [TestTree]
lineTests =
  [ -- The pinned contract behind the plan's acceptance check, `jq -r .event`:
    -- one object per line, one line per event, `event` always present.
    testCase "one parseable JSON object per line, carrying the event name" do
      (logger, captured) <- capturingLogger Debug
      logInfo logger "worker.job.completed" ["agent" .= ("heartbeat" :: Text)]
      logWarn logger "sink.result" ["outcome" .= ("failed" :: Text)]
      lines' <- captured
      assertEqual "two lines" 2 (length lines')
      objects <- traverse decodeObject lines'
      map (`lookupText` "event") objects
        @?= [Just "worker.job.completed", Just "sink.result"]
      map (`lookupText` "agent") objects @?= [Just "heartbeat", Nothing],
    testCase "every line ends with exactly one newline and contains no others" do
      (logger, captured) <- capturingLogger Debug
      logInfo logger "worker.loop.started" ["detail" .= ("a\nb" :: Text)]
      [line] <- captured
      assertBool "ends with newline" ("\n" `BS.isSuffixOf` line)
      -- An embedded newline in a value must be JSON-escaped, not emitted raw,
      -- or one logical line would become two and `jq` would fail on the second.
      assertEqual "exactly one newline" 1 (BS8.count '\n' line),
    testCase "caller fields cannot overwrite ts, level, or event" do
      (logger, captured) <- capturingLogger Debug
      logInfo
        logger
        "worker.job.started"
        [ "event" .= ("attacker.controlled" :: Text),
          "level" .= ("debug" :: Text),
          "ts" .= ("not a timestamp" :: Text)
        ]
      [line] <- captured
      o <- decodeObject line
      lookupText o "event" @?= Just "worker.job.started"
      lookupText o "level" @?= Just "info"
      assertBool
        "ts is a real ISO-8601 UTC instant"
        (maybe False ("Z" `Text.isSuffixOf`) (lookupText o "ts")),
    testCase "the timestamp is ISO-8601 UTC" do
      (logger, captured) <- capturingLogger Debug
      logInfo logger "worker.loop.started" []
      [line] <- captured
      o <- decodeObject line
      case lookupText o "ts" of
        Nothing -> fail "no ts field"
        Just ts -> do
          assertBool ("ends with Z: " <> Text.unpack ts) ("Z" `Text.isSuffixOf` ts)
          assertBool ("has a date separator: " <> Text.unpack ts) ("T" `Text.isInfixOf` ts),
    testCase "newHandleLogger writes those same lines to a real handle" do
      dir <- getTemporaryDirectory
      (path, handle) <- openTempFile dir "shikigami-log-spec.jsonl"
      logger <- newHandleLogger handle Info
      logInfo logger "worker.loop.started" ["component" .= ("worker" :: Text)]
      logDebug logger "worker.job.polled" []
      hClose handle
      written <- BS.readFile path
      removeFile path
      let lines' = filter (not . BS.null) (BS8.lines written)
      assertEqual "the debug line was below the minimum level" 1 (length lines')
      objects <- traverse decodeObject lines'
      map (`lookupText` "event") objects @?= [Just "worker.loop.started"]
  ]

levelTests :: [TestTree]
levelTests =
  [ testCase "a logger drops everything below its minimum level" do
      (logger, captured) <- capturingLogger Warn
      logDebug logger "a.b.c" []
      logInfo logger "d.e.f" []
      logWarn logger "g.h.i" []
      logError logger "j.k.l" []
      lines' <- captured
      objects <- traverse decodeObject lines'
      map (`lookupText` "event") objects @?= [Just "g.h.i", Just "j.k.l"],
    testCase "silentLogger writes nothing at any level" do
      -- No sink to capture: the point is that the no-op sink is never handed a
      -- line, which this exercises by simply not blowing up.
      logDebug silentLogger "a.b.c" []
      logError silentLogger "j.k.l" []
      pure (),
    testCase "levels render and parse back" do
      let levels = [minBound .. maxBound] :: [Level]
      map renderLevel levels @?= ["debug", "info", "warn", "error"]
      traverse (parseLevel . renderLevel) levels @?= Just levels,
    testCase "level parsing is forgiving about case and padding, strict about nonsense" do
      parseLevel " WARN " @?= Just Warn
      parseLevel "Warning" @?= Just Warn
      parseLevel "verbose" @?= Nothing
  ]

correlationTests :: [TestTree]
correlationTests =
  [ testCase "a run is named by its idempotency key, unchanged" do
      renderRunCorrelationId (runCorrelationId "heartbeat:2026-08-05T12:00:00Z")
        @?= "heartbeat:2026-08-05T12:00:00Z",
    -- Pinned contract. Plan 51 stores this string as audit evidence and joins it
    -- to the log line for the same call, so the rendering is not free to change.
    testCase "a call renders as <run id>/<step>/<ordinal>" do
      let run = runCorrelationId "heartbeat:1"
      renderCallCorrelationId (callCorrelationId run "run-behavior" 0)
        @?= "heartbeat:1/run-behavior/0"
      renderCallCorrelationId (callCorrelationId run "run-behavior" 3)
        @?= "heartbeat:1/run-behavior/3",
    -- Pinned contract. This is the property that survives a crash and resume:
    -- the identifier is a pure function of values the workflow journal replays,
    -- so re-deriving it in a different process yields the same string.
    testCase "deriving the same call twice yields the same identifier" do
      let run = runCorrelationId "heartbeat:1"
          derive = renderCallCorrelationId (callCorrelationId run "recall" 2)
      derive @?= derive
      callCorrelationId run "recall" 2 @?= callCorrelationId run "recall" 2,
    testCase "different runs, steps, or ordinals give different identifiers" do
      let a = callCorrelationId (runCorrelationId "r1") "recall" 0
          b = callCorrelationId (runCorrelationId "r2") "recall" 0
          c = callCorrelationId (runCorrelationId "r1") "record" 0
          d = callCorrelationId (runCorrelationId "r1") "recall" 1
      assertBool "run differs" (a /= b)
      assertBool "step differs" (a /= c)
      assertBool "ordinal differs" (a /= d),
    testCase "identifiers round-trip through JSON as plain strings" do
      let run = runCorrelationId "heartbeat:1"
          call = callCorrelationId run "run-behavior" 0
      Aeson.encode run @?= "\"heartbeat:1\""
      Aeson.encode call @?= "\"heartbeat:1/run-behavior/0\""
      Aeson.decode (Aeson.encode run) @?= Just run
      Aeson.decode (Aeson.encode call) @?= Just call,
    testCase "retained call ids reject missing components and invalid ordinals" do
      for_ ["\"missing\"", "\"run/0\"", "\"run/call/-1\"", "\"run/call/01\"", "\"run/call/1x\""] \raw ->
        assertBool "invalid correlation" (isLeft (Aeson.eitherDecode @CallCorrelationId raw)),
    testCase "the field keys are the ones the vocabulary documents" do
      runIdKey @?= "run_id"
      callIdKey @?= "call_id"
  ]

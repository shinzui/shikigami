module Shikigami.RecordSpec (tests) where

import Data.Aeson (Value (..), object, (.=))
import Data.Bits ((.&.))
import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Keiro.Workflow (WorkflowId (..))
import Shikigami.Record
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removePathForcibly)
import System.FilePath ((</>))
import System.Posix.Files (fileMode, getFileStatus)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Record"
    [ testCase "record kinds are checked dotted names" do
        assertBool "two segments" (isRight (mkRecordKind "authority.decided"))
        assertBool "hyphens and digits" (isRight (mkRecordKind "coding-agent.attempt2.settled"))
        assertBool "one segment" (isLeft (mkRecordKind "authority"))
        assertBool "uppercase" (isLeft (mkRecordKind "Authority.decided"))
        assertBool "empty segment" (isLeft (mkRecordKind "authority..decided"))
        assertBool "leading digit" (isLeft (mkRecordKind "authority.1decided"))
        assertBool "longer than 64" (isLeft (mkRecordKind ("a." <> Text.replicate 63 "b"))),
      testCase "a payload above 8 KiB is refused" do
        let large = object ["blob" .= Text.replicate 9000 "x"]
        case mkRecordEntry decided large of
          Left (RecordEntryTooLarge size) -> assertBool "reports the size" (size > maxRecordPayloadBytes)
          other -> assertFailure ("expected a size refusal, got " <> show other)
        assertBool "small payloads pass" (isRight (mkRecordEntry decided (object ["decision" .= ("allowed" :: Text)]))),
      testCase "the file store is mode 0600, append-only and readable by query" do
        temporary <- getTemporaryDirectory
        let directory = temporary </> "shikigami-record-spec"
            path = directory </> "nested" </> "record.jsonl"
        removePathForcibly directory
        createDirectoryIfMissing True directory
        record <- either (fail . show) pure =<< fileRecord path
        mapM_ (\e -> record.append e >>= either (fail . show) pure) [event "run-1" "allowed", event "run-1" "unavailable", event "run-2" "allowed"]
        mode <- fileMode <$> getFileStatus path
        (mode .&. 0o777) @?= 0o600
        lines' <- lines <$> readFile path
        length lines' @?= 3
        reopened <- either (fail . show) pure =<< fileRecord path
        _ <- reopened.append (event "run-2" "denied")
        (length . lines <$> readFile path) >>= (@?= 4)
        everything <- readRecordFile path RecordQuery {run = Nothing, kinds = AllKinds, limit = defaultRecordLimit}
        fmap length everything @?= Right 4
        runOne <- readRecordFile path RecordQuery {run = Just (WorkflowId "run-1"), kinds = AllKinds, limit = defaultRecordLimit}
        fmap length runOne @?= Right 2
        refusals <- readRecordFile path RecordQuery {run = Nothing, kinds = RefusalsOnly, limit = defaultRecordLimit}
        fmap length refusals @?= Right 2
        latest <- readRecordFile path RecordQuery {run = Nothing, kinds = AllKinds, limit = either (error . Text.unpack) id (mkRecordLimit 1)}
        fmap (fmap (.run)) latest @?= Right [Just (WorkflowId "run-2")]
        removePathForcibly directory
    ]

decided :: RecordKind
decided = either (error . Text.unpack) id (mkRecordKind "authority.decided")

event :: Text -> Text -> RecordEvent
event runId decision =
  RecordEvent
    { at = UTCTime (fromGregorian 2026 11 15) 0,
      run = Just (WorkflowId runId),
      principal = "agent_test",
      tier = unspecifiedTier,
      agent = Nothing,
      entry = either (error . show) id (mkRecordEntry decided (object ["decision" .= decision, "detail" .= Null]))
    }

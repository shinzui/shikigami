module Shikigami.DirectoryStoreSpec (tests) where

import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Loader (AgentLoadReport (..), loadAgentsReport)
import Shikigami.Directory.Store
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "directory store"
    [ testCase "complete load reports persist successes and full failures" $
        withPool \pool -> do
          report <- loadAgentsReport "../agents"
          expectRight "recordLoadStates" =<< recordLoadStates pool "../agents" report
          rows <- queryLoadStates pool
          length rows @?= length (entries report)
          case find (Text.isSuffixOf "/broken.dhall" . manifestPathOf) rows of
            Nothing -> assertFailure "broken.dhall has no durable load-state row"
            Just (_, agent, status, enabled, problem) -> do
              agent @?= Nothing
              status @?= "failed"
              enabled @?= Nothing
              assertBool "the Dhall failure is absent" (maybe False (not . Text.null) problem),
      testCase "repeat writes are idempotent and stale paths are reconciled" $
        withPool \pool -> do
          report@AgentLoadReport {entries} <- loadAgentsReport "../agents"
          expectRight "first recordLoadStates" =<< recordLoadStates pool "../agents" report
          expectRight "repeat recordLoadStates" =<< recordLoadStates pool "../agents" report
          countLoadStates pool >>= (@?= fromIntegral (length entries))
          let reduced = AgentLoadReport {entries = take 1 entries}
          expectRight "reduced recordLoadStates" =<< recordLoadStates pool "../agents" reduced
          countLoadStates pool >>= (@?= 1),
      testCase "run skips are idempotent per stage and key" $
        withPool \pool -> do
          let triggerSkip =
                RunSkip
                  { agentName = "heartbeat",
                    principalId = Just "agent_heartbeat",
                    stage = TriggerStage,
                    detail = "schedule",
                    reason = "principal lifecycle is paused",
                    idempotencyKey = "schedule:heartbeat:2026-08-23T00:00:00Z"
                  }
              drainSkip = triggerSkip {stage = DrainStage, detail = "agent-run"}
          expectRight "first trigger skip" =<< recordRunSkip pool triggerSkip
          expectRight "repeat trigger skip" =<< recordRunSkip pool triggerSkip
          countRunSkips pool TriggerStage (idempotencyKeyOf triggerSkip) >>= (@?= 1)
          expectRight "same key at drain" =<< recordRunSkip pool drainSkip
          countAllRunSkips pool >>= (@?= 2)
    ]

type LoadStateRow = (Text, Maybe Text, Text, Maybe Bool, Maybe Text)

withPool :: (Pool -> IO a) -> IO a
withPool use =
  withShikigamiMigratedDatabase \connectionString ->
    withStore (defaultConnectionSettings connectionString) (use . pool)

queryLoadStates :: Pool -> IO [LoadStateRow]
queryLoadStates pool =
  expectPoolRight "query load states"
    =<< Pool.use pool (Session.statement () loadStatesStatement)

countLoadStates :: Pool -> IO Int64
countLoadStates pool =
  expectPoolRight "count load states"
    =<< Pool.use pool (Session.statement () countLoadStatesStatement)

countRunSkips :: Pool -> SkipStage -> Text -> IO Int64
countRunSkips pool stage key =
  expectPoolRight "count run skips"
    =<< Pool.use pool (Session.statement (stageText stage, key) countRunSkipsStatement)

countAllRunSkips :: Pool -> IO Int64
countAllRunSkips pool =
  expectPoolRight "count all run skips"
    =<< Pool.use pool (Session.statement () countAllRunSkipsStatement)

loadStatesStatement :: Statement () [LoadStateRow]
loadStatesStatement =
  preparable
    """
    SELECT manifest_path, agent_name, status, enabled, error
      FROM shikigami.agent_load_state
     ORDER BY manifest_path
    """
    Encoders.noParams
    ( Decoders.rowList
        ( (,,,,)
            <$> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nullable Decoders.bool)
            <*> Decoders.column (Decoders.nullable Decoders.text)
        )
    )

countLoadStatesStatement :: Statement () Int64
countLoadStatesStatement =
  preparable
    "SELECT count(*) FROM shikigami.agent_load_state"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

countRunSkipsStatement :: Statement (Text, Text) Int64
countRunSkipsStatement =
  preparable
    "SELECT count(*) FROM shikigami.run_skips WHERE stage = $1 AND idempotency_key = $2"
    ( (fst >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (snd >$< Encoders.param (Encoders.nonNullable Encoders.text))
    )
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

countAllRunSkipsStatement :: Statement () Int64
countAllRunSkipsStatement =
  preparable
    "SELECT count(*) FROM shikigami.run_skips"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

manifestPathOf :: LoadStateRow -> Text
manifestPathOf (manifestPath, _, _, _, _) = manifestPath

idempotencyKeyOf :: RunSkip -> Text
idempotencyKeyOf RunSkip {idempotencyKey} = idempotencyKey

stageText :: SkipStage -> Text
stageText = \case
  TriggerStage -> "trigger"
  DrainStage -> "drain"

expectRight :: String -> Either Text a -> IO a
expectRight label = either (assertFailure . ((label <> ": ") <>) . Text.unpack) pure

expectPoolRight :: String -> Either Pool.UsageError a -> IO a
expectPoolRight label = either (assertFailure . ((label <> ": ") <>) . show) pure

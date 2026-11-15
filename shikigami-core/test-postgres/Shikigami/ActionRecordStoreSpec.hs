module Shikigami.ActionRecordStoreSpec (tests) where

import Control.Exception (bracket)
import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Hasql.Connection.Settings qualified as ConnectionSettings
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Keiro.Workflow (WorkflowId (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Authority (AuthorityFailure (..), allowAllForTests, denyAll, invokeToolAction, recordedIn, scopeToRun)
import Shikigami.Log qualified as Log
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Record
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "ActionRecordStore"
    [ testCase "appended events read back oldest first, filtered by run, kind and refusal" $ withPool databaseFixture \pool -> do
        let record = postgresRecord pool
        mapM_
          (\(offset, runId, kind, decision) -> record.append (event offset runId kind decision) >>= either (assertFailure . show) pure)
          [ (0, "run-1", "authority.decided", "allowed"),
            (1, "run-1", "authority.decided", "unavailable"),
            (2, "run-2", "authority.decided", "denied"),
            (3, "run-1", "output.delivered", "allowed")
          ]
        everything <- readRecord pool (query Nothing AllKinds 50)
        fmap (fmap (.at)) everything @?= Right [at' 0, at' 1, at' 2, at' 3]
        runOne <- readRecord pool (query (Just "run-1") AllKinds 50)
        fmap length runOne @?= Right 3
        authority <- readRecord pool (query Nothing (KindPrefix "authority.") 50)
        fmap length authority @?= Right 3
        refusals <- readRecord pool (query Nothing RefusalsOnly 50)
        fmap (fmap (.run)) refusals @?= Right [Just (WorkflowId "run-1"), Just (WorkflowId "run-2")]
        latestTwo <- readRecord pool (query Nothing AllKinds 2)
        fmap (fmap (.at)) latestTwo @?= Right [at' 2, at' 3],
      testCase "a recorded authority leaves one row per decision scoped to its run" $ withPool databaseFixture \pool -> do
        agent <- either (fail . Text.unpack) pure (mkAgentName "triage-note")
        action <- either (fail . Text.unpack) pure (invokeToolAction "shikigami.workspace" "1" "admit-digest")
        let principal = declarationCoordinate "agent_01h000000000000000triage"
            refusing = scopeToRun (Just (WorkflowId "run-denied")) agent (recordedIn Log.silentLogger Nothing pool denyAll)
            allowing = scopeToRun (Just (WorkflowId "run-allowed")) agent (recordedIn Log.silentLogger Nothing pool allowAllForTests)
        _ <- refusing.decide principal action
        _ <- allowing.decide principal action
        denied <- readRecord pool (query (Just "run-denied") AllKinds 50)
        fmap (fmap (fmap recordKindText . Just . fst . recordEntry . (.entry))) denied @?= Right [Just "authority.decided"]
        fmap (fmap (.agent)) denied @?= Right [Just agent]
        allowed <- readRecord pool (query (Just "run-allowed") RefusalsOnly 50)
        fmap length allowed @?= Right 0,
      testCase "an unreachable record store refuses an action the authority would allow" $
        withShikigamiFreshDatabase databaseFixture \connStr -> do
          -- The same server with a database that does not exist: every
          -- append fails as it would after PostgreSQL stops mid-run.
          let unreachable = ConnectionSettings.connectionString connStr <> ConnectionSettings.dbname "shikigami_record_store_absent"
          bracket (Pool.acquire (PoolConfig.settings [PoolConfig.staticConnectionSettings unreachable])) Pool.release \pool -> do
            action <- either (fail . Text.unpack) pure (invokeToolAction "shikigami.workspace" "1" "admit-digest")
            result <- (recordedIn Log.silentLogger Nothing pool allowAllForTests).decide (declarationCoordinate "agent_test") action
            case result of
              Left (AuthorityUnavailable detail) -> assertBool "names the record" ("action record unavailable" `Text.isPrefixOf` detail)
              other -> assertFailure ("expected a refusal, got " <> show other)
    ]

withPool :: DatabaseFixture -> (Pool -> IO a) -> IO a
withPool databaseFixture use =
  withShikigamiFreshDatabase databaseFixture \connStr ->
    withStore (defaultConnectionSettings connStr) (use . (.pool))

query :: Maybe Text -> KindFilter -> Int -> RecordQuery
query runId kinds n = RecordQuery {run = WorkflowId <$> runId, kinds, limit = either (error . Text.unpack) id (mkRecordLimit n)}

at' :: Integer -> UTCTime
at' offset = addUTCTime (fromInteger offset) (UTCTime (fromGregorian 2026 11 15) 0)

event :: Integer -> Text -> Text -> Text -> RecordEvent
event offset runId kindText decision =
  RecordEvent
    { at = at' offset,
      run = Just (WorkflowId runId),
      principal = "agent_test",
      tier = unspecifiedTier,
      agent = Nothing,
      entry = either (error . show) id (mkRecordEntry (either (error . Text.unpack) id (mkRecordKind kindText)) (object ["decision" .= decision]))
    }

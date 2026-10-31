module Shikigami.DirectoryStoreSpec (tests) where

import Contravariant.Extras (contrazip2)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
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
import Hasql.Transaction.Sessions qualified as Transactions
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Loader (AgentLoadReport (..), loadAgentsReport)
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Run.Key (RunKey, parseRunKey, runKeyText)
import Shikigami.Directory.Store
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "directory store"
    [ testCase "corrupt skips refuse whole lists and roll back ignored refusals" (corruptSkips databaseFixture),
      testCase "complete load reports persist successes and full failures" $
        (withPool databaseFixture) \pool -> do
          report <- loadAgentsReport "../agents"
          expectRight "recordLoadStates" =<< recordLoadStates pool "../agents" report
          rows <- queryLoadStates pool
          length rows @?= length ((.entries) report)
          case find (Text.isSuffixOf "/broken.dhall" . manifestPathOf) rows of
            Nothing -> assertFailure "broken.dhall has no durable load-state row"
            Just (_, agent, status, enabled, problem) -> do
              agent @?= Nothing
              status @?= "failed"
              enabled @?= Nothing
              assertBool "the Dhall failure is absent" (maybe False (not . Text.null) problem),
      testCase "repeat writes are idempotent and stale paths are reconciled" $
        (withPool databaseFixture) \pool -> do
          report@AgentLoadReport {entries} <- loadAgentsReport "../agents"
          expectRight "first recordLoadStates" =<< recordLoadStates pool "../agents" report
          expectRight "repeat recordLoadStates" =<< recordLoadStates pool "../agents" report
          countLoadStates pool >>= (@?= fromIntegral (length entries))
          let reduced = AgentLoadReport {entries = take 1 entries}
          expectRight "reduced recordLoadStates" =<< recordLoadStates pool "../agents" reduced
          countLoadStates pool >>= (@?= 1),
      testCase "run skips are idempotent per stage and key" $
        (withPool databaseFixture) \pool -> do
          let triggerSkip =
                RunSkip
                  { agentName = fixtureAgentName "heartbeat",
                    principalId = Just "agent_heartbeat",
                    stage = TriggerStage,
                    detail = "schedule",
                    reason = "principal lifecycle is paused",
                    idempotencyKey = fixtureRunKey "schedule:heartbeat:2026-08-23T00:00:00Z"
                  }
              drainSkip = (triggerSkip & #stage .~ (DrainStage) & #detail .~ ("agent-run"))
          expectRight "first trigger skip" =<< recordRunSkip pool triggerSkip
          expectRight "repeat trigger skip" =<< recordRunSkip pool triggerSkip
          countRunSkips pool TriggerStage (idempotencyKeyOf triggerSkip) >>= (@?= 1)
          expectRight "same key at drain" =<< recordRunSkip pool drainSkip
          countAllRunSkips pool >>= (@?= 2)
    ]

type LoadStateRow = (Text, Maybe Text, Text, Maybe Bool, Maybe Text)

withPool :: DatabaseFixture -> (Pool -> IO a) -> IO a
withPool databaseFixture use =
  (withShikigamiFreshDatabase databaseFixture) \connectionString ->
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
    ( contrazip2
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Encoders.param (Encoders.nonNullable Encoders.text))
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
idempotencyKeyOf RunSkip {idempotencyKey} = runKeyText idempotencyKey

stageText :: SkipStage -> Text
stageText = \case
  TriggerStage -> "trigger"
  DrainStage -> "drain"

expectRight :: String -> Either Text a -> IO a
expectRight label = either (assertFailure . ((label <> ": ") <>) . Text.unpack) pure

expectPoolRight :: String -> Either Pool.UsageError a -> IO a
expectPoolRight label = either (assertFailure . ((label <> ": ") <>) . show) pure

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

fixtureRunKey :: Text -> RunKey
fixtureRunKey = either (error . show) id . parseRunKey

-- Start from complete public writes; corrupt exactly one retained member beside
-- another valid member. No decoder error may turn it into a shorter list.
corruptSkips :: DatabaseFixture -> IO ()
corruptSkips fixture = withPool fixture \pool -> do
  let original = RunSkip (fixtureAgentName "heartbeat") (Just "agent_heartbeat") DrainStage "agent-run" "paused" (fixtureRunKey "corrupt-control")
      sibling = original & #stage .~ TriggerStage & #idempotencyKey .~ fixtureRunKey "valid-sibling"
      transaction action = expectPoolRight "transaction" =<< Pool.use pool (Transactions.transaction Transactions.ReadCommitted Transactions.Write action)
      sql query = expectPoolRight "SQL" =<< Pool.use pool (Session.statement () (preparable query Encoders.noParams Decoders.noResult))
  listRunSkips pool >>= (@?= Right [])
  lookupDrainSkip pool original.agentName original.idempotencyKey >>= (@?= Right Nothing)
  expectRight "write original" =<< recordRunSkip pool original
  expectRight "write sibling" =<< recordRunSkip pool sibling
  listRunSkips pool >>= (@?= Right [original, sibling])
  lookupDrainSkip pool original.agentName original.idempotencyKey >>= (@?= Right (Just original))
  sql "ALTER TABLE shikigami.run_skips DROP CONSTRAINT run_skips_stage_check"
  let mutations =
        [ ("UPDATE shikigami.run_skips SET agent_name='' WHERE idempotency_key='corrupt-control'", "UPDATE shikigami.run_skips SET agent_name='heartbeat' WHERE idempotency_key='corrupt-control'", False),
          ("UPDATE shikigami.run_skips SET idempotency_key='' WHERE idempotency_key='corrupt-control'", "UPDATE shikigami.run_skips SET idempotency_key='corrupt-control' WHERE idempotency_key=''", False),
          ("UPDATE shikigami.run_skips SET stage='broken' WHERE idempotency_key='corrupt-control'", "UPDATE shikigami.run_skips SET stage='drain' WHERE idempotency_key='corrupt-control'", False),
          ("UPDATE shikigami.run_skips SET principal_id='' WHERE idempotency_key='corrupt-control'", "UPDATE shikigami.run_skips SET principal_id='agent_heartbeat' WHERE idempotency_key='corrupt-control'", True)
        ]
  -- A principal is external text under the existing contract, including empty
  -- text. That positive control prevents inventing a new identity admission rule.
  mapM_
    ( \(corrupt, repair, admitted) -> do
        sql corrupt
        if admitted
          then do
            rows <- expectRight "external principal control" =<< listRunSkips pool
            rows @?= [original & #principalId .~ Just "", sibling]
          else do
            listRunSkips pool >>= (@?= Left "corrupt retained directory run skip")
            ignored <- transaction do
              recordRunSkipTx (original & #idempotencyKey .~ fixtureRunKey "must-rollback")
              result <- listRunSkipsTx
              recordRunSkipTx (original & #idempotencyKey .~ fixtureRunKey "also-rollback")
              pure result
            ignored @?= Left "corrupt retained directory run skip"
            countAllRunSkips pool >>= (@?= 2)
        sql repair
        listRunSkips pool >>= (@?= Right [original, sibling])
    )
    mutations
  sql "ALTER TABLE shikigami.run_skips RENAME TO run_skips_unavailable"
  unavailable <- listRunSkips pool
  case unavailable of
    Left err -> assertBool "SQL failure remains distinct" (err /= "corrupt retained directory run skip")
    Right _ -> assertFailure "SQL failure was hidden"
  unavailableLookup <- lookupDrainSkip pool original.agentName original.idempotencyKey
  case unavailableLookup of
    Left err -> assertBool "lookup SQL failure remains distinct" (err /= "corrupt retained directory run skip")
    Right _ -> assertFailure "lookup SQL failure was hidden"
  sql "ALTER TABLE shikigami.run_skips_unavailable RENAME TO run_skips"
  lookupDrainSkip pool original.agentName original.idempotencyKey >>= (@?= Right (Just original))

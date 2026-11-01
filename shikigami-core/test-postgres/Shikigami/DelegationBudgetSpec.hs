module Shikigami.DelegationBudgetSpec (tests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Monad (replicateM)
import Data.Either (rights)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Keiro.Workflow (WorkflowId (..))
import Kiroku.Store.Connection (defaultConnectionSettings)
import Shikigami.Agent.Decl (DelegationBudget, mkDelegationBudget)
import Shikigami.Agent.Delegate.Context (DelegationBudgetId)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Delegation.BudgetStore
  ( BatchReservationResult (..),
    BudgetReservationError (..),
    ReservationResult (..),
    delegationBudgetIdFor,
    reservationCount,
    reserveDelegationSlot,
    reserveDelegationSlots,
  )
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "DelegationBudget"
    [ testCase "replay reserves a deterministic child only once" (replayIsIdempotent databaseFixture),
      testCase "an oversized batch reserves no child" (batchExhaustionIsAtomic databaseFixture),
      testCase "replaying a batch consumes no additional slots" (batchReplayIsIdempotent databaseFixture),
      testCase "concurrent branches cannot overspend the root limit" (concurrentLimit databaseFixture),
      testCase "a descendant cannot invent a missing root ledger" (missingLedger databaseFixture)
    ]

replayIsIdempotent :: DatabaseFixture -> IO ()
replayIsIdempotent databaseFixture =
  (withFixture databaseFixture) \appEnv -> do
    let root = WorkflowId "budget-root-replay"
        budgetId = delegationBudgetIdFor root
        child = WorkflowId "budget-child-replay"
    first <- reserve appEnv budgetId (Just (root, budget 1)) child
    second <- reserve appEnv budgetId Nothing child
    assertEqual "first occurrence consumes one slot" (Right DelegationSlotReserved) first
    assertEqual "same child id is replay success" (Right DelegationSlotAlreadyReserved) second

batchExhaustionIsAtomic :: DatabaseFixture -> IO ()
batchExhaustionIsAtomic databaseFixture =
  (withFixture databaseFixture) \appEnv -> do
    let root = WorkflowId "budget-root-atomic-batch"
        budgetId = delegationBudgetIdFor root
        firstChild = WorkflowId "budget-batch-first"
        secondChild = WorkflowId "budget-batch-second"
    rejected <- reserveBatch appEnv budgetId (Just (root, budget 1)) (firstChild :| [secondChild])
    assertEqual "the complete oversized batch is rejected" (Right DelegationBatchExhausted) rejected
    firstAfterRejection <- reserve appEnv budgetId Nothing firstChild
    secondAfterFirst <- reserve appEnv budgetId Nothing secondChild
    assertEqual "the failed batch left its first child unreserved" (Right DelegationSlotReserved) firstAfterRejection
    assertEqual "the failed batch consumed no hidden slot" (Right DelegationSlotsExhausted) secondAfterFirst

batchReplayIsIdempotent :: DatabaseFixture -> IO ()
batchReplayIsIdempotent databaseFixture =
  (withFixture databaseFixture) \appEnv -> do
    let root = WorkflowId "budget-root-batch-replay"
        budgetId = delegationBudgetIdFor root
        children = WorkflowId "budget-batch-replay-first" :| [WorkflowId "budget-batch-replay-second"]
    first <- reserveBatch appEnv budgetId (Just (root, budget 2)) children
    second <- reserveBatch appEnv budgetId Nothing children
    assertEqual
      "the first batch consumes both slots together"
      (Right (DelegationBatchReserved (reservationCount 2) (reservationCount 0)))
      first
    assertEqual
      "the replay recognizes both reservations without spending"
      (Right (DelegationBatchReserved (reservationCount 0) (reservationCount 2)))
      second

concurrentLimit :: DatabaseFixture -> IO ()
concurrentLimit databaseFixture =
  (withFixture databaseFixture) \appEnv -> do
    let root = WorkflowId "budget-root-concurrent"
        budgetId = delegationBudgetIdFor root
        children = [WorkflowId ("budget-child-" <> Text.pack (show ordinal)) | ordinal <- [1 :: Int .. 10]]
    gate <- newEmptyMVar
    resultVars <- replicateM (length children) newEmptyMVar
    sequence_
      [ forkIO do
          readMVar gate
          result <- reserve appEnv budgetId (Just (root, budget 3)) child
          putMVar resultVar result
      | (child, resultVar) <- zip children resultVars
      ]
    putMVar gate ()
    results <- traverse takeMVar resultVars
    let successful = rights results
    assertEqual "exactly three distinct children reserve" 3 (length (filter (== DelegationSlotReserved) successful))
    assertEqual "every later child sees exhaustion" 7 (length (filter (== DelegationSlotsExhausted) successful))
    case [child | (child, Right DelegationSlotReserved) <- zip children results] of
      firstReserved : _ -> do
        replayed <- reserve appEnv budgetId Nothing firstReserved
        assertEqual "a reserved child remains replayable after exhaustion" (Right DelegationSlotAlreadyReserved) replayed
      [] -> assertFailure "the concurrent reservation test produced no winner"

missingLedger :: DatabaseFixture -> IO ()
missingLedger databaseFixture =
  (withFixture databaseFixture) \appEnv -> do
    let root = WorkflowId "budget-root-missing"
        budgetId = delegationBudgetIdFor root
    result <- reserve appEnv budgetId Nothing (WorkflowId "budget-child-missing")
    assertEqual "a propagated id must already name a ledger" (Left (DelegationBudgetLedgerMissing budgetId)) result

reserve :: AppEnv -> DelegationBudgetId -> Maybe (WorkflowId, DelegationBudget) -> WorkflowId -> IO (Either BudgetReservationError ReservationResult)
reserve appEnv budgetId seed child = do
  stored <- runAppIO appEnv (reserveDelegationSlot budgetId seed child fixedTime)
  either (assertFailure . show) pure stored

reserveBatch :: AppEnv -> DelegationBudgetId -> Maybe (WorkflowId, DelegationBudget) -> NonEmpty WorkflowId -> IO (Either BudgetReservationError BatchReservationResult)
reserveBatch appEnv budgetId seed children = do
  stored <- runAppIO appEnv (reserveDelegationSlots budgetId seed children fixedTime)
  either (assertFailure . show) pure stored

budget :: Integer -> DelegationBudget
budget value =
  either (error . Text.unpack) id (mkDelegationBudget (fromInteger value))

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 8 22) 0

withFixture :: DatabaseFixture -> (AppEnv -> IO a) -> IO a
withFixture databaseFixture use =
  (withShikigamiFreshDatabase databaseFixture) \connectionString -> do
    tracer <- noopTracer
    use
      AppEnv
        { connectionSettings = defaultConnectionSettings connectionString,
          tracer,
          metrics = Nothing,
          store = Nothing
        }

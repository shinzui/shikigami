module Shikigami.DelegationBudgetSpec (tests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Monad (replicateM)
import Data.Either (rights)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Keiro.Workflow (WorkflowId (..))
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Shikigami.Agent.Decl (DelegationBudget, mkDelegationBudget)
import Shikigami.Agent.Delegate.Context (DelegationBudgetId)
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.Store.DelegationBudget
  ( BudgetReservationError (..),
    ReservationResult (..),
    delegationBudgetIdFor,
    reserveDelegationSlot,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "DelegationBudget"
    [ testCase "replay reserves a deterministic child only once" replayIsIdempotent,
      testCase "concurrent branches cannot overspend the root limit" concurrentLimit,
      testCase "a descendant cannot invent a missing root ledger" missingLedger
    ]

replayIsIdempotent :: IO ()
replayIsIdempotent =
  withFixture \appEnv -> do
    let root = WorkflowId "budget-root-replay"
        budgetId = delegationBudgetIdFor root
        child = WorkflowId "budget-child-replay"
    first <- reserve appEnv budgetId (Just (root, budget 1)) child
    second <- reserve appEnv budgetId Nothing child
    assertEqual "first occurrence consumes one slot" (Right DelegationSlotReserved) first
    assertEqual "same child id is replay success" (Right DelegationSlotAlreadyReserved) second

concurrentLimit :: IO ()
concurrentLimit =
  withFixture \appEnv -> do
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

missingLedger :: IO ()
missingLedger =
  withFixture \appEnv -> do
    let root = WorkflowId "budget-root-missing"
        budgetId = delegationBudgetIdFor root
    result <- reserve appEnv budgetId Nothing (WorkflowId "budget-child-missing")
    assertEqual "a propagated id must already name a ledger" (Left (DelegationBudgetLedgerMissing budgetId)) result

reserve :: AppEnv -> DelegationBudgetId -> Maybe (WorkflowId, DelegationBudget) -> WorkflowId -> IO (Either BudgetReservationError ReservationResult)
reserve appEnv budgetId seed child = do
  stored <- runAppIO appEnv (reserveDelegationSlot budgetId seed child fixedTime)
  either (assertFailure . show) pure stored

budget :: Integer -> DelegationBudget
budget value =
  either (error . Text.unpack) id (mkDelegationBudget (fromInteger value))

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 8 22) 0

withFixture :: (AppEnv -> IO a) -> IO a
withFixture use =
  withShikigamiMigratedDatabase \connectionString -> do
    tracer <- noopTracer
    use
      AppEnv
        { connectionSettings = defaultConnectionSettings connectionString,
          tracer,
          metrics = Nothing
        }

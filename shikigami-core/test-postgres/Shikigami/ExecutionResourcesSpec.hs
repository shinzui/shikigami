module Shikigami.ExecutionResourcesSpec (tests) where

import Control.Concurrent.Async (concurrently)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Effectful (Eff)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Decl (mkDelegationBudget)
import Shikigami.Execution.Identity
import Shikigami.Execution.Resources
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Store.DelegationBudget
import Shikigami.Store.ExecutionResources
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "ExecutionResources"
    [ testCase "last-slot race admits exactly one dispatch" $ withFixture fixture \env -> do
        seed env [(ActiveWork, 1)]
        reserveModel env "one"
        reserveModel env "two"
        (a, b) <- concurrently (run env (begin "a" "one")) (run env (begin "b" "two"))
        assertBool
          "one winner, one exhausted, so dispatcher can run exactly once"
          ((a == Right Accepted && b == Left (ResourceExhausted ActiveWork)) || (b == Right Accepted && a == Left (ResourceExhausted ActiveWork)))
        snapshot <- root env
        snapshot.active @?= 1,
      testCase "all dimensions reserve together or none" $ withFixture fixture \env -> do
        seed env [(Tokens, 5)]
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Left (ResourceExhausted Tokens))
        snapshot <- root env
        snapshot.usage @?= emptyUsage
        run env (beginAttempt rid 0 (attempt "a" "one" 5) now) >>= (@?= Right Accepted),
      testCase "whole operation batch rolls back on exhaustion" $ withFixture fixture \env -> do
        seed env [(LifetimeDescendants, 1)]
        run env (reserveOperations rid 0 [child "one", child "two"] now) >>= (@?= Left (ResourceExhausted LifetimeDescendants))
        snapshot <- root env
        snapshot.usage @?= emptyUsage
        run env (reserveOperation rid 0 (child "one") now) >>= (@?= Right Accepted),
      testCase "conflicting duplicate batch rolls back its first insert" $ withFixture fixture \env -> do
        seed env []
        let altered = OperationRequest (OperationId "one") Nothing ToolOperation Map.empty "different"
        run env (reserveOperations rid 0 [model "one", altered] now) >>= (@?= Left IdentityConflict)
        run env (begin "a" "one") >>= (@?= Left OperationMissing),
      testCase "replay after lost response spends nothing and cannot widen" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        before <- root env
        run env (begin "a" "one") >>= (@?= Right AlreadyAccepted)
        run env (beginAttempt rid 0 (attempt "a" "one" 11) now) >>= (@?= Left IdentityConflict)
        after <- root env
        after @?= before
        run env (enrollRoot rid (envelope [(Tokens, 500)])) >>= (@?= Left IdentityConflict),
      testCase "fresh transport attempts spend cumulative counters" $ withFixture fixture \env -> do
        seed env [(ModelAttempts, 2)]
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        settle env "a" 4
        run env (begin "b" "one") >>= (@?= Right Accepted)
        settle env "b" 3
        run env (begin "c" "one") >>= (@?= Left (ResourceExhausted ModelAttempts))
        snapshot <- root env
        Map.lookup ModelAttempts snapshot.usage.settled @?= Just 2
        Map.lookup Tokens snapshot.known @?= Just 7,
      testCase "unknown attempts survive reopen and require reconciliation" $ withFixture fixture \env -> do
        seed env [(ActiveWork, 1)]
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        run env (settleAttempt rid (AttemptId "a") (UnknownUsage "transport outcome unknown")) >>= (@?= Right Accepted)
        snapshot <- root env
        run env (inspectAttempt rid (AttemptId "a")) >>= (@?= Right (Just (Attempt (attempt "a" "one" 10) (Just (UnknownUsage "transport outcome unknown")))))
        snapshot.unknown @?= 1
        snapshot.active @?= 1
        run env (begin "b" "one") >>= (@?= Left (ResourceExhausted ActiveWork))
        run env (settleAttempt rid (AttemptId "a") (KnownUsage (measure 3))) >>= (@?= Left SettlementConflict)
        run env (reconcileAttempt rid (AttemptId "a") (measure 3)) >>= (@?= Right Accepted)
        final <- root env
        final.unknown @?= 0
        final.active @?= 0
        Map.lookup Tokens final.known @?= Just 3,
      testCase "racing identical settlements commit only once" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        let finish = run env (settleAttempt rid (AttemptId "a") (KnownUsage (measure 3)))
        (a, b) <- concurrently finish finish
        assertBool "exactly one writes" ([a, b] == [Right Accepted, Right AlreadyAccepted] || [b, a] == [Right Accepted, Right AlreadyAccepted])
        run env (settleAttempt rid (AttemptId "a") (KnownUsage (measure 4))) >>= (@?= Left SettlementConflict)
        snapshot <- root env
        Map.lookup Tokens snapshot.known @?= Just 3,
      testCase "overage is retained and stops future dispatch" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        settle env "a" 11
        snapshot <- root env
        snapshot.overage @?= True
        Map.lookup Tokens snapshot.known @?= Just 11
        run env (begin "b" "one") >>= (@?= Left OverageRecorded),
      testCase "cancellation and cutoff deny admission but preserve recording" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        run env (beginAttempt rid 0 (attempt "b" "one" 10) (addUTCTime 3600 now)) >>= (@?= Left CutoffReached)
        run env (setRootControl rid 0 True Nothing) >>= (@?= Right ())
        run env (beginAttempt rid 1 (attempt "b" "one" 10) now) >>= (@?= Left RootCancelled)
        settle env "a" 5
        run env (begin "a" "one") >>= (@?= Right AlreadyAccepted)
        run env (setRootControl rid 1 False Nothing) >>= (@?= Left (InvalidResourceRequest "cancellation is irreversible")),
      testCase "reduced active cap drains accepted work without fabricating cancellation" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        run env (setRootControl rid 0 False (Just 0)) >>= (@?= Right ())
        run env (beginAttempt rid 1 (attempt "b" "one" 10) now) >>= (@?= Left (ResourceExhausted ActiveWork))
        settle env "a" 5
        snapshot <- root env
        snapshot.active @?= 0
        snapshot.cancelled @?= False,
      testCase "unknown policy cannot claim a finite token cap" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        let request = AttemptRequest (AttemptId "a") (OperationId "one") (Map.fromList [(ActiveWork, 1), (ModelAttempts, 1)]) AdmittedUnknownUsage
        result <- run env (beginAttempt rid 0 request now)
        assertBool "refused before dispatch" (case result of Left (InvalidResourceRequest _) -> True; _ -> False)
        snapshot <- root env
        snapshot.usage @?= emptyUsage,
      testCase "absent dimension is denied; explicitly unbounded usage is admitted" $ withFixture fixture \env -> do
        let restricted = Envelope (Map.singleton ActiveWork (Limited 1)) (addUTCTime 3600 now)
        run env (enrollRoot rid restricted) >>= (@?= Right Accepted)
        run env (reserveOperation rid 0 (child "one") now) >>= (@?= Left (DimensionNotAdmitted LifetimeDescendants))
        let other = ExecutionRootId "explicit-root"
            explicit = Envelope (Map.fromList [(ActiveWork, Limited 1), (ModelAttempts, ExplicitlyUnbounded), (Tokens, ExplicitlyUnbounded), (CostMicroUsd, ExplicitlyUnbounded)]) (addUTCTime 3600 now)
        run env (enrollRoot other explicit) >>= (@?= Right Accepted)
        run env (reserveOperation other 0 (model "one") now) >>= (@?= Right Accepted)
        let request = AttemptRequest (AttemptId "a") (OperationId "one") (Map.fromList [(ActiveWork, 1), (ModelAttempts, 1)]) AdmittedUnknownUsage
        run env (beginAttempt other 0 request now) >>= (@?= Right Accepted),
      testCase "suballocations hold root capacity and cannot reset consumption" $ withFixture fixture \env -> do
        seed env [(LifetimeDescendants, 2)]
        let allocation = AllocationId "worker"
            slice = Envelope (Map.singleton LifetimeDescendants (Limited 2)) (addUTCTime 3600 now)
            scoped = OperationRequest (OperationId "one") (Just allocation) ChildOperation (Map.singleton LifetimeDescendants 1) "child-v1"
        run env (narrowAllocation rid 0 allocation Nothing slice now) >>= (@?= Right Accepted)
        run env (reserveOperation rid 0 (child "direct") now) >>= (@?= Left (ResourceExhausted LifetimeDescendants))
        run env (reserveOperation rid 0 scoped now) >>= (@?= Right Accepted)
        let narrower = Envelope (Map.singleton LifetimeDescendants (Limited 1)) slice.cutoff
        run env (narrowAllocation rid 0 allocation Nothing narrower now) >>= (@?= Right Accepted)
        run env (narrowAllocation rid 0 allocation Nothing slice now) >>= \result -> assertBool "cannot widen" (case result of Left _ -> True; _ -> False)
        run env (reserveOperation rid 0 (child "direct") now) >>= (@?= Right Accepted)
        run env (reserveOperation rid 0 (child "third") now) >>= (@?= Left (ResourceExhausted LifetimeDescendants)),
      testCase "missing roots and scopes never seed allowance" $ withFixture fixture \env -> do
        run env (reserveOperation rid 0 (child "one") now) >>= (@?= Left RootMissing)
        seed env []
        let scoped = OperationRequest (OperationId "one") (Just (AllocationId "missing")) ChildOperation (Map.singleton LifetimeDescendants 1) "child-v1"
        run env (reserveOperation rid 0 scoped now) >>= (@?= Left AllocationMissing),
      testCase "transaction hook rolls settlement back with the accepted outcome" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        before <- root env
        run
          env
          ( runTransaction do
              result <- settleAttemptTx rid (AttemptId "a") (KnownUsage (measure 2))
              Tx.condemn
              pure result
          )
          >>= (@?= Right Accepted)
        after <- root env
        after @?= before
        settle env "a" 2,
      testCase "historical delegation exhaustion rolls back new root reservations" $ withFixture fixture \env -> do
        seed env []
        let workflow = WorkflowId "delegating-root"
            budgetId = delegationBudgetIdFor workflow
            cap = either (error . show) id (mkDelegationBudget 1)
            children = WorkflowId "first" :| [WorkflowId "second"]
        run env (reserveEnrolledDelegationSlots rid budgetId (Just (workflow, cap)) children now) >>= (@?= Right DelegationBatchExhausted)
        snapshot <- root env
        snapshot.usage @?= emptyUsage
        run env (reserveEnrolledDelegationSlots rid budgetId (Just (workflow, cap)) (WorkflowId "first" :| []) now) >>= (@?= Right (DelegationBatchReserved 1 0)),
      testCase "resource refusal leaves historical descendant allowance untouched" $ withFixture fixture \env -> do
        seed env [(LifetimeDescendants, 1)]
        let workflow = WorkflowId "delegating-root"
            budgetId = delegationBudgetIdFor workflow
            cap = either (error . show) id (mkDelegationBudget 2)
            children = WorkflowId "first" :| [WorkflowId "second"]
        run env (reserveEnrolledDelegationSlots rid budgetId (Just (workflow, cap)) children now) >>= (@?= Left (DelegationResourceRefused (ResourceExhausted LifetimeDescendants)))
        run env (reserveDelegationSlots budgetId (Just (workflow, cap)) children now) >>= (@?= Right (DelegationBatchReserved 2 0)),
      testCase "descendant cannot replace its bound root to regain allowance" $ withFixture fixture \env -> do
        seed env []
        let workflow = WorkflowId "delegating-root"
            budgetId = delegationBudgetIdFor workflow
            cap = either (error . show) id (mkDelegationBudget 2)
            other = ExecutionRootId "replacement-root"
        run env (reserveEnrolledDelegationSlots rid budgetId (Just (workflow, cap)) (WorkflowId "first" :| []) now) >>= (@?= Right (DelegationBatchReserved 1 0))
        run env (reserveDelegationSlots budgetId Nothing (WorkflowId "second" :| []) now) >>= (@?= Left (DelegationResourceRefused IdentityConflict))
        run env (enrollRoot other (envelope [])) >>= (@?= Right Accepted)
        run env (reserveEnrolledDelegationSlots other budgetId Nothing (WorkflowId "second" :| []) now) >>= (@?= Left (DelegationResourceRefused IdentityConflict))
        run env (inspectRoot other) >>= \result -> case result of
          Right snapshot -> snapshot.usage @?= emptyUsage
          Left err -> assertFailure (show err)
        run env (reserveEnrolledDelegationSlots rid budgetId Nothing (WorkflowId "second" :| []) now) >>= (@?= Right (DelegationBatchReserved 1 0)),
      testCase "duplicate delegated children spend once across both ledgers" $ withFixture fixture \env -> do
        seed env []
        let workflow = WorkflowId "delegating-root"
            budgetId = delegationBudgetIdFor workflow
            cap = either (error . show) id (mkDelegationBudget 1)
            children = WorkflowId "same" :| [WorkflowId "same"]
        run env (reserveEnrolledDelegationSlots rid budgetId (Just (workflow, cap)) children now) >>= (@?= Right (DelegationBatchReserved 1 0))
        run env (reserveEnrolledDelegationSlots rid budgetId Nothing children now) >>= (@?= Right (DelegationBatchReserved 0 1))
        snapshot <- root env
        Map.lookup LifetimeDescendants snapshot.usage.settled @?= Just 1,
      testCase "terminal transport releases active work while unknown cost remains held" $ withFixture fixture \env -> do
        seed env [(ActiveWork, 1), (CostMicroUsd, 10)]
        reserveModel env "one"
        let request = AttemptRequest (AttemptId "a") (OperationId "one") (Map.fromList [(ActiveWork, 1), (ModelAttempts, 1), (Tokens, 10), (CostMicroUsd, 10)]) EnforcedCeiling
            partial = PartialUsage (Map.singleton Tokens 3) [CostMicroUsd] "invoice usage unavailable"
        run env (beginAttempt rid 0 request now) >>= (@?= Right Accepted)
        run env (settleAttempt rid (AttemptId "a") partial) >>= (@?= Right Accepted)
        run env (settleAttempt rid (AttemptId "a") partial) >>= (@?= Right AlreadyAccepted)
        snapshot <- root env
        snapshot.active @?= 0
        snapshot.unknown @?= 1
        Map.lookup CostMicroUsd snapshot.usage.held @?= Just 10
        Map.lookup Tokens snapshot.known @?= Just 3
        run env (beginAttempt rid 0 (AttemptRequest (AttemptId "b") (OperationId "one") (Map.fromList [(ActiveWork, 1), (ModelAttempts, 1), (Tokens, 10), (CostMicroUsd, 1)]) EnforcedCeiling) now) >>= (@?= Left (ResourceExhausted CostMicroUsd))
        run env (reconcileAttempt rid (AttemptId "a") (Map.fromList [(Tokens, 4), (CostMicroUsd, 3)])) >>= (@?= Left SettlementConflict)
        run env (reconcileAttempt rid (AttemptId "a") (Map.fromList [(Tokens, 3), (CostMicroUsd, 3)])) >>= (@?= Right Accepted)
        final <- root env
        final.active @?= 0
        final.unknown @?= 0
        Map.lookup ModelAttempts final.known @?= Just 1
        Map.lookup Tokens final.known @?= Just 3
        Map.lookup CostMicroUsd final.known @?= Just 3
    ]

rid :: ExecutionRootId
rid = ExecutionRootId "root"

now :: UTCTime
now = UTCTime (fromGregorian 2026 10 27) 0

envelope :: [(Dimension, Integer)] -> Envelope
envelope overrides = Envelope (Map.map Limited (Map.union (Map.fromList overrides) (Map.fromList [(d, 100) | d <- [minBound .. maxBound]]))) (addUTCTime 3600 now)

seed :: AppEnv -> [(Dimension, Integer)] -> IO ()
seed env limits = run env (enrollRoot rid (envelope limits)) >>= (@?= Right Accepted)

model :: String -> OperationRequest
model key = OperationRequest (OperationId (fromString key)) Nothing ModelOperation Map.empty "model-v1"

child :: String -> OperationRequest
child key = OperationRequest (OperationId (fromString key)) Nothing ChildOperation (Map.singleton LifetimeDescendants 1) "child-v1"

reserveModel :: AppEnv -> String -> IO ()
reserveModel env key = run env (reserveOperation rid 0 (model key) now) >>= (@?= Right Accepted)

attempt :: String -> String -> Integer -> AttemptRequest
attempt key operation tokens = AttemptRequest (AttemptId (fromString key)) (OperationId (fromString operation)) (Map.fromList [(ActiveWork, 1), (ModelAttempts, 1), (Tokens, tokens), (CostMicroUsd, 0)]) EnforcedCeiling

begin :: String -> String -> Eff AppEffects (Either ResourceError Admission)
begin key operation = beginAttempt rid 0 (attempt key operation 10) now

settle :: AppEnv -> String -> Integer -> IO ()
settle env key tokens = run env (settleAttempt rid (AttemptId (fromString key)) (KnownUsage (Map.fromList [(Tokens, tokens), (CostMicroUsd, 0)]))) >>= (@?= Right Accepted)

root :: AppEnv -> IO Root
root env = run env (inspectRoot rid) >>= either (\err -> assertFailure (show err)) pure

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= either (\err -> assertFailure (show err)) pure

withFixture :: DatabaseFixture -> (AppEnv -> IO a) -> IO a
withFixture fixture use = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  use AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing}

fromString :: String -> Data.Text.Text
fromString = Data.Text.pack

measure :: Integer -> Quantities
measure n = Map.fromList [(Tokens, n), (CostMicroUsd, 0)]

module Shikigami.ExecutionResourcesSpec (tests) where

import Contravariant.Extras (contrazip2)
import Control.Concurrent.Async (concurrently, replicateConcurrently)
import Control.Lens ((&), (.~))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Effectful (Eff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.Agent.Decl (mkDelegationBudget)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (ResolvedAgentIdentity (CompatibilityAgent))
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.Delegation.BudgetStore
import Shikigami.Execution.Counter (AttemptCount, noAttempts, parseAttemptCount)
import Shikigami.Execution.Identity
import Shikigami.Execution.Quantity (ResourceAmount, parseResourceAmount)
import Shikigami.Execution.Resources
import Shikigami.Execution.ResourcesStore
import Shikigami.Fixture.ExecutionIdentity (fixtureAllocationId, fixtureAttemptId, fixtureRootId)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.StateRevision (StateRevision, parseRevision)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "ExecutionResources"
    [ testCase "root origin allocates once across concurrent and missing-response retries" $ withFixture fixture \env -> do
        let caller = either (error . show) id (mkAgentName "root-owner")
            create supplied = allocateRootForWorkflow (CompatibilityAgent caller) caller (WorkflowId "native-root-run") supplied (envelope [])
        values <- replicateConcurrently 8 (run env (create Nothing))
        identifier <- case values of Right first : _ -> pure first; other -> assertFailure (show other)
        values @?= replicate 8 (Right identifier)
        run env (create Nothing) >>= (@?= Right identifier)
        run env (create (Just identifier)) >>= (@?= Right identifier)
        rootOriginCounts env >>= (@?= (1, 1))
        run env (allocateRootForWorkflow (CompatibilityAgent caller) caller (WorkflowId "native-root-run") Nothing (envelope [(Tokens, fixtureAmount 3)])) >>= (@?= Left IdentityConflict)
        other <- newExecutionRootId
        run env (create (Just other)) >>= (@?= Left IdentityConflict)
        run env (allocateRootForWorkflow (CompatibilityAgent caller) caller (WorkflowId "unknown-run") (Just identifier) (envelope [])) >>= (@?= Left IdentityConflict)
        rootOriginCounts env >>= (@?= (1, 1)),
      testCase "root origin binds the current creator and agent" $ withFixture fixture \env -> do
        let caller = either (error . show) id (mkAgentName "root-owner")
            other = either (error . show) id (mkAgentName "other-owner")
            create creator agent = allocateRootForWorkflow creator agent (WorkflowId "native-root-run") Nothing (envelope [])
        _ <- run env (create (CompatibilityAgent caller) caller)
        run env (create (CompatibilityAgent other) caller) >>= (@?= Left IdentityConflict)
        run env (create (CompatibilityAgent caller) other) >>= (@?= Left IdentityConflict)
        rootOriginCounts env >>= (@?= (1, 1)),
      testCase "a root publication failure rolls its origin back before retry" $ withFixture fixture \env -> do
        let caller = either (error . show) id (mkAgentName "root-owner")
            create = allocateRootForWorkflow (CompatibilityAgent caller) caller (WorkflowId "native-root-run") Nothing (envelope [])
        run env (runTransaction (Tx.sql "CREATE FUNCTION shikigami.reject_root_fixture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture root refusal'; END $$; CREATE TRIGGER reject_root_fixture BEFORE INSERT ON shikigami.execution_roots FOR EACH ROW EXECUTE FUNCTION shikigami.reject_root_fixture()"))
        failed <- runAppIO env create
        case failed of Left _ -> pure (); other -> assertFailure (show other)
        rootOriginCounts env >>= (@?= (0, 0))
        run env (runTransaction (Tx.sql "DROP TRIGGER reject_root_fixture ON shikigami.execution_roots; DROP FUNCTION shikigami.reject_root_fixture()"))
        recovered <- run env create
        case recovered of Right _ -> pure (); other -> assertFailure (show other)
        rootOriginCounts env >>= (@?= (1, 1)),
      testCase "last-slot race admits exactly one dispatch" $ withFixture fixture \env -> do
        seed env [(ActiveWork, (fixtureAmount 1))]
        reserveModel env "one"
        reserveModel env "two"
        (a, b) <- concurrently (run env (begin "a" "one")) (run env (begin "b" "two"))
        assertBool
          "one winner, one exhausted, so dispatcher can run exactly once"
          ((a == Right Accepted && b == Left (ResourceExhausted ActiveWork)) || (b == Right Accepted && a == Left (ResourceExhausted ActiveWork)))
        snapshot <- root env
        snapshot.active @?= (fixtureCount 1),
      testCase "all dimensions reserve together or none" $ withFixture fixture \env -> do
        seed env [(Tokens, (fixtureAmount 5))]
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Left (ResourceExhausted Tokens))
        snapshot <- root env
        snapshot.usage @?= emptyUsage
        run env (beginAttempt rid (fixtureRevision 0) (attempt "a" "one" 5) now) >>= (@?= Right Accepted),
      testCase "whole operation batch rolls back on exhaustion" $ withFixture fixture \env -> do
        seed env [(LifetimeDescendants, (fixtureAmount 1))]
        run env (reserveOperations rid (fixtureRevision 0) [child "one", child "two"] now) >>= (@?= Left (ResourceExhausted LifetimeDescendants))
        snapshot <- root env
        snapshot.usage @?= emptyUsage
        run env (reserveOperation rid (fixtureRevision 0) (child "one") now) >>= (@?= Right Accepted),
      testCase "conflicting duplicate batch rolls back its first insert" $ withFixture fixture \env -> do
        seed env []
        let altered = OperationRequest (OperationId "one") Nothing ToolOperation Map.empty "different"
        run env (reserveOperations rid (fixtureRevision 0) [model "one", altered] now) >>= (@?= Left IdentityConflict)
        run env (begin "a" "one") >>= (@?= Left OperationMissing),
      testCase "replay after lost response spends nothing and cannot widen" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        before <- root env
        run env (begin "a" "one") >>= (@?= Right AlreadyAccepted)
        run env (beginAttempt rid (fixtureRevision 0) (attempt "a" "one" 11) now) >>= (@?= Left IdentityConflict)
        after <- root env
        after @?= before
        run env (enrollRoot rid (envelope [(Tokens, (fixtureAmount 500))])) >>= (@?= Left IdentityConflict),
      testCase "fresh transport attempts spend cumulative counters" $ withFixture fixture \env -> do
        seed env [(ModelAttempts, (fixtureAmount 2))]
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        settle env "a" 4
        run env (begin "b" "one") >>= (@?= Right Accepted)
        settle env "b" 3
        run env (begin "c" "one") >>= (@?= Left (ResourceExhausted ModelAttempts))
        snapshot <- root env
        Map.lookup ModelAttempts snapshot.usage.settled @?= Just (fixtureAmount 2)
        Map.lookup Tokens snapshot.known @?= Just (fixtureAmount 7),
      testCase "unknown attempts survive reopen and require reconciliation" $ withFixture fixture \env -> do
        seed env [(ActiveWork, (fixtureAmount 1))]
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        run env (settleAttempt rid (fixtureAttemptId "a") (UnknownUsage "transport outcome unknown")) >>= (@?= Right Accepted)
        snapshot <- root env
        run env (inspectAttempt rid (fixtureAttemptId "a")) >>= (@?= Right (Just (Attempt (attempt "a" "one" 10) (Just (UnknownUsage "transport outcome unknown")))))
        snapshot.unknown @?= (fixtureCount 1)
        snapshot.active @?= (fixtureCount 1)
        run env (begin "b" "one") >>= (@?= Left (ResourceExhausted ActiveWork))
        run env (settleAttempt rid (fixtureAttemptId "a") (KnownUsage (measure 3))) >>= (@?= Left SettlementConflict)
        run env (reconcileAttempt rid (fixtureAttemptId "a") (measure 3)) >>= (@?= Right Accepted)
        final <- root env
        final.unknown @?= (fixtureCount 0)
        final.active @?= (fixtureCount 0)
        Map.lookup Tokens final.known @?= Just (fixtureAmount 3),
      testCase "racing identical settlements commit only once" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        let finish = run env (settleAttempt rid (fixtureAttemptId "a") (KnownUsage (measure 3)))
        (a, b) <- concurrently finish finish
        assertBool "exactly one writes" ([a, b] == [Right Accepted, Right AlreadyAccepted] || [b, a] == [Right Accepted, Right AlreadyAccepted])
        run env (settleAttempt rid (fixtureAttemptId "a") (KnownUsage (measure 4))) >>= (@?= Left SettlementConflict)
        snapshot <- root env
        Map.lookup Tokens snapshot.known @?= Just (fixtureAmount 3),
      testCase "known-counter overflow refuses before changing the root or attempt" $
        refusedSettlement fixture False (\before -> before & #known .~ Map.singleton ModelAttempts (fixtureAmount (toInteger (maxBound :: Int64)))),
      testCase "active-count underflow refuses before changing the root or attempt" $
        refusedSettlement fixture False (\before -> before & #active .~ noAttempts),
      testCase "unknown-count underflow refuses reconciliation without changing the root or attempt" $
        refusedSettlement fixture True (\before -> before & #unknown .~ noAttempts),
      testCase "overage is retained and stops future dispatch" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        settle env "a" 11
        snapshot <- root env
        snapshot.overage @?= OverageDetected
        Map.lookup Tokens snapshot.known @?= Just (fixtureAmount 11)
        run env (begin "b" "one") >>= (@?= Left OverageRecorded),
      testCase "cancellation and cutoff deny admission but preserve recording" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        run env (beginAttempt rid (fixtureRevision 0) (attempt "b" "one" 10) (addUTCTime 3600 now)) >>= (@?= Left CutoffReached)
        run env (setRootControl rid (fixtureRevision 0) StopWork Nothing) >>= (@?= Right ())
        run env (beginAttempt rid (fixtureRevision 1) (attempt "b" "one" 10) now) >>= (@?= Left RootCancelled)
        settle env "a" 5
        run env (begin "a" "one") >>= (@?= Right AlreadyAccepted)
        run env (setRootControl rid (fixtureRevision 1) ContinueWork Nothing) >>= (@?= Left (InvalidResourceRequest "cancellation is irreversible")),
      testCase "reduced active cap drains accepted work without fabricating cancellation" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        run env (setRootControl rid (fixtureRevision 0) ContinueWork (Just (fixtureAmount 0))) >>= (@?= Right ())
        run env (beginAttempt rid (fixtureRevision 1) (attempt "b" "one" 10) now) >>= (@?= Left (ResourceExhausted ActiveWork))
        settle env "a" 5
        snapshot <- root env
        snapshot.active @?= (fixtureCount 0)
        snapshot.cancelled @?= ContinueWork,
      testCase "unknown policy cannot claim a finite token cap" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        let request = AttemptRequest (fixtureAttemptId "a") (OperationId "one") (Map.fromList [(ActiveWork, (fixtureAmount 1)), (ModelAttempts, (fixtureAmount 1))]) AdmittedUnknownUsage
        result <- run env (beginAttempt rid (fixtureRevision 0) request now)
        assertBool "refused before dispatch" (case result of Left (InvalidResourceRequest _) -> True; _ -> False)
        snapshot <- root env
        snapshot.usage @?= emptyUsage,
      testCase "absent dimension is denied; explicitly unbounded usage is admitted" $ withFixture fixture \env -> do
        let restricted = Envelope (Map.singleton ActiveWork (Limited (fixtureAmount 1))) (addUTCTime 3600 now)
        run env (enrollRoot rid restricted) >>= (@?= Right Accepted)
        run env (reserveOperation rid (fixtureRevision 0) (child "one") now) >>= (@?= Left (DimensionNotAdmitted LifetimeDescendants))
        let other = fixtureRootId "explicit-root"
            explicit = Envelope (Map.fromList [(ActiveWork, Limited (fixtureAmount 1)), (ModelAttempts, ExplicitlyUnbounded), (Tokens, ExplicitlyUnbounded), (CostMicroUsd, ExplicitlyUnbounded)]) (addUTCTime 3600 now)
        run env (enrollRoot other explicit) >>= (@?= Right Accepted)
        run env (reserveOperation other (fixtureRevision 0) (model "one") now) >>= (@?= Right Accepted)
        let request = AttemptRequest (fixtureAttemptId "a") (OperationId "one") (Map.fromList [(ActiveWork, (fixtureAmount 1)), (ModelAttempts, (fixtureAmount 1))]) AdmittedUnknownUsage
        run env (beginAttempt other (fixtureRevision 0) request now) >>= (@?= Right Accepted),
      testCase "suballocations hold root capacity and cannot reset consumption" $ withFixture fixture \env -> do
        seed env [(LifetimeDescendants, (fixtureAmount 2))]
        let allocation = fixtureAllocationId "worker"
            slice = Envelope (Map.singleton LifetimeDescendants (Limited (fixtureAmount 2))) (addUTCTime 3600 now)
            scoped = OperationRequest (OperationId "one") (Just allocation) ChildOperation (Map.singleton LifetimeDescendants (fixtureAmount 1)) "child-v1"
        run env (narrowAllocation rid (fixtureRevision 0) allocation Nothing slice now) >>= (@?= Right Accepted)
        run env (reserveOperation rid (fixtureRevision 0) (child "direct") now) >>= (@?= Left (ResourceExhausted LifetimeDescendants))
        run env (reserveOperation rid (fixtureRevision 0) scoped now) >>= (@?= Right Accepted)
        let narrower = Envelope (Map.singleton LifetimeDescendants (Limited (fixtureAmount 1))) slice.cutoff
        run env (narrowAllocation rid (fixtureRevision 0) allocation Nothing narrower now) >>= (@?= Right Accepted)
        run env (narrowAllocation rid (fixtureRevision 0) allocation Nothing slice now) >>= \result -> assertBool "cannot widen" (case result of Left _ -> True; _ -> False)
        run env (reserveOperation rid (fixtureRevision 0) (child "direct") now) >>= (@?= Right Accepted)
        run env (reserveOperation rid (fixtureRevision 0) (child "third") now) >>= (@?= Left (ResourceExhausted LifetimeDescendants)),
      testCase "missing roots and scopes never seed allowance" $ withFixture fixture \env -> do
        run env (reserveOperation rid (fixtureRevision 0) (child "one") now) >>= (@?= Left RootMissing)
        seed env []
        let scoped = OperationRequest (OperationId "one") (Just (fixtureAllocationId "missing")) ChildOperation (Map.singleton LifetimeDescendants (fixtureAmount 1)) "child-v1"
        run env (reserveOperation rid (fixtureRevision 0) scoped now) >>= (@?= Left AllocationMissing),
      testCase "transaction hook rolls settlement back with the accepted outcome" $ withFixture fixture \env -> do
        seed env []
        reserveModel env "one"
        run env (begin "a" "one") >>= (@?= Right Accepted)
        before <- root env
        run
          env
          ( runTransaction do
              result <- settleAttemptTx rid (fixtureAttemptId "a") (KnownUsage (measure 2))
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
        seed env [(LifetimeDescendants, (fixtureAmount 1))]
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
            other = fixtureRootId "replacement-root"
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
        Map.lookup LifetimeDescendants snapshot.usage.settled @?= Just (fixtureAmount 1),
      testCase "terminal transport releases active work while unknown cost remains held" $ withFixture fixture \env -> do
        seed env [(ActiveWork, (fixtureAmount 1)), (CostMicroUsd, (fixtureAmount 10))]
        reserveModel env "one"
        let request = AttemptRequest (fixtureAttemptId "a") (OperationId "one") (Map.fromList [(ActiveWork, (fixtureAmount 1)), (ModelAttempts, (fixtureAmount 1)), (Tokens, (fixtureAmount 10)), (CostMicroUsd, (fixtureAmount 10))]) EnforcedCeiling
            partial = PartialUsage (Map.singleton Tokens (fixtureAmount 3)) [CostMicroUsd] "invoice usage unavailable"
        run env (beginAttempt rid (fixtureRevision 0) request now) >>= (@?= Right Accepted)
        run env (settleAttempt rid (fixtureAttemptId "a") partial) >>= (@?= Right Accepted)
        run env (settleAttempt rid (fixtureAttemptId "a") partial) >>= (@?= Right AlreadyAccepted)
        snapshot <- root env
        snapshot.active @?= (fixtureCount 0)
        snapshot.unknown @?= (fixtureCount 1)
        Map.lookup CostMicroUsd snapshot.usage.held @?= Just (fixtureAmount 10)
        Map.lookup Tokens snapshot.known @?= Just (fixtureAmount 3)
        run env (beginAttempt rid (fixtureRevision 0) (AttemptRequest (fixtureAttemptId "b") (OperationId "one") (Map.fromList [(ActiveWork, (fixtureAmount 1)), (ModelAttempts, (fixtureAmount 1)), (Tokens, (fixtureAmount 10)), (CostMicroUsd, (fixtureAmount 1))]) EnforcedCeiling) now) >>= (@?= Left (ResourceExhausted CostMicroUsd))
        run env (reconcileAttempt rid (fixtureAttemptId "a") (Map.fromList [(Tokens, (fixtureAmount 4)), (CostMicroUsd, (fixtureAmount 3))])) >>= (@?= Left SettlementConflict)
        run env (reconcileAttempt rid (fixtureAttemptId "a") (Map.fromList [(Tokens, (fixtureAmount 3)), (CostMicroUsd, (fixtureAmount 3))])) >>= (@?= Right Accepted)
        final <- root env
        final.active @?= (fixtureCount 0)
        final.unknown @?= (fixtureCount 0)
        Map.lookup ModelAttempts final.known @?= Just (fixtureAmount 1)
        Map.lookup Tokens final.known @?= Just (fixtureAmount 3)
        Map.lookup CostMicroUsd final.known @?= Just (fixtureAmount 3)
    ]

rid :: ExecutionRootId
rid = fixtureRootId "root"

now :: UTCTime
now = UTCTime (fromGregorian 2026 10 27) 0

envelope :: [(Dimension, ResourceAmount)] -> Envelope
envelope overrides = Envelope (Map.map Limited (Map.union (Map.fromList overrides) (Map.fromList [(d, fixtureAmount 100) | d <- [minBound .. maxBound]]))) (addUTCTime 3600 now)

seed :: AppEnv -> [(Dimension, ResourceAmount)] -> IO ()
seed env limits = run env (enrollRoot rid (envelope limits)) >>= (@?= Right Accepted)

model :: String -> OperationRequest
model key = OperationRequest (OperationId (fromString key)) Nothing ModelOperation Map.empty "model-v1"

child :: String -> OperationRequest
child key = OperationRequest (OperationId (fromString key)) Nothing ChildOperation (Map.singleton LifetimeDescendants (fixtureAmount 1)) "child-v1"

reserveModel :: AppEnv -> String -> IO ()
reserveModel env key = run env (reserveOperation rid (fixtureRevision 0) (model key) now) >>= (@?= Right Accepted)

attempt :: String -> String -> Integer -> AttemptRequest
attempt key operation tokens = AttemptRequest (fixtureAttemptId (fromString key)) (OperationId (fromString operation)) (Map.fromList [(ActiveWork, (fixtureAmount 1)), (ModelAttempts, (fixtureAmount 1)), (Tokens, fixtureAmount tokens), (CostMicroUsd, (fixtureAmount 0))]) EnforcedCeiling

begin :: String -> String -> Eff AppEffects (Either ResourceError Admission)
begin key operation = beginAttempt rid (fixtureRevision 0) (attempt key operation 10) now

settle :: AppEnv -> String -> Integer -> IO ()
settle env key tokens = run env (settleAttempt rid (fixtureAttemptId (fromString key)) (KnownUsage (Map.fromList [(Tokens, fixtureAmount tokens), (CostMicroUsd, (fixtureAmount 0))]))) >>= (@?= Right Accepted)

root :: AppEnv -> IO Root
root env = run env (inspectRoot rid) >>= either (\err -> assertFailure (show err)) pure

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= either (\err -> assertFailure (show err)) pure

withFixture :: DatabaseFixture -> (AppEnv -> IO a) -> IO a
withFixture fixture use = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  use AppEnv {connectionSettings = defaultConnectionSettings connection, tracer, metrics = Nothing, store = Nothing}

fromString :: String -> Data.Text.Text
fromString = Data.Text.pack

measure :: Integer -> Quantities
measure n = Map.fromList [(Tokens, fixtureAmount n), (CostMicroUsd, (fixtureAmount 0))]

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)

fixtureAmount :: Integer -> ResourceAmount
fixtureAmount amount = either (error . show) id (parseResourceAmount amount)

fixtureCount :: Integer -> AttemptCount scope
fixtureCount count = either (error . show) id (parseAttemptCount count)

-- Isolated boundary seeds use only the application's own table. No framework
-- journal, receipt or projection is edited, and successful admission precedes
-- each refusal so unrelated setup failure cannot satisfy the assertion.
refusedSettlement :: DatabaseFixture -> Bool -> (Root -> Root) -> IO ()
refusedSettlement fixture reconcile change = withFixture fixture \env -> do
  seed env []
  reserveModel env "one"
  run env (begin "a" "one") >>= (@?= Right Accepted)
  if reconcile
    then run env (settleAttempt rid (fixtureAttemptId "a") (UnknownUsage "fixture missing billing")) >>= (@?= Right Accepted)
    else pure ()
  before <- root env
  beforeAttempt <- run env (inspectAttempt rid (fixtureAttemptId "a"))
  let invalid = change before
  run
    env
    ( runTransaction
        ( Tx.statement
            (Aeson.toJSON invalid, executionRootIdText rid)
            ( preparable
                "UPDATE shikigami.execution_roots SET state=$1 WHERE root_id=$2"
                (contrazip2 (E.param (E.nonNullable E.jsonb)) (E.param (E.nonNullable E.text)))
                D.noResult
            )
        )
    )
  root env >>= (@?= invalid)
  result <- run env (if reconcile then reconcileAttempt rid (fixtureAttemptId "a") (measure 3) else settleAttempt rid (fixtureAttemptId "a") (KnownUsage (measure 3)))
  assertBool "invalid accounting refused" (case result of Left (InvalidResourceRequest _) -> True; _ -> False)
  root env >>= (@?= invalid)
  run env (inspectAttempt rid (fixtureAttemptId "a")) >>= (@?= beforeAttempt)

rootOriginCounts :: AppEnv -> IO (Int64, Int64)
rootOriginCounts env = run env (runTransaction (Tx.statement () statement))
  where
    statement = preparable "SELECT (SELECT count(*) FROM shikigami.execution_roots), (SELECT count(*) FROM shikigami.execution_root_origins)" E.noParams (D.singleRow ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8)))

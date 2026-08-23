{-# LANGUAGE MultilineStrings #-}

-- | Durable, root-run-wide delegation accounting.
--
-- Every descendant shares one ledger row. Reserving the same deterministic
-- child workflow id is replay success; reserving a new id consumes exactly one
-- slot while the ledger row is locked, so sibling branches cannot overspend a
-- remainder they each observed independently.
module Shikigami.Store.DelegationBudget
  ( ReservationResult (..),
    BatchReservationResult (..),
    BudgetReservationError (..),
    delegationBudgetIdFor,
    reserveDelegationSlot,
    reserveDelegationSlots,
  )
where

import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Workflow (WorkflowId (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Numeric.Natural (Natural)
import Shikigami.Agent.Decl (DelegationBudget, delegationBudgetInt)
import Shikigami.Agent.Delegate.Context (DelegationBudgetId (..))
import Shikigami.Id.Name (nameBytes)
import Shikigami.Prelude

data ReservationResult
  = DelegationSlotReserved
  | DelegationSlotAlreadyReserved
  | DelegationSlotsExhausted
  deriving stock (Eq, Show)

-- | Result of reserving one complete idempotent batch.  Exhaustion inserts no
-- child reservation and consumes no slot; an accepted replay reports every id
-- as existing and consumes nothing further.
data BatchReservationResult
  = DelegationBatchReserved !Natural !Natural
  | DelegationBatchExhausted
  deriving stock (Eq, Show)

data BudgetReservationError
  = DelegationBudgetLedgerMissing !DelegationBudgetId
  deriving stock (Eq, Show)

-- | The deterministic ledger identity for a root workflow instance.
delegationBudgetIdFor :: WorkflowId -> DelegationBudgetId
delegationBudgetIdFor (WorkflowId rootWorkflowId) =
  DelegationBudgetId
    ( Text.pack
        ( UUID.toString
            ( UUID.V5.generateNamed
                UUID.V5.namespaceURL
                (nameBytes ("shikigami:delegation-budget:" <> rootWorkflowId))
            )
        )
    )

-- | Reserve one distinct child id under a shared ledger.
--
-- A root supplies @(root workflow id, maximum)@ the first time it delegates;
-- descendants pass 'Nothing' because the propagated budget id must already
-- name the root's row. Ledger creation and reservation live in the same store
-- transaction. Child workflow registration follows this reservation because
-- Keiro 0.14 exposes only a public 'spawnChild' operation that owns its own
-- transaction; replay repairs a crash between the two without spending twice.
reserveDelegationSlot ::
  (Store :> es) =>
  DelegationBudgetId ->
  Maybe (WorkflowId, DelegationBudget) ->
  WorkflowId ->
  UTCTime ->
  Eff es (Either BudgetReservationError ReservationResult)
reserveDelegationSlot budgetId seed childWorkflowId now =
  reserveDelegationSlots budgetId seed (childWorkflowId :| []) now <&> fmap toSingleResult
  where
    toSingleResult = \case
      DelegationBatchReserved 1 _ -> DelegationSlotReserved
      DelegationBatchReserved _ _ -> DelegationSlotAlreadyReserved
      DelegationBatchExhausted -> DelegationSlotsExhausted

-- | Reserve a complete set of distinct child ids under one ledger-row lock.
--
-- Duplicate ids are defensively collapsed, although callers are expected to
-- reject duplicate stable delegation keys during pure preflight.  Every
-- existence check, capacity check, reservation insert, and consumption update
-- occurs in the same transaction, so a batch either owns all new slots or
-- none.
reserveDelegationSlots ::
  (Store :> es) =>
  DelegationBudgetId ->
  Maybe (WorkflowId, DelegationBudget) ->
  NonEmpty WorkflowId ->
  UTCTime ->
  Eff es (Either BudgetReservationError BatchReservationResult)
reserveDelegationSlots budgetId seed childWorkflowIds now =
  runTransaction do
    traverse_ (\(rootWorkflowId, limit) -> Tx.statement (budgetId, rootWorkflowId, limit, now) insertBudgetStatement) seed
    Tx.statement budgetId lockBudgetStatement >>= \case
      Nothing -> pure (Left (DelegationBudgetLedgerMissing budgetId))
      Just (limit, consumed) -> do
        reservationStates <-
          traverse
            (\childWorkflowId -> (childWorkflowId,) <$> Tx.statement (budgetId, childWorkflowId) reservationExistsStatement)
            uniqueChildWorkflowIds
        let newChildWorkflowIds = [childWorkflowId | (childWorkflowId, False) <- reservationStates]
            existingCount = length reservationStates - length newChildWorkflowIds
            newCount = length newChildWorkflowIds
        if consumed + newCount > limit
          then pure (Right DelegationBatchExhausted)
          else do
            traverse_ (\childWorkflowId -> Tx.statement (budgetId, childWorkflowId, now) insertReservationStatement) newChildWorkflowIds
            when (newCount > 0) do
              Tx.statement (budgetId, newCount, now) incrementBudgetStatement
            pure
              ( Right
                  (DelegationBatchReserved (fromIntegral newCount) (fromIntegral existingCount))
              )
  where
    uniqueChildWorkflowIds = NonEmpty.toList (NonEmpty.nub childWorkflowIds)

insertBudgetStatement :: Statement (DelegationBudgetId, WorkflowId, DelegationBudget, UTCTime) ()
insertBudgetStatement =
  preparable
    """
    INSERT INTO shikigami.delegation_budgets
      (budget_id, root_workflow_id, maximum, consumed, created_at, updated_at)
    VALUES ($1, $2, $3, 0, $4, $4)
    ON CONFLICT DO NOTHING
    """
    ( ((\(DelegationBudgetId value, _, _, _) -> value) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, WorkflowId value, _, _) -> value) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, value, _) -> fromIntegral (delegationBudgetInt value)) >$< Encoders.param (Encoders.nonNullable Encoders.int4))
        <> ((\(_, _, _, value) -> value) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz))
    )
    Decoders.noResult

lockBudgetStatement :: Statement DelegationBudgetId (Maybe (Int, Int))
lockBudgetStatement =
  preparable
    """
    SELECT maximum, consumed
    FROM shikigami.delegation_budgets
    WHERE budget_id = $1
    FOR UPDATE
    """
    ((\(DelegationBudgetId value) -> value) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    ( Decoders.rowMaybe
        ( (,)
            <$> Decoders.column (Decoders.nonNullable (fromIntegral <$> Decoders.int4))
            <*> Decoders.column (Decoders.nonNullable (fromIntegral <$> Decoders.int4))
        )
    )

reservationExistsStatement :: Statement (DelegationBudgetId, WorkflowId) Bool
reservationExistsStatement =
  preparable
    """
    SELECT EXISTS (
      SELECT 1
      FROM shikigami.delegation_reservations
      WHERE budget_id = $1 AND child_workflow_id = $2
    )
    """
    ( ((\(DelegationBudgetId value, _) -> value) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, WorkflowId value) -> value) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    )
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

insertReservationStatement :: Statement (DelegationBudgetId, WorkflowId, UTCTime) ()
insertReservationStatement =
  preparable
    """
    INSERT INTO shikigami.delegation_reservations
      (budget_id, child_workflow_id, reserved_at)
    VALUES ($1, $2, $3)
    """
    ( ((\(DelegationBudgetId value, _, _) -> value) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, WorkflowId value, _) -> value) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, value) -> value) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz))
    )
    Decoders.noResult

incrementBudgetStatement :: Statement (DelegationBudgetId, Int, UTCTime) ()
incrementBudgetStatement =
  preparable
    """
    UPDATE shikigami.delegation_budgets
    SET consumed = consumed + $2,
        updated_at = $3
    WHERE budget_id = $1
    """
    ( ((\(DelegationBudgetId value, _, _) -> value) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, value, _) -> fromIntegral value) >$< Encoders.param (Encoders.nonNullable Encoders.int4))
        <> ((\(_, _, value) -> value) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz))
    )
    Decoders.noResult

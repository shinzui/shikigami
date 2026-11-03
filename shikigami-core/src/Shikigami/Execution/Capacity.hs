{-# LANGUAGE DataKinds #-}

-- | Shared, short-transaction admission. Tickets are retained operation/attempt
-- identities. A live permit never expires merely because a clock or process
-- lease elapsed: the owning executor must settle or reconcile its work.
module Shikigami.Execution.Capacity
  ( CapacityLimit,
    parseCapacityLimit,
    capacityLimit,
    RuntimeLimits (..),
    defaultRuntimeLimits,
    validateHeadroom,
    CapacitySnapshot (..),
    CapacityError (..),
    registerTx,
    admitTx,
    releaseTx,
    inspectTx,
    reconfigureTx,
    configureTx,
  )
where

import Contravariant.Extras (contrazip2)
import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Aeson qualified as Aeson
import Data.Int (Int64)
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Shikigami.Execution.Claim
import Shikigami.Prelude
import Shikigami.StateRevision

newtype CapacityLimit = CapacityLimit Int
  deriving stock (Eq, Ord, Show)

parseCapacityLimit :: Int -> Either Text CapacityLimit
parseCapacityLimit value
  | value >= 1 && value <= 128 = Right (CapacityLimit value)
  | otherwise = Left "execution capacity must be between 1 and 128"

capacityLimit :: CapacityLimit -> Int
capacityLimit (CapacityLimit value) = value

instance ToJSON CapacityLimit where toJSON = toJSON . capacityLimit

instance FromJSON CapacityLimit where parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseCapacityLimit

data RuntimeLimits = RuntimeLimits
  { execution :: !CapacityLimit,
    advances :: !CapacityLimit,
    expectedRevision :: !(Maybe (StateRevision "execution-capacity"))
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON RuntimeLimits where
  parseJSON = Aeson.genericParseJSON (Aeson.defaultOptions {Aeson.rejectUnknownFields = True})

defaultRuntimeLimits :: RuntimeLimits
defaultRuntimeLimits = RuntimeLimits (CapacityLimit 1) (CapacityLimit 1) Nothing

-- Four pool connections remain available to timers, queue finalization,
-- outbox/collector work and operational queries during an admission burst.
validateHeadroom :: Int -> RuntimeLimits -> Either Text ()
validateHeadroom pool limits = unless (capacityLimit limits.execution + capacityLimit limits.advances + 4 <= pool) (Left "worker capacity exceeds database pool headroom")

data CapacitySnapshot = CapacitySnapshot
  { maximum :: !CapacityLimit,
    revision :: !(StateRevision "execution-capacity"),
    active :: !Int,
    waiting :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CapacityError = CapacityConflict | CapacityUnavailable | CapacityCorrupt
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Always acquire the operation's root lock before this global lock when the
-- caller also owns root accounting. All other operations take only this lock.
control :: Transaction (Either CapacityError (CapacityLimit, Int64, Int64))
control = do
  row <- Tx.statement () (preparable "SELECT maximum,revision,turn FROM shikigami.execution_capacity WHERE singleton FOR UPDATE" E.noParams (D.rowMaybe ((,,) <$> D.column (D.nonNullable D.int4) <*> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8))))
  pure case row of
    Just (bound, revision, turn) | revision >= 0 && turn >= 0 -> case parseCapacityLimit (fromIntegral bound) of
      Right maximum -> Right (maximum, revision, turn)
      Left _ -> Left CapacityCorrupt
    _ -> Left CapacityCorrupt

registerTx :: Text -> Text -> Transaction (Either CapacityError ())
registerTx root ticket
  | not (valid root && valid ticket) = pure (Left CapacityConflict)
  | otherwise =
      control >>= \case
        Left err -> pure (Left err)
        Right _ -> do
          Tx.statement root (preparable "INSERT INTO shikigami.execution_capacity_roots(root_key) VALUES ($1) ON CONFLICT (root_key) DO NOTHING" text D.noResult)
          Tx.statement (ticket, root) (preparable "INSERT INTO shikigami.execution_capacity_tickets(ticket_key,root_key) VALUES ($1,$2) ON CONFLICT (ticket_key) DO NOTHING" (contrazip2 text text) D.noResult)
          stored <- Tx.statement ticket getTicket
          pure case stored of Just (actual, _, _) | actual == root -> Right (); _ -> Left CapacityConflict
  where
    valid value = not (Text.null value) && Text.length value <= 512

-- | True grants only the exact owner supplied here. An expired *undispatched*
-- execution claim can transfer this permit in the same transaction as its new
-- claim/fence. Dispatched work never reaches that transfer branch.
admitTx :: Text -> ClaimOwner -> Maybe ClaimOwner -> Transaction (Either CapacityError Bool)
admitTx ticket owner previousOwner =
  control >>= \case
    Left err -> pure (Left err)
    Right (maximum, _, turn) -> do
      stored <- Tx.statement ticket getTicket
      case stored of
        Nothing -> pure (Left CapacityConflict)
        Just (_, "settled", _) -> pure (Right False)
        Just (_, "active", Just actual) | actual == claimOwnerText owner || Just actual == (claimOwnerText <$> previousOwner) -> do
          Tx.statement (ticket, claimOwnerText owner) (preparable "UPDATE shikigami.execution_capacity_tickets SET owner=$2 WHERE ticket_key=$1 AND phase='active'" (contrazip2 text text) D.noResult)
          pure (Right True)
        Just (_, "active", Just _) -> pure (Right False)
        Just (root, "waiting", Nothing) -> do
          active <- Tx.statement () activeCount
          chosen <- Tx.statement () nextTicket
          if active >= fromIntegral (capacityLimit maximum) || chosen /= Just ticket
            then pure (Right False)
            else
              if turn == maxBound
                then pure (Left CapacityUnavailable)
                else do
                  Tx.statement (ticket, claimOwnerText owner) (preparable "UPDATE shikigami.execution_capacity_tickets SET phase='active',owner=$2 WHERE ticket_key=$1 AND phase='waiting'" (contrazip2 text text) D.noResult)
                  Tx.statement () (preparable "UPDATE shikigami.execution_capacity SET turn=turn+1 WHERE singleton" E.noParams D.noResult)
                  Tx.statement (root, turn + 1) (preparable "UPDATE shikigami.execution_capacity_roots SET last_turn=$2 WHERE root_key=$1" (contrazip2 text integer) D.noResult)
                  pure (Right True)
        _ -> pure (Left CapacityCorrupt)

-- Owner/fence validation belongs to the same transaction in the caller. A
-- queued cancellation has no owner and can retire only an unstarted ticket.
releaseTx :: Text -> Maybe ClaimOwner -> Transaction (Either CapacityError ())
releaseTx ticket owner =
  control >>= \case
    Left err -> pure (Left err)
    Right _ -> do
      stored <- Tx.statement ticket getTicket
      case stored of
        Just (_, "settled", Nothing) -> pure (Right ())
        Just (_, phase, actual) | (phase == "waiting" && actual == Nothing) || (phase == "active" && actual == (claimOwnerText <$> owner) && isJust owner) -> do
          Tx.statement ticket (preparable "UPDATE shikigami.execution_capacity_tickets SET phase='settled',owner=NULL WHERE ticket_key=$1" text D.noResult)
          pure (Right ())
        _ -> pure (Left CapacityConflict)

inspectTx :: Transaction (Either CapacityError CapacitySnapshot)
inspectTx =
  control >>= \case
    Left err -> pure (Left err)
    Right (maximum, revision, _) -> do
      active <- Tx.statement () activeCount
      waiting <- Tx.statement () (preparable "SELECT count(*) FROM shikigami.execution_capacity_tickets WHERE phase='waiting'" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))
      pure do
        checked <- either (const (Left CapacityCorrupt)) Right (parseRevision (toInteger revision))
        unless (active <= fromIntegral (maxBound :: Int) && waiting <= fromIntegral (maxBound :: Int)) (Left CapacityCorrupt)
        Right (CapacitySnapshot maximum checked (fromIntegral active) (fromIntegral waiting))

-- Lowering below occupancy drains naturally. Existing owners retain permits;
-- admission compares the global occupancy with the newly retained maximum.
reconfigureTx :: StateRevision "execution-capacity" -> CapacityLimit -> Transaction (Either CapacityError ())
reconfigureTx expected maximum =
  control >>= \case
    Left err -> pure (Left err)
    Right (_, revision, _) | revisionNumber expected /= toInteger revision -> pure (Left CapacityConflict)
    Right (_, revision, _) | revision == maxBound -> pure (Left CapacityUnavailable)
    Right _ -> do
      Tx.statement (fromIntegral (capacityLimit maximum) :: Int64) (preparable "UPDATE shikigami.execution_capacity SET maximum=$1::integer,revision=revision+1 WHERE singleton" integer D.noResult)
      pure (Right ())

-- Replica startup may bootstrap a fresh control once. Later changes require
-- the operator's observed revision; a stale replica cannot silently raise a
-- newer lowered limit. Repeated startup with the retained value is idempotent.
configureTx :: RuntimeLimits -> Transaction (Either CapacityError ())
configureTx limits =
  inspectTx >>= \case
    Left err -> pure (Left err)
    Right snapshot | snapshot.maximum == limits.execution -> pure (Right ())
    Right snapshot | maybe (revisionNumber snapshot.revision == 0) (== snapshot.revision) limits.expectedRevision -> reconfigureTx snapshot.revision limits.execution
    Right _ -> pure (Left CapacityConflict)

text :: E.Params Text
text = E.param (E.nonNullable E.text)

integer :: E.Params Int64
integer = E.param (E.nonNullable E.int8)

getTicket :: Statement Text (Maybe (Text, Text, Maybe Text))
getTicket = preparable "SELECT root_key,phase,owner FROM shikigami.execution_capacity_tickets WHERE ticket_key=$1 FOR UPDATE" text (D.rowMaybe ((,,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text) <*> D.column (D.nullable D.text)))

activeCount :: Statement () Int64
activeCount = preparable "SELECT count(*) FROM shikigami.execution_capacity_tickets WHERE phase='active'" E.noParams (D.singleRow (D.column (D.nonNullable D.int8)))

-- Least recently served root, then the oldest accepted attempt within that
-- root. Admission changes only the chosen root's turn, giving bounded rounds.
nextTicket :: Statement () (Maybe Text)
nextTicket = preparable "SELECT t.ticket_key FROM shikigami.execution_capacity_tickets t JOIN shikigami.execution_capacity_roots r USING(root_key) WHERE t.phase='waiting' ORDER BY r.last_turn,t.sequence LIMIT 1" E.noParams (D.rowMaybe (D.column (D.nonNullable D.text)))

{-# LANGUAGE DataKinds #-}

-- | Actual typed-program calls share the root/selection owner with workers.
-- Evidence and the root receipt commit or refuse in the same transaction.
module Shikigami.Decision.Accounting (accountedDecisionHooks, decisionDeadline, boundDecisionTimeout) where

import Baikai.Context (Context)
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Options qualified as Options
import Control.Lens ((&), (.~))
import Data.Aeson (Result (..), Value, fromJSON, object, (.=))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Shikigami.Attestation.Resolve (ResolvedProfile)
import Shikigami.Decision.Contract
import Shikigami.Decision.Evidence
import Shikigami.Execution.Identity qualified as Identity
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.SelectionRuntime (outcomeFor, requestFingerprint, reservation)
import Shikigami.Execution.SelectionStore qualified as Calls

-- The caller owns a live executor permit and checks its exact claim before
-- every call. A workflow step never waits on this operation.
accountedDecisionHooks :: DecisionEvidenceStore -> Maybe ResolvedProfile -> ExecutionSelection -> IO (Either DecisionFailure ()) -> Model -> Context -> Options -> IO (Either DecisionFailure (Options, DecisionCallHooks))
accountedDecisionHooks store profile selection authorize model context options = do
  deadline <- decisionDeadline store profile selection
  now <- getCurrentTime
  pure $ do
    expires <- deadline
    timeout <- boundDecisionTimeout (either (error . show) id (parseDecisionTimeout (toInteger (maxBound :: Int)))) expires now
    let ceilingMs = max 1 (decisionTimeoutMicros timeout `div` 1000)
        actual = options & #timeoutMs .~ Just (maybe ceilingMs (min ceilingMs) (Options.timeoutMs options))
    pure (actual, hooksFor actual)
  where
    hooksFor options = decisionCallHooksWithAccounting store profile (allocate options) settle
    allocate options token call = do
      identifier <- Identity.newAttemptId
      now <- getCurrentTime
      fresh <- authorize
      pure do
        root <- traverse Roots.inspectRootTx selection.rootId
        let checked = do
              fresh
              if call.effectiveModel == selection.descriptor && call.prepared.model == selection.descriptor && call.prepared.policy == selection.profile
                then Right ()
                else Left (decisionFailure ContractMismatch "decision selection differs from its preparation")
              current <- traverse (first (const refusal)) root
              limits <- first (const refusal) (Calls.callLimitsFor selection profile)
              (quantities, policy) <- first (const refusal) (reservation limits current model options)
              pure (limits, Resources.AttemptRequest identifier (Identity.operationIdWithPrefix ('d' :| "ecision-call:") (decisionCallIdText (attemptId token))) quantities policy)
        case checked of
          Left err -> pure (Left err)
          Right (limits, request) -> do
            admitted <- Calls.reserveSelectionCallTx selection limits request (requestFingerprint selection context options) now
            case admitted of
              Right (Calls.NewCall receipt) -> do
                Tx.statement (object ["call" .= attemptId token, "preparation" .= call.prepared.identity, "receipt" .= receipt]) insertReceipt
                pure (Right ())
              _ -> pure (Left refusal)
    settle token status evidence = do
      retained <- Tx.statement (decisionCallIdText (attemptId token)) findReceipt
      case retained of
        Just value
          | Success receipt <- fromJSON @Calls.CallReceipt value,
            receipt.assignmentId == selection.assignmentId && receipt.rootId == selection.rootId && receipt.request.operationId == Identity.operationIdWithPrefix ('d' :| "ecision-call:") (decisionCallIdText (attemptId token)) -> do
              let outcome = case status of
                    CallUnknown -> (outcomeFor True evidence) {Calls.phase = Calls.CallTransportUnknown}
                    _ -> outcomeFor (status /= CallSucceeded) evidence
              result <- Calls.finishSelectionCallTx receipt outcome
              pure (() <$ first (const refusal) result)
        _ -> pure (Left (decisionFailure EvidenceFailure "decision resource receipt is unavailable"))
    refusal = decisionFailure CallLimitExceeded "decision root or execution limits refused actual provider work"

insertReceipt :: Statement Value ()
insertReceipt = preparable "INSERT INTO shikigami.decision_resource_calls(call_id,preparation_id,receipt) VALUES ($1->>'call',$1->>'preparation',$1->'receipt')" (E.param (E.nonNullable E.jsonb)) D.noResult

findReceipt :: Statement Text (Maybe Value)
findReceipt = preparable "SELECT receipt FROM shikigami.decision_resource_calls WHERE call_id=$1" (E.param (E.nonNullable E.text)) (D.rowMaybe (D.column (D.nonNullable D.jsonb)))

-- Deadlines are current owner facts, not copied counters. Pinning a larger
-- process timeout cannot move either the root or profile cutoff.
decisionDeadline :: DecisionEvidenceStore -> Maybe ResolvedProfile -> ExecutionSelection -> IO (Either DecisionFailure (Maybe UTCTime))
decisionDeadline store profile selection = decisionEvidenceTransaction store $ do
  root <- traverse Roots.inspectRootTx selection.rootId
  now <- Tx.statement () (preparable "SELECT clock_timestamp()" E.noParams (D.singleRow (D.column (D.nonNullable D.timestamptz))))
  pure $ do
    current <- traverse (first (const refusal)) root
    mapM_ (\value -> first (const refusal) (Resources.checkRoot now value.revision value)) current
    limits <- first (const refusal) (Calls.callLimitsFor selection profile)
    pure $ case catMaybes [(\root -> root.envelope.cutoff) <$> current, limits.cutoff] of
      [] -> Nothing
      deadlines -> Just (minimum deadlines)
  where
    refusal = decisionFailure CallLimitExceeded "typed decision root or profile deadline is unavailable"

boundDecisionTimeout :: DecisionTimeout -> Maybe UTCTime -> UTCTime -> Either DecisionFailure DecisionTimeout
boundDecisionTimeout original Nothing _ = Right original
boundDecisionTimeout original (Just deadline) now
  | now >= deadline = Left (decisionFailure CallLimitExceeded "typed decision deadline reached")
  | otherwise = first (const (decisionFailure ContractMismatch "invalid decision deadline")) (parseDecisionTimeout (min (toInteger (decisionTimeoutMicros original)) (max 1 (floor (diffUTCTime deadline now * 1000000)))))

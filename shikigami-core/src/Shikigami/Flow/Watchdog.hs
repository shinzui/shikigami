{-# LANGUAGE DataKinds #-}

-- | One bounded advisory sweep per invocation. No intervention operations.
module Shikigami.Flow.Watchdog (watchdogSweep, watchdogFlowName, watchdogSlots, driftAlias) where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Effectful (Eff, (:>))
import Effectful.Exception (throwIO, try)
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, declarationCoordinate)
import Shikigami.Decision.Contract (DecisionSlot, FailureCode (EvidenceFailure), failureCode)
import Shikigami.Decision.ModelAlias (ModelAlias, modelAliasFromNonEmpty)
import Shikigami.Flow.Capability (Sink, emitSignals)
import Shikigami.Flow.Decision (Decision, DecisionLabel (Drift), decide, decisionSlot, decisionStep)
import Shikigami.Flow.Observe
import Shikigami.Objective.Observation (ObjectiveObservation (..))
import Shikigami.Program.Decision (programRef)
import Shikigami.Program.Decision.Drift qualified as Program
import Shikigami.Program.DecisionRunner (DecisionAbort (..))
import Shikigami.Sink.Types (SinkOutcome (..), SinkResult (..))
import Shikigami.Watchdog.Classify
import Shikigami.Watchdog.Delivery qualified as Delivery
import Shikigami.Watchdog.Drift qualified as Drift
import Shikigami.Watchdog.Grant (GrantSnapshot (..))
import Shikigami.Watchdog.Ledger (PageOutcomeView (..), SweepSummary (..))
import Shikigami.Watchdog.Observation
import Shikigami.Watchdog.Types

watchdogFlowName :: DeclarationCoordinate "flow"
watchdogFlowName = declarationCoordinate "watchdog-sweep"

driftAlias :: ModelAlias
driftAlias = modelAliasFromNonEmpty ('d' :| "rift")

watchdogSlots :: [DecisionSlot]
watchdogSlots = [decisionSlot (decisionStep Drift (programRef Program.driftProgram)) [driftAlias]]

watchdogSweep :: (Observe :> es, Decision :> es, Sink :> es) => Value -> Eff es Value
watchdogSweep _ =
  resolveGrant >>= \case
    Left reason -> pure (refused reason)
    Right granted ->
      openSweep granted >>= \case
        Left reason -> pure (refused reason)
        Right opened ->
          observeActive granted opened.cursor >>= \case
            Left reason -> do
              _ <- closeSweep opened.sweepId (SweepSummary opened.openedAt 0 1 0 PassIncomplete)
              pure (refused reason)
            Right observed -> do
              let page = observed.page
                  outcomes = classifyPage granted.grant.windows page observed.priors
              recordPage opened.sweepId observed outcomes >>= \case
                Left reason -> do
                  _ <- closeSweep opened.sweepId (SweepSummary page.observedAt (fromIntegral (length page.subjects)) 1 0 PassIncomplete)
                  pure (refused reason)
                Right liveness -> do
                  drift <- assessDrift granted observed outcomes opened
                  let notices = liveness.notices <> either (const []) (.notices) drift
                      conversations = Map.fromList [(owner.objectiveId, conversation) | owner <- observed.objectives, Just conversation <- [owner.conversation]]
                      addressed = case granted.delivery of Nothing -> []; Just policy -> map (Delivery.address policy conversations) notices
                  delivered <- case NonEmpty.nonEmpty addressed of Nothing -> pure []; Just batch -> emitSignals (declarationCoordinate "watchdog-deliver") batch
                  let summary = SweepSummary page.observedAt (fromIntegral (length page.subjects)) (fromIntegral (length (filter refusedDelivery delivered)) + fromIntegral (length page.refusals) + either (const 1) (const 0) drift + if null notices || granted.delivery /= Nothing then 0 else 1) (fromIntegral (length notices)) page.passCompleted
                  closed <- closeSweep opened.sweepId summary
                  pure (object ["summary" .= summary, "delivery" .= delivered, "closed" .= closed, "drift" .= either toJSON (const (toJSON ("checked-or-disabled" :: Text))) drift])
  where
    refused reason = object ["refused" .= reason]
    refusedDelivery result = case result.outcome of Enqueued _ -> False; Delivered _ -> False; _ -> True

assessDrift :: (Observe :> es, Decision :> es) => Granted -> ObservedPage -> [Observed] -> SweepOpened -> Eff es (Either Text PageOutcomeView)
assessDrift granted observed outcomes opened
  | not granted.driftEnabled = pure (Right empty)
  | Just budget <- granted.grant.driftBudget =
      let page = observed.page
          eligible = [subject | subject <- page.subjects, any (\value -> value.subject == subject.subject && value.outcome == Clear Progressing) outcomes]
          cadence = Drift.DriftCadence granted.grant.windows.drift budget
       in case Drift.dueForDrift cadence page.observedAt observed.checks eligible of
            Nothing -> pure (Right empty)
            Just (objective, subjects) -> case [owner | owner <- observed.objectives, owner.objectiveId == objective] of
              [owner] -> case Drift.buildDriftInput budget owner subjects of
                Left reason -> pure (Left reason)
                Right input -> do
                  result <- try @DecisionAbort (decide (decisionStep Drift (programRef Program.driftProgram)) driftAlias input)
                  case result of
                    Left abort@(DecisionAbort failure) | failureCode failure == EvidenceFailure -> throwIO abort
                    Left (DecisionAbort _) -> pure (Left "drift decision refused")
                    Right proposal -> case Program.validateDriftAssessment input proposal of
                      Left _ -> pure (Left "drift assessment refused")
                      Right assessment -> case Drift.checksForAssessment page.observedAt input subjects assessment of
                        Left _ -> pure (Left "drift input binding refused")
                        Right checks -> do
                          let values = mapMaybe (driftOutcome page granted outcomes) (NonEmpty.toList (Program.assessmentView assessment))
                          recordDrift opened.sweepId page.observedAt values checks >>= \case
                            Left _ -> pure (Left "drift ledger refused")
                            Right outcome -> pure (Right outcome)
              _ -> pure (Left "drift objective unavailable")
  | otherwise = pure (Right empty)
  where
    empty = PageOutcomeView [] 0 0 0

driftOutcome :: ObservationPage -> Granted -> [Observed] -> Program.DriftSubjectAssessment -> Maybe Observed
driftOutcome page granted outcomes answer = do
  original <- case filter ((== answer.subject) . (.subject)) outcomes of [value] -> Just value; _ -> Nothing
  subject <- case filter ((== answer.subject) . (.subject)) page.subjects of [value] -> Just value; _ -> Nothing
  let instant = page.observedAt
      prior = original.prior
      window = ObservedWindow (maybe instant (.firstSeenAt) prior) (maybe instant (.lastChangedAt) prior) instant
      limit = ObservationLimit granted.grant.budget (if page.passCompleted == PassCompleted then Complete else Unknown) subject.relationshipsComplete
      summary = EvidenceSummary DriftWork [] Nothing [] 0 (Just answer.category)
  outcome <- case answer.category of
    WithinScope -> Just (Clear Progressing)
    _ -> case NonEmpty.nonEmpty answer.evidence of
      Nothing -> Nothing
      Just evidence -> Just (Detected (Detection DriftWork Progressing summary evidence window limit))
  pure (Observed original.subject original.objective original.mark original.prior outcome)

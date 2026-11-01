module Shikigami.Flow.ShikumiDecisionExample (shikumiDecisionExample, exampleSlots) where

import Data.Aeson (Result (..), Value, eitherDecodeStrict, encode, fromJSON, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text.Encoding qualified as TE
import Effectful (Eff, (:>))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Delegate (DelegationRequest (..))
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Decision.Contract
import Shikigami.Flow.Decision
import Shikigami.Flow.Delegate (Delegate)
import Shikigami.Flow.Delegate qualified as Delegate
import Shikigami.Program.Decision (programRef)
import Shikigami.Program.Decision.Examples
import Shikigami.Router.Decision (RouteDecision (..), RouteOutcome (..), RouteSelection (..))

triageStep :: DecisionStep Request TriageResult
triageStep = decisionStep Triage (programRef triageProgram)

investigationStep :: DecisionStep InvestigationInput InvestigationResult
investigationStep = decisionStep Investigation (programRef investigationProgram)

exampleSlots :: [DecisionSlot]
exampleSlots = [decisionSlot triageStep [modelAliasFromNonEmpty ('t' :| "riage")], decisionSlot investigationStep [modelAliasFromNonEmpty ('i' :| "nvestigate")]]

shikumiDecisionExample :: (Decision :> es, Delegate :> es) => Value -> Eff es Value
shikumiDecisionExample payload = do
  input <- case fromJSON payload of
    Error _ -> refuseDecision (decisionFailure InvalidInput "decision example expects a request object")
    Success value -> pure value
  triage <- decide triageStep (modelAliasFromNonEmpty ('t' :| "riage")) input
  case triage.action of
    ReturnNow -> pure (object ["triage" .= triage, "results" .= ([] :: [Value])])
    Investigate -> do
      catalog <- investigationCatalog
      investigation <-
        decide
          investigationStep
          (modelAliasFromNonEmpty ('i' :| "nvestigate"))
          InvestigationInput {request = input.request, triageSummary = triage.summary, candidateCatalog = TE.decodeUtf8 (LBS.toStrict (encode catalog))}
      case investigation.action of
        ReturnResult -> pure (object ["triage" .= triage, "investigation" .= investigation, "results" .= ([] :: [Value])])
        ProposeRoute -> do
          proposal <- case eitherDecodeStrict (TE.encodeUtf8 investigation.routeJson) of
            Left _ -> refuseDecision (decisionFailure OutputDecodeFailure "investigation route proposal cannot be decoded")
            Right value -> validateInvestigationRoute catalog value
          results <- case proposal.outcome of
            Matched selections -> do
              children <-
                Delegate.delegateBatch
                  catalog
                  (fmap (\selection -> DelegationRequest (declarationCoordinate ("decision-investigate-" <> agentNameText selection.agent)) selection.agent payload) selections)
              NE.toList <$> traverse Delegate.awaitOne children
            NoMatch _ -> pure []
            Ambiguous _ _ -> pure []
          pure (object ["triage" .= triage, "investigation" .= investigation, "route" .= proposal, "results" .= results])

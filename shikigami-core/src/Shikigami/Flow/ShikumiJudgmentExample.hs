module Shikigami.Flow.ShikumiJudgmentExample (shikumiJudgmentExample, judgmentSlots) where

import Data.Aeson (Result (..), Value, fromJSON, toJSON)
import Data.List.NonEmpty (NonEmpty (..))
import Effectful (Eff, (:>))
import Shikigami.Decision.Contract
import Shikigami.Flow.Decision
import Shikigami.Program.Decision (programRef)
import Shikigami.Program.Decision.JudgmentExample (Ticket, TicketJudgment, judgmentProgram)

judgmentStep :: DecisionStep Ticket TicketJudgment
judgmentStep = decisionStep Judgment (programRef judgmentProgram)

judgmentSlots :: [DecisionSlot]
judgmentSlots = [decisionSlot judgmentStep [modelAliasFromNonEmpty ('j' :| "udge")]]

shikumiJudgmentExample :: (Decision :> es) => Value -> Eff es Value
shikumiJudgmentExample payload = do
  ticket <- case fromJSON payload of
    Success value -> pure value
    Error _ -> refuseDecision (decisionFailure InvalidInput "judgment example expects a supplied ticket object")
  toJSON <$> decide judgmentStep (modelAliasFromNonEmpty ('j' :| "udge")) ticket

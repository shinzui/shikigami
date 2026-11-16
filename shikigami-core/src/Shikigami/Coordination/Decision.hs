module Shikigami.Coordination.Decision (adaptiveStep, adaptiveSlots, adaptiveModel) where

import Shikigami.Decision.Contract (DecisionSlot, ModelAlias, parseModelAlias)
import Shikigami.Flow.Decision (DecisionAccounting (UnaccountedCall), DecisionStep, adaptiveSite, decisionSlot, decisionStep)
import Shikigami.Program.Decision (programRef)
import Shikigami.Program.Decision.Adaptive

adaptiveModel :: ModelAlias
adaptiveModel = either (error . show) id (parseModelAlias "adaptive")

adaptiveStep :: DecisionStep AdaptiveInput AdaptiveResult
adaptiveStep = decisionStep adaptiveSite UnaccountedCall (programRef adaptiveProgram)

adaptiveSlots :: [DecisionSlot]
adaptiveSlots = [decisionSlot adaptiveStep [adaptiveModel]]

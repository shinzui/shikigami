-- | The composition these specs run under: the builtin pack and this one.
module FlowPack.Watchdog.Registry (watchdogRegistry, watchdogDecisionServices) where

import FlowPack.Watchdog (watchdogPack)
import Shikigami.Decision.ModelCatalog (ModelCatalog)
import Shikigami.Flow.Builtin (builtinPack)
import Shikigami.Flow.Decision (DecisionServices)
import Shikigami.Flow.Pack (FlowRegistry, composeFlowRegistry, decisionServices)

watchdogRegistry :: FlowRegistry
watchdogRegistry = either (error . show) id (composeFlowRegistry [builtinPack, watchdogPack])

watchdogDecisionServices :: ModelCatalog -> DecisionServices
watchdogDecisionServices = decisionServices watchdogRegistry

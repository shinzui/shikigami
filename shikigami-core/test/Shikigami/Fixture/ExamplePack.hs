{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}

-- | A test-local pack of example flows and decision programs.
--
-- The kernel's decision, delegation and objective tests need flows that
-- decide, delegate and create objectives, and a core test may not depend on a
-- flow pack. These fixtures began as copies of the example flows that now
-- live in @packs/flow-pack-examples@; they keep their original labels, which
-- are test-local and appear in no workflow specification.
module Shikigami.Fixture.ExamplePack
  ( examplesFixturePack,
    exampleFlowRegistry,
    fixtureDecisionServices,
    fixtureDecisionPrograms,
    fixtureDecisionCodecs,
    triageDecisionSlot,
    investigationDecisionSlot,
    judgmentDecisionSlot,
  )
where

import Data.Aeson (Value)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import Effectful (Eff)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Name (agentNameFromNonEmpty)
import Shikigami.Decision.Contract (DecisionSlot)
import Shikigami.Decision.ModelCatalog (ModelCatalog)
import Shikigami.Fixture.DecisionExampleFlow (exampleSlots, shikumiDecisionExample)
import Shikigami.Fixture.DecisionExamples (investigationDecisionSlot, investigationProgram, triageDecisionSlot, triageProgram)
import Shikigami.Fixture.JudgmentExample (judgmentProgram)
import Shikigami.Fixture.JudgmentExampleFlow (judgmentDecisionSlot, judgmentSlots, shikumiJudgmentExample)
import Shikigami.Fixture.ObjectiveExampleFlow (objectiveExample)
import Shikigami.Flow (DecisionMode (..), FlowDef (..), FlowEffects, LifecycleDiagram (..))
import Shikigami.Flow.Builtin (builtinPack)
import Shikigami.Flow.Decision (DecisionServices)
import Shikigami.Flow.Delegate qualified as Delegate
import Shikigami.Flow.Pack
import Shikigami.Program.Decision (ProgramRegistry, ResultCodecRegistry, SomeProgram (..), retainedCodec)
import Shikigami.RuntimePolicy (DefaultModelRequirement (..))

examplesFixturePack :: FlowPack
examplesFixturePack =
  FlowPack
    { name = either (error . show) id (parseFlowPackName "example-fixtures"),
      flows =
        [ flow "objective-example" [] DefaultModelOptional objectiveExample,
          flow "shikumi-decision-example" exampleSlots DefaultModelOptional shikumiDecisionExample,
          flow "shikumi-judgment-example" judgmentSlots DefaultModelOptional shikumiJudgmentExample,
          flow "delegation-proof" [] DefaultModelRequired delegationProofFlow
        ],
      decisionPrograms = [SomeProgram triageProgram, SomeProgram investigationProgram, SomeProgram judgmentProgram],
      retainedCodecs = [retainedCodec triageProgram, retainedCodec investigationProgram, retainedCodec judgmentProgram],
      tasks = []
    }
  where
    flow :: Text -> [DecisionSlot] -> DefaultModelRequirement -> (forall es. (FlowEffects es) => Value -> Eff es Value) -> PackFlow
    flow name decisionSlots requiresDefaultModel body =
      kernelCapabilityFlow
        FlowDef
          { name = declarationCoordinate name,
            lifecycle = LifecycleDiagram "flowchart LR\n Start --> End" [],
            decisionSlots,
            requiresDefaultModel,
            decisionMode = StrictDecisions
          }
        body

-- | A flow that reaches the governed child-run machinery with a static target.
delegationProofFlow :: (FlowEffects es) => Value -> Eff es Value
delegationProofFlow payload = do
  child <- Delegate.delegate (declarationCoordinate "web-researcher") (agentNameFromNonEmpty ('w' :| "eb-researcher")) payload
  Delegate.awaitOne child

-- | The builtin pack and the example fixtures, as a distribution composes packs.
exampleFlowRegistry :: FlowRegistry
exampleFlowRegistry = either (error . show) id (composeFlowRegistry [builtinPack, examplesFixturePack])

fixtureDecisionServices :: ModelCatalog -> DecisionServices
fixtureDecisionServices = decisionServices exampleFlowRegistry

fixtureDecisionPrograms :: ProgramRegistry
fixtureDecisionPrograms = decisionProgramRegistry exampleFlowRegistry

fixtureDecisionCodecs :: ResultCodecRegistry
fixtureDecisionCodecs = resultCodecRegistry exampleFlowRegistry

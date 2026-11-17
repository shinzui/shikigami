-- | The examples pack: the flows this repository teaches with.
--
-- A pack is one value. A distribution passes it to a role's @...With@ entry
-- point, and that executable can then run agents whose manifests name these
-- flows; the stock executables, which compose no pack, refuse them.
module FlowPack.Examples
  ( examplesPack,
    atRiskCustomerDefinition,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import FlowPack.Examples.Body.AtRiskCustomer (atRiskCustomerFlow, atRiskCustomerFlowName)
import FlowPack.Examples.Body.DecisionExample (exampleSlots, shikumiDecisionExample)
import FlowPack.Examples.Body.DelegationProof (delegationProof)
import FlowPack.Examples.Body.JudgmentExample (judgmentSlots, shikumiJudgmentExample)
import FlowPack.Examples.Body.ObjectiveExample (objectiveExample)
import FlowPack.Examples.Lifecycle.AtRiskCustomer (atRiskCustomerMermaid, atRiskCustomerValidationWarnings)
import FlowPack.Examples.Program.Judgment (judgmentProgram)
import FlowPack.Examples.Program.Triage (investigationProgram, triageProgram)
import Shikigami.Decision.Contract (DecisionSlot)
import Shikigami.Flow.Sdk
import Shikigami.Flow.Sdk.Program

examplesPack :: FlowPack
examplesPack =
  FlowPack
    { name = either (error . show) id (parseFlowPackName "examples"),
      -- Every body needs kernel capabilities alone, so the pack has no
      -- interpreter of its own to review.
      flows =
        [ kernelCapabilityFlow atRiskCustomerDefinition atRiskCustomerFlow,
          kernelCapabilityFlow (definition "objective-example" "Create --> Plan --> Progress --> Inspect" [] DefaultModelOptional) objectiveExample,
          kernelCapabilityFlow (definition "shikumi-decision-example" "Request --> Triage --> Investigation --> Specialist" exampleSlots DefaultModelOptional) shikumiDecisionExample,
          kernelCapabilityFlow (definition "shikumi-judgment-example" "Ticket --> Judgment --> Result" judgmentSlots DefaultModelOptional) shikumiJudgmentExample,
          kernelCapabilityFlow (definition "delegation-proof" "Supervisor --> WebResearcher" [] DefaultModelRequired) delegationProof
        ],
      -- A decision program a flow of this pack decides with, and the codec
      -- that keeps reading its committed results after the program retires.
      decisionPrograms = [SomeProgram triageProgram, SomeProgram investigationProgram, SomeProgram judgmentProgram],
      retainedCodecs = [retainedCodec triageProgram, retainedCodec investigationProgram, retainedCodec judgmentProgram],
      tasks = [],
      settings = [],
      triggers = noTriggerHooks,
      adminVerbs = [],
      gauges = [],
      authorities = [],
      outputs = [],
      approvalChannels = []
    }

definition :: Text -> Text -> [DecisionSlot] -> DefaultModelRequirement -> FlowDef
definition name stages decisionSlots requiresDefaultModel =
  FlowDef
    { name = declarationCoordinate name,
      lifecycle = LifecycleDiagram ("flowchart LR\n " <> stages) [],
      decisionSlots,
      requiresDefaultModel,
      decisionMode = StrictDecisions
    }

atRiskCustomerDefinition :: FlowDef
atRiskCustomerDefinition =
  FlowDef
    { name = atRiskCustomerFlowName,
      lifecycle =
        LifecycleDiagram
          { mermaid = atRiskCustomerMermaid,
            validationWarnings = Text.pack . show <$> atRiskCustomerValidationWarnings
          },
      decisionSlots = [],
      requiresDefaultModel = DefaultModelRequired,
      decisionMode = StrictDecisions
    }

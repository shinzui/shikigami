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

import Data.Text qualified as Text
import FlowPack.Examples.Body.AtRiskCustomer (atRiskCustomerFlow, atRiskCustomerFlowName)
import FlowPack.Examples.Lifecycle.AtRiskCustomer (atRiskCustomerMermaid, atRiskCustomerValidationWarnings)
import Shikigami.Flow.Sdk

examplesPack :: FlowPack
examplesPack =
  FlowPack
    { name = either (error . show) id (parseFlowPackName "examples"),
      -- The body needs kernel capabilities alone, so the pack has no
      -- interpreter of its own to review.
      flows = [kernelCapabilityFlow atRiskCustomerDefinition atRiskCustomerFlow],
      decisionPrograms = [],
      retainedCodecs = [],
      tasks = []
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

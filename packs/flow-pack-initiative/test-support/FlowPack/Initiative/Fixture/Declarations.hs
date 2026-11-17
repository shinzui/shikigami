{-# LANGUAGE DataKinds #-}

-- | A minimal agent declaration for tests that need one to exist and do not
-- care what it runs.
module FlowPack.Initiative.Fixture.Declarations
  ( fixtureDecl,
  )
where

import Data.Text (Text)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Agent.DeclarationValue (agentEnablement, declarationCoordinate)
import Shikigami.Agent.Name (mkAgentName)

fixtureDecl :: Text -> AgentDecl
fixtureDecl agentName =
  AgentDecl
    { name = either (error . show) id (mkAgentName agentName),
      description = "initiative fixture agent",
      trigger = Event {eventType = declarationCoordinate "test.fixture"},
      behavior = ShikumiProgram {task = declarationCoordinate "noop-summary", preferEnrichment = False, grounding = Nothing},
      delegates = [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      tools = [],
      outputs = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = agentEnablement True,
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

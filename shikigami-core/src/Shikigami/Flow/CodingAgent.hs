{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

-- | The coding-agent capability of Flow bodies (EP-2 of MasterPlan 22).
--
-- A flow names each call with a stable key; each key is its own keyed child
-- workflow, @shikigami.coding-agent-step@, so a body may run several agents
-- and a replay reads their journaled outcomes instead of launching again.
-- The body receives no 'Store' or 'IOE': the interpreter spawns and awaits
-- the child, and the tier's runner (resolved by the composition that drives
-- the child) decides, launches and settles it.
module Shikigami.Flow.CodingAgent
  ( CodingAgent,
    CodingAgentEnv (..),
    codingAgentKey,
    runCodingAgentStep,
    runCodingAgent,
    unavailableCodingAgent,
  )
where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Keiro.Workflow (Workflow)
import Kiroku.Store.Effect (Store)
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, declarationCoordinate)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Capability.Declared (ToolDecl)
import Shikigami.CodingAgent.Types (CodingAgentOutcome (..), CodingAgentStep, FailureReason (TierRefused))
import Shikigami.CodingAgent.Workflow (runCodingAgentChild)

data CodingAgent :: Effect where
  RunCodingAgentStep :: DeclarationCoordinate "coding-agent-key" -> CodingAgentStep -> Value -> CodingAgent m CodingAgentOutcome

type instance DispatchOf CodingAgent = Dynamic

-- | What the interpreter attributes a flow's coding-agent steps to.
data CodingAgentEnv = CodingAgentEnv
  { agent :: !AgentName,
    identity :: !AgentIdentity,
    -- | The repository the run names, if any.
    repository :: !(Maybe Text),
    -- | The declaration's tools, given to each coding agent the flow runs.
    tools :: ![ToolDecl]
  }

-- | A call-site key. It must be stable across code changes: it names the
-- child workflow whose journal a replay reads.
codingAgentKey :: Text -> DeclarationCoordinate "coding-agent-key"
codingAgentKey = declarationCoordinate

-- | Run one coding-agent step under a key, with the payload quoted to the
-- agent as evidence.
runCodingAgentStep :: (CodingAgent :> es) => DeclarationCoordinate "coding-agent-key" -> CodingAgentStep -> Value -> Eff es CodingAgentOutcome
runCodingAgentStep key requested payload = send (RunCodingAgentStep key requested payload)

runCodingAgent :: (Workflow :> es, Store :> es, IOE :> es) => CodingAgentEnv -> Eff (CodingAgent : es) a -> Eff es a
runCodingAgent CodingAgentEnv {agent, identity, repository, tools} =
  interpret \_ -> \case
    RunCodingAgentStep key requested payload -> runCodingAgentChild agent identity key requested payload repository tools

-- | For harnesses that run flow bodies without a run to attach children to.
unavailableCodingAgent :: Eff (CodingAgent : es) a -> Eff es a
unavailableCodingAgent =
  interpret \_ -> \case
    RunCodingAgentStep {} -> pure (Failed (TierRefused "coding agents are unavailable in this flow harness"))

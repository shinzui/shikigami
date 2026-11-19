{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

-- | Declared tools as durable steps of a flow body (EP-3 M4 of MasterPlan
-- 22). Each call names a stable key; each key is its own child workflow, so a
-- replay reads the journaled outcome instead of running the command again.
module Shikigami.Flow.DeclaredTool
  ( -- | The constructor is exported for interpreters outside a run, such
    -- as tests; a flow body uses 'runDeclaredTool' or 'runDeclaredToolIn'.
    DeclaredTool (..),
    DeclaredToolEnv (..),
    toolStepKey,
    runDeclaredTool,
    runDeclaredToolIn,
    runDeclaredToolCapability,
    unavailableDeclaredTool,
  )
where

import Data.Text (Text)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Keiro.Workflow (Workflow)
import Kiroku.Store.Effect (Store)
import Shikigami.Agent.DeclarationValue (DeclarationCoordinate, declarationCoordinate)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Capability.Declared (ToolDecl)
import Shikigami.DeclaredTool.Workflow (ToolStep, ToolStepOutcome (ToolFailed), runDeclaredToolChild)

data DeclaredTool :: Effect where
  -- | A step, in the named repository or (with 'Nothing') the run's own.
  RunToolStep :: Maybe Text -> DeclarationCoordinate "tool-step-key" -> ToolStep -> DeclaredTool m ToolStepOutcome

type instance DispatchOf DeclaredTool = Dynamic

data DeclaredToolEnv = DeclaredToolEnv
  { agent :: !AgentName,
    identity :: !AgentIdentity,
    tools :: ![ToolDecl],
    repository :: !(Maybe Text)
  }

toolStepKey :: Text -> DeclarationCoordinate "tool-step-key"
toolStepKey = declarationCoordinate

runDeclaredTool :: (DeclaredTool :> es) => DeclarationCoordinate "tool-step-key" -> ToolStep -> Eff es ToolStepOutcome
runDeclaredTool key requested = send (RunToolStep Nothing key requested)

-- | A step in another repository (a mori URI or a path the operator's
-- approvals file names), run in that repository's worktree of this run.
runDeclaredToolIn :: (DeclaredTool :> es) => Text -> DeclarationCoordinate "tool-step-key" -> ToolStep -> Eff es ToolStepOutcome
runDeclaredToolIn repository key requested = send (RunToolStep (Just repository) key requested)

runDeclaredToolCapability :: (Workflow :> es, Store :> es, IOE :> es) => DeclaredToolEnv -> Eff (DeclaredTool : es) a -> Eff es a
runDeclaredToolCapability DeclaredToolEnv {agent, identity, tools, repository} =
  interpret \_ -> \case
    RunToolStep elsewhere key requested -> runDeclaredToolChild agent identity key requested tools (maybe repository Just elsewhere)

unavailableDeclaredTool :: Eff (DeclaredTool : es) a -> Eff es a
unavailableDeclaredTool =
  interpret \_ -> \case
    RunToolStep {} -> pure (ToolFailed "declared-tool steps are unavailable in this flow harness")

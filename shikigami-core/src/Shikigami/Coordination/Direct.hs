{-# LANGUAGE DataKinds #-}

-- | Direct work uses a permitted pure Skill under the coordinator's own
-- principal. It has an accepted execution and no continuing-worker identity.
module Shikigami.Coordination.Direct (supported, admit) where

import Data.List (find)
import Data.Text qualified as Text
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.Agent.DeclarationValue (declarationCoordinateText)
import Shikigami.Behavior.Input (triggerOnly)
import Shikigami.Behavior.Run (BehaviorEnv (..))
import Shikigami.Behavior.Skill (SkillDir (..))
import Shikigami.Capability.Overlay (emptyResolvedCapabilitySet)
import Shikigami.Coordination.Checkpoint (Checkpoint (..))
import Shikigami.Coordination.Proposal qualified as P
import Shikigami.Coordination.Runtime qualified as Runtime
import Shikigami.Coordination.Types
import Shikigami.Execution.AssignmentKey (assignmentIdFor)
import Shikigami.Execution.Driver (ExecutionStart)
import Shikigami.Execution.Identity (OperationId, operationIdText)
import Shikigami.Execution.Policy.Types (narrowHarnessPolicy)
import Shikigami.Execution.Selection qualified as Selection
import Shikigami.Execution.Start qualified as Start
import Shikigami.Execution.Tools (ExecutionToolMenu (..))
import Shikigami.Execution.Transcript (ExecutionError (..))
import Shikigami.Flow.Decision (DecisionServices (..))
import Shikigami.Objective.Types
import Shikigami.Prelude
import Shikigami.WorkerSession.Capability (CoordinatorRun (..), WorkerInstruction (..))
import Shikigami.WorkerSession.Input (instructionText)

supported :: Admission -> P.Placement -> Bool
supported admission placement =
  placement.assignment.owner == admission.run.identity && placement.target /= admission.declaration.name && case role of
    Just declaration | Agent.Skill {} <- declaration.behavior -> null declaration.sinks && null declaration.capabilityOverlays && null declaration.delegates && isNothing declaration.routing && isNothing declaration.sanctionedProfile
    _ -> False
  where
    role = find ((== placement.target) . (.name)) admission.declarations

admit :: Runtime.Runtime -> Admission -> Checkpoint -> P.Placement -> OperationId -> WorkerInstruction -> IO (Either ExecutionError ExecutionStart)
admit runtime admission checkpoint placement operation instruction
  | not (supported admission placement) = pure (Left (ExecutionPolicyRefused "direct work requires an admitted pure Skill role"))
  | otherwise = case find ((== placement.target) . (.name)) admission.declarations of
      Nothing -> pure (Left ExecutionIdentityConflict)
      Just declaration -> case declaration.behavior of
        Agent.Skill {path} -> do
          now <- getCurrentTime
          let assignment = assignmentIdFor ("adaptive-direct:" <> operationIdText operation)
              selected = Selection.resolveExecutionSelection assignment runtime.decisions.catalog (Selection.defaultBinding runtime.behavior.model runtime.behavior.options) declaration.execution instruction.selection admission.origin.permittedAliases admission.profile (Just admission.organization.rootId) now
          case selected of
            Left _ -> pure (Left (ExecutionPolicyRefused "direct work model is outside its pinned role"))
            Right selection -> do
              let input = Start.SkillInput (triggerOnly (toJSON (instructionText instruction.text))) []
                  work = Start.SkillAssignment admission.run.runId declaration.name admission.run.identity admission.run.sessionId selection admission.profile emptyResolvedCapabilitySet (narrowHarnessPolicy admission.harness declaration.harness) (SkillDir (Text.unpack (declarationCoordinateText path))) (pure (Right input))
              Start.admitSkillExecution runtime.execution (const (pure (Right (ExecutionToolMenu (toJSON ([] :: [Text])) [])))) work
        _ -> pure (Left ExecutionIdentityConflict)

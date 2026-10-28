-- | Assignment admission freezes loaded inputs once. Mutable Skill files,
-- process defaults and provider leases are never consulted to reinterpret an
-- existing execution or its accepted terminal result.
module Shikigami.Execution.Start
  ( SkillAssignment (..),
    SkillInput (..),
    admitSkillExecution,
    readExecutionResult,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Effectful (Eff)
import Kioku.App (AppEffects)
import Kioku.Id (SessionId)
import Shikigami.Agent.Name (AgentName)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Attestation.Resolve (ResolvedProfile)
import Shikigami.Behavior.Input (BehaviorInput)
import Shikigami.Behavior.Skill (SkillDir, SkillManifest (..), loadSkillManifest, skillRequestText)
import Shikigami.Capability.Overlay (ResolvedCapabilitySet)
import Shikigami.Execution.Driver (ExecutionDriverResult (..), ExecutionStart (..))
import Shikigami.Execution.Executor (ExecutionRuntime (..), runExecutionStore)
import Shikigami.Execution.Policy.Types (HarnessPolicy)
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Store qualified as Store
import Shikigami.Execution.Tools (ExecutionToolMenu (..))
import Shikigami.Execution.Transcript
import Shikigami.Prelude
import System.Timeout (timeout)

data SkillAssignment = SkillAssignment
  { runId :: !Text,
    agent :: !AgentName,
    identity :: !AgentIdentity,
    sessionId :: !SessionId,
    selection :: !ExecutionSelection,
    sanctionedProfile :: !(Maybe ResolvedProfile),
    capabilities :: !ResolvedCapabilitySet,
    policy :: !HarnessPolicy,
    skillDir :: !SkillDir,
    input :: !(IO (Either ExecutionError SkillInput))
  }
  deriving stock (Generic)

data SkillInput = SkillInput
  { request :: !BehaviorInput,
    history :: ![ReplayMessage]
  }
  deriving stock (Generic)

admitSkillExecution :: ExecutionRuntime -> (ExecutionSnapshot -> IO (Either ExecutionError ExecutionToolMenu)) -> SkillAssignment -> IO (Either ExecutionError ExecutionStart)
admitSkillExecution runtime describe assignment = do
  existing <- owned (Store.inspectExecution execution)
  case existing of
    Left err -> pure (Left err)
    Right (Just _) -> do
      access <- owned (Store.authorizeReplay execution assignment.identity (runtime.replayAuthority assignment.identity))
      case access of
        Left err -> pure (Left err)
        Right permit -> do
          loaded <- owned (Store.loadExecution permit)
          pure do
            (snapshot, _) <- loaded
            unless (snapshot.identity == assignment.identity && snapshot.agent == assignment.agent && snapshot.runId == assignment.runId && snapshot.sessionId == assignment.sessionId && snapshot.selection == assignment.selection) (Left ExecutionIdentityConflict)
            pure (ExecutionStart execution)
    Right Nothing -> do
      manifest <- loadSkillManifest assignment.skillDir
      case manifest of
        Left _ -> pure (Left (ExecutionPolicyRefused "Skill instructions are unavailable or invalid"))
        Right skill -> do
          supplied <- assignment.input
          case supplied of
            Left err -> pure (Left err)
            Right input -> do
              let initial =
                    ExecutionSnapshot
                      { format = 1,
                        executionId = execution,
                        runId = assignment.runId,
                        agent = assignment.agent,
                        identity = assignment.identity,
                        sessionId = assignment.sessionId,
                        selection = assignment.selection,
                        sanctionedProfile = assignment.sanctionedProfile,
                        instructions = SkillInstructions skill.name skill.description skill.body,
                        initialContext = ReplayContext 2 (Just skill.description) (input.history <> [RequestTurn [TextBlock (skillRequestText skill input.request)] Nothing]),
                        capabilities = assignment.capabilities,
                        offeredTools = toJSON ([] :: [Aeson.Value]),
                        policy = assignment.policy,
                        toolBindings = []
                      }
              case validateSnapshot initial >> void (Store.payloadReference (toJSON initial)) of
                Left err -> pure (Left err)
                Right () -> do
                  authority <- runtime.authorize initial
                  case authority of
                    Left _ -> pure (Left (ExecutionPolicyRefused "fresh assignment authority refused"))
                    Right () -> do
                      described <- timeout (max 1 (min 30 runtime.timeoutSeconds) * 1000000) (describe initial)
                      let menu = fromMaybe (Left (ExecutionPolicyRefused "tool menu description exceeded its admission deadline")) described
                      case menu of
                        Left err -> pure (Left err)
                        Right frozen -> do
                          let snapshot = initial & #offeredTools .~ frozen.offeredTools & #toolBindings .~ frozen.toolBindings
                          admitted <- owned (Store.admitExecution snapshot)
                          case admitted of
                            Right _ -> pure (Right (ExecutionStart execution))
                            -- Another admission may have won after the initial
                            -- read. Its frozen snapshot wins even if the file or
                            -- process configuration changed between attempts.
                            Left ExecutionIdentityConflict -> admitSkillExecution runtime describe assignment
                            Left err -> pure (Left err)
  where
    execution = executionIdFor assignment.selection.assignmentId
    owned :: Eff AppEffects (Either ExecutionError a) -> IO (Either ExecutionError a)
    owned = runExecutionStore runtime

readExecutionResult :: ExecutionRuntime -> AgentIdentity -> ExecutionDriverResult -> IO (Either ExecutionError Value)
readExecutionResult runtime identity accepted = do
  metadata <- owned (Store.inspectExecution accepted.executionId)
  case metadata of
    Right (Just (state, binding, _))
      | binding.identity == identity && state.phase == accepted.phase && state.result == accepted.result && state.failure == accepted.failure ->
          if state.phase /= Succeeded
            then pure (Left (fromMaybe ExecutionCommandRefused state.failure))
            else do
              access <- owned (Store.authorizeReplay accepted.executionId identity (runtime.replayAuthority identity))
              case (access, state.result) of
                (Right permit, Just ref) -> owned (Store.readReplayPayload permit "execution-result" ref)
                (Left err, _) -> pure (Left err)
                _ -> pure (Left CorruptReplay)
    Left err -> pure (Left err)
    _ -> pure (Left ExecutionIdentityConflict)
  where
    owned :: Eff AppEffects (Either ExecutionError a) -> IO (Either ExecutionError a)
    owned = runExecutionStore runtime

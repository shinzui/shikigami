{-# LANGUAGE DataKinds #-}

-- | Queue work reacquires the coordinator's native admitted origin before any
-- real decision call. Root membership and the source assignment fence stay live.
module Shikigami.Coordination.DecisionAuthority (authorize, authorizeRun) where

import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Keiro.Workflow (loadStepIndex)
import Shikigami.AdaptiveDelivery.Generated.WorkflowRuntime qualified as Generated
import Shikigami.App (AppEnv, runAppIO)
import Shikigami.Coordination.Proposal (Policy (..))
import Shikigami.Coordination.Runtime qualified as Runtime
import Shikigami.Coordination.Types
import Shikigami.Decision.Contract
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Transcript
import Shikigami.Objective.Runtime (ObjectiveRuntime (..))
import Shikigami.Prelude
import Shikigami.WorkerSession.Capability (CoordinatorRun (..))

authorize :: Runtime.Runtime -> ExecutionSnapshot -> DecisionWork -> IO (Either Text ())
authorize runtime snapshot work = do
  loaded <- runAppIO runtime.objectives.appEnv (loadStepIndex Generated.workflowName snapshot.runId 0)
  case first (const "adaptive native admission is unavailable") loaded >>= decode of
    Left err -> pure (Left err)
    Right admission -> do
      let prepared = work.prepared
          bound = snapshot.identity == admission.run.identity && snapshot.runId == admission.run.runId && snapshot.selection.rootId == Just admission.organization.rootId && prepared.workflowId == snapshot.runId && prepared.model `elem` admission.decisions.models && prepared.policy == admission.decisions.policy && any (\slot -> slot.label == prepared.label && prepared.program `elem` slot.programs && prepared.model.alias `elem` slot.models) admission.decisions.slots
      if not bound
        then pure (Left "typed decision differs from native adaptive admission")
        else
          Runtime.validateAdmission runtime admission >>= \case
            Left _ -> pure (Left "adaptive native origin refused")
            Right () -> first (const "adaptive current authority refused") <$> Runtime.fresh runtime admission
  where
    decode steps = case Map.lookup "ingest-adaptive" steps of
      Just raw | Aeson.Success admission <- Aeson.fromJSON @Admission raw -> Right admission
      _ -> Left "adaptive admitted input is unavailable"

-- Shared admission guard for direct accepted Skill work as well as decision
-- wrappers. Ordinary AgentRun workflow identities have no entry in this family.
authorizeRun :: AppEnv -> Maybe Runtime.Runtime -> ExecutionSnapshot -> IO (Either Text ())
authorizeRun env configured snapshot = do
  loaded <- runAppIO env (loadStepIndex Generated.workflowName snapshot.runId 0)
  case loaded of
    Left _ -> pure (Left "Adaptive native authority is unavailable")
    Right entries -> case Map.lookup "ingest-adaptive" entries of
      Nothing -> pure (Right ())
      Just raw -> case (Aeson.fromJSON @Admission raw, configured) of
        (Aeson.Success admission, Just runtime)
          | snapshot.identity == admission.run.identity && snapshot.runId == admission.run.runId && snapshot.selection.rootId == Just admission.organization.rootId ->
              Runtime.validateAdmission runtime admission >>= \case
                Right () -> first (const "Adaptive current authority refused") <$> Runtime.fresh runtime admission
                Left _ -> pure (Left "Adaptive native origin refused")
        _ -> pure (Left "Adaptive native admission differs from accepted work")

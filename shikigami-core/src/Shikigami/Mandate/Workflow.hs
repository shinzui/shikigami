{-# LANGUAGE DataKinds #-}

-- | The continuing supervisor rotates once per observation. Fresh mode runs
-- the same bounded checkpoint adapter in a distinct, awaited native child.
module Shikigami.Mandate.Workflow (registry, workflow, freshWorkflow, configuredHosts, Start (..), Seed (..), CycleStart (..), cycleWorkflowId) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (Eff, raise)
import Effectful.Exception (throwIO)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), awaitStep, continueAsNew, currentRunGeneration, currentWorkflow, restoreSeed, step)
import Keiro.Workflow.Child (awaitChild, spawnChild)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.App (AppEffects)
import Shikigami.Behavior.Error (TransientBehaviorFailure (..))
import Shikigami.Coordination.Wake qualified as Wake
import Shikigami.Mandate.Cycle qualified as Cycle
import Shikigami.Mandate.Store qualified as Store
import Shikigami.Mandate.Types
import Shikigami.Objective.Capability qualified as Owner
import Shikigami.Objective.Runtime qualified as Objectives
import Shikigami.Objective.Types hiding (CreateRequest)
import Shikigami.Prelude
import Shikigami.RecurringCheckpointCycle.Generated.WorkflowRuntime qualified as Fresh
import Shikigami.RecurringObjective.Generated.WorkflowRuntime qualified as Native
import Shikigami.Workflow.Versioning qualified as Versioning

newtype Start = Start {mandateId :: MandateId}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype Seed = Seed {start :: Maybe Start}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

mandateStartWorkflowId :: Start -> WorkflowId
mandateStartWorkflowId start = mandateWorkflowId start.mandateId

data CycleStart = CycleStart {mandateId :: !MandateId, revision :: !(StateRevision "mandate")}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

cycleWorkflowId :: CycleStart -> WorkflowId
cycleWorkflowId input = WorkflowId ("mandate-cycle:" <> input.mandateId.value <> ":" <> Text.pack (show (revisionNumber input.revision)))

configuredHosts :: Objectives.ObjectiveRuntime -> Maybe (Owner.ObjectiveHost, AccessPrincipal -> Owner.ObjectiveHost)
configuredHosts runtime = do
  operator <- runtime.settings.operator
  let service = Owner.ObjectiveHost runtime.settings (pure (Right (LocalOperator operator))) runtime.actions (\_ _ -> pure (Left ObjectiveDenied)) (\_ _ -> pure (Left ObjectiveDenied)) (\_ -> pure (Left ObjectiveInvalidEvidence))
      actorHost actor = case actor of
        LocalOperator identity | identity == operator -> service
        RecordedAgent identity -> Objectives.hostFor runtime identity
        _ -> service {Owner.authenticate = pure (Left ObjectiveDenied)}
  pure (service, actorHost)

registry :: Maybe Objectives.ObjectiveRuntime -> WorkflowRegistry AppEffects
registry runtime = Map.fromList [(Native.workflowName, WorkflowDef (\_ -> workflow runtime Nothing)), (Fresh.workflowName, WorkflowDef (\_ -> freshWorkflow runtime))]

require :: Either ObjectiveError a -> Eff (Workflow : AppEffects) a
require = either (throwIO . TransientBehaviorFailure . ("recurring checkpoint unavailable: " <>) . Text.pack . show) pure

hosts :: Maybe Objectives.ObjectiveRuntime -> Eff (Workflow : AppEffects) (Owner.ObjectiveHost, AccessPrincipal -> Owner.ObjectiveHost)
hosts runtime = maybe (throwIO (TransientBehaviorFailure "recurring objective providers unavailable")) pure (runtime >>= configuredHosts)

workflow :: Maybe Objectives.ObjectiveRuntime -> Maybe Start -> Eff (Workflow : AppEffects) Bool
workflow runtime initial = do
  seed <- restoreSeed (Seed Nothing)
  start <- step (StepName "ingest-mandate") (maybe (throwIO (userError "recurring objective missing admitted mandate")) pure (seed.start <|> initial))
  native <- currentWorkflow
  unless (native == (Native.workflowName, mandateStartWorkflowId start)) (throwIO (userError "recurring objective identity mismatch"))
  (service, actorHost) <- hosts runtime
  current <- step (StepName "read-mandate") (raise (Store.serviceInspect service start.mandateId) >>= require)
  observed <-
    if isJust current.stopReason
      then pure current
      else case current.admission.mode of
        ContinuingCoordinator -> step (StepName "reconcile-mandate") do
          now <- liftIO getCurrentTime
          raise (Cycle.reconcileCycle service actorHost start.mandateId now) >>= require
        FreshCycleRun -> do
          let input = CycleStart start.mandateId current.revision
              childId = cycleWorkflowId input
          child <- spawnChild Fresh.workflowName childId (pure current)
          Versioning.admitWorkflowInput Fresh.workflowName childId (StepName "ingest-mandate-cycle") (toJSON input)
          awaitChild child
  if isJust observed.stopReason
    then pure True
    else do
      (token, await) <- Native.allocateDeclaredAwait Native.mandateChangeAwait
      (name, identity) <- currentWorkflow
      generation <- currentRunGeneration
      let after = maybe initialRevision (.revision) observed.watermark
          listener = Wake.Listener observed.admission.objectiveId name identity generation token after
      _ <- step (StepName "publish-mandate-wake") do
        -- A command may have committed between reconciliation and publication.
        -- Reacquire the current version; the journal records only this reference.
        latest <- raise (Store.serviceInspect service start.mandateId) >>= require
        if isJust latest.stopReason
          then Wake.prepareListener listener >>= runTransaction >> pure latest
          else raise (Store.publishWake service start.mandateId latest.revision listener) >>= require
      _ <- await :: Eff (Workflow : AppEffects) Bool
      continueAsNew (Seed (Just start))

freshWorkflow :: Maybe Objectives.ObjectiveRuntime -> Eff (Workflow : AppEffects) Mandate
freshWorkflow runtime = do
  -- A child can be discovered between spawn and input publication. Absence
  -- suspends without failing or consuming a checkpoint; the public admission
  -- append resolves this exact static label after a parent restart.
  start <- awaitStep (StepName "ingest-mandate-cycle") (pure ())
  native <- currentWorkflow
  unless (native == (Fresh.workflowName, cycleWorkflowId start)) (throwIO (userError "checkpoint cycle identity mismatch"))
  (service, actorHost) <- hosts runtime
  step (StepName "reconcile-current-checkpoint") do
    now <- liftIO getCurrentTime
    raise (Cycle.reconcileCycle service actorHost start.mandateId now) >>= require

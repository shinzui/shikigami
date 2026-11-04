{-# LANGUAGE TypeFamilies #-}

module Shikigami.Coordination.Capability (AdaptiveDelivery, deliver, runAdaptiveDelivery, runAdaptiveDeliveryDisabled) where

import Data.Aeson (Value, toJSON)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Exception (throwIO)
import Keiro.Workflow (PatchId (..), StepName (..), Workflow, patch, step)
import Keiro.Workflow.Child (awaitChild, spawnChild)
import Kiroku.Store.Effect (Store)
import Shikigami.AdaptiveDelivery.Generated.WorkflowRuntime qualified as Generated
import Shikigami.Attestation.Resolve (ResolvedProfile)
import Shikigami.Coordination.Identity
import Shikigami.Coordination.Runtime qualified as Runtime
import Shikigami.Coordination.Types
import Shikigami.Decision.Contract
import Shikigami.Execution.Policy.Types (HarnessPolicy)
import Shikigami.Objective.Reference (ObjectiveAssociation (..))
import Shikigami.Objective.Types (ObjectiveError (..))
import Shikigami.Prelude (Text, liftIO)
import Shikigami.Program.DecisionRunner (DecisionAbort (..))
import Shikigami.StateRevision (initialRevision)
import Shikigami.WorkerSession.Capability (CoordinatorRun)
import Shikigami.Workflow.Versioning (admitWorkflowInput)

data AdaptiveDelivery :: Effect where
  Deliver :: DecisionPolicySnapshot -> Value -> AdaptiveDelivery m Value

type instance DispatchOf AdaptiveDelivery = Dynamic

deliver :: (AdaptiveDelivery :> es) => DecisionPolicySnapshot -> Value -> Eff es Value
deliver policy payload = send (Deliver policy payload)

-- Existing Flows never invoke this capability, and old patch snapshots retain
-- the unavailable branch. Only the new compiled call site introduces a child.
runAdaptiveDelivery :: (Workflow :> es, Store :> es, IOE :> es) => Maybe Runtime.Runtime -> CoordinatorRun -> Maybe ResolvedProfile -> Either Text HarnessPolicy -> Eff (AdaptiveDelivery : es) a -> Eff es a
runAdaptiveDelivery configured origin profile harness = interpret $ \_ -> \case
  Deliver decisions payload -> do
    checkedHarness <- either (const (throwIO (DecisionAbort (decisionFailure InvalidSlot "adaptive harness permission refused")))) pure harness
    enabled <- patch (PatchId "shikigami-adaptive-delivery-v1")
    if not enabled
      then throwIO (DecisionAbort (decisionFailure InvalidSlot "adaptive delivery is unavailable to this historical workflow"))
      else case configured of
        Nothing -> throwIO (DecisionAbort (decisionFailure InvalidSlot "adaptive delivery providers are unavailable"))
        Just runtime -> do
          pinned <- step (StepName "adaptive-admission") $ do
            liftIO (runtime.beforeStep (StepName "adaptive-admission"))
            value <- liftIO (Runtime.admit runtime origin profile checkedHarness decisions payload)
            liftIO (runtime.afterStep (StepName "adaptive-admission"))
            pure value
          admission <- either (const (throwIO (DecisionAbort (decisionFailure InvalidSlot "adaptive admission refused")))) pure pinned
          let identity = admittedAdaptiveWorkflowId admission
          child <- spawnChild Generated.workflowName identity (pure (DeliveryResult admission.objective.objectiveId initialRevision Nothing "Unavailable" Nothing))
          admitWorkflowInput Generated.workflowName identity (StepName "ingest-adaptive") (toJSON admission)
          toJSON <$> awaitChild child

runAdaptiveDeliveryDisabled :: (IOE :> es) => Eff (AdaptiveDelivery : es) a -> Eff es a
runAdaptiveDeliveryDisabled = interpret $ \_ -> \case
  Deliver _ _ -> throwIO (DecisionAbort (decisionFailure InvalidSlot "adaptive delivery is unavailable"))

module Shikigami.Agent.Workflow.Input
  ( awaitInput,
    deliverInput,
    deliverInputTo,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Map.Strict qualified as Map
import Effectful (Eff, IOE, (:>))
import Keiro.Workflow (StepName (..), Workflow, WorkflowId, WorkflowName, awakeableAllocStepPrefix, currentGeneration, loadStepIndex)
import Keiro.Workflow.Awakeable (AwakeableId, awakeableNamed, signalAwakeable)
import Kiroku.Store.Effect (Store)
import Shikigami.Agent.Workflow.Name (agentRunWorkflowName)
import Shikigami.Prelude

awaitInput ::
  (Workflow :> es, Store :> es, IOE :> es, FromJSON a) =>
  StepName ->
  Eff es a
awaitInput stepName = do
  (_aid, awaitAnswer) <- awakeableNamed stepName
  awaitAnswer

deliverInput ::
  (Store :> es, IOE :> es, ToJSON a) =>
  WorkflowId ->
  StepName ->
  a ->
  Eff es Bool
deliverInput = deliverInputTo agentRunWorkflowName

-- | Signal a named awakeable in whichever generation is live.
--
-- __The generation is resolved, never assumed.__ This read used to pass a
-- literal @0@. That was correct only for a workflow that never rotates its
-- journal: 'Keiro.Workflow.continueAsNew' abandons the awakeable ids the closing
-- generation handed out and the next generation allocates fresh opaque ones,
-- journaled under @awkid:\<label\>@ in /that/ generation's step index. A
-- generation-0 read of a rotated workflow therefore finds an abandoned id and
-- signals something nobody is awaiting, reporting a delivery that did not
-- happen.
deliverInputTo ::
  (Store :> es, IOE :> es, ToJSON a) =>
  WorkflowName ->
  WorkflowId ->
  StepName ->
  a ->
  Eff es Bool
deliverInputTo workflowName workflowId stepName value = do
  generation <- currentGeneration workflowName workflowId
  stepIndex <- loadStepIndex workflowName workflowId generation
  case Map.lookup (awakeableAllocStepPrefix <> unStepName stepName) stepIndex >>= parseMaybe Aeson.parseJSON of
    Nothing -> pure False
    Just (aid :: AwakeableId) -> signalAwakeable aid value

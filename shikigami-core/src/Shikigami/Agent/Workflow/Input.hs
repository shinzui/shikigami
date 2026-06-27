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
import Keiro.Workflow (StepName (..), Workflow, WorkflowId, WorkflowName, awakeableAllocStepPrefix, loadStepIndex)
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

deliverInputTo ::
  (Store :> es, IOE :> es, ToJSON a) =>
  WorkflowName ->
  WorkflowId ->
  StepName ->
  a ->
  Eff es Bool
deliverInputTo workflowName workflowId stepName value = do
  stepIndex <- loadStepIndex workflowName workflowId 0
  case Map.lookup (awakeableAllocStepPrefix <> unStepName stepName) stepIndex >>= parseMaybe Aeson.parseJSON of
    Nothing -> pure False
    Just (aid :: AwakeableId) -> signalAwakeable aid value

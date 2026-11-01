{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}

-- | Trusted factories receive operation coordinates outside model arguments.
-- Only providers needed by an unfinished tool are reacquired at dispatch.
module Shikigami.Execution.Tools
  ( NativeToolFactory (..),
    staticNativeTools,
    withExecutionTools,
    ExecutionToolMenu (..),
    describeExecutionTools,
  )
where

import Data.Aeson (Value)
import Data.List (nub)
import Data.Text qualified as Text
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Principal (principalScopeText, resolveAgentIdentity)
import Shikigami.Capability.Catalog (ExecutionMode (Durable))
import Shikigami.Capability.Overlay
import Shikigami.Capability.Provider
import Shikigami.Capability.Tools (namespaceCapabilityTools, overlayToolName)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Executor (BoundTool (..))
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Runner (DispatchContext (..), OperationContext (..))
import Shikigami.Execution.Transcript
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikigami.StateRevision
import Shikumi.Tool (ToolError (..), ToolRegistry, mkDynTool, mkRegistry, registryBaikai, registryTools, someToolDescription, someToolName, someToolSchema)

-- Describing a menu cannot manufacture accepted operation coordinates. A
-- trusted factory receives those coordinates only when preparing actual work.
data NativeToolFactory = NativeToolFactory
  { describe :: !(ExecutionSnapshot -> IO (Either ExecutionError [BoundTool])),
    prepare :: !(ExecutionSnapshot -> OperationContext -> Maybe (ExecutionCoordinate "tool-name") -> IO (Either ExecutionError [BoundTool]))
  }

data ExecutionToolMenu = ExecutionToolMenu
  { offeredTools :: !Value,
    toolBindings :: ![ToolBinding]
  }
  deriving stock (Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Show ExecutionToolMenu where show _ = "ExecutionToolMenu <protected>"

staticNativeTools :: ToolRegistry -> NativeToolFactory
staticNativeTools registry =
  NativeToolFactory
    { describe = \_ -> pure (Right tools),
      prepare = \_ _ requested -> pure (Right (filter (\tool -> maybe True (== tool.binding.name) requested) tools))
    }
  where
    tools = [BoundTool (ToolBinding (executionCoordinate (someToolName tool)) (executionCoordinate "native/1") (executionDigestFor "shikigami.tool-schema/1" (someToolSchema tool)) UncertainEffect UnreportedInvoiceCost) tool | tool <- registryTools registry]

describeExecutionTools :: Log.Logger -> ActionAuthorizer -> CapabilityProviderRegistry -> NativeToolFactory -> ExecutionSnapshot -> IO (Either ExecutionError ExecutionToolMenu)
describeExecutionTools logger authorizer providers factory snapshot = do
  described <- factory.describe snapshot
  case described of
    Left err -> pure (Left err)
    Right tools -> withBoundTools logger authorizer providers snapshot Nothing Nothing tools \accepted ->
      pure (ExecutionToolMenu (toJSON (registryBaikai (mkRegistry (map (.tool) accepted)))) (map (.binding) accepted))

withExecutionTools :: Log.Logger -> ActionAuthorizer -> CapabilityProviderRegistry -> NativeToolFactory -> ExecutionSnapshot -> DispatchContext -> Maybe (ExecutionCoordinate "tool-name") -> ([BoundTool] -> IO a) -> IO (Either ExecutionError a)
withExecutionTools logger authorizer providers factory snapshot context requested use = do
  native <- factory.prepare snapshot context.operation requested
  case native of
    Left err -> pure (Left err)
    Right tools -> withBoundTools logger authorizer providers snapshot (Just context) requested tools use

withBoundTools :: Log.Logger -> ActionAuthorizer -> CapabilityProviderRegistry -> ExecutionSnapshot -> Maybe DispatchContext -> Maybe (ExecutionCoordinate "tool-name") -> [BoundTool] -> ([BoundTool] -> IO a) -> IO (Either ExecutionError a)
withBoundTools logger authorizer providers snapshot context requested tools use = case resolveAgentIdentity snapshot.identity of
  Left _ -> pure (Left ExecutionIdentityConflict)
  Right subject
    | not (validNative tools) -> pure (Left (ExecutionPolicyRefused "native tool factory differs from its binding"))
    | any (any ((/= Observation) . (.operationClass)) . (.tools)) generic -> pure (Left (ExecutionPolicyRefused "durable mutation overlays are unavailable"))
    | not (null governed) && isNothing snapshot.workspace -> pure (Left (ExecutionPolicyRefused "historical execution has no governed workspace admission"))
    | otherwise -> do
        prepared <- prepareGovernedTools providers snapshot context requested governed
        case prepared of
          Left err -> pure (Left err)
          Right durable -> do
            let allTools = tools <> durable
            if not (validNative allTools)
              then pure (Left (ExecutionPolicyRefused "durable tools collide with the offered menu"))
              else do
                result <- withCapabilityOverlays logger authorizer providers (scope subject) (mkResolvedCapabilitySet generic) (mkRegistry (map (.tool) allTools)) \registry _ ->
                  let bound tool = case [binding | BoundTool {binding} <- allTools, executionCoordinateText binding.name == someToolName tool] of
                        [binding] -> Right (BoundTool binding tool)
                        _ -> (\binding -> BoundTool binding tool) <$> overlayBinding tool
                   in case traverse bound (registryTools registry) of
                        Left err -> pure (Left err)
                        Right accepted | length accepted <= 128 -> Right <$> use accepted
                        _ -> pure (Left (ExecutionPolicyRefused "offered tool menu exceeds its supported ceiling"))
                pure (either (const (Left (ExecutionPolicyRefused "exact capability lease is unavailable"))) id result)
  where
    scope subject = CapabilityScope (WorkflowRun snapshot.runId) (declarationCoordinate (principalScopeText subject)) Durable
    selected = filter needed (resolvedCapabilities snapshot.capabilities)
    governed = filter (durableAdapterInstalled providers) selected
    generic = filter (not . durableAdapterInstalled providers) selected
    needed descriptor = maybe True (\name -> any (\tool -> executionCoordinate (overlayToolName descriptor.capability tool.name) == name) descriptor.tools) requested
    validNative tools = length tools <= 128 && length (nub (map (\bound -> bound.binding.name) tools)) == length tools && all (\bound -> executionCoordinateText bound.binding.name == someToolName bound.tool && bound.binding.schemaDigest == executionDigestFor "shikigami.tool-schema/1" (someToolSchema bound.tool) && not (Text.null (executionCoordinateText bound.binding.revision))) tools
    overlayBinding tool = case [(descriptor, entry) | descriptor <- selected, entry <- descriptor.tools, overlayToolName descriptor.capability entry.name == someToolName tool] of
      [(descriptor, entry)] -> Right (ToolBinding (executionCoordinate (someToolName tool)) (executionCoordinate (capabilityIdText descriptor.capability <> ":" <> capabilityRevisionText descriptor.revision)) (executionDigestFor "shikigami.tool-schema/1" (someToolSchema tool)) (recoveryFor entry.operationClass) UnreportedInvoiceCost)
      _ -> Left (ExecutionPolicyRefused "leased tool is outside the admitted descriptor")
    recoveryFor Observation = RepeatableObservation
    recoveryFor IdempotentMutation = IdempotentEffect
    recoveryFor IrreversibleEmission = UncertainEffect

-- Description is data-only. Only accepted dispatch receives a preparation
-- callback, whose actual invocation must recheck exact authority and ownership.
prepareGovernedTools :: CapabilityProviderRegistry -> ExecutionSnapshot -> Maybe DispatchContext -> Maybe (ExecutionCoordinate "tool-name") -> [CapabilityDescriptor] -> IO (Either ExecutionError [BoundTool])
prepareGovernedTools registry snapshot context requested descriptors = do
  groups <- traverse prepareDescriptor descriptors
  pure (concat <$> sequence groups)
  where
    refused :: Either ExecutionError a
    refused = Left (ExecutionPolicyRefused "exact durable adapter preparation refused")
    prepareDescriptor descriptor = case resolveDurableAdapter registry descriptor of
      Nothing -> pure refused
      Just adapter -> do
        results <- traverse (prepareContract descriptor adapter) (filter (\contract -> maybe True (== executionCoordinate (overlayToolName descriptor.capability (executionCoordinateText contract.name))) requested) adapter.contracts)
        pure (sequence results)
    prepareContract descriptor adapter contract = do
      raw <- case context of
        Nothing -> pure (Right (mkDynTool (executionCoordinateText contract.name) contract.description contract.schema (\_ -> pure (Left (ToolRunFailed (executionCoordinateText contract.name) "description cannot execute")))))
        Just dispatch
          | dispatch.operation.executionId /= snapshot.executionId || dispatch.generation <= initialRevision -> pure refused
          | otherwise -> adapter.prepare snapshot dispatch contract.name
      pure do
        tool <- raw
        unless (someToolName tool == executionCoordinateText contract.name && someToolDescription tool == contract.description && someToolSchema tool == contract.schema) refused
        namespaced <- either (const refused) Right (namespaceCapabilityTools descriptor.capability [tool])
        case namespaced of
          [actual] -> Right (BoundTool (ToolBinding (executionCoordinate (someToolName actual)) (executionCoordinate (capabilityIdText descriptor.capability <> ":" <> capabilityRevisionText descriptor.revision)) (executionDigestFor "shikigami.tool-schema/1" contract.schema) contract.recovery contract.invoiceCost) actual)
          _ -> refused

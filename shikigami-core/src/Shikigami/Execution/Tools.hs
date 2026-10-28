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
import Shikigami.Agent.Principal (principalScopeText, resolveAgentIdentity)
import Shikigami.Capability.Catalog (ExecutionMode (Durable))
import Shikigami.Capability.Overlay
import Shikigami.Capability.Provider
import Shikigami.Capability.Tools (overlayToolName)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Executor (BoundTool (..))
import Shikigami.Execution.Policy.Types
import Shikigami.Execution.Runner (OperationContext)
import Shikigami.Execution.Transcript
import Shikigami.Log qualified as Log
import Shikigami.Prelude
import Shikumi.Tool (ToolRegistry, mkRegistry, registryBaikai, registryTools, someToolName, someToolSchema)

-- Describing a menu cannot manufacture accepted operation coordinates. A
-- trusted factory receives those coordinates only when preparing actual work.
data NativeToolFactory = NativeToolFactory
  { describe :: ExecutionSnapshot -> IO (Either ExecutionError [BoundTool]),
    prepare :: ExecutionSnapshot -> OperationContext -> Maybe Text -> IO (Either ExecutionError [BoundTool])
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
    tools = [BoundTool (ToolBinding (someToolName tool) "native/1" (versionedDigest "shikigami.tool-schema/1" (someToolSchema tool)) UncertainEffect UnreportedInvoiceCost) tool | tool <- registryTools registry]

describeExecutionTools :: Log.Logger -> ActionAuthorizer -> CapabilityProviderRegistry -> NativeToolFactory -> ExecutionSnapshot -> IO (Either ExecutionError ExecutionToolMenu)
describeExecutionTools logger authorizer providers factory snapshot = do
  described <- factory.describe snapshot
  case described of
    Left err -> pure (Left err)
    Right tools -> withBoundTools logger authorizer providers snapshot Nothing tools \accepted ->
      pure (ExecutionToolMenu (toJSON (registryBaikai (mkRegistry (map (.tool) accepted)))) (map (.binding) accepted))

withExecutionTools :: Log.Logger -> ActionAuthorizer -> CapabilityProviderRegistry -> NativeToolFactory -> ExecutionSnapshot -> OperationContext -> Maybe Text -> ([BoundTool] -> IO a) -> IO (Either ExecutionError a)
withExecutionTools logger authorizer providers factory snapshot context requested use = do
  native <- factory.prepare snapshot context requested
  case native of
    Left err -> pure (Left err)
    Right tools -> withBoundTools logger authorizer providers snapshot requested tools use

withBoundTools :: Log.Logger -> ActionAuthorizer -> CapabilityProviderRegistry -> ExecutionSnapshot -> Maybe Text -> [BoundTool] -> ([BoundTool] -> IO a) -> IO (Either ExecutionError a)
withBoundTools logger authorizer providers snapshot requested tools use = case resolveAgentIdentity snapshot.identity of
  Left _ -> pure (Left ExecutionIdentityConflict)
  Right subject
    | not (validNative tools) -> pure (Left (ExecutionPolicyRefused "native tool factory differs from its binding"))
    | any (any ((/= Observation) . (.operationClass)) . (.tools)) selected -> pure (Left (ExecutionPolicyRefused "durable mutation overlays are unavailable"))
    | otherwise -> do
        result <- withCapabilityOverlays logger authorizer providers (scope subject) (mkResolvedCapabilitySet selected) (mkRegistry (map (.tool) tools)) \registry _ ->
          let bound tool = case [binding | BoundTool {binding} <- tools, binding.name == someToolName tool] of
                [binding] -> Right (BoundTool binding tool)
                _ -> (\binding -> BoundTool binding tool) <$> overlayBinding tool
           in case traverse bound (registryTools registry) of
                Left err -> pure (Left err)
                Right accepted | length accepted <= 128 -> Right <$> use accepted
                _ -> pure (Left (ExecutionPolicyRefused "offered tool menu exceeds its supported ceiling"))
        pure (either (const (Left (ExecutionPolicyRefused "exact capability lease is unavailable"))) id result)
  where
    scope subject = CapabilityScope snapshot.runId (principalScopeText subject) Durable
    selected = filter needed (resolvedCapabilities snapshot.capabilities)
    needed descriptor = maybe True (\name -> any (\tool -> overlayToolName descriptor.capability tool.name == name) descriptor.tools) requested
    validNative tools = length tools <= 128 && length (nub (map (\bound -> bound.binding.name) tools)) == length tools && all (\bound -> bound.binding.name == someToolName bound.tool && bound.binding.schemaDigest == versionedDigest "shikigami.tool-schema/1" (someToolSchema bound.tool) && not (Text.null bound.binding.revision)) tools
    overlayBinding tool = case [(descriptor, entry) | descriptor <- selected, entry <- descriptor.tools, overlayToolName descriptor.capability entry.name == someToolName tool] of
      [(descriptor, entry)] -> Right (ToolBinding (someToolName tool) (capabilityIdText descriptor.capability <> ":" <> capabilityRevisionText descriptor.revision) (versionedDigest "shikigami.tool-schema/1" (someToolSchema tool)) (recoveryFor entry.operationClass) UnreportedInvoiceCost)
      _ -> Left (ExecutionPolicyRefused "leased tool is outside the admitted descriptor")
    recoveryFor Observation = RepeatableObservation
    recoveryFor IdempotentMutation = IdempotentEffect
    recoveryFor IrreversibleEmission = UncertainEffect

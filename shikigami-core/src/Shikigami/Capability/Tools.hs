-- | Collision-safe composition for model-facing capability tools.
--
-- 'Shikumi.Tool.mkRegistry' intentionally uses last-wins map construction. That
-- is convenient for ordinary local registries, but an overlay must never replace
-- a base tool or another overlay silently. This module validates all names before
-- constructing the final registry and gives every overlay tool a stable namespace.
module Shikigami.Capability.Tools
  ( CapabilityToolError (..),
    overlayToolName,
    namespaceCapabilityTools,
    composeCapabilityTools,
    composeCapabilityToolsWithNames,
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Shikigami.Capability.Overlay (CapabilityId, capabilityIdText)
import Shikumi.Tool (SomeTool (..), Tool (..), ToolRegistry, mkRegistry, registryNames, registryTools, someToolName)

-- | Why a set of tools cannot be composed additively.
data CapabilityToolError
  = DuplicateCapabilityToolGroup {capability :: !CapabilityId}
  | DuplicateLogicalToolName {capability :: !CapabilityId, name :: !Text}
  | FinalToolNameCollision {name :: !Text}
  deriving stock (Eq, Show, Generic)

-- | The model-facing name of one logical tool supplied by an overlay.
-- Capability dots become dashes so the namespace is stable and compact while
-- retaining any dashes already present in the validated capability id.
overlayToolName :: CapabilityId -> Text -> Text
overlayToolName capability logicalName =
  "overlay__"
    <> Text.replace "." "-" (capabilityIdText capability)
    <> "__"
    <> logicalName

-- | Rewrite one capability's tools into its model-facing namespace. Duplicate
-- logical names are rejected before any registry can apply last-wins behavior.
namespaceCapabilityTools :: CapabilityId -> [SomeTool] -> Either CapabilityToolError [SomeTool]
namespaceCapabilityTools capability tools = do
  ensureUniqueLogicalNames capability tools
  pure (rename <$> tools)
  where
    rename (SomeTool Tool {name = logicalName, description, run}) =
      SomeTool
        Tool
          { name = overlayToolName capability logicalName,
            description,
            run
          }
    rename (DynTool logicalName description schema run) =
      DynTool (overlayToolName capability logicalName) description schema run

-- | Compose overlay tools with a base registry after validating the whole final
-- name set. The base registry is an input, never a value an overlay may replace.
composeCapabilityTools ::
  ToolRegistry ->
  [(CapabilityId, [SomeTool])] ->
  Either CapabilityToolError ToolRegistry
composeCapabilityTools base groups = fst <$> composeCapabilityToolsWithNames base groups

-- | The registry plus its sorted names, suitable for lifecycle logs.
composeCapabilityToolsWithNames ::
  ToolRegistry ->
  [(CapabilityId, [SomeTool])] ->
  Either CapabilityToolError (ToolRegistry, [Text])
composeCapabilityToolsWithNames base groups = do
  ensureUniqueCapabilityGroups groups
  overlayTools <- concat <$> traverse (uncurry namespaceCapabilityTools) groups
  let allTools = registryTools base <> overlayTools
  ensureUniqueFinalNames allTools
  let registry = mkRegistry allTools
  pure (registry, registryNames registry)

ensureUniqueCapabilityGroups :: [(CapabilityId, [SomeTool])] -> Either CapabilityToolError ()
ensureUniqueCapabilityGroups = go Set.empty
  where
    go :: Set CapabilityId -> [(CapabilityId, [SomeTool])] -> Either CapabilityToolError ()
    go _ [] = Right ()
    go seen ((capability, _) : rest)
      | capability `Set.member` seen = Left DuplicateCapabilityToolGroup {capability}
      | otherwise = go (Set.insert capability seen) rest

ensureUniqueLogicalNames :: CapabilityId -> [SomeTool] -> Either CapabilityToolError ()
ensureUniqueLogicalNames capability = go Set.empty
  where
    go :: Set Text -> [SomeTool] -> Either CapabilityToolError ()
    go _ [] = Right ()
    go seen (tool : rest)
      | name `Set.member` seen = Left DuplicateLogicalToolName {capability, name}
      | otherwise = go (Set.insert name seen) rest
      where
        name = someToolName tool

ensureUniqueFinalNames :: [SomeTool] -> Either CapabilityToolError ()
ensureUniqueFinalNames tools =
  case foldl' step (Right Set.empty) tools of
    Left collision -> Left collision
    Right _ -> Right ()
  where
    step :: Either CapabilityToolError (Set Text) -> SomeTool -> Either CapabilityToolError (Set Text)
    step (Left collision) _ = Left collision
    step (Right seen) tool
      | name `Set.member` seen = Left FinalToolNameCollision {name}
      | otherwise = Right (Set.insert name seen)
      where
        name = someToolName tool

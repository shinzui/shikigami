{-# LANGUAGE DataKinds #-}

-- | Operator-owned capability composition for the two one-off commands.
module Shikigami.Agent.Capability.OneOff
  ( OneOffCapabilityError (..),
    oneOffCapabilityRuntime,
    renderOneOffCapabilityError,
    withOneOffCapabilityOverlays,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Unique (hashUnique, newUnique)
import GHC.Generics (Generic)
import Shikigami.Action.Authorization (ActionAuthorizer)
import Shikigami.Agent.Capability.Workspace
  ( WorkspaceError,
    renderWorkspaceError,
    resolveWorkspaceScope,
    workspaceReadDescriptor,
    workspaceReadId,
    workspaceReadProvider,
  )
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..))
import Shikigami.Agent.Decl qualified as Agent
import Shikigami.Agent.DeclarationValue
import Shikigami.Behavior.Run (BehaviorEnv)
import Shikigami.Behavior.Run qualified as Behavior
import Shikigami.Capability.Catalog
  ( CapabilityCatalogError,
    CapabilityResolutionError (..),
    ExecutionMode (Durable, OneOff),
    ResolutionSubject (..),
    mkCapabilityCatalog,
    resolveCapabilityOverlays,
  )
import Shikigami.Capability.Overlay
  ( CapabilityDescriptor (..),
    CapabilityOperationClass (Observation),
    CapabilityToolDescriptor (..),
    capabilityIdText,
  )
import Shikigami.Capability.Provider
  ( CapabilityProviderRegistryError,
    CapabilityRun (..),
    CapabilityRuntime (..),
    CapabilityRuntimeError,
    CapabilityScope (..),
    emptyCapabilityRuntime,
    mkCapabilityProviderRegistry,
    withCapabilityOverlays,
  )
import Shikigami.Execution.Coordinate (executionCoordinateText)
import Shikigami.Log qualified as Log

data OneOffCapabilityError
  = OneOffCatalogInvalid !CapabilityCatalogError
  | OneOffResolutionRefused !CapabilityResolutionError
  | OneOffWorkspaceInvalid !WorkspaceError
  | OneOffProviderRegistryInvalid !CapabilityProviderRegistryError
  | OneOffCapabilityRuntimeFailed !CapabilityRuntimeError
  deriving stock (Eq, Show, Generic)

renderOneOffCapabilityError :: OneOffCapabilityError -> Text
renderOneOffCapabilityError = \case
  OneOffCatalogInvalid err -> "built-in capability catalog is invalid: " <> Text.pack (show err)
  OneOffResolutionRefused err -> renderResolutionError err
  OneOffWorkspaceInvalid err -> renderWorkspaceError err
  OneOffProviderRegistryInvalid err -> "built-in capability provider registry is invalid: " <> Text.pack (show err)
  OneOffCapabilityRuntimeFailed err -> "capability provider failed: " <> Text.pack (show err)

-- | Build the observation-only workspace runtime used by the durable
-- @shikigami-agent-run@ workflow. An empty declaration needs no catalog,
-- provider, or workspace and therefore returns the shared empty runtime without
-- touching the filesystem.
oneOffCapabilityRuntime :: Maybe FilePath -> AgentDecl -> IO (Either OneOffCapabilityError CapabilityRuntime)
oneOffCapabilityRuntime workspaceArgument AgentDecl {capabilityOverlays}
  | null capabilityOverlays = pure (Right emptyCapabilityRuntime)
  | otherwise =
      case mkCapabilityCatalog [workspaceReadDescriptor] of
        Left err -> pure (Left (OneOffCatalogInvalid err))
        Right catalog -> do
          workspace <- resolveWorkspaceScope workspaceArgument
          case workspace of
            Left err -> pure (Left (OneOffWorkspaceInvalid err))
            Right scope ->
              pure case mkCapabilityProviderRegistry [workspaceReadProvider scope] of
                Left err -> Left (OneOffProviderRegistryInvalid err)
                Right providers ->
                  Right
                    CapabilityRuntime
                      { catalog,
                        providers,
                        authorize = authorizeForMode Durable
                      }

-- | Resolve requested overlays against the fixed one-off catalog, acquire them
-- for exactly one callback, and derive an immutable behavior environment. The
-- empty branch deliberately avoids catalog construction and all workspace IO.
withOneOffCapabilityOverlays ::
  Log.Logger ->
  ActionAuthorizer ->
  Maybe FilePath ->
  AgentDecl ->
  BehaviorEnv ->
  (BehaviorEnv -> IO value) ->
  IO (Either OneOffCapabilityError value)
withOneOffCapabilityOverlays logger actionAuthorizer workspaceArgument decl@AgentDecl {capabilityOverlays} baseEnv callback
  | null capabilityOverlays = Right <$> callback baseEnv
  | otherwise =
      case mkCapabilityCatalog [workspaceReadDescriptor] of
        Left err -> pure (Left (OneOffCatalogInvalid err))
        Right catalog ->
          case resolveCapabilityOverlays catalog (authorizeForMode OneOff) subject capabilityOverlays of
            Left err -> pure (Left (OneOffResolutionRefused err))
            Right resolved -> do
              workspace <- resolveWorkspaceScope workspaceArgument
              case workspace of
                Left err -> pure (Left (OneOffWorkspaceInvalid err))
                Right scope ->
                  case mkCapabilityProviderRegistry [workspaceReadProvider scope] of
                    Left err -> pure (Left (OneOffProviderRegistryInvalid err))
                    Right providers -> do
                      unique <- newUnique
                      let runtimeScope =
                            CapabilityScope
                              { runId = OneOffRun ("one-off:" <> Text.pack (show (hashUnique unique))),
                                principal = declaredPrincipal,
                                mode = OneOff
                              }
                      runtimeResult <-
                        withCapabilityOverlays
                          logger
                          actionAuthorizer
                          providers
                          runtimeScope
                          resolved
                          ((.tools) baseEnv)
                          (\registry _active -> callback (Behavior.withCapabilityTools resolved registry baseEnv))
                      pure case runtimeResult of
                        Left err -> Left (OneOffCapabilityRuntimeFailed err)
                        Right value -> Right value
  where
    subject =
      ResolutionSubject
        { principal = principalText decl,
          mode = OneOff,
          behavior = (.behavior) decl,
          profile = Nothing
        }

    declaredPrincipal =
      case principalText decl of
        Just value -> value
        Nothing -> declarationCoordinate ""

authorizeForMode :: ExecutionMode -> ResolutionSubject -> CapabilityDescriptor -> Either CapabilityResolutionError ()
authorizeForMode expectedMode ResolutionSubject {principal, mode} descriptor@CapabilityDescriptor {capability, tools}
  | mode /= expectedMode = denied (executionModeText expectedMode <> " workspace capability used in the wrong execution mode")
  | maybe True (Text.null . declarationCoordinateText) principal = denied "a non-empty declared principal is required"
  | descriptor /= workspaceReadDescriptor = denied "only the immutable workspace.read revision 1 descriptor is installed"
  | capability /= workspaceReadId = denied "only workspace.read is authorized"
  | any ((/= Observation) . operationClassOf) tools = denied "workspace.read admits observation tools only"
  | otherwise = Right ()
  where
    denied reason = Left CapabilityAuthorizationDenied {capability, reason}
    operationClassOf CapabilityToolDescriptor {operationClass} = operationClass

executionModeText :: ExecutionMode -> Text
executionModeText = \case
  OneOff -> "one-off"
  Durable -> "durable"

principalText :: AgentDecl -> Maybe (DeclarationCoordinate "principal")
principalText AgentDecl {identity} =
  case identity of
    Nothing -> Nothing
    Just IdentityDecl {principal} -> Just principal

renderResolutionError :: CapabilityResolutionError -> Text
renderResolutionError = \case
  DuplicateCapabilityRequest {capability} ->
    "duplicate capability request: " <> capabilityIdText capability
  UnknownCapability {capability} ->
    "unknown one-off capability: " <> capabilityIdText capability
  MissingCapabilityIdentity ->
    "capability overlays require a declared agent identity"
  CapabilityAuthorizationDenied {capability, reason} ->
    "capability " <> capabilityIdText capability <> " is not authorized: " <> reason
  CapabilityBehaviorUnsupported {behaviorKind} ->
    "capability overlays are not supported for " <> behaviorKind <> " behaviors"
  DurableCapabilityOperationNotAllowed {capability, name} ->
    "capability " <> capabilityIdText capability <> " tool " <> executionCoordinateText name <> " is not allowed in this execution mode"

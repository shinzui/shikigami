{-# LANGUAGE DataKinds #-}

-- | Exact-revision provider lookup and run-scoped capability leases.
--
-- A provider registry is operator-owned live state. A resolved capability set is
-- durable public data. This module joins them only for one callback, verifies
-- that every live value still describes the pinned public semantics, and releases
-- every acquired lease in reverse order on every exit path.
module Shikigami.Capability.Provider
  ( CapabilityRuntime (..),
    emptyCapabilityRuntime,
    CapabilityScope (..),
    CapabilityAcquireError (..),
    CapabilityReleaseError (..),
    CapabilityLease (..),
    CapabilityProvider (..),
    CapabilityProviderRegistry,
    CapabilityProviderRegistryError (..),
    CapabilityReleaseFailure (..),
    CapabilityRuntimeError (..),
    mkCapabilityProviderRegistry,
    emptyCapabilityProviderRegistry,
    resolveProvider,
    withCapabilityOverlays,
    DurableToolContract (..),
    DurableAdapter (..),
    installDurableAdapters,
    resolveDurableAdapter,
    durableAdapterInstalled,
  )
where

import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, mask, throwIO)
import Control.Exception qualified as Exception
import Control.Monad (foldM)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Data.ByteString.Lazy qualified as Lazy
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful.Dispatch.Static (unsafeEff_)
import Effectful.Error.Static (throwError)
import GHC.Generics (Generic)
import Kikan.En.Action (AgentAction (..), actionValueErrorText, mkCapabilityTarget, mkCapabilityToolTarget)
import Shikigami.Action.Authorization
  ( ActionAuthorizationFailure (..),
    ActionAuthorizer (..),
    authorizationFailureDetail,
  )
import Shikigami.Behavior.Error (boundedBehaviorDetail)
import Shikigami.Capability.Catalog
  ( CapabilityCatalog,
    CapabilityResolutionError (..),
    ExecutionMode,
    ResolutionSubject,
    emptyCapabilityCatalog,
    mkCapabilityCatalog,
  )
import Shikigami.Capability.Overlay (CapabilityDescriptor (..), CapabilityId, CapabilityOperationClass (..), CapabilityRevision, CapabilityToolDescriptor (..), ResolvedCapabilitySet, capabilityIdText, capabilityRevisionText, resolvedCapabilities)
import Shikigami.Capability.Tools (CapabilityToolError, composeCapabilityToolsWithNames)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Coordinate (ExecutionCoordinate, executionCoordinateText)
import Shikigami.Execution.Policy.Types (RecoveryClass (..), ToolInvoiceCost)
import Shikigami.Execution.Runner (DispatchContext)
import Shikigami.Execution.Transcript (ExecutionError, ExecutionSnapshot)
import Shikigami.Log qualified as Log
import Shikumi.Error (ShikumiError (..))
import Shikumi.Tool (SomeTool (..), Tool (..), ToolRegistry, someToolName)

-- | Process-local capability policy and provider state for durable agent runs.
-- Only the result of resolving through this bundle is journaled; the bundle
-- itself contains functions and live factories and therefore has no JSON
-- instance.
data CapabilityRuntime = CapabilityRuntime
  { catalog :: !CapabilityCatalog,
    providers :: !CapabilityProviderRegistry,
    authorize ::
      !( ResolutionSubject ->
         CapabilityDescriptor ->
         Either CapabilityResolutionError ()
       )
  }

-- | Compatibility runtime for every existing construction site. Empty overlay
-- requests resolve without consulting policy; a non-empty request cannot be
-- found in the empty catalog and therefore cannot reach this deny-all callback.
emptyCapabilityRuntime :: CapabilityRuntime
emptyCapabilityRuntime =
  CapabilityRuntime
    { catalog = emptyCapabilityCatalog,
      providers = emptyCapabilityProviderRegistry,
      authorize = \_ CapabilityDescriptor {capability} ->
        Left
          CapabilityAuthorizationDenied
            { capability,
              reason = "the empty capability runtime authorizes no overlays"
            }
    }

-- | Public, non-secret inputs a provider may use to scope one acquisition.
data CapabilityScope = CapabilityScope
  { runId :: !Text,
    principal :: !Text,
    mode :: !ExecutionMode
  }
  deriving stock (Eq, Show, Generic)

newtype CapabilityAcquireError = CapabilityAcquireError {detail :: Text}
  deriving stock (Eq, Show, Generic)

newtype CapabilityReleaseError = CapabilityReleaseError {detail :: Text}
  deriving stock (Eq, Show, Generic)

-- | One successful acquisition. The release action belongs to this concrete
-- resource and is never encoded, journaled, or shared between callbacks.
data CapabilityLease = CapabilityLease
  { descriptor :: !CapabilityDescriptor,
    tools :: ![SomeTool],
    release :: !(IO (Either CapabilityReleaseError ()))
  }

-- | A factory for one exact immutable public descriptor.
data CapabilityProvider = CapabilityProvider
  { descriptor :: !CapabilityDescriptor,
    acquire :: !(CapabilityScope -> IO (Either CapabilityAcquireError CapabilityLease))
  }

data CapabilityProviderRegistry
  = CapabilityProviderRegistry
      (Map (CapabilityId, CapabilityRevision) CapabilityProvider)
      (Map (CapabilityId, CapabilityRevision, Text) DurableAdapter)

data CapabilityProviderRegistryError
  = DuplicateCapabilityProvider
      { capability :: !CapabilityId,
        revision :: !CapabilityRevision
      }
  | InvalidDurableAdapter {capability :: !CapabilityId, revision :: !CapabilityRevision}
  deriving stock (Eq, Show, Generic)

data CapabilityReleaseFailure = CapabilityReleaseFailure
  { descriptor :: !CapabilityDescriptor,
    error :: !CapabilityReleaseError
  }
  deriving stock (Eq, Show, Generic)

-- | Typed failures owned by the live provider boundary. Callback exceptions
-- are deliberately absent: they propagate after cleanup so callers retain their
-- existing exception and retry classification.
data CapabilityRuntimeError
  = CapabilityProviderUnavailable
      { capability :: !CapabilityId,
        revision :: !CapabilityRevision
      }
  | CapabilityProviderDescriptorMismatch
      { expected :: !CapabilityDescriptor,
        actual :: !CapabilityDescriptor
      }
  | CapabilityAcquireFailed
      { descriptor :: !CapabilityDescriptor,
        error :: !CapabilityAcquireError
      }
  | CapabilityAcquireThrew
      { descriptor :: !CapabilityDescriptor,
        detail :: !Text
      }
  | CapabilityAuthorizationFailed
      { descriptor :: !CapabilityDescriptor,
        authorizationError :: !ActionAuthorizationFailure
      }
  | CapabilityLeaseDescriptorMismatch
      { expected :: !CapabilityDescriptor,
        actual :: !CapabilityDescriptor
      }
  | CapabilityLeaseToolMismatch
      { descriptor :: !CapabilityDescriptor,
        expectedNames :: ![Text],
        actualNames :: ![Text]
      }
  | CapabilityToolCompositionFailed !CapabilityToolError
  | CapabilityReleaseFailures ![CapabilityReleaseFailure]
  deriving stock (Eq, Show, Generic)

mkCapabilityProviderRegistry ::
  [CapabilityProvider] ->
  Either CapabilityProviderRegistryError CapabilityProviderRegistry
mkCapabilityProviderRegistry providers =
  (\registry -> CapabilityProviderRegistry registry Map.empty) <$> foldl' addProvider (Right Map.empty) providers
  where
    addProvider accumulated provider@CapabilityProvider {descriptor = CapabilityDescriptor {capability, revision}} = do
      registry <- accumulated
      case Map.lookup (capability, revision) registry of
        Just _ -> Left DuplicateCapabilityProvider {capability, revision}
        Nothing -> Right (Map.insert (capability, revision) provider registry)

emptyCapabilityProviderRegistry :: CapabilityProviderRegistry
emptyCapabilityProviderRegistry = CapabilityProviderRegistry Map.empty Map.empty

-- | Find only the exact revision pinned in a resolved snapshot and verify the
-- provider advertises the complete same descriptor. There is no current-version
-- fallback.
resolveProvider ::
  CapabilityProviderRegistry ->
  CapabilityDescriptor ->
  Either CapabilityRuntimeError CapabilityProvider
resolveProvider (CapabilityProviderRegistry registry _) expected@CapabilityDescriptor {capability, revision} =
  case Map.lookup (capability, revision) registry of
    Nothing -> Left CapabilityProviderUnavailable {capability, revision}
    Just provider@CapabilityProvider {descriptor = actual}
      | actual == expected -> Right provider
      | otherwise -> Left CapabilityProviderDescriptorMismatch {expected, actual}

-- | Acquire every pinned provider, compose a derived registry, run one callback,
-- and release all successful acquisitions in LIFO order. Acquisition and
-- successful-body cleanup failures are typed 'Left' values. Callback exceptions
-- propagate after cleanup; asynchronous acquisition exceptions do likewise.
withCapabilityOverlays ::
  Log.Logger ->
  ActionAuthorizer ->
  CapabilityProviderRegistry ->
  CapabilityScope ->
  ResolvedCapabilitySet ->
  ToolRegistry ->
  (ToolRegistry -> Set CapabilityId -> IO value) ->
  IO (Either CapabilityRuntimeError value)
withCapabilityOverlays logger actionAuthorizer registry scope resolved base callback =
  mask \restore ->
    acquireAll
      (\provider -> restore ((.acquire) provider scope))
      (\composed active -> restore (callback composed active))
      []
      []
      (resolvedCapabilities resolved)
  where
    acquireAll restoreAcquire restoreCallback leases groups = \case
      [] ->
        case composeCapabilityToolsWithNames base (reverse groups) of
          Left toolError -> do
            cleanup <- releaseAll logger scope leases
            rethrowCleanupAsync cleanup
            pure (Left (CapabilityToolCompositionFailed toolError))
          Right (composed, _toolNames) -> do
            bodyResult <- Exception.try @SomeException (restoreCallback composed activeIds)
            cleanup@(releaseFailures, _) <- releaseAll logger scope leases
            case bodyResult of
              Left bodyException -> throwIO bodyException
              Right value -> do
                rethrowCleanupAsync cleanup
                if null releaseFailures
                  then pure (Right value)
                  else pure (Left (CapabilityReleaseFailures releaseFailures))
      expected : rest ->
        case resolveProvider registry expected of
          Left runtimeError -> do
            cleanup <- releaseAll logger scope leases
            rethrowCleanupAsync cleanup
            pure (Left runtimeError)
          Right provider -> do
            authorized <- authorizeProvider actionAuthorizer scope expected
            case authorized of
              Left authorizationError -> do
                cleanup <- releaseAll logger scope leases
                rethrowCleanupAsync cleanup
                pure (Left CapabilityAuthorizationFailed {descriptor = expected, authorizationError})
              Right () -> do
                logAcquiring logger scope expected
                acquired <- Exception.try @SomeException (restoreAcquire provider)
                handleAcquired restoreAcquire restoreCallback leases groups expected rest acquired

    handleAcquired restoreAcquire restoreCallback leases groups expected rest acquired =
      case acquired of
        Left exception -> do
          logAcquireFailed logger scope expected (exceptionDetail exception)
          cleanup <- releaseAll logger scope leases
          if isAsyncException exception
            then throwIO exception
            else do
              rethrowCleanupAsync cleanup
              pure (Left CapabilityAcquireThrew {descriptor = expected, detail = exceptionDetail exception})
        Right (Left acquireError) -> do
          logAcquireFailed logger scope expected (acquireErrorDetail acquireError)
          cleanup <- releaseAll logger scope leases
          rethrowCleanupAsync cleanup
          pure (Left CapabilityAcquireFailed {descriptor = expected, error = acquireError})
        Right (Right lease) -> do
          let leases' = lease : leases
          case validateLease expected lease of
            Left runtimeError -> do
              logAcquireFailed logger scope expected (runtimeErrorDetail runtimeError)
              cleanup <- releaseAll logger scope leases'
              rethrowCleanupAsync cleanup
              pure (Left runtimeError)
            Right logicalNames -> do
              logAcquired logger scope expected logicalNames
              let guardedTools = guardCapabilityTool actionAuthorizer scope expected <$> toolsOf lease
              acquireAll
                restoreAcquire
                restoreCallback
                leases'
                ((capabilityOf expected, guardedTools) : groups)
                rest

    activeIds = Set.fromList (capabilityOf <$> resolvedCapabilities resolved)

validateLease :: CapabilityDescriptor -> CapabilityLease -> Either CapabilityRuntimeError [Text]
validateLease expected CapabilityLease {descriptor = actual, tools}
  | actual /= expected = Left CapabilityLeaseDescriptorMismatch {expected, actual}
  | actualNames /= expectedNames =
      Left CapabilityLeaseToolMismatch {descriptor = expected, expectedNames, actualNames}
  | otherwise = Right actualNames
  where
    expectedNames = sort (descriptorToolNames expected)
    actualNames = sort (someToolName <$> tools)

releaseAll ::
  Log.Logger ->
  CapabilityScope ->
  [CapabilityLease] ->
  IO ([CapabilityReleaseFailure], Maybe SomeException)
releaseAll logger scope = fmap (\(failures, interrupted) -> (reverse failures, interrupted)) . go [] Nothing
  where
    go failures interrupted [] = pure (failures, interrupted)
    go failures interrupted (lease@CapabilityLease {descriptor, release} : rest) = do
      logReleasing logger scope descriptor (someToolName <$> toolsOf lease)
      released <- Exception.try @SomeException release
      case released of
        Right (Right ()) -> do
          logReleased logger scope descriptor (someToolName <$> toolsOf lease)
          go failures interrupted rest
        Right (Left releaseError) -> do
          logReleaseFailed logger scope descriptor (releaseErrorDetail releaseError)
          go (CapabilityReleaseFailure {descriptor, error = releaseError} : failures) interrupted rest
        Left exception -> do
          let releaseError = CapabilityReleaseError (exceptionDetail exception)
              interrupted' =
                if isAsyncException exception
                  then case interrupted of
                    Just _ -> interrupted
                    Nothing -> Just exception
                  else interrupted
          logReleaseFailed logger scope descriptor (releaseErrorDetail releaseError)
          go (CapabilityReleaseFailure {descriptor, error = releaseError} : failures) interrupted' rest

rethrowCleanupAsync :: ([CapabilityReleaseFailure], Maybe SomeException) -> IO ()
rethrowCleanupAsync (_, Nothing) = pure ()
rethrowCleanupAsync (_, Just exception) = throwIO exception

capabilityOf :: CapabilityDescriptor -> CapabilityId
capabilityOf CapabilityDescriptor {capability} = capability

toolsOf :: CapabilityLease -> [SomeTool]
toolsOf CapabilityLease {tools} = tools

descriptorToolNames :: CapabilityDescriptor -> [Text]
descriptorToolNames CapabilityDescriptor {tools} = logicalName <$> tools
  where
    logicalName CapabilityToolDescriptor {name} = name

authorizeProvider :: ActionAuthorizer -> CapabilityScope -> CapabilityDescriptor -> IO (Either ActionAuthorizationFailure ())
authorizeProvider ActionAuthorizer {authorize} CapabilityScope {principal} CapabilityDescriptor {capability, revision} =
  case mkCapabilityTarget (capabilityIdText capability) (capabilityRevisionText revision) of
    Left problem -> pure (Left (ActionCoordinatesInvalid (actionValueErrorText problem)))
    Right target -> fmap (const ()) <$> authorize principal (ConnectCapability target)

guardCapabilityTool :: ActionAuthorizer -> CapabilityScope -> CapabilityDescriptor -> SomeTool -> SomeTool
guardCapabilityTool ActionAuthorizer {authorize} CapabilityScope {principal} CapabilityDescriptor {capability, revision} (SomeTool Tool {name, description, run}) =
  SomeTool
    Tool
      { name,
        description,
        run = \input -> do
          authorization <-
            unsafeEff_
              case mkCapabilityToolTarget (capabilityIdText capability) (capabilityRevisionText revision) name of
                Left problem -> pure (Left (ActionCoordinatesInvalid (actionValueErrorText problem)))
                Right target -> authorize principal (InvokeCapabilityTool target)
          case authorization of
            Right _ -> run input
            Left failure@ActionPolicyDenied {} -> throwError (ValidationFailure (authorizationFailureDetail failure))
            Left failure -> throwError (ProviderFailure (authorizationFailureDetail failure))
      }
guardCapabilityTool ActionAuthorizer {authorize} CapabilityScope {principal} CapabilityDescriptor {capability, revision} (DynTool name description schema run) =
  DynTool name description schema \input -> do
    authorization <-
      unsafeEff_
        case mkCapabilityToolTarget (capabilityIdText capability) (capabilityRevisionText revision) name of
          Left problem -> pure (Left (ActionCoordinatesInvalid (actionValueErrorText problem)))
          Right target -> authorize principal (InvokeCapabilityTool target)
    case authorization of
      Right _ -> run input
      Left failure@ActionPolicyDenied {} -> throwError (ValidationFailure (authorizationFailureDetail failure))
      Left failure -> throwError (ProviderFailure (authorizationFailureDetail failure))

acquireErrorDetail :: CapabilityAcquireError -> Text
acquireErrorDetail (CapabilityAcquireError detail) = boundedBehaviorDetail detail

releaseErrorDetail :: CapabilityReleaseError -> Text
releaseErrorDetail (CapabilityReleaseError detail) = boundedBehaviorDetail detail

exceptionDetail :: SomeException -> Text
exceptionDetail = boundedBehaviorDetail . Text.pack . displayException

isAsyncException :: SomeException -> Bool
isAsyncException exception =
  case fromException exception :: Maybe SomeAsyncException of
    Just _ -> True
    Nothing -> False

runtimeErrorDetail :: CapabilityRuntimeError -> Text
runtimeErrorDetail = boundedBehaviorDetail . Text.pack . show

logAcquiring :: Log.Logger -> CapabilityScope -> CapabilityDescriptor -> IO ()
logAcquiring logger scope descriptor =
  Log.logInfo logger "capability.overlay.acquiring" (lifecycleFields scope descriptor (descriptorToolNames descriptor))

logAcquired :: Log.Logger -> CapabilityScope -> CapabilityDescriptor -> [Text] -> IO ()
logAcquired logger scope descriptor names =
  Log.logInfo logger "capability.overlay.acquired" (lifecycleFields scope descriptor names)

logReleasing :: Log.Logger -> CapabilityScope -> CapabilityDescriptor -> [Text] -> IO ()
logReleasing logger scope descriptor names =
  Log.logInfo logger "capability.overlay.releasing" (lifecycleFields scope descriptor names)

logReleased :: Log.Logger -> CapabilityScope -> CapabilityDescriptor -> [Text] -> IO ()
logReleased logger scope descriptor names =
  Log.logInfo logger "capability.overlay.released" (lifecycleFields scope descriptor names)

logAcquireFailed :: Log.Logger -> CapabilityScope -> CapabilityDescriptor -> Text -> IO ()
logAcquireFailed logger scope descriptor detail =
  Log.logError
    logger
    "capability.overlay.acquire_failed"
    (lifecycleFields scope descriptor (descriptorToolNames descriptor) <> ["error" .= detail])

logReleaseFailed :: Log.Logger -> CapabilityScope -> CapabilityDescriptor -> Text -> IO ()
logReleaseFailed logger scope descriptor detail =
  Log.logError
    logger
    "capability.overlay.release_failed"
    (lifecycleFields scope descriptor (descriptorToolNames descriptor) <> ["error" .= detail])

lifecycleFields :: CapabilityScope -> CapabilityDescriptor -> [Text] -> [Pair]
lifecycleFields CapabilityScope {runId, principal, mode} CapabilityDescriptor {capability, revision} names =
  [ "run_id" .= runId,
    "principal" .= principal,
    "mode" .= mode,
    "capability" .= capabilityIdText capability,
    "revision" .= capabilityRevisionText revision,
    "tool_names" .= sort names
  ]

-- | Descriptions contain no executable callbacks. Menu inspection cannot
-- prepare an attempt or launch a provider effect.
data DurableToolContract = DurableToolContract
  { name :: !(ExecutionCoordinate "tool-name"),
    description :: !Text,
    schema :: !Aeson.Value,
    recovery :: !RecoveryClass,
    invoiceCost :: !ToolInvoiceCost
  }

data DurableAdapter = DurableAdapter
  { descriptor :: !CapabilityDescriptor,
    contracts :: ![DurableToolContract],
    prepare :: !(ExecutionSnapshot -> DispatchContext -> ExecutionCoordinate "tool-name" -> IO (Either ExecutionError SomeTool))
  }

-- | Explicit operator installation, separate from generic overlay factories.
-- The key includes the descriptor digest; duplicate immutable revisions refuse.
installDurableAdapters :: [DurableAdapter] -> CapabilityProviderRegistry -> Either CapabilityProviderRegistryError CapabilityProviderRegistry
installDurableAdapters adapters (CapabilityProviderRegistry generic existing) = CapabilityProviderRegistry generic <$> foldM add existing adapters
  where
    add registry adapter = do
      let descriptor = adapter.descriptor
          capability = descriptor.capability
          revision = descriptor.revision
          invalid = Left (InvalidDurableAdapter capability revision)
      if any (\(id, rev, _) -> id == capability && rev == revision) (Map.keys registry)
        then Left (DuplicateCapabilityProvider capability revision)
        else case mkCapabilityCatalog [descriptor] of
          Left _ -> invalid
          Right _
            | sort (map (\contract -> executionCoordinateText contract.name) adapter.contracts) /= sort (map (\tool -> tool.name) descriptor.tools) -> invalid
            | length (nub (map (\contract -> contract.name) adapter.contracts)) /= length adapter.contracts -> invalid
            | not (all (\contract -> Text.length contract.description <= 1024 && Lazy.length (Aeson.encode contract.schema) <= 65536 && objectSchema contract.schema && recoveryMatches descriptor contract) adapter.contracts) -> invalid
            | otherwise -> Right (Map.insert (capability, revision, descriptorDigest descriptor) adapter registry)
    objectSchema (Aeson.Object _) = True
    objectSchema _ = False
    recoveryMatches descriptor contract = case [tool.operationClass | tool <- descriptor.tools, tool.name == executionCoordinateText contract.name] of
      [Observation] -> contract.recovery == RepeatableObservation
      [IdempotentMutation] -> contract.recovery `elem` [IdempotentEffect, UncertainEffect]
      [IrreversibleEmission] -> contract.recovery == UncertainEffect
      _ -> False

resolveDurableAdapter :: CapabilityProviderRegistry -> CapabilityDescriptor -> Maybe DurableAdapter
resolveDurableAdapter (CapabilityProviderRegistry _ registry) descriptor = Map.lookup (descriptor.capability, descriptor.revision, descriptorDigest descriptor) registry

durableAdapterInstalled :: CapabilityProviderRegistry -> CapabilityDescriptor -> Bool
durableAdapterInstalled registry descriptor = maybe False (const True) (resolveDurableAdapter registry descriptor)

descriptorDigest :: CapabilityDescriptor -> Text
descriptorDigest = versionedDigest "shikigami.durable-adapter-descriptor/1" . Aeson.toJSON

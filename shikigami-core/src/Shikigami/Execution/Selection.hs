-- | Pure whole-assignment admission over the single operator model catalog.
module Shikigami.Execution.Selection
  ( ExecutionSelection (..),
    SelectionSource (..),
    ExecutionSelectionFailure (..),
    resolveExecutionSelection,
    selectionBinding,
    defaultBinding,
    effectiveBindingOptions,
  )
where

import Baikai.Auth (ApiKeySource (ApiKeyLiteral))
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Options qualified as Options
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.List (find, nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text qualified as Text
import Shikigami.Attestation.Profile (SanctionedExecutionProfileRef)
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Resolve (ResolvedProfile (..))
import Shikigami.Behavior.Provider.Call (providerCallFor, validateProfileCall)
import Shikigami.Decision.Contract (ModelAlias, ModelDescriptor (..), modelAliasFromNonEmpty, modelAliasText)
import Shikigami.Decision.ModelCatalog
import Shikigami.Execution.AssignmentKey (AssignmentKey)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Execution.Request
import Shikigami.Prelude hiding (Options)

data SelectionSource = DeclaredAlias | ProcessDefault
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ExecutionSelection = ExecutionSelection
  { assignmentId :: !AssignmentKey,
    descriptor :: !ModelDescriptor,
    effectiveOptions :: !Aeson.Value,
    permittedAliases :: ![ModelAlias],
    profile :: !(Maybe SanctionedExecutionProfileRef),
    rootId :: !(Maybe ExecutionRootId),
    source :: !SelectionSource,
    admittedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ExecutionSelectionFailure
  = ExecutionAliasForbidden
  | ExecutionAliasUnavailable
  | ExecutionRequirementConflict
  | ExecutionThinkingConflict
  | ExecutionProfileConflict
  | ExecutionOptionsIncompatible
  | PinnedBindingUnavailable
  | InvalidExecutionPermission
  | ExecutionResourceBoundUnsupported
  | ExecutionBehaviorUnsupported
  | ExecutionRootUnavailable
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The legacy process default is a real immutable descriptor for new runs.
-- Binding identity describes authority/endpoint semantics, not secret rotations.
defaultBinding :: Model -> Options -> Either ExecutionSelectionFailure ModelBinding
defaultBinding model options = do
  credential <- case Options.apiKey options of
    Nothing -> Right Nothing
    Just (ApiKeyLiteral key) -> Right (Just (opaqueCredential key))
    _ -> Left PinnedBindingUnavailable
  either
    (const (Left ExecutionOptionsIncompatible))
    Right
    (modelBinding (modelAliasFromNonEmpty ('_' :| "_process_default__")) "1" "behavior.default" "1" model ((options & #apiKey .~ (Nothing))) credential)

resolveExecutionSelection ::
  AssignmentKey ->
  ModelCatalog ->
  Either ExecutionSelectionFailure ModelBinding ->
  Maybe ExecutionPolicy ->
  Maybe ExecutionRequest ->
  Maybe [ModelAlias] ->
  Maybe ResolvedProfile ->
  Maybe ExecutionRootId ->
  UTCTime ->
  Either ExecutionSelectionFailure ExecutionSelection
resolveExecutionSelection assignmentId catalog fallback declaration requested inherited profile rootId admittedAt = do
  let policy = declaration
      request = fromMaybe (ExecutionRequest Nothing Nothing Nothing) requested
      restrict allowed = maybe allowed (filter (`elem` allowed)) inherited
  unless (maybe True validAliases inherited && maybe True validAliases request.permittedAliases) (Left InvalidExecutionPermission)
  (binding, allowed, source) <- case policy of
    Nothing -> do
      binding <- fallback
      let alias = (modelDescriptor binding).alias
          allowed = restrict [alias]
      when (maybe False (/= alias) request.alias || alias `notElem` allowed) (Left ExecutionRequirementConflict)
      pure (binding, allowed, ProcessDefault)
    Just permission -> do
      let permitted = permission.permittedAliases
          wanted = fromMaybe permission.defaultAlias request.alias
          allowed = restrict permitted
      unless (validPermission permission) (Left InvalidExecutionPermission)
      unless (wanted `elem` allowed) (Left ExecutionAliasForbidden)
      descriptor <- maybe (Left ExecutionAliasUnavailable) Right (find (\d -> d.alias == wanted) (catalogDescriptors catalog))
      binding <- either (const (Left PinnedBindingUnavailable)) Right (pinnedBinding catalog descriptor)
      pure (binding, allowed, DeclaredAlias)
  let narrowed = maybe allowed (filter (`elem` allowed)) request.permittedAliases
      descriptor = modelDescriptor binding
      selectedAlias = descriptor.alias
  unless (selectedAlias `elem` narrowed) (Left ExecutionRequirementConflict)
  when (maybe False (\wanted -> descriptor.thinking /= Just wanted) request.thinking) (Left ExecutionThinkingConflict)
  forM_ profile \resolved -> case validateProfileCall resolved (providerCallFor (bindingModel binding) (bindingOptions binding)) of
    Left _ -> Left ExecutionProfileConflict
    Right () -> Right ()
  unless (publicExecutionOptions (bindingOptions binding)) (Left ExecutionOptionsIncompatible)
  when (isJust (profile >>= (\p -> p.profile.limits.maxCostMicroUsd))) (Left ExecutionResourceBoundUnsupported)
  pure
    ExecutionSelection
      { assignmentId,
        descriptor,
        effectiveOptions = toJSON (effectiveBindingOptions profile binding),
        permittedAliases = nub narrowed,
        profile = (.ref) <$> profile,
        rootId,
        source,
        admittedAt
      }

selectionBinding :: ModelCatalog -> ModelBinding -> Maybe ResolvedProfile -> ExecutionSelection -> Either ExecutionSelectionFailure ModelBinding
selectionBinding catalog fallback profile selection = do
  unless (selection.profile == ((.ref) <$> profile)) (Left ExecutionProfileConflict)
  binding <- case selection.source of
    ProcessDefault | modelDescriptor fallback == selection.descriptor -> Right fallback
    ProcessDefault -> Left PinnedBindingUnavailable
    DeclaredAlias -> either (const (Left PinnedBindingUnavailable)) Right (pinnedBinding catalog selection.descriptor)
  unless (publicExecutionOptions (bindingOptions binding)) (Left PinnedBindingUnavailable)
  unless (toJSON (effectiveBindingOptions profile binding) == selection.effectiveOptions) (Left PinnedBindingUnavailable)
  forM_ profile \resolved -> case validateProfileCall resolved (providerCallFor (bindingModel binding) (bindingOptions binding)) of
    Left _ -> Left ExecutionProfileConflict
    Right () -> Right ()
  pure binding

validAliases :: [ModelAlias] -> Bool
validAliases aliases = length aliases <= 64 && length (nub aliases) == length aliases && all ((<= 256) . Text.length . modelAliasText) aliases

validPermission :: ExecutionPolicy -> Bool
validPermission permission = permission.defaultAlias `elem` permission.permittedAliases && validAliases permission.permittedAliases

effectiveBindingOptions :: Maybe ResolvedProfile -> ModelBinding -> Options
effectiveBindingOptions profile binding =
  let base = bindingOptions binding
      caps = catMaybes [Options.maxTokens base, fromIntegral . max 0 <$> (profile >>= (\p -> p.profile.limits.maxTokens))]
   in (base & #maxTokens .~ (case caps of [] -> Nothing; xs -> Just (minimum xs)))

-- These settings are explicitly secret in the operator configuration. A
-- durable selection must not serialize them into its snapshot or journal.
-- API credentials use the separate opaque binding; no redaction changes replay.
publicExecutionOptions :: Options -> Bool
publicExecutionOptions options = Map.null (Options.headers options) && Map.null (Options.metadata options)

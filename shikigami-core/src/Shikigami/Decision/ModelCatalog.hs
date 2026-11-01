-- | Operator-owned aliases and process-local bindings. Payloads never create
-- model values, endpoints or credentials. Only trusted configuration does.
module Shikigami.Decision.ModelCatalog
  ( OpaqueCredential,
    opaqueCredential,
    revealCredential,
    ModelBinding,
    modelBinding,
    modelDescriptor,
    bindingModel,
    bindingOptions,
    bindingCredential,
    ModelCatalog,
    modelCatalog,
    retainModelBindings,
    catalogDescriptors,
    resolveModel,
    resolvePolicy,
    pinnedBinding,
    slotErrors,
  )
where

import Baikai.Api (Api (..))
import Baikai.Model (Model)
import Baikai.Model qualified as Model
import Baikai.Options (Options)
import Baikai.Options qualified as Options
import Control.Lens ((&), (.~))
import Data.Aeson (object, (.=))
import Data.Generics.Labels ()
import Data.List (find, nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Attestation.Resolve (ResolvedProfile, ResolvedProfileView (..), resolvedProfileView)
import Shikigami.Behavior.Compatibility (validateResponseOptions)
import Shikigami.Behavior.Provider.Call (ProviderCall (..), providerCallFor, validateProfileCall)
import Shikigami.Decision.Contract
import Shikigami.Program.Decision (ProgramRegistry, programDescriptors)

newtype OpaqueCredential = OpaqueCredential Text
  deriving stock (Eq)

opaqueCredential :: Text -> OpaqueCredential
opaqueCredential = OpaqueCredential

revealCredential :: OpaqueCredential -> Text
revealCredential (OpaqueCredential value) = value

data ModelBinding = ModelBinding
  { descriptor :: !ModelDescriptor,
    model :: !Model,
    options :: !Options,
    credential :: !(Maybe OpaqueCredential)
  }
  deriving stock (Eq)

-- | Model values are resolved from the generated per-API catalogs by Config.
-- Options are immutable and credential-free; the runner injects the secret only
-- at the actual transport boundary. All option metadata joins the digest.
modelBinding :: ModelAlias -> Text -> Text -> Text -> Model -> Options -> Maybe OpaqueCredential -> Either DecisionFailure ModelBinding
modelBinding alias suppliedVersion suppliedBindingId suppliedBindingVersion model options credential = do
  version <- capture suppliedVersion
  bindingId <- capture suppliedBindingId
  bindingVersion <- capture suppliedBindingVersion
  admit version bindingId bindingVersion
  where
    capture :: Text -> Either DecisionFailure (ModelRegistration scope)
    capture = either (const (refuse "model descriptor identities must be nonempty")) Right . parseModelRegistration
    admit version bindingId bindingVersion
      | Options.apiKey options /= Nothing = refuse "model options must not carry a credential"
      | Model.api model `notElem` [AnthropicMessages, OpenAIChatCompletions, OpenAIResponses, Custom "stub"] = refuse "decision model requires an admitted HTTP or stub API"
      | Model.api model /= Custom "stub", maybe True (Text.null . revealCredential) credential = refuse "decision credential binding is unavailable"
      | Left _ <- validateResponseOptions model options = refuse "decision response options are incompatible"
      | otherwise =
          let call = providerCallFor model options
              digest =
                modelDescriptorDigest
                  (object ["alias" .= alias, "version" .= version, "tuple" .= call, "model" .= model, "options" .= options, "bindingId" .= bindingId, "bindingVersion" .= bindingVersion])
           in Right
                ModelBinding
                  { descriptor = ModelDescriptor {alias, version, digest, provider = call.provider, api = call.api, endpointClass = call.endpointClass, modelId = call.modelId, thinking = call.thinking, bindingId, bindingVersion},
                    model,
                    options,
                    credential
                  }
    refuse = Left . decisionFailure UnavailableModel

modelDescriptor :: ModelBinding -> ModelDescriptor
modelDescriptor binding = binding.descriptor

bindingModel :: ModelBinding -> Model
bindingModel binding = binding.model

bindingOptions :: ModelBinding -> Options
bindingOptions binding = binding.options

bindingCredential :: ModelBinding -> Maybe OpaqueCredential
bindingCredential binding = binding.credential

data ModelCatalog = ModelCatalog [ModelBinding] [ModelBinding]
  deriving stock (Eq)

modelCatalog :: [ModelBinding] -> Either DecisionFailure ModelCatalog
modelCatalog entries
  | length aliases /= length (nub aliases) = Left (decisionFailure UnknownModel "duplicate operator model alias")
  | otherwise = Right (ModelCatalog entries [])
  where
    aliases = [binding.descriptor.alias | binding <- entries]

catalogDescriptors :: ModelCatalog -> [ModelDescriptor]
catalogDescriptors (ModelCatalog entries _) = map modelDescriptor entries

resolveModel :: ModelCatalog -> AgentDecl -> Maybe ResolvedProfile -> ModelAlias -> Either DecisionFailure ModelDescriptor
resolveModel (ModelCatalog entries _) declaration profile alias
  | alias `notElem` declaration.decisionModels = Left (decisionFailure ForbiddenModel "agent does not authorize decision model alias")
  | otherwise = case find (\binding -> binding.descriptor.alias == alias) entries of
      Nothing -> Left (decisionFailure UnknownModel "operator model alias is unavailable")
      Just binding -> do
        case profile of
          Nothing -> Right ()
          Just pinned -> case validateProfileCall pinned (providerCallFor binding.model binding.options) of
            Left _ -> Left (decisionFailure ForbiddenModel "pinned profile forbids decision model tuple")
            Right () -> Right ()
        Right binding.descriptor

-- | Resolve the complete finite inventory once, including unexecuted slots.
-- An allowed alias excluded by a profile is removed; each slot must retain at
-- least one selection. It never gains an alias from a different slot.
resolvePolicy :: ProgramRegistry -> [DecisionSlot] -> ModelCatalog -> AgentDecl -> Maybe ResolvedProfile -> Either DecisionFailure DecisionPolicySnapshot
resolvePolicy programs slots catalog declaration profile = do
  case slotErrors programs declaration slots of
    [] -> Right ()
    _ -> Left (decisionFailure InvalidSlot "invalid compiled decision slot inventory")
  let aliases = nub (concatMap (\slot -> slot.models) slots)
      resolve alias = case resolveModel catalog declaration profile alias of
        Right descriptor -> Right (Just descriptor)
        Left refusal | failureCode refusal == ForbiddenModel -> Right Nothing
        Left refusal -> Left refusal
  selections <- traverse resolve aliases
  let resolved = [descriptor | Just descriptor <- selections]
      admitted = map (\descriptor -> descriptor.alias) resolved
      narrowed :: [DecisionSlot]
      narrowed = [(slot & #models .~ (filter (`elem` admitted) slot.models)) | slot <- slots]
  if any (null . (\slot -> slot.models)) narrowed
    then Left (decisionFailure ForbiddenModel "decision slot has no authorized available model")
    else Right (DecisionPolicySnapshot narrowed resolved ((\p -> (resolvedProfileView p).ref) <$> profile))

pinnedBinding :: ModelCatalog -> ModelDescriptor -> Either DecisionFailure ModelBinding
pinnedBinding (ModelCatalog active retained) wanted =
  maybe
    (Left (decisionFailure UnavailableModel "pinned model or credential binding is unavailable"))
    Right
    (find (\binding -> binding.descriptor == wanted) (active <> retained))

slotErrors :: ProgramRegistry -> AgentDecl -> [DecisionSlot] -> [Text]
slotErrors registry declaration slots =
  ["duplicate decision slot label" | length labels /= length (nub labels)]
    <> concatMap check slots
  where
    labels = map (\slot -> slot.label) slots
    check slot =
      ["decision slot has no program or model" | null slot.programs || null slot.models]
        <> ["decision slot program contract is not registered" | any (`notElem` programDescriptors registry) slot.programs]
        <> ["decision slot model alias is not declared by agent" | any (`notElem` declaration.decisionModels) slot.models]

-- | Retained historical bindings serve pending snapshots without expanding the
-- active alias catalog or declaration authority. Reusing an immutable alias /
-- version with different authority is refused even across active/history sets.
retainModelBindings :: ModelCatalog -> [ModelBinding] -> Either DecisionFailure ModelCatalog
retainModelBindings (ModelCatalog active retained) historical = do
  let allEntries = active <> retained <> historical
      conflicts a b =
        a.descriptor.alias == b.descriptor.alias
          && a.descriptor.version == b.descriptor.version
          && a.descriptor /= b.descriptor
  if or [conflicts a b | a <- allEntries, b <- allEntries]
    then Left (decisionFailure ContractMismatch "retained model version has conflicting authority")
    else Right (ModelCatalog active (retained <> historical))

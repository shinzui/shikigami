-- | Building a behavior environment around the provider an operator selected.
--
-- "Shikigami.App.Config" decides /which/ provider runs a @Skill@ behavior and
-- resolves what that branch needs. This module turns that answer into a live
-- 'BehaviorEnv': it installs the matching baikai handler, lowers the resolved
-- credential into the per-call options at the one boundary that needs plaintext,
-- and says out loud which provider the process is about to run with.
--
-- == Why the announcement is unconditional
--
-- The stub is a real provider. It loads a @SKILL.md@, builds the same baikai
-- request the Anthropic handler would, and answers with a fixed sentence — which
-- the runtime then records as a durable learning and dispatches sinks for. A
-- worker running the stub is therefore indistinguishable, from the outside, from
-- a worker running a model, right up to the point somebody reads the reply. That
-- is the failure this module exists to close: 'newBehaviorEnvFor' cannot build an
-- environment without logging one line naming the provider, so a stub can be the
-- default without ever being a silent default. The caller supplies the logger,
-- which is why the announcement is a 'Shikigami.Log' event rather than a bare
-- write: a worker's standard error is one stream of JSON objects, and this line
-- is not allowed to be the exception that breaks parsing it.
--
-- The complementary half is durable rather than logged: the model id travels into
-- the kioku session row as @modelUsed@ (see
-- "Shikigami.Agent.Workflow"), so a run made by the stub is distinguishable from
-- a real one forever after, not just in the startup log of a process that has
-- since restarted.
module Shikigami.Behavior.Provider
  ( -- * The selection
    ProviderSelection (..),
    lookupAnthropicModel,

    -- * The profile boundary
    ProviderCall (..),
    ProfileViolation (..),
    renderProfileViolation,
    constrainBehaviorEnv,
    newBehaviorEnvForProfile,
    newBehaviorEnvForProfileWithLogger,

    -- * Building an environment for it
    newBehaviorEnvFor,
    withModelBinding,

    -- * Saying which one is active
    describeProviderSelection,
    providerTag,
    providerCall,
    providerCallFor,
    matchesCall,
    validateProfileCall,
    validateProviderSelection,
    validateResponseRequest,
    renderResponseCompatibilityError,
  )
where

import Baikai.Api (Api (..))
import Baikai.Auth (ApiKeySource (ApiKeyLiteral))
import Baikai.Model qualified as Model
import Baikai.Options (Options, emptyOptions)
import Baikai.Options qualified as Options
import Baikai.Provider.Claude.Api qualified as Claude
import Baikai.Provider.OpenAI.Api qualified as OpenAI
import Baikai.Provider.OpenAI.Responses qualified as Responses
import Baikai.Trace (TraceSink)
import Control.Lens ((&), (.~))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Set qualified as Set
import Data.Text (Text)
import Handan.Runtime (newRuntime)
import Shikigami.App.Config (ProviderSelection (..), SecretText, lookupAnthropicModel, revealSecretText)
import Shikigami.Attestation.Resolve (ResolvedProfile)
import Shikigami.Behavior.Compatibility
import Shikigami.Behavior.Provider.Call
import Shikigami.Behavior.Run (BehaviorEnv (..), defaultToolTurnLimit)
import Shikigami.Behavior.StubProvider (registerStubProvider, stubModel)
import Shikigami.Decision.ModelCatalog (ModelBinding, bindingCredential, bindingModel, bindingOptions, revealCredential)
import Shikigami.Log qualified as Log
import Shikumi.Tool (mkRegistry)

-- | Refuse a behavior environment before it can build or dispatch a provider
-- request unless its whole tuple is permitted by the pinned profile.
--
-- Selected model ids come from Baikai's catalog, not a free-text fallback. An
-- id different from the profile's exact id therefore misses the tuple rather
-- than being guessed to be an alias. Likewise, Baikai has no provider/model
-- fallback in this construction path; those prohibitions remain closed by the
-- absence of such machinery.
constrainBehaviorEnv :: ResolvedProfile -> BehaviorEnv -> Either ProfileViolation BehaviorEnv
constrainBehaviorEnv resolved env = env <$ validateProfileCall resolved (providerCall env)

-- | Build and constrain a selected provider with the same unconditional
-- announcement as 'newBehaviorEnvFor'. The workflow normally constrains its
-- already-built process environment with 'constrainBehaviorEnv'; this
-- constructor is useful for one-off callers that have the selection itself.
newBehaviorEnvForProfile ::
  ResolvedProfile ->
  ProviderSelection ->
  Maybe TraceSink ->
  IO (Either ProfileViolation BehaviorEnv)
newBehaviorEnvForProfile resolvedProfile selection traceSink = do
  logger <- Log.newStderrLogger Log.Info
  newBehaviorEnvForProfileWithLogger logger resolvedProfile selection traceSink

-- | The logged form used when a process already owns its structured logger.
newBehaviorEnvForProfileWithLogger ::
  Log.Logger ->
  ResolvedProfile ->
  ProviderSelection ->
  Maybe TraceSink ->
  IO (Either ProfileViolation BehaviorEnv)
newBehaviorEnvForProfileWithLogger logger resolvedProfile selection traceSink =
  constrainBehaviorEnv resolvedProfile <$> newBehaviorEnvFor logger selection traceSink

-- | Build the behavior environment an operator's configuration asked for, and
-- announce it.
--
-- Both branches register the stub handler. It answers for the @Custom \"stub\"@
-- API tag, which no real model carries, so registering it alongside a real
-- provider costs one map insert and keeps any in-process tooling that dispatches
-- 'Shikigami.Behavior.StubProvider.stubModel' working. Registration is
-- overwrite-by-tag in baikai, so calling this repeatedly is harmless.
--
-- The deterministic constructors in "Shikigami.Behavior.Run" —
-- 'Shikigami.Behavior.Run.newBehaviorEnv' and
-- 'Shikigami.Behavior.Run.newBehaviorEnvWithTraceSink' — remain the way tests
-- build a stub environment. They stay silent, because a test suite that
-- announced a provider a hundred times would train everyone to ignore the line
-- that matters.
newBehaviorEnvFor :: Log.Logger -> ProviderSelection -> Maybe TraceSink -> IO BehaviorEnv
newBehaviorEnvFor logger selection traceSink = do
  Log.logInfo
    logger
    "behavior.provider.selected"
    [ "provider" .= providerTag selection,
      "detail" .= describeProviderSelection selection
    ]
  runtime <- newRuntime
  registerStubProvider
  case selection of
    UseStub ->
      pure
        BehaviorEnv
          { runtime,
            model = stubModel,
            options = emptyOptions,
            traceSink,
            providerRegistry = Nothing,
            tools = mkRegistry [],
            activeOverlays = Set.empty,
            toolTurnLimit = defaultToolTurnLimit
          }
    UseAnthropic model credential -> do
      Claude.register
      pure
        BehaviorEnv
          { runtime,
            model,
            options = credentialOptions credential,
            traceSink,
            providerRegistry = Nothing,
            tools = mkRegistry [],
            activeOverlays = Set.empty,
            toolTurnLimit = defaultToolTurnLimit
          }
    UseHttp model options credential -> do
      case Model.api model of
        AnthropicMessages -> Claude.register
        OpenAIChatCompletions -> OpenAI.register
        OpenAIResponses -> Responses.register
        _ -> fail "configured HTTP response has a non-HTTP API"
      pure
        BehaviorEnv
          { runtime,
            model,
            options = options {Options.apiKey = Just (ApiKeyLiteral (revealSecretText credential))},
            traceSink,
            providerRegistry = Nothing,
            tools = mkRegistry [],
            activeOverlays = Set.empty,
            toolTurnLimit = defaultToolTurnLimit
          }

validateProviderSelection :: ProviderSelection -> Either ResponseCompatibilityError ()
validateProviderSelection = \case
  UseStub -> Right ()
  UseAnthropic model _ -> validateResponseOptions model emptyOptions
  UseHttp model options _ -> validateResponseOptions model options

-- | The same compatible HTTP options builder, applied to an already pinned
-- catalog binding. Credentials remain process-local and are never serialized.
withModelBinding :: ModelBinding -> BehaviorEnv -> Either ResponseCompatibilityError BehaviorEnv
withModelBinding binding env = do
  validateResponseOptions (bindingModel binding) (bindingOptions binding)
  let options = (bindingOptions binding) {Options.apiKey = ApiKeyLiteral . revealCredential <$> bindingCredential binding}
  pure (env & #model .~ bindingModel binding & #options .~ options)

-- | Lower a resolved credential into the per-call options baikai dispatches with.
--
-- This is the single point where the Anthropic key exists as plaintext, and it
-- exists there because the transport needs a string. The alternative baikai
-- offers — leaving @apiKey@ empty and letting the Claude handler read
-- @ANTHROPIC_API_KEY@ itself — is deliberately not taken: it would put a second
-- credential path outside Settei's precedence, provenance, and redaction, so a
-- deployment could end up authenticating as something @--explain-config@ never
-- mentioned.
--
-- The result is process-local. 'Baikai.Options.Options' does have a 'Show' and a
-- 'ToJSON', but both render an 'ApiKeyLiteral' as a redaction marker rather than
-- its content, so an accidental trace of this value cannot spill the key.
credentialOptions :: SecretText -> Options
credentialOptions credential =
  emptyOptions {Options.apiKey = Just (ApiKeyLiteral (revealSecretText credential))}

providerCall :: BehaviorEnv -> ProviderCall
providerCall BehaviorEnv {model, options} = providerCallFor model options

-- | The low-cardinality name of the selected provider, for the @provider@ field.
-- The human sentence goes in @detail@; this is what an operator groups by.
providerTag :: ProviderSelection -> Text
providerTag = \case
  UseStub -> "stub"
  UseAnthropic {} -> "anthropic"
  UseHttp model _ _ -> case Model.api model of
    OpenAIChatCompletions -> "openai"
    OpenAIResponses -> "openai-responses"
    _ -> "anthropic"

-- | Render a selection for an operator.
--
-- Pattern-matches rather than deriving, because the Anthropic branch holds a
-- credential: what comes out is the provider, the model id, and the fact that a
-- credential was resolved — never any part of its value.
describeProviderSelection :: ProviderSelection -> Text
describeProviderSelection = \case
  UseStub ->
    "model provider: STUB — no model will be called; set behavior.provider=anthropic to use a real model"
  UseAnthropic model _credential ->
    "model provider: anthropic model=" <> Model.modelId model <> " endpoint=" <> Model.baseUrl model <> " credential=present"
  selected@(UseHttp model _ _) ->
    "model provider: "
      <> providerTag selected
      <> " model="
      <> Model.modelId model
      <> " endpoint="
      <> Model.baseUrl model
      <> " credential=present"

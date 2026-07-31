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
-- environment without writing one line to standard error naming the provider, so
-- a stub can be the default without ever being a silent default.
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

    -- * Building an environment for it
    newBehaviorEnvFor,

    -- * Saying which one is active
    describeProviderSelection,
    providerLogLine,
  )
where

import Baikai.Auth (ApiKeySource (ApiKeyLiteral))
import Baikai.Model (modelId)
import Baikai.Options (Options (..), emptyOptions)
import Baikai.Provider.Claude.Api qualified as Claude
import Baikai.Trace (TraceSink)
import Data.Text (Text)
import Data.Text.IO qualified as TextIO
import Handan.Runtime (newRuntime)
import Shikigami.App.Config (ProviderSelection (..), SecretText, lookupAnthropicModel, revealSecretText)
import Shikigami.Behavior.Run (BehaviorEnv (..))
import Shikigami.Behavior.StubProvider (registerStubProvider, stubModel)
import System.IO qualified as IO

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
newBehaviorEnvFor :: ProviderSelection -> Maybe TraceSink -> IO BehaviorEnv
newBehaviorEnvFor selection traceSink = do
  TextIO.hPutStrLn IO.stderr (providerLogLine selection)
  runtime <- newRuntime
  registerStubProvider
  case selection of
    UseStub ->
      pure BehaviorEnv {runtime, model = stubModel, options = emptyOptions, traceSink}
    UseAnthropic model credential -> do
      Claude.register
      pure BehaviorEnv {runtime, model, options = credentialOptions credential, traceSink}

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
  emptyOptions {apiKey = Just (ApiKeyLiteral (revealSecretText credential))}

-- | The one line 'newBehaviorEnvFor' writes to standard error, in the same
-- @[shikigami.\<component\>]@ shape as the worker's own startup lines.
providerLogLine :: ProviderSelection -> Text
providerLogLine selection = "[shikigami.behavior] " <> describeProviderSelection selection

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
    "model provider: anthropic model=" <> modelId model <> " credential=present"

-- | The behavior runner: dispatch a loaded 'AgentDecl' on its behavior union and
-- return the behavior's output as a JSON value. The @ShikumiProgram@ arm runs a
-- registered Shikumi task; the @Skill@ arm runs a baikai completion. Both run
-- deterministically with stubs (no model key). EP-5's worker calls 'runBehavior'; the
-- sinks (EP-3) consume its output value.
module Shikigami.Behavior.Run
  ( BehaviorEnv (..),
    BehaviorInput (..),
    RunError (..),
    behaviorModelId,
    defaultToolTurnLimit,
    newBehaviorEnv,
    newBehaviorEnvWithTraceSink,
    runBehavior,
    completeBehaviorRequest,
    runBehaviorAttempt,
    -- | Exported for "Shikigami.BehaviorRetrySpec", which supplies a slow or
    -- retryable action without registering a process-global model provider.
    runBehaviorAttemptWith,
    -- | Exported for "Shikigami.BehaviorInputSpec", which runs a locally
    -- constructed task to observe the input a real dispatch supplies.
    runProgramTask,
    triggerOnly,
    withCapabilityTools,
  )
where

import Baikai.Context (Context)
import Baikai.Model (Model, modelId)
import Baikai.Options (Options, emptyOptions)
import Baikai.Provider.Registry (ProviderRegistry, completeRequestWith, globalProviderRegistry)
import Baikai.Response (Response)
import Baikai.Trace (TraceSink)
import Baikai.Trace qualified as BaikaiTrace
import Control.Exception (throwIO)
import Control.Lens ((&), (.~))
import Data.Aeson (Value)
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, nominalDiffTimeToSeconds)
import GHC.Generics (Generic)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.DeclarationValue
import Shikigami.Behavior.Error
  ( FailureClass (..),
    RunError (..),
    TransientBehaviorFailure (..),
    boundedBehaviorDetail,
    classifyRunError,
    renderRunError,
  )
import Shikigami.Behavior.Input (BehaviorInput (..), triggerOnly)
import Shikigami.Behavior.Skill (SkillDir (..), ToolTurnLimit, parseToolTurnLimit, runSkillWith)
import Shikigami.Behavior.StubProvider (registerStubProvider, stubModel)
import Shikigami.Capability.Overlay (CapabilityId, ResolvedCapabilitySet, resolvedCapabilities)
import Shikigami.Capability.Overlay qualified as Overlay
import Shikigami.Program.Registry (lookupTask)
import Shikigami.Program.Runtime (ProgramRuntime, newProgramRuntime)
import Shikigami.Program.Task (ProgramTask (..))
import Shikumi.Tool (ToolRegistry, mkRegistry)
import System.Timeout (timeout)

-- | What 'runBehavior' needs to run either arm: a 'ProgramRuntime' (built once),
-- the model the skill arm dispatches with, and the per-call options that model is
-- dispatched under. Built once at worker startup.
--
-- 'options' is where the resolved API credential lives, in baikai's
-- 'Baikai.Auth.ApiKeyLiteral' form. It is carried rather than looked up so that
-- the key source is decided once, by "Shikigami.App.Config", instead of by
-- whichever provider handler happens to run — baikai's own handlers will fall
-- back to reading @ANTHROPIC_API_KEY@ from the environment when the field is
-- empty, and a second credential path outside Settei is exactly what this avoids.
-- The value is never logged, encoded, or journaled.
data BehaviorEnv = BehaviorEnv
  { runtime :: !ProgramRuntime,
    model :: !Model,
    options :: !Options,
    traceSink :: !(Maybe TraceSink),
    providerRegistry :: !(Maybe ProviderRegistry),
    tools :: !ToolRegistry,
    activeOverlays :: !(Set CapabilityId),
    toolTurnLimit :: !ToolTurnLimit
  }
  deriving stock (Generic)

-- | Hard model-turn ceiling for a tool-using Skill behavior.
defaultToolTurnLimit :: ToolTurnLimit
defaultToolTurnLimit = either (error . show) id (parseToolTurnLimit 8)

-- | The upstream id of the model this environment dispatches with — @stub-v1@
-- under the stub, @claude-haiku-4-5@ and the like under a real provider.
--
-- This is what a completed run records on its kioku session as @modelUsed@,
-- which is the durable half of the promise that a stub never passes for a model.
-- The startup log says what /this/ process is running; the session row says what
-- produced /that/ answer, and survives the process.
--
-- A plain field selector would be ambiguous at most call sites, because baikai's
-- own 'Baikai.Response.Response' has a @model@ field too.
behaviorModelId :: BehaviorEnv -> Text
behaviorModelId BehaviorEnv {model} = modelId model

-- | Build a deterministic stub environment: construct the 'ProgramRuntime' and
-- register the stub baikai provider so the skill arm runs without a key.
--
-- This is the /test/ constructor, and it is stub-only by design — it is what
-- lets the suite run a whole agent loop with no key and a fixed reply. A process
-- an operator configures builds its environment with
-- 'Shikigami.Behavior.Provider.newBehaviorEnvFor', which honours
-- @behavior.provider@ and announces what it chose.
newBehaviorEnv :: IO BehaviorEnv
newBehaviorEnv =
  newBehaviorEnvWithTraceSink Nothing

-- | 'newBehaviorEnv' with a trace sink attached. Stub-only for the same reason.
newBehaviorEnvWithTraceSink :: Maybe TraceSink -> IO BehaviorEnv
newBehaviorEnvWithTraceSink traceSink = do
  rt <- newProgramRuntime
  registerStubProvider
  pure
    BehaviorEnv
      { runtime = rt,
        model = stubModel,
        options = emptyOptions,
        traceSink,
        providerRegistry = Nothing,
        tools = mkRegistry [],
        activeOverlays = Set.empty,
        toolTurnLimit = defaultToolTurnLimit
      }

-- | Derive one callback-local environment from an immutable base environment.
-- The active ids come from the same resolved snapshot whose leases produced the
-- composed registry.
withCapabilityTools :: ResolvedCapabilitySet -> ToolRegistry -> BehaviorEnv -> BehaviorEnv
withCapabilityTools resolved registry env =
  env
    & #tools .~ registry
    & #activeOverlays .~ Set.fromList (descriptorCapability <$> resolvedCapabilities resolved)
  where
    descriptorCapability Overlay.CapabilityDescriptor {Overlay.capability = capabilityId} = capabilityId

-- | Dispatch on the behavior union. The 'BehaviorInput' is what triggered the run
-- and what the agent remembers; the output @Value@ is the behavior's result.
runBehavior :: BehaviorEnv -> AgentDecl -> BehaviorInput -> IO (Either RunError Value)
runBehavior env decl input
  | not (overlaysMatch env decl) =
      pure
        ( Left
            ( CapabilityOverlayMismatch
                ((.capabilityOverlays) decl)
                (Set.toAscList ((.activeOverlays) env))
            )
        )
  | otherwise = case (.behavior) decl of
      ShikumiProgram {task = t} ->
        case lookupTask (declarationCoordinateText t) of
          Nothing -> pure (Left (UnknownTask (declarationCoordinateText t)))
          Just tk -> runProgramTask ((.runtime) env) tk input
      Skill {path = p} ->
        runSkillWith
          ((.model) env)
          ((.options) env)
          ((.tools) env)
          ((.toolTurnLimit) env)
          (SkillDir (Text.unpack (declarationCoordinateText p)))
          input
          (completeBehaviorRequest env)
      Flow {} ->
        pure (Left (UnsupportedBehavior "Flow"))
      CoordinatingSkill {} ->
        pure (Left (UnsupportedBehavior "CoordinatingSkill requires an admitted durable coordination scope"))
      Deterministic {} ->
        -- Deterministic-rule behaviors are EP-6's concern; the runner does not execute them.
        pure (Left (UnsupportedBehavior "Deterministic"))

overlaysMatch :: BehaviorEnv -> AgentDecl -> Bool
overlaysMatch BehaviorEnv {activeOverlays} AgentDecl {capabilityOverlays} =
  length capabilityOverlays == Set.size requested
    && requested == activeOverlays
  where
    requested = Set.fromList capabilityOverlays

-- | Bound one synchronous behavior call. Retryable failures and timeouts throw
-- before a workflow step can append them; permanent failures remain a bounded
-- journal value.
runBehaviorAttempt :: NominalDiffTime -> BehaviorEnv -> AgentDecl -> BehaviorInput -> IO (Either Text Value)
runBehaviorAttempt attemptTimeout env decl input =
  runBehaviorAttemptWith attemptTimeout (runBehavior env decl input)

runBehaviorAttemptWith :: NominalDiffTime -> IO (Either RunError Value) -> IO (Either Text Value)
runBehaviorAttemptWith attemptTimeout action = do
  attempted <- timeout (timeoutMicroseconds attemptTimeout) action
  case attempted of
    Nothing ->
      throwIO
        ( TransientBehaviorFailure
            ( boundedBehaviorDetail
                ("behavior attempt timed out after " <> Text.pack (show attemptTimeout))
            )
        )
    Just (Left err) ->
      case classifyRunError err of
        Transient -> throwIO (TransientBehaviorFailure (renderRunError err))
        Permanent -> pure (Left (renderRunError err))
    Just (Right value) -> pure (Right value)

timeoutMicroseconds :: NominalDiffTime -> Int
timeoutMicroseconds duration =
  fromInteger
    ( max
        1
        ( min
            (toInteger (maxBound :: Int))
            (ceiling (nominalDiffTimeToSeconds duration * 1000000))
        )
    )

-- | Parse the original behavior input, then execute the typed task.
runProgramTask :: ProgramRuntime -> ProgramTask -> BehaviorInput -> IO (Either RunError Value)
runProgramTask rt (ProgramTask {parse, run}) input =
  case parse input of
    Left err -> pure (Left (ProgramInputFailed err))
    Right parsed -> run rt parsed

completeBehaviorRequest :: BehaviorEnv -> Model -> Context -> Options -> IO Response
completeBehaviorRequest env = case env.traceSink of
  Nothing -> completeRequestWith registry
  Just sink -> BaikaiTrace.withTraceWith registry sink
  where
    registry = fromMaybe globalProviderRegistry env.providerRegistry

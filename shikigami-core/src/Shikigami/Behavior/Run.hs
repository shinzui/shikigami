-- | The behavior runner: dispatch a loaded 'AgentDecl' on its behavior union and
-- return the behavior's output as a JSON value. The @ShikumiProgram@ arm runs a
-- registered @handan@ task; the @Skill@ arm runs a baikai completion. Both run
-- deterministically with stubs (no model key). EP-5's worker calls 'runBehavior'; the
-- sinks (EP-3) consume its output value.
module Shikigami.Behavior.Run
  ( BehaviorEnv (..),
    BehaviorInput (..),
    RunError (..),
    behaviorModelId,
    newBehaviorEnv,
    newBehaviorEnvWithTraceSink,
    programArgs,
    runBehavior,
    -- | Exported for "Shikigami.BehaviorInputSpec", which runs a locally
    -- constructed task to observe the argument map a real dispatch builds.
    runProgramTask,
    triggerOnly,
  )
where

import Baikai.Model (Model, modelId)
import Baikai.Options (Options, emptyOptions)
import Baikai.Trace (TraceSink)
import Baikai.Trace qualified as BaikaiTrace
import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Text (encodeToLazyText)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as TL
import Handan.Contract (Envelope (..), Status (ErrorS))
import Handan.Runtime (Runtime, newRuntime)
import Handan.Task (Task (..))
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Behavior.Error (RunError (..))
import Shikigami.Behavior.Input (BehaviorInput (..), memoryContentText, triggerOnly)
import Shikigami.Behavior.Skill (SkillDir (..), runSkill, runSkillWith)
import Shikigami.Behavior.StubProvider (registerStubProvider, stubModel)
import Shikigami.Program.Registry (lookupTask)

-- | What 'runBehavior' needs to run either arm: a handan 'Runtime' (built once),
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
  { runtime :: !Runtime,
    model :: !Model,
    options :: !Options,
    traceSink :: !(Maybe TraceSink)
  }

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

-- | Build a deterministic stub environment: construct the handan 'Runtime' and
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
  rt <- newRuntime
  registerStubProvider
  pure BehaviorEnv {runtime = rt, model = stubModel, options = emptyOptions, traceSink}

-- | Dispatch on the behavior union. The 'BehaviorInput' is what triggered the run
-- and what the agent remembers; the output @Value@ is the behavior's result.
runBehavior :: BehaviorEnv -> AgentDecl -> BehaviorInput -> IO (Either RunError Value)
runBehavior env decl input =
  case behavior decl of
    ShikumiProgram {task = t} ->
      case lookupTask t of
        Nothing -> pure (Left (UnknownTask t))
        Just tk -> runProgramTask (runtime env) tk input
    Skill {path = p} ->
      runSkillWithTrace (traceSink env) (model env) (options env) (SkillDir (Text.unpack p)) input
    Flow {} ->
      pure (Left (UnsupportedBehavior "Flow"))
    Deterministic {} ->
      -- Deterministic-rule behaviors are EP-6's concern; the runner does not execute them.
      pure (Left (UnsupportedBehavior "Deterministic"))

-- | Run a program task: parse its input from the argument map, run it, and
-- extract the @Envelope@'s verdict as the output value.
runProgramTask :: Runtime -> Task -> BehaviorInput -> IO (Either RunError Value)
runProgramTask rt (Task {taskParse = parse, taskRun = run}) input =
  case parse (programArgs input) of
    Left err -> pure (Left (ProgramFailed err))
    Right parsed -> envelopeToResult <$> run rt parsed

-- | The behavior's input as handan's argument map — the program arm's equivalent
-- of the skill arm's user message.
--
-- handan's parse seam is @taskParse :: ArgMap -> Either Text i@ over
-- @Map Text Text@, so both values travel as compact JSON text under fixed keys.
-- A task that does not care about either key ignores it, which is why this is
-- safe for every task already registered; a task that does care reads
-- @payload@ or @prior@. Previously this was @Map.empty@, so a program could not
-- see what triggered it no matter what it asked for.
programArgs :: BehaviorInput -> Map Text Text
programArgs BehaviorInput {payload, recalled} =
  Map.fromList
    [ ("payload", compactJson payload),
      ("prior", compactJson (toJSON (memoryContentText <$> recalled)))
    ]

compactJson :: Value -> Text
compactJson = TL.toStrict . encodeToLazyText

-- | Map a handan 'Envelope' to the runner's result: an @ErrorS@ status is a failure;
-- otherwise the verdict (or @null@ if a pure effect produced none) is the output.
envelopeToResult :: Envelope -> Either RunError Value
envelopeToResult (Envelope {status = st, verdict = v, message = msg}) =
  case st of
    ErrorS -> Left (ProgramFailed msg)
    _ -> Right (maybe Aeson.Null id v)

runSkillWithTrace :: Maybe TraceSink -> Model -> Options -> SkillDir -> BehaviorInput -> IO (Either RunError Value)
runSkillWithTrace Nothing model options dir input =
  runSkill model options dir input
runSkillWithTrace (Just sink) model options dir input =
  runSkillWith model options dir input (BaikaiTrace.withTrace sink)

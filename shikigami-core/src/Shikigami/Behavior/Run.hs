-- | The behavior runner: dispatch a loaded 'AgentDecl' on its behavior union and
-- return the behavior's output as a JSON value. The @ShikumiProgram@ arm runs a
-- registered @handan@ task; the @Skill@ arm runs a baikai completion. Both run
-- deterministically with stubs (no model key). EP-5's worker calls 'runBehavior'; the
-- sinks (EP-3) consume its output value.
module Shikigami.Behavior.Run
  ( BehaviorEnv (..),
    RunError (..),
    newBehaviorEnv,
    runBehavior,
  )
where

import Baikai.Model (Model)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Map qualified as Map
import Data.Text qualified as Text
import Handan.Contract (Envelope (..), Status (ErrorS))
import Handan.Runtime (Runtime, newRuntime)
import Handan.Task (Task (..))
import Shikigami.Api.Agent (AgentDecl (..), Behavior (..))
import Shikigami.Behavior.Error (RunError (..))
import Shikigami.Behavior.Skill (SkillDir (..), runSkill)
import Shikigami.Behavior.StubProvider (registerStubProvider, stubModel)
import Shikigami.Program.Registry (lookupTask)

-- | What 'runBehavior' needs to run either arm: a handan 'Runtime' (built once) and
-- the model the skill arm dispatches with. Built once at worker startup.
data BehaviorEnv = BehaviorEnv
  { runtime :: !Runtime,
    model :: !Model
  }

-- | Build the env once: construct the handan 'Runtime' and register the stub baikai
-- provider so the skill arm runs without a key.
newBehaviorEnv :: IO BehaviorEnv
newBehaviorEnv = do
  rt <- newRuntime
  registerStubProvider
  pure BehaviorEnv {runtime = rt, model = stubModel}

-- | Dispatch on the behavior union. The input @Value@ is the trigger payload; the
-- output @Value@ is the behavior's result.
runBehavior :: BehaviorEnv -> AgentDecl -> Value -> IO (Either RunError Value)
runBehavior env decl payload =
  case behavior decl of
    ShikumiProgram {task = t} ->
      case lookupTask t of
        Nothing -> pure (Left (UnknownTask t))
        Just tk -> runProgramTask (runtime env) tk payload
    Skill {path = p} ->
      runSkill (model env) (SkillDir (Text.unpack p)) payload
    Deterministic {} ->
      -- Deterministic-rule behaviors are EP-6's concern; the runner does not execute them.
      pure (Left (UnsupportedBehavior "Deterministic"))

-- | Run a program task: parse its input (the stub ignores the args), run it, and
-- extract the @Envelope@'s verdict as the output value.
runProgramTask :: Runtime -> Task -> Value -> IO (Either RunError Value)
runProgramTask rt (Task {taskParse = parse, taskRun = run}) _payload =
  case parse Map.empty of
    Left err -> pure (Left (ProgramFailed err))
    Right input -> envelopeToResult <$> run rt input

-- | Map a handan 'Envelope' to the runner's result: an @ErrorS@ status is a failure;
-- otherwise the verdict (or @null@ if a pure effect produced none) is the output.
envelopeToResult :: Envelope -> Either RunError Value
envelopeToResult (Envelope {status = st, verdict = v, message = msg}) =
  case st of
    ErrorS -> Left (ProgramFailed msg)
    _ -> Right (maybe Aeson.Null id v)

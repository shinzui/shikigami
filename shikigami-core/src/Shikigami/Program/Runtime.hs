{-# LANGUAGE DataKinds #-}

-- | Process-local Shikumi execution. Application policy and attempt accounting
-- belong to DecisionRunner; both execution modes share this interpreter stack.
module Shikigami.Program.Runtime
  ( ProgramRuntime (..),
    newProgramRuntime,
    runProgramWith,
    streamProgramWith,
  )
where

import Baikai.Model (Model)
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.Claude.Api qualified as Claude
import Baikai.Provider.Registry (globalProviderRegistry)
import Effectful (Eff, IOE, liftIO, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import GHC.Generics (Generic)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM, LLMConfig, defaultLLMConfig, runLLMResilient)
import Shikumi.Program (Program, runProgram)
import Shikumi.Routing (Routing, routeLLM, runRouting)
import Shikumi.Stream (StreamEvent, streamProgram)

-- No Show or encoding: the configuration can carry process-local providers.
data ProgramRuntime = ProgramRuntime
  { config :: !LLMConfig,
    defaultModel :: !Model
  }
  deriving stock (Generic)

-- | Preserve the legacy bootstrap and default for program behaviors. Skill
-- model selection is independent; decisions replace these values locally.
newProgramRuntime :: IO ProgramRuntime
newProgramRuntime = do
  Claude.register
  pure
    ProgramRuntime
      { config = defaultLLMConfig globalProviderRegistry,
        defaultModel = Models.anthropic_claude_haiku_4_5
      }

runProgramWith :: ProgramRuntime -> Program i o -> i -> IO (Either ShikumiError o)
runProgramWith runtime program input = runAction runtime (runProgram program input)

streamProgramWith :: ProgramRuntime -> Program i o -> i -> (StreamEvent -> IO ()) -> IO (Either ShikumiError o)
streamProgramWith runtime program input observe =
  runAction runtime (streamProgram program input (liftIO . observe))

-- Routing must rewrite the placeholder before resilient dispatch sees it.
runAction :: ProgramRuntime -> Eff '[LLM, Routing, Concurrent, Error ShikumiError, IOE] a -> IO (Either ShikumiError a)
runAction ProgramRuntime {config, defaultModel} =
  runEff
    . runErrorNoCallStack @ShikumiError
    . runConcurrent
    . runRouting defaultModel
    . runLLMResilient config
    . routeLLM

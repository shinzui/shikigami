{-# LANGUAGE GADTs #-}

-- | The behavior catalog hides each task's parsed input type while retaining
-- the original trigger and recalled learnings at its parsing boundary.
module Shikigami.Program.Task (ProgramTask (..)) where

import Data.Aeson (Value)
import Data.Text (Text)
import Shikigami.Behavior.Error (RunError)
import Shikigami.Behavior.Input (BehaviorInput)
import Shikigami.Program.Runtime (ProgramRuntime)

data ProgramTask where
  ProgramTask ::
    { name :: !Text,
      parse :: !(BehaviorInput -> Either Text i),
      run :: !(ProgramRuntime -> i -> IO (Either RunError Value))
    } ->
    ProgramTask

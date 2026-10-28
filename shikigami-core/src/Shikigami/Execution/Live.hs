module Shikigami.Execution.Live (MissingLiveExecution (..)) where

import Control.Exception (Exception)

data MissingLiveExecution = MissingLiveExecution
  deriving stock (Eq, Show)

instance Exception MissingLiveExecution

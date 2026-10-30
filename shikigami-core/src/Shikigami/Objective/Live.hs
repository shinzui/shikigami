module Shikigami.Objective.Live (MissingLiveObjective (..)) where

import Control.Exception (Exception)
import Prelude

data MissingLiveObjective = MissingLiveObjective deriving stock (Show)

instance Exception MissingLiveObjective

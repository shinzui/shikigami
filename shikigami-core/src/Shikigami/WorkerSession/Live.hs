module Shikigami.WorkerSession.Live (MissingLiveSession (..)) where

import Control.Exception (Exception)
import Prelude

data MissingLiveSession = MissingLiveSession
  deriving stock (Show)

instance Exception MissingLiveSession

module Shikigami.Mandate.Live where

import Control.Exception (Exception)

data MissingLiveMandate = MissingLiveMandate deriving stock (Show)

instance Exception MissingLiveMandate

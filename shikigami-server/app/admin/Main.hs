module Main (main) where

import Control.Monad (join)
import Options.Applicative (execParser)
import Shikigami.Server.Command (adminInfo)

-- | @shikigami@: the administrative, validation, enqueue, and test-stub commands.
main :: IO ()
main = join (execParser adminInfo)

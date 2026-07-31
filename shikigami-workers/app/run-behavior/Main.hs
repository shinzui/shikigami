module Main (main) where

import Control.Monad (join)
import Options.Applicative (execParser)
import Shikigami.Workers.Command (runBehaviorInfo)

-- | @shikigami-run-behavior@. See "Shikigami.Workers.Command" for the role it plays.
main :: IO ()
main = join (execParser runBehaviorInfo)

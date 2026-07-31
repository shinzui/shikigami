module Main (main) where

import Control.Monad (join)
import Options.Applicative (execParser)
import Shikigami.Workers.Command (schedulerInfo)

-- | @shikigami-scheduler@. See "Shikigami.Workers.Command" for the role it plays.
main :: IO ()
main = join (execParser schedulerInfo)

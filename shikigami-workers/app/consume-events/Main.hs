module Main (main) where

import Control.Monad (join)
import Options.Applicative (execParser)
import Shikigami.Workers.Command (consumeEventsInfo)

-- | @shikigami-consume-events@. See "Shikigami.Workers.Command" for the role it plays.
main :: IO ()
main = join (execParser consumeEventsInfo)

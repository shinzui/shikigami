module Main (main) where

import Control.Monad (join)
import Options.Applicative (execParser)
import Shikigami.Workers.Command (consumeStreamInfo)

-- | @shikigami-consume-stream@. See "Shikigami.Workers.Command" for the role it plays.
main :: IO ()
main = join (execParser consumeStreamInfo)

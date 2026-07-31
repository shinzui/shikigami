module Main (main) where

import Control.Monad (join)
import Options.Applicative (execParser)
import Shikigami.Workers.Command (agentRunInfo)

-- | @shikigami-agent-run@. See "Shikigami.Workers.Command" for the role it plays.
main :: IO ()
main = join (execParser agentRunInfo)

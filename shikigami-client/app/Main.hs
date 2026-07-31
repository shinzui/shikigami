module Main (main) where

import Control.Monad (join)
import Options.Applicative (execParser)
import Shikigami.Client.Command (clientInfo)

-- | @shikigami-client@: call a running shikigami server through the typed client.
main :: IO ()
main = join (execParser clientInfo)

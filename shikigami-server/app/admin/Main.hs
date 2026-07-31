module Main (main) where

import Shikigami.Server.Command (runAdmin)

-- | @shikigami@: the administrative, validation, enqueue, and test-stub commands.
main :: IO ()
main = runAdmin

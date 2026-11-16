-- | The @shikigami@ admin command composed with the examples pack.
module Main (main) where

import FlowPack.Examples (examplesPack)
import Shikigami.Server.Command (runAdminWith)

main :: IO ()
main = runAdminWith [examplesPack]

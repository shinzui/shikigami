module Main (main) where

import Codd.Environment (getCoddSettings)
import Data.Time (secondsToDiffTime)
import Shikigami.Migrations (runShikigamiMigrationsNoCheck)

main :: IO ()
main = do
  settings <- getCoddSettings
  _ <- runShikigamiMigrationsNoCheck settings (secondsToDiffTime 5)
  pure ()

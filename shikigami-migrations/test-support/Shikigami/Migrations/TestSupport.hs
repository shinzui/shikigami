module Shikigami.Migrations.TestSupport
  ( withShikigamiMigratedDatabase,
  )
where

import Codd.Extras.Settings (noCheckCoddSettings)
import Codd.Extras.TestSupport (withMigratedDatabase)
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import Shikigami.Migrations (runShikigamiMigrationsNoCheck)

withShikigamiMigratedDatabase :: (Text -> IO a) -> IO a
withShikigamiMigratedDatabase =
  withMigratedDatabase \connStr -> do
    _ <-
      runShikigamiMigrationsNoCheck
        (noCheckCoddSettings ["kiroku", "keiro", "kioku", "shikigami", "pgmq", "public"] connStr)
        (secondsToDiffTime 5)
    pure ()

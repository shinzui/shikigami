{-# LANGUAGE MultilineStrings #-}

-- | Ephemeral, fully-migrated databases for the repository's database-backed
-- test suites.
--
-- The July 2026 cohort replaced the codd apply path with @pg-migrate@, so this
-- module now drives 'Database.PostgreSQL.Migrate.Test.withMigratedDatabase'.
-- The exported signature is unchanged — callers still receive a connection
-- string — because that is what @shikigami-core@ and @shikigami-workers@ tests
-- hand to their pools.
module Shikigami.Migrations.TestSupport
  ( withShikigamiMigratedDatabase,
  )
where

import Data.Text (Text)
import Database.PostgreSQL.Migrate.Test qualified as PgMigrate
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shikigami.Migrations (shikigamiMigrationPlan)

withShikigamiMigratedDatabase :: (Text -> IO a) -> IO a
withShikigamiMigratedDatabase use = do
  plan <- either (fail . show) pure shikigamiMigrationPlan
  result <-
    PgMigrate.withMigratedDatabase plan \connection -> do
      connectionStringResult <- Connection.use connection connectionStringSession
      connectionString <- either (fail . show) pure connectionStringResult
      use connectionString
  either (fail . show) pure result

-- pg-migrate-test-support supplies a live Hasql connection so assertions cannot
-- inherit runner session state. Shikigami's callers want a connection string, so
-- recover the ephemeral server's coordinates from that fresh callback session.
connectionStringSession :: Session.Session Text
connectionStringSession = Session.statement () connectionStringStatement

connectionStringStatement :: Statement () Text
connectionStringStatement =
  preparable
    """
    SELECT 'host=' || split_part(current_setting('unix_socket_directories'), ',', 1)
        || ' port=' || current_setting('port')
        || ' dbname=' || current_database()
        || ' user=' || current_user
    """
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))

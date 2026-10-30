-- | One migrated template per suite and an isolated database per example.
-- Runtime packages must never acquire PostgreSQL through this test boundary.
module Shikigami.Migrations.TestSupport
  ( DatabaseFixture,
    withShikigamiMigratedSuite,
    withShikigamiFreshDatabase,
    withShikigamiMigratedDatabase,
  )
where

import Data.Text (Text)
import Keiro.Test.Postgres qualified as Postgres
import Kioku.Migrations qualified as Kioku
import Pgmq.Migration qualified as Pgmq
import Shikigami.Migrations (reconcileShikigamiReadModels, shikigamiMigrations)

type DatabaseFixture = Postgres.Fixture

-- | Keiro supplies Kiroku and Keiro. Add the application components exactly once;
-- The transport schema is owned by the published PGMQ component.
withShikigamiMigratedSuite :: (DatabaseFixture -> IO a) -> IO a
withShikigamiMigratedSuite use = do
  kioku <- either (fail . show) pure Kioku.kiokuMigrations
  pgmq <- either (fail . show) pure Pgmq.pgmqMigrations
  shikigami <- either (fail . show) pure shikigamiMigrations
  Postgres.withMigratedSuiteWith [kioku, pgmq, shikigami] use

-- | Clone the suite template, reconcile Kioku's compiled read-model identities,
-- and release the clone even when the example raises an exception. All caller
-- connections must be bracketed inside the callback so they close before drop.
withShikigamiFreshDatabase :: DatabaseFixture -> (Text -> IO a) -> IO a
withShikigamiFreshDatabase fixture use =
  Postgres.withFreshDatabase fixture \connectionString -> do
    reconcileShikigamiReadModels connectionString
    use connectionString

-- | Convenience for a standalone check. Suites should share the suite fixture.
withShikigamiMigratedDatabase :: (Text -> IO a) -> IO a
withShikigamiMigratedDatabase use =
  withShikigamiMigratedSuite \fixture -> withShikigamiFreshDatabase fixture use

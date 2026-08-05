{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

-- | Shikigami's schema evolution, expressed as a @pg-migrate@ component and
-- composed with the components the runtime libraries publish.
--
-- @kioku-migrations@ publishes @kiokuMigrations@ as a 'MigrationComponent'
-- rather than a pre-concatenated list, so this module names the four components
-- explicitly and lets @pg-migrate@ order them from their declared dependencies,
-- instead of relying on kioku to have pre-concatenated kiroku and keiro.
--
-- The durable migration identity is @\<component\>\/\<migration-name\>@, and the
-- migration name is the SQL filename without its extension. Renaming a file
-- therefore renames an applied migration, which a database that already ran it
-- will reject — so treat the names as fixed once applied, and add rather than
-- rename. @pg-migrate@ also fingerprints each migration's exact bytes, so
-- editing applied SQL is a checksum mismatch for the same reason; corrections go
-- in a new numbered manifest entry.
--
-- Transaction mode is declared in Haskell, on the component, not in a SQL header
-- comment.
module Shikigami.Migrations
  ( DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    embeddedMigrationEntries,
    shikigamiMigrations,
    shikigamiMigrationPlan,
    reconcileShikigamiReadModels,
  )
where

import Control.Exception (throwIO)
import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Database.PostgreSQL.Migrate
  ( DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    migrationComponentFromEmbeddedSql,
    migrationPlan,
  )
import Database.PostgreSQL.Migrate.Embed (embedMigrationManifest)
import Keiro.Migrations qualified as Keiro
import Kioku.App (runAppIO, withNoopAppEnv)
import Kioku.Migrations qualified as Kioku
import Kioku.ReadModel (reconcileReadModelRegistry)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Migrations qualified as Kiroku

-- | Shikigami's own SQL, embedded at compile time from @sql-migrations/manifest@.
-- The manifest's order is the migration order; the recompile plugin makes GHC
-- notice a newly added file.
embeddedMigrationEntries :: NonEmpty (FilePath, ByteString)
embeddedMigrationEntries =
  $(embedMigrationManifest "sql-migrations/manifest")

-- | The @shikigami@ component: the detector suppression table and the vendored
-- PGMQ schema. It depends on @kioku@, which in turn depends on @keiro@ and
-- @kiroku@, so the plan orders it last.
shikigamiMigrations :: Either DefinitionError MigrationComponent
shikigamiMigrations =
  migrationComponentFromEmbeddedSql
    "shikigami"
    (Set.singleton "kioku")
    embeddedMigrationEntries

-- | The complete Kiroku, Keiro, Kioku, and Shikigami plan in dependency order.
--
-- A 'DefinitionError' here means an embedded component is malformed, which is a
-- compile-time-embedded fact rather than anything an operator can fix at run
-- time; it is raised as an error the way the upstream components do.
shikigamiMigrationPlan :: Either PlanError MigrationPlan
shikigamiMigrationPlan = do
  kiroku <- componentOrDie "Kiroku" Kiroku.kirokuMigrations
  keiro <- componentOrDie "Keiro" Keiro.keiroMigrations
  kioku <- componentOrDie "Kioku" Kioku.kiokuMigrations
  shikigami <- componentOrDie "Shikigami" shikigamiMigrations
  migrationPlan (kiroku :| [keiro, kioku, shikigami])
  where
    componentOrDie label =
      either
        (error . (("invalid embedded " <> label <> " migration component: ") <>) . show)
        pure

-- | Bring keiro's @keiro_read_models@ registry up to the identity the compiled
-- Kioku expects.
--
-- Applying the plan is only half the job. Keiro records each read model's
-- version and shape hash in a registry row and refuses to serve a query whose
-- row disagrees with the code, and @registerReadModel@ only ever /inserts/ — so
-- an existing row stays pinned at its old identity and every query for that
-- model fails closed after a Kioku upgrade. @kioku-migrate up@ reconciles the
-- registry for hosts that use it; a host running a composed plan directly, as
-- this one does, must call this itself.
--
-- Run it at migration time, not at process startup, or every booting process
-- races to write the registry. It is idempotent: a second run writes nothing.
reconcileShikigamiReadModels :: Text -> IO ()
reconcileShikigamiReadModels connectionString =
  withNoopAppEnv (defaultConnectionSettings connectionString) \env -> do
    outcome <- runAppIO env reconcileReadModelRegistry
    either throwIO (const (pure ())) outcome

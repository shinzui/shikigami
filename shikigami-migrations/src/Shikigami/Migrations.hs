{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

-- | Shikigami's schema evolution, expressed as a @pg-migrate@ component and
-- composed with the components the runtime libraries publish.
--
-- The July 2026 cohort moved every library in the stack off codd:
-- @kioku-migrations 0.2@ publishes @kiokuMigrations@ as a
-- 'MigrationComponent' rather than a list of codd @AddedSqlMigration@s, so
-- there is no longer a codd-shaped set to append to. This module therefore
-- names the four components explicitly and lets @pg-migrate@ order them from
-- their declared dependencies, instead of relying on kioku to have
-- pre-concatenated kiroku and keiro.
--
-- The durable migration identity is @\<component\>\/\<migration-name\>@, and the
-- migration name is the SQL filename without its extension. The filenames here
-- keep their original codd-era timestamps and their @-- codd: in-txn@ header
-- comments on purpose: they are the payload evidence
-- @docs\/plans\/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md@
-- needs to import an existing codd ledger. Do not rename or reformat them.
module Shikigami.Migrations
  ( DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    embeddedMigrationEntries,
    shikigamiMigrations,
    shikigamiMigrationPlan,
  )
where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
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
import Kioku.Migrations qualified as Kioku
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

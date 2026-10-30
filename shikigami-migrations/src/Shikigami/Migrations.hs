{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

-- | Shikigami's schema evolution, expressed as a @pg-migrate@ component and
-- composed with the components the runtime libraries publish.
--
-- @kioku-migrations@ publishes @kiokuMigrations@ as a 'MigrationComponent'
-- rather than a pre-concatenated list, so this module names the five components
-- explicitly and lets @pg-migrate@ validate their declared dependency order,
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
    verifyShikigamiMigrations,
    verifyShikigamiSchema,
  )
where

import Control.Exception (bracket, throwIO)
import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
  ( DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    VerificationReport (..),
    defaultRunOptions,
    migrationComponentFromEmbeddedSql,
    migrationPlan,
    verifyMigrationPlan,
  )
import Database.PostgreSQL.Migrate.Embed (embedMigrationManifest)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Keiro.Migrations qualified as Keiro
import Keiro.Migrations.SchemaCheck qualified as Schema
import Kioku.App (runAppIO, withNoopAppEnv)
import Kioku.Migrations qualified as Kioku
import Kioku.ReadModel (reconcileReadModelRegistry)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Migrations qualified as Kiroku
import Language.Haskell.TH.Syntax qualified as TH
import Pgmq.Migration qualified as Pgmq

-- | Shikigami's own SQL, embedded at compile time from @sql-migrations/manifest@.
-- The manifest's order is the migration order; the recompile plugin makes GHC
-- notice a newly added file.
embeddedMigrationEntries :: NonEmpty (FilePath, ByteString)
embeddedMigrationEntries =
  $(embedMigrationManifest "sql-migrations/manifest")

-- | Application tables depend on Kioku and the upstream-owned PGMQ schema.
-- The first-release baseline installs PGMQ exactly once through its component.
shikigamiMigrations :: Either DefinitionError MigrationComponent
shikigamiMigrations =
  migrationComponentFromEmbeddedSql
    "shikigami"
    (Set.fromList ["kioku", "pgmq"])
    embeddedMigrationEntries

-- | The complete Kiroku, Keiro, Kioku, PGMQ and application plan.
--
-- A 'DefinitionError' here means an embedded component is malformed, which is a
-- compile-time-embedded fact rather than anything an operator can fix at run
-- time; it is raised as an error the way the upstream components do.
shikigamiMigrationPlan :: Either PlanError MigrationPlan
shikigamiMigrationPlan = do
  kiroku <- componentOrDie "Kiroku" Kiroku.kirokuMigrations
  keiro <- componentOrDie "Keiro" Keiro.keiroMigrations
  kioku <- componentOrDie "Kioku" Kioku.kiokuMigrations
  pgmq <- componentOrDie "PGMQ" Pgmq.pgmqMigrations
  shikigami <- componentOrDie "Shikigami" shikigamiMigrations
  migrationPlan (kiroku :| [keiro, kioku, pgmq, shikigami])
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

-- | Read-only startup handshake. Refuse missing, changed, failed or unknown
-- migration history before acquiring runtime resources. Only the migration
-- executable applies or repairs the composed plan.
verifyShikigamiMigrations :: Text -> IO ()
verifyShikigamiMigrations connectionString = do
  plan <- either (ioError . userError . show) pure shikigamiMigrationPlan
  result <- verifyMigrationPlan defaultRunOptions (Settings.connectionString connectionString) plan
  case result of
    Right report
      | null report.issues && null report.pendingMigrations && null report.unknownMigrations -> pure ()
    other -> ioError (userError ("runtime migration verification failed: " <> show other))

-- | Independent live-object verification for the migration CLI. The released
-- framework snapshot supports PostgreSQL 18 and refuses other server majors.
verifyShikigamiSchema :: Text -> IO ()
verifyShikigamiSchema connectionString =
  bracket
    (Connection.acquire (Settings.connectionString connectionString) >>= either (fail . show) pure)
    Connection.release
    \connection -> do
      result <- Connection.use connection do
        framework <- Schema.verifyExpectedSchemaSession
        application <- Schema.snapshotSchema "shikigami"
        pure ((<> Schema.compareSchemaSnapshot expectedApplicationSchema application) <$> framework)
      case result of
        Right (Right []) -> pure ()
        other -> ioError (userError ("live schema verification failed: " <> show other))

expectedApplicationSchema :: Text
expectedApplicationSchema =
  Text.pack
    $( do
         path <- TH.makeRelativeToProject "expected-schema.txt"
         TH.addDependentFile path
         TH.runIO (readFile path) >>= TH.lift
     )

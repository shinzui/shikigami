-- | @shikigami-migrate@: plan, apply, and verify the database migrations.
--
-- == Why this executable does not use the shared configuration declaration
--
-- Every other Shikigami binary resolves its settings from
-- @Shikigami.App.Config@ in @shikigami-core@. This one cannot, and the reason is
-- structural rather than a matter of taste: @shikigami-core@'s test suite
-- depends on this package's public @test-support@ sublibrary (it needs a
-- migrated database), so adding @shikigami-core@ to this executable's
-- @build-depends@ makes the two packages mutually dependent. Cabal's solver
-- rejects that outright — it reports @rejecting: shikigami-core:*test (cyclic
-- dependencies)@ and refuses to build the project — because it detects cycles at
-- package rather than component granularity.
--
-- So this binary reads @DATABASE_URL@ itself. That is the application-owned
-- connection boundary documented by @pg-migrate-cli@, not a second Shikigami
-- application configuration surface: nothing else in this process has a setting
-- to share. The decision at
-- @docs\/adr\/0032-the-migration-cli-keeps-a-dedicated-configuration-boundary.md@
-- accepts this deliberately rather than splitting the shared declaration into
-- another package or duplicating it here.
--
-- This executable initializes a fresh ledger and will refuse to re-apply
-- migrations it has already recorded.
module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate (defaultRunOptions)
import Database.PostgreSQL.Migrate.CLI
  ( CheckOptions (..),
    ExitClass (ExitSucceeded),
    ListOptions (..),
    MigrationCommand (..),
    NewOptions (..),
    OutputFormat (JsonOutput, TextOutput),
    OutputOptions (..),
    PlanOptions (..),
    RepairOptions (..),
    StatusOptions (..),
    UpOptions (..),
    VerifyOptions (..),
    cliEnvironment,
    exitClass,
    migrationCommandParser,
    renderMigrationCommandJson,
    renderMigrationCommandText,
    runMigrationCommand,
  )
import Hasql.Connection.Settings qualified as Settings
import Options.Applicative
  ( execParser,
    fullDesc,
    helper,
    info,
    progDesc,
    (<**>),
  )
import Shikigami.Migrations (reconcileShikigamiReadModels, shikigamiMigrationPlan)
import System.Environment (lookupEnv)
import System.Exit qualified as Exit

main :: IO ()
main = do
  plan <- either (fail . show) pure shikigamiMigrationPlan
  command <-
    execParser
      ( info
          (migrationCommandParser plan <**> helper)
          (fullDesc <> progDesc "Manage the Shikigami database schema")
      )
  databaseUrl <-
    lookupEnv "DATABASE_URL"
      >>= maybe (fail "DATABASE_URL is required") pure
  let environment =
        cliEnvironment
          (Settings.connectionString (Text.pack databaseUrl))
          plan
          defaultRunOptions
  outcome <- runMigrationCommand environment command
  -- Applying the plan is only half the job; see 'reconcileShikigamiReadModels'.
  -- Only the writing command does this, and only when it succeeded.
  case (command, exitClass outcome) of
    (Up {}, ExitSucceeded) -> reconcileShikigamiReadModels (Text.pack databaseUrl)
    _ -> pure ()
  case outputFormatOf command of
    TextOutput -> Text.IO.putStrLn (renderMigrationCommandText outcome)
    JsonOutput ->
      LazyByteString.putStrLn (Aeson.encode (renderMigrationCommandJson outcome))
  Exit.exitWith case exitClass outcome of
    ExitSucceeded -> Exit.ExitSuccess
    _ -> Exit.ExitFailure 1

outputFormatOf :: MigrationCommand -> OutputFormat
outputFormatOf = \case
  Plan PlanOptions {output = OutputOptions format} -> format
  List ListOptions {output = OutputOptions format} -> format
  Check CheckOptions {output = OutputOptions format} -> format
  Status StatusOptions {output = OutputOptions format} -> format
  Verify VerifyOptions {output = OutputOptions format} -> format
  Up UpOptions {output = OutputOptions format} -> format
  Repair RepairOptions {output = OutputOptions format} -> format
  New NewOptions {output = OutputOptions format} -> format

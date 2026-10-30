-- | The migration smoke: apply the plan to a real database, twice.
--
-- The composition tests next door are pure — they check that the five
-- components are named and ordered correctly without a server. They cannot
-- catch SQL that does not run, a component whose declared dependencies are
-- satisfiable on paper but not in PostgreSQL, or a migration that is not
-- idempotent. This module runs the thing.
--
-- The second pass is the point. pg-migrate keys applied migrations by
-- @\<component\>\/\<migration-name\>@ in its own ledger, so re-running must
-- report every migration 'AlreadyApplied' and execute no DDL. A migration that
-- appears as 'AppliedNow' twice would mean the ledger is not recording it, which
-- is exactly the failure mode that makes a production deploy non-repeatable.
--
-- Every database this repository creates starts from an empty ledger, so a fresh
-- apply is the only path there is; there is no prior migration tool to import
-- history from.
module Main (main) where

import Control.Exception (IOException, bracket, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate
  ( MigrationOutcome (AppliedNow),
    MigrationReport (..),
    MigrationResult (..),
    defaultRunOptions,
    runMigrationPlan,
  )
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Keiro.Migrations.SchemaCheck qualified as Schema
import Shikigami.Migrations (shikigamiMigrationPlan, verifyShikigamiMigrations, verifyShikigamiSchema)
import Shikigami.Migrations.TestSupport (withShikigamiFreshDatabase, withShikigamiMigratedSuite)
import System.Environment (lookupEnv)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

main :: IO ()
main = withShikigamiMigratedSuite \databaseFixture ->
  defaultMain
    ( testGroup
        "shikigami-migrations smoke"
        [ testCase "startup verifies the complete migrated ledger without applying work" do
            withShikigamiFreshDatabase databaseFixture \connectionString -> do
              verifyShikigamiMigrations connectionString
              verifyShikigamiMigrations connectionString,
          testCase "startup refuses a pending migration and does not apply it" do
            withShikigamiFreshDatabase databaseFixture \connectionString -> do
              -- Deliberately corrupt only this disposable clone to model a
              -- rollout whose last application migration has not run.
              withConnection connectionString \connection ->
                runSession connection (Session.script "DELETE FROM pgmigrate.migrations WHERE component = 'shikigami' AND position = (SELECT max(position) FROM pgmigrate.migrations WHERE component = 'shikigami')")
              result <- try @IOException (verifyShikigamiMigrations connectionString)
              assertBool "pending migration refuses startup" (either (Text.isInfixOf "PendingMigration" . Text.pack . show) (const False) result)
              again <- try @IOException (verifyShikigamiMigrations connectionString)
              assertBool "verification did not repair the ledger" (either (const True) (const False) again),
          testCase "startup refuses a missing ledger and does not initialize it" do
            withShikigamiFreshDatabase databaseFixture \connectionString -> do
              withConnection connectionString \connection ->
                runSession connection (Session.script "DROP SCHEMA pgmigrate CASCADE")
              result <- try @IOException (verifyShikigamiMigrations connectionString)
              assertBool "missing ledger refuses startup" (either (const True) (const False) result)
              withConnection connectionString \connection ->
                runSession connection (Session.statement () noLedger) >>= (@?= True),
          testCase "startup refuses changed migration bytes" do
            withShikigamiFreshDatabase databaseFixture \connectionString -> do
              withConnection connectionString \connection ->
                runSession connection (Session.script "UPDATE pgmigrate.migrations SET checksum = decode(repeat('0',64),'hex') WHERE component = 'shikigami'")
              result <- try @IOException (verifyShikigamiMigrations connectionString)
              assertBool "checksum mismatch refuses startup" (either (Text.isInfixOf "MigrationChecksumMismatch" . Text.pack . show) (const False) result),
          testCase "startup refuses an unknown migration without repairing it" do
            withShikigamiFreshDatabase databaseFixture \connectionString -> do
              withConnection connectionString \connection ->
                runSession connection (Session.script "UPDATE pgmigrate.migrations SET migration = 'unknown-first-release-entry' WHERE component = 'shikigami' AND position = (SELECT max(position) FROM pgmigrate.migrations WHERE component = 'shikigami')")
              result <- try @IOException (verifyShikigamiMigrations connectionString)
              assertBool "unknown migration refuses startup" (either (const True) (const False) result)
              again <- try @IOException (verifyShikigamiMigrations connectionString)
              assertBool "verification leaves the unknown entry intact" (either (const True) (const False) again),
          testCase "fresh provisioning includes transport and store prerequisites" do
            withShikigamiFreshDatabase databaseFixture \connectionString ->
              withConnection connectionString \connection ->
                runSession connection (Session.statement () releasedPrerequisites) >>= (@?= True),
          testCase "fresh application schema matches the reviewed snapshot and detects drift" do
            withShikigamiFreshDatabase databaseFixture \connectionString ->
              withConnection connectionString \connection -> do
                actual <- runSession connection (Schema.snapshotSchema "shikigami")
                regenerate <- lookupEnv "SHIKIGAMI_REGENERATE_EXPECTED_SCHEMA"
                case regenerate of
                  Just "1" -> Text.IO.writeFile "expected-schema.txt" actual
                  _ -> pure ()
                expected <- Text.IO.readFile "expected-schema.txt"
                Schema.compareSchemaSnapshot expected actual @?= []
                verifyShikigamiSchema connectionString
                runSession connection (Session.script "ALTER TABLE shikigami.fired ADD COLUMN unexpected_probe boolean")
                drifted <- runSession connection (Schema.snapshotSchema "shikigami")
                refused <- try @IOException (verifyShikigamiSchema connectionString)
                assertBool "operator verification refuses drift" (either (const True) (const False) refused)
                assertBool "live schema drift must fail independently of the ledger" (not (null (Schema.compareSchemaSnapshot expected drifted))),
          testCase "a fresh database applies the plan, and re-applying is a no-op" do
            plan <- either (fail . show) pure shikigamiMigrationPlan
            withShikigamiFreshDatabase databaseFixture \connectionString -> do
              -- The suite template already applied the plan; the fresh clone has
              -- a reconciled read-model registry; this is the second pass.
              report <-
                runMigrationPlan
                  defaultRunOptions
                  (Settings.connectionString connectionString)
                  plan
                  >>= either (fail . show) pure
              let reapplied =
                    [ migration result
                    | result <- NonEmpty.toList (results report),
                      outcome result == AppliedNow
                    ]
              assertBool
                ("re-running applied migrations again: " <> show reapplied)
                (null reapplied)
              assertBool
                "the second pass reported no migrations at all"
                (not (null (NonEmpty.toList (results report))))
              cleanupIssues report @?= [],
          testCase "the applied plan spans all five components" do
            plan <- either (fail . show) pure shikigamiMigrationPlan
            withShikigamiFreshDatabase databaseFixture \connectionString -> do
              report <-
                runMigrationPlan
                  defaultRunOptions
                  (Settings.connectionString connectionString)
                  plan
                  >>= either (fail . show) pure
              let rendered = Text.pack (show (migration <$> NonEmpty.toList (results report)))
              mapM_
                ( \component ->
                    assertBool
                      (Text.unpack component <> " is missing from the applied ledger")
                      (component `Text.isInfixOf` rendered)
                )
                ["kiroku", "keiro", "kioku", "pgmq", "shikigami"],
          testCase "examples share one template and isolate their data" do
            (firstName, firstTemplate) <- withShikigamiFreshDatabase databaseFixture \connectionString ->
              withConnection connectionString \connection -> do
                runSession connection (Session.script "CREATE TABLE public.fixture_sentinel (value integer); INSERT INTO public.fixture_sentinel VALUES (1)")
                runSession connection (Session.statement () coordinates)
            withShikigamiFreshDatabase databaseFixture \connectionString ->
              withConnection connectionString \connection -> do
                (secondName, secondTemplate) <- runSession connection (Session.statement () coordinates)
                assertBool "fresh database per example" (firstName /= secondName)
                firstTemplate @?= secondTemplate
                runSession connection (Session.statement () noSentinel) >>= (@?= True)
                runSession connection (Session.statement firstName databaseAbsent) >>= (@?= True),
          testCase "an exception releases the clone before the next example" do
            failedName <- newIORef ""
            result <- try @IOException $ withShikigamiFreshDatabase databaseFixture \connectionString -> do
              withConnection connectionString \connection -> do
                (name, _) <- runSession connection (Session.statement () coordinates)
                writeIORef failedName name
              ioError (userError "intentional fixture cleanup probe")
            assertBool "the callback exception escapes" (either (const True) (const False) result)
            name <- readIORef failedName
            assertBool "callback reached the clone" (not (Text.null name))
            withShikigamiFreshDatabase databaseFixture \connectionString ->
              withConnection connectionString \connection ->
                runSession connection (Session.statement name databaseAbsent) >>= (@?= True)
        ]
    )

withConnection :: Text -> (Connection.Connection -> IO a) -> IO a
withConnection connectionString =
  bracket
    (Connection.acquire (Settings.connectionString connectionString) >>= either (fail . show) pure)
    Connection.release

runSession :: Connection.Connection -> Session.Session a -> IO a
runSession connection session = Connection.use connection session >>= either (fail . show) pure

coordinates :: Statement () (Text, Int64)
coordinates =
  preparable
    "SELECT current_database()::text, oid::bigint FROM pg_database WHERE datname = 'keiro_template'"
    E.noParams
    (D.singleRow ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.int8)))

noSentinel :: Statement () Bool
noSentinel =
  preparable
    "SELECT to_regclass('public.fixture_sentinel') IS NULL"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

databaseAbsent :: Statement Text Bool
databaseAbsent =
  preparable
    "SELECT NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)"
    (E.param (E.nonNullable E.text))
    (D.singleRow (D.column (D.nonNullable D.bool)))

noLedger :: Statement () Bool
noLedger =
  preparable
    "SELECT to_regnamespace('pgmigrate') IS NULL"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

releasedPrerequisites :: Statement () Bool
releasedPrerequisites =
  preparable
    """
    SELECT
      EXISTS (SELECT 1 FROM pgmigrate.migrations
              WHERE component = 'pgmq' AND migration = '0007-notify-only-registered-queues' AND status = 'applied')
      AND (SELECT count(*) = 5 FROM pgmigrate.migrations
           WHERE component = 'kiroku' AND migration IN ('0012','0013','0014','0015','0016') AND status = 'applied')
      AND to_regprocedure('pgmq.notify_queue_listeners()') IS NOT NULL
      AND to_regclass('shikigami.fired') IS NOT NULL
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

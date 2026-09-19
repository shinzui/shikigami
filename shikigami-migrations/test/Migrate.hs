-- | The migration smoke: apply the plan to a real database, twice.
--
-- The composition tests next door are pure — they check that the four
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
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
  ( MigrationOutcome (AppliedNow),
    MigrationPlan,
    MigrationReport (..),
    MigrationResult (..),
    PlanError,
    connectionProvider,
    defaultRunOptions,
    migrationComponentFromEmbeddedSql,
    migrationPlan,
    runMigrationPlan,
    runMigrationPlanWith,
  )
import Database.PostgreSQL.Migrate.Test (withMigratedDatabase)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Keiro.Migrations qualified as Keiro
import Kioku.Migrations qualified as Kioku
import Kiroku.Store.Migrations qualified as Kiroku
import Shikigami.Migrations (shikigamiMigrationPlan, shikigamiMigrations, verifyShikigamiMigrations)
import Shikigami.Migrations.TestSupport (withShikigamiFreshDatabase, withShikigamiMigratedSuite)
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
          testCase "a real Keiro 0.15 ledger upgrades through 0032 and preserves durable rows" do
            oldPlan <- either (fail . show) pure legacy015MigrationPlan
            newPlan <- either (fail . show) pure shikigamiMigrationPlan
            upgraded <- withMigratedDatabase oldPlan \connection -> do
              runSession connection (Session.script legacyDurableSeed)
              oldLedger <- runSession connection (Session.statement () ledgerBefore0032)
              runSession connection (Session.script hostileMigrationHost)
              oldSearchPath <- runSession connection (Session.statement () currentSearchPath)
              let provider = connectionProvider (\use -> Right <$> use connection)
              first <- runMigrationPlanWith defaultRunOptions provider newPlan >>= either (fail . show) pure
              let applied =
                    [ migration result
                    | result <- NonEmpty.toList (results first),
                      outcome result == AppliedNow
                    ]
              assertBool ("upgrade applies exactly Keiro migration 0032: " <> show applied) (length applied == 1)
              runSession connection (Session.statement oldLedger upgradePreserved)
                >>= (@?= True)
              runSession connection (Session.statement oldSearchPath hostileHostPreserved)
                >>= (@?= True)
              second <- runMigrationPlanWith defaultRunOptions provider newPlan >>= either (fail . show) pure
              assertBool
                "second upgrade pass applies no migration"
                (null [() | result <- NonEmpty.toList (results second), outcome result == AppliedNow])
              cleanupIssues first @?= []
              cleanupIssues second @?= []
            either (fail . show) pure upgraded,
          testCase "the applied plan spans all four components" do
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
                ["kiroku", "keiro", "kioku", "shikigami"],
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

-- Keiro 0.15.0.0 contains the exact first 31 migration payloads exported by
-- 0.17.0.0; the released tarballs differ only by 0032 plus the manifest line.
-- Kioku 0.5.2.0 and 0.7.0.0 publish byte-identical migration components.
legacy015MigrationPlan :: Either PlanError MigrationPlan
legacy015MigrationPlan = do
  let oldKeiroEntries =
        [ entry
        | entry@(file, _) <- NonEmpty.toList Keiro.embeddedMigrationEntries,
          file /= "0032.sql"
        ]
  entries <- maybe (error "Keiro 0.15 migration fixture is empty") pure (NonEmpty.nonEmpty oldKeiroEntries)
  kiroku <- either (error . show) pure Kiroku.kirokuMigrations
  keiro <- either (error . show) pure (migrationComponentFromEmbeddedSql "keiro" (Set.singleton "kiroku") entries)
  kioku <- either (error . show) pure Kioku.kiokuMigrations
  shikigami <- either (error . show) pure shikigamiMigrations
  migrationPlan (kiroku :| [keiro, kioku, shikigami])

legacyDurableSeed :: Text
legacyDurableSeed =
  """
  SELECT pgmq.create('shikigami_run_jobs');
  SELECT pgmq.send('shikigami_run_jobs', '{"seed":"queue"}'::jsonb);
  INSERT INTO keiro.keiro_workflows
    (workflow_id, workflow_name, generation, status)
  VALUES ('legacy-workflow', 'shikigami.agent', 3, 'suspended');
  INSERT INTO keiro.keiro_timers
    (timer_id, process_manager_name, correlation_id, fire_at, payload, status, attempts, last_error)
  VALUES
    ('018f1000-0000-7000-8000-000000000010', 'shikigami.agent', 'legacy-workflow',
     '2026-09-19T00:00:00Z', '{"seed":"timer"}'::jsonb, 'dead', 2, 'legacy reason');
  INSERT INTO shikigami.run_evidence
    (run_id, run_evidence_id, status, verdict, reasons, binding, observations,
     expected_call_count, recorded_call_count)
  VALUES
    ('legacy-run', 'legacy-evidence', 'attested', 'sanctioned', '["preserved"]'::jsonb,
     '{"profile":"legacy"}'::jsonb, '{"source":"0.15"}'::jsonb, 1, 1);
  """

-- The host deliberately supplies an identically named relation first on the
-- session path. Migration 0032 must still alter keiro.keiro_timers and must not
-- mutate the runner's path as a side effect.
hostileMigrationHost :: Text
hostileMigrationHost =
  """
  CREATE SCHEMA hostile;
  CREATE TABLE hostile.keiro_timers (marker text);
  SET SESSION search_path TO hostile, public;
  """

currentSearchPath :: Statement () Text
currentSearchPath =
  preparable
    "SELECT current_setting('search_path')"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.text)))

hostileHostPreserved :: Statement Text Bool
hostileHostPreserved =
  preparable
    """
    SELECT
      current_setting('search_path') = $1
      AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'hostile' AND table_name = 'keiro_timers'
          AND column_name IN ('resume_claim_token', 'resume_lease_until')
      )
      AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'keiro' AND table_name = 'keiro_timers'
          AND column_name = 'resume_claim_token'
      )
    """
    (E.param (E.nonNullable E.text))
    (D.singleRow (D.column (D.nonNullable D.bool)))

ledgerBefore0032 :: Statement () Text
ledgerBefore0032 =
  preparable
    """
    SELECT string_agg(component || '/' || migration || ':' || encode(checksum, 'hex'), ',' ORDER BY component, position)
    FROM pgmigrate.migrations
    WHERE NOT (component = 'keiro' AND migration = '0032')
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.text)))

upgradePreserved :: Statement Text Bool
upgradePreserved =
  preparable
    """
    SELECT
      $1 = (
        SELECT string_agg(component || '/' || migration || ':' || encode(checksum, 'hex'), ',' ORDER BY component, position)
        FROM pgmigrate.migrations
        WHERE NOT (component = 'keiro' AND migration = '0032')
      )
      AND EXISTS (
        SELECT 1 FROM pgmigrate.migrations
        WHERE component = 'keiro' AND migration = '0032' AND status = 'applied'
      )
      AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'keiro' AND table_name = 'keiro_timers'
          AND column_name = 'resume_claim_token'
      )
      AND EXISTS (
        SELECT 1 FROM keiro.keiro_workflows
        WHERE workflow_id = 'legacy-workflow' AND generation = 3 AND status = 'suspended'
      )
      AND EXISTS (
        SELECT 1 FROM keiro.keiro_timers
        WHERE timer_id = '018f1000-0000-7000-8000-000000000010'
          AND status = 'dead' AND attempts = 2 AND last_error = 'legacy reason'
          AND payload = '{"seed":"timer"}'::jsonb
          AND resume_claim_token IS NULL AND resume_lease_until IS NULL
      )
      AND EXISTS (
        SELECT 1 FROM shikigami.run_evidence
        WHERE run_id = 'legacy-run' AND verdict = 'sanctioned'
          AND binding = '{"profile":"legacy"}'::jsonb
      )
      AND EXISTS (
        SELECT 1 FROM pgmq.q_shikigami_run_jobs
        WHERE message = '{"seed":"queue"}'::jsonb
      )
    """
    (E.param (E.nonNullable E.text))
    (D.singleRow (D.column (D.nonNullable D.bool)))

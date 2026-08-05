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

import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
  ( MigrationOutcome (AppliedNow),
    MigrationReport (..),
    MigrationResult (..),
    defaultRunOptions,
    runMigrationPlan,
  )
import Hasql.Connection.Settings qualified as Settings
import Shikigami.Migrations (shikigamiMigrationPlan)
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

main :: IO ()
main =
  defaultMain
    ( testGroup
        "shikigami-migrations smoke"
        [ testCase "a fresh database applies the plan, and re-applying is a no-op" do
            plan <- either (fail . show) pure shikigamiMigrationPlan
            withShikigamiMigratedDatabase \connectionString -> do
              -- withShikigamiMigratedDatabase already applied the plan and
              -- reconciled the read-model registry; this is the second pass.
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
          testCase "the applied plan spans all four components" do
            plan <- either (fail . show) pure shikigamiMigrationPlan
            withShikigamiMigratedDatabase \connectionString -> do
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
                ["kiroku", "keiro", "kioku", "shikigami"]
        ]
    )

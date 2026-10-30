module Main (main) where

import Data.ByteString.Char8 qualified as ByteString
import Data.List (isInfixOf, isPrefixOf)
import Data.List.NonEmpty qualified as NonEmpty
import Shikigami.Migrations
  ( embeddedMigrationEntries,
    shikigamiMigrationPlan,
    shikigamiMigrations,
  )
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

main :: IO ()
main = defaultMain (testGroup "shikigami-migrations" [compositionTests])

-- | The migration plan composes correctly.
--
-- What this package owns is /composition/: shikigami's own component ordered
-- behind the components kiroku, keiro, and kioku publish. Applying the plan is
-- exercised on every run of every other package's database tests, through the
-- @test-support@ sublibrary. What those runs cannot catch early is a
-- composition mistake, so these cases fail on it immediately, without a
-- database.
--
-- @kiokuMigrations@ is a single @pg-migrate@ component rather than a
-- pre-concatenated list, and ordering comes from declared component
-- dependencies rather than from filename timestamps. The
-- hazard is therefore no longer "duplicate timestamps" but "a component missing
-- from the plan" or "shikigami ordered before the schema it builds on".
--
-- @pg-migrate@ keeps 'Database.PostgreSQL.Migrate.MigrationPlan' abstract and
-- exposes its resolved order only through 'Show', so that rendering is what
-- these cases read. They deliberately do not import
-- @Database.PostgreSQL.Migrate.Internal@.
compositionTests :: TestTree
compositionTests =
  testGroup
    "migration plan"
    [ testCase "shikigami's own component is well-formed" do
        case shikigamiMigrations of
          Left err -> assertFailure ("the shikigami component failed to define: " <> show err)
          Right _ -> pure (),
      testCase "shikigami embeds its own SQL" do
        assertBool
          "no SQL was embedded from sql-migrations/manifest"
          (not (null (foldr (:) [] embeddedMigrationEntries))),
      testCase "the lifecycle evidence migration is appended with both tables" do
        let filename = "0010-agent-load-state-and-run-skips.sql"
        case lookup filename (NonEmpty.toList embeddedMigrationEntries) of
          Nothing -> assertFailure (filename <> " is missing from the embedded manifest")
          Just sql -> do
            assertBool "agent_load_state DDL is missing" ("shikigami.agent_load_state" `ByteString.isInfixOf` sql)
            assertBool "run_skips DDL is missing" ("shikigami.run_skips" `ByteString.isInfixOf` sql),
      testCase "the practice-review attention migration is appended without delivery state" do
        let filename = "0012-practice-review-attention.sql"
        case lookup filename (NonEmpty.toList embeddedMigrationEntries) of
          Nothing -> assertFailure (filename <> " is missing from the embedded manifest")
          Just sql -> do
            assertBool "attention reservation DDL is missing" ("shikigami.practice_review_attention" `ByteString.isInfixOf` sql)
            assertBool "attention review association DDL is missing" ("shikigami.practice_review_attention_reviews" `ByteString.isInfixOf` sql)
            assertBool "attention reservation must not duplicate delivery status" (not ("delivery_status" `ByteString.isInfixOf` sql)),
      testCase "the plan orders all four components by dependency" do
        plan <- either (fail . show) pure shikigamiMigrationPlan
        let rendered = show plan
        assertBool
          ("the plan does not name all four components: " <> rendered)
          (all (\c -> quoted c `isInfixOf` rendered) components)
        assertBool
          ("the components are not in dependency order: " <> rendered)
          (ascending (indexOf rendered . quoted <$> components))
    ]
  where
    components = ["kiroku", "keiro", "kioku", "shikigami"]

    quoted c = "\"" <> c <> "\""

    -- The offset of the needle's first occurrence.
    indexOf haystack needle =
      length (takeWhile (not . (needle `isPrefixOf`)) (suffixes haystack))

    suffixes xs =
      xs : case xs of
        [] -> []
        _ : rest -> suffixes rest

    ascending xs = and (zipWith (<) xs (drop 1 xs))

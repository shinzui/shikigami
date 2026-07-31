module Main (main) where

import Codd.Parsing (AddedSqlMigration (..), SqlMigration (..))
import Data.List (sort)
import Shikigami.Migrations (shikigamiMigrations, shikigamiOwnMigrations)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

main :: IO ()
main = defaultMain (testGroup "shikigami-migrations" [compositionTests])

-- | The migration set composes correctly.
--
-- What this package owns is /composition/: shikigami's own SQL files appended to
-- the set kioku already publishes. Applying them is exercised on every run of
-- every other package's database tests, through the @test-support@ sublibrary.
-- What those runs cannot catch early is a composition mistake, because codd
-- rejects it at apply time with an error about timestamps rather than about the
-- mistake.
--
-- Note what is deliberately /not/ asserted: that the list is in timestamp order.
-- It is not, and need not be — kioku concatenates several published sets, and
-- codd orders them itself when applying. Asserting an order the system never
-- promised would be a test of this test.
--
-- The specific hazard is documented in "Shikigami.Migrations": @kiokuMigrations@
-- already composes kiroku, keiro, and kioku's own migrations, so prepending
-- kiroku or keiro again produces duplicate timestamps. These cases fail on that
-- immediately, without a database.
compositionTests :: TestTree
compositionTests =
  testGroup
    "migration set"
    [ testCase "the set is non-empty and includes shikigami's own migrations" do
        full <- shikigamiMigrations :: IO [AddedSqlMigration IO]
        own <- shikigamiOwnMigrations :: IO [AddedSqlMigration IO]
        assertBool "the composed set is empty" (not (null full))
        assertBool "shikigami contributes no migrations of its own" (not (null own))
        assertBool
          "the composed set does not contain shikigami's own migrations"
          (all (`elem` fmap nameOf full) (fmap nameOf own)),
      testCase "shikigami's own migrations come last" do
        full <- shikigamiMigrations :: IO [AddedSqlMigration IO]
        own <- shikigamiOwnMigrations :: IO [AddedSqlMigration IO]
        let names = fmap nameOf full
            ownNames = fmap nameOf own
        drop (length names - length ownNames) names @?= ownNames,
      testCase "no migration name appears twice" do
        full <- shikigamiMigrations :: IO [AddedSqlMigration IO]
        let names = sort (fmap nameOf full)
        names @?= dedupe names,
      testCase "no migration timestamp appears twice" do
        full <- shikigamiMigrations :: IO [AddedSqlMigration IO]
        let timestamps = sort (fmap (show . addedSqlTimestamp) full)
        assertBool
          ( "duplicate migration timestamps would be rejected by codd: "
              <> show (duplicates timestamps)
          )
          (null (duplicates timestamps))
    ]
  where
    nameOf = migrationName . addedSqlMig

    dedupe = foldr (\x acc -> if [x] == take 1 acc then acc else x : acc) []

    duplicates xs = [x | (x, y) <- zip xs (drop 1 xs), x == y]

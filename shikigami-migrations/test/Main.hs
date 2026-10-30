module Main (main) where

import Control.Monad (forM_)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString.Char8 qualified as ByteString
import Data.Char (toUpper)
import Data.List (isInfixOf, isPrefixOf)
import Data.List.NonEmpty qualified as NonEmpty
import Database.PostgreSQL.Migrate.Embed (checkMigrationManifest)
import Shikigami.Migrations
  ( embeddedMigrationEntries,
    shikigamiMigrationPlan,
    shikigamiMigrations,
  )
import System.Directory (copyFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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
    [ testCase "runtime source membership, embedded bytes and checksum lock agree" do
        entries <- checkMigrationManifest "sql-migrations/manifest" >>= either (fail . show) pure
        entries @?= embeddedMigrationEntries
        validateIntegrity "sql-migrations" >>= (@?= Right ()),
      testCase "application migration bodies are qualified and do not change search_path" do
        entries <- checkMigrationManifest "sql-migrations/manifest" >>= either (fail . show) pure
        forM_ entries \(name, bytes) ->
          assertBool (name <> ": unqualified object or search_path mutation") (null (bodyViolations (ByteString.unpack bytes))),
      testCase "body lint rejects unqualified DDL and session path changes" do
        assertBool "unqualified target" (not (null (bodyViolations "CREATE TABLE widgets (id int);")))
        assertBool "path mutation" (not (null (bodyViolations "SET search_path TO public;")))
        bodyViolations "CREATE TABLE shikigami.widgets (id int);" @?= [],
      testCase "runtime integrity refuses changed payloads and unlisted SQL" do
        withSystemTempDirectory "shikigami-migrations-integrity" \directory -> do
          let names = "manifest" : "migrations.lock" : map fst (NonEmpty.toList embeddedMigrationEntries)
          forM_ names \name -> copyFile ("sql-migrations" </> name) (directory </> name)
          validateIntegrity directory >>= (@?= Right ())
          let firstName = fst (NonEmpty.head embeddedMigrationEntries)
          ByteString.appendFile (directory </> firstName) "\n-- tampered payload\n"
          result <- validateIntegrity directory
          assertBool "tampered SQL must fail its checksum" (either (const True) (const False) result)
          copyFile ("sql-migrations" </> firstName) (directory </> firstName)
          ByteString.writeFile (directory </> "9999-unlisted.sql") "SELECT 1;\n"
          unlisted <- validateIntegrity directory
          assertBool "unlisted SQL must fail directory membership" (either (const True) (const False) unlisted),
      testCase "shikigami's own component is well-formed" do
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
      testCase "the plan orders all five components by dependency" do
        plan <- either (fail . show) pure shikigamiMigrationPlan
        let rendered = show plan
        assertBool
          ("the plan does not name all five components: " <> rendered)
          (all (\c -> quoted c `isInfixOf` rendered) components)
        assertBool
          ("the components are not in dependency order: " <> rendered)
          (ascending (indexOf rendered . quoted <$> components))
    ]
  where
    components = ["kiroku", "keiro", "kioku", "pgmq", "shikigami"]

    quoted c = "\"" <> c <> "\""

    -- The offset of the needle's first occurrence.
    indexOf haystack needle =
      length (takeWhile (not . (needle `isPrefixOf`)) (suffixes haystack))

    suffixes xs =
      xs : case xs of
        [] -> []
        _ : rest -> suffixes rest

    ascending xs = and (zipWith (<) xs (drop 1 xs))

-- Read source files at test runtime, independently of Cabal's rebuild decision.
validateIntegrity :: FilePath -> IO (Either String ())
validateIntegrity directory = do
  entries <- checkMigrationManifest (directory </> "manifest")
  case entries of
    Left err -> pure (Left (show err))
    Right checked -> do
      locked <- ByteString.readFile (directory </> "migrations.lock")
      let expected = ByteString.pack (concatMap lockLine (NonEmpty.toList checked))
      pure (if locked == expected then Right () else Left "migration checksum lock differs from source payloads")
  where
    lockLine (name, bytes) = show (hash bytes :: Digest SHA256) <> "  " <> name <> "\n"

-- Match object-bearing statement heads and REFERENCES in application DDL.
-- Comments are removed first; this is a conservative source gate, not a SQL parser.
bodyViolations :: String -> [String]
bodyViolations sql =
  ["search_path" | "SEARCH_PATH" `isInfixOf` cleaned]
    <> filter (not . isInfixOf ".") (concatMap targets (statements cleaned))
  where
    cleaned = unlines (map (map toUpper . stripComment) (lines sql))
    stripComment [] = []
    stripComment ('-' : '-' : _) = []
    stripComment (char : rest) = char : stripComment rest
    statements text = case break (== ';') text of
      (statement, []) -> [words statement]
      (statement, _ : rest) -> words statement : statements rest
    targets tokens = headTarget tokens <> referenced tokens
    headTarget ("CREATE" : "UNIQUE" : rest) = headTarget ("CREATE" : rest)
    headTarget ("CREATE" : "INDEX" : rest) = afterOn rest
    headTarget ("CREATE" : kind : rest)
      | kind `elem` ["TABLE", "VIEW", "SEQUENCE", "TYPE", "FUNCTION"] = objectName rest
    headTarget ("ALTER" : "TABLE" : rest) = objectName rest
    headTarget ("INSERT" : "INTO" : rest) = objectName rest
    headTarget ("DELETE" : "FROM" : rest) = objectName rest
    headTarget ("UPDATE" : rest) = objectName rest
    headTarget _ = []
    objectName ("IF" : "NOT" : "EXISTS" : rest) = objectName rest
    objectName ("IF" : "EXISTS" : rest) = objectName rest
    objectName (name : _) = [name]
    objectName [] = []
    afterOn ("ON" : rest) = objectName rest
    afterOn (_ : rest) = afterOn rest
    afterOn [] = []
    referenced ("REFERENCES" : name : rest) = name : referenced rest
    referenced (_ : rest) = referenced rest
    referenced [] = []

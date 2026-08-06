-- | The C11 grant gate against a real database.
--
-- Milestone 2 proved the gate compiles with a 'GrantSource' threaded through it;
-- these prove it actually decides correctly against @shikigami.sink_grants@, and
-- that the seed rows the migration inserts preserve the behavior the compiled-in
-- table used to give.
--
-- Every case runs on its own ephemeral, fully-migrated PostgreSQL database via
-- 'withShikigamiMigratedDatabase', so the seed rows are exactly what the
-- migration wrote and nothing leaks between cases.
module Shikigami.GrantStoreSpec (tests) where

import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Pool (Pool)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.Sink.GrantStore
  ( GrantCursor (..),
    GrantPage (..),
    GrantPageRequest (..),
    GrantRow (..),
    GrantSource (DbGrants),
    PageSize,
    checkGrant,
    defaultPageSize,
    listGrants,
    mkPageSize,
    revokeGrant,
    upsertGrant,
  )
import Shikigami.Sink.Permission (AgentIdentity (..), Denied (..), SinkKind (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "GrantStore"
    [ testGroup "seed data" seedTests,
      testGroup "runtime grant and revoke" runtimeTests,
      testGroup "paging" pagingTests
    ]

-- | Run a case against a fresh migrated database, handing it a pool.
withPool :: (Pool -> IO a) -> IO a
withPool use =
  withShikigamiMigratedDatabase \connStr ->
    withStore (defaultConnectionSettings connStr) (use . pool)

-- | The gate's verdict, with the denial reason kept for failure messages.
-- Named @verdict@ rather than @granted@ because 'GrantRow' already has a
-- @granted@ field, which @DuplicateRecordFields@ makes ambiguous.
verdict :: Pool -> Text -> SinkKind -> IO (Either Text ())
verdict pool agent kind =
  checkGrant (DbGrants pool) (AgentIdentity agent) kind >>= \case
    Right () -> pure (Right ())
    Left (Denied reason) -> pure (Left reason)

assertGranted :: String -> Pool -> Text -> SinkKind -> IO ()
assertGranted label pool agent kind =
  verdict pool agent kind >>= \case
    Right () -> pure ()
    Left reason -> assertFailure (label <> ": expected granted, got denial: " <> show reason)

assertDenied :: String -> Pool -> Text -> SinkKind -> IO Text
assertDenied label pool agent kind =
  verdict pool agent kind >>= \case
    Right () -> assertFailure (label <> ": expected a denial, but the sink was granted")
    Left reason -> pure reason

seedTests :: [TestTree]
seedTests =
  [ -- The migration's seed rows must reproduce defaultGrantTable exactly, or
    -- applying it silently changes who may deliver what.
    testCase "a seeded agent is granted the kind it was seeded with" do
      withPool \pool -> do
        assertGranted "heartbeat/KawaDigest" pool "heartbeat" SKawaDigest
        assertGranted "heartbeat/DanwaConversation" pool "heartbeat" SDanwaConversation
        assertGranted "triage-note/ReiAction" pool "triage-note" SReiAction,
    testCase "an unknown agent is denied, and the reason says no grant exists" do
      withPool \pool -> do
        reason <- assertDenied "intruder" pool "intruder" SKawaDigest
        assertBool
          ("reason should name the missing grant: " <> show reason)
          ("has no grant for KawaDigest" `isInfixOfT` reason),
    testCase "a seeded agent is denied a kind it was not seeded with" do
      -- danwa-heartbeat has DanwaConversation only. This is the case that would
      -- pass by accident if the gate keyed on the agent rather than the pair.
      withPool \pool -> do
        assertGranted "danwa-heartbeat/DanwaConversation" pool "danwa-heartbeat" SDanwaConversation
        _ <- assertDenied "danwa-heartbeat/KizashiSignal" pool "danwa-heartbeat" SKizashiSignal
        pure (),
    testCase "the proof agents ship denied" do
      -- The behavior-preserving seed deliberately omits them; granting one at
      -- runtime is the demonstration that runtime grants work.
      withPool \pool -> do
        _ <- assertDenied "digest-watcher" pool "digest-watcher" SKawaDigest
        _ <- assertDenied "web-researcher" pool "web-researcher" SKizashiSignal
        pure ()
  ]

runtimeTests :: [TestTree]
runtimeTests =
  [ testCase "granting at runtime flips a denial to a grant" do
      withPool \pool -> do
        _ <- assertDenied "before" pool "digest-watcher" SKawaDigest
        upsertGrant pool "digest-watcher" SKawaDigest (Just "test") >>= expectRight "upsertGrant"
        assertGranted "after" pool "digest-watcher" SKawaDigest,
    testCase "revoking flips it back, and the reason distinguishes revoked from absent" do
      withPool \pool -> do
        upsertGrant pool "digest-watcher" SKawaDigest (Just "test") >>= expectRight "upsertGrant"
        assertGranted "granted" pool "digest-watcher" SKawaDigest
        revoked <- revokeGrant pool "digest-watcher" SKawaDigest (Just "test") >>= expectRight "revokeGrant"
        assertEqual "a row was revoked" True revoked
        reason <- assertDenied "revoked" pool "digest-watcher" SKawaDigest
        -- Not "has no grant for": an operator must be able to tell a deliberate
        -- revocation from a grant nobody ever made.
        assertBool
          ("reason should say revoked, got: " <> show reason)
          ("is revoked" `isInfixOfT` reason),
    testCase "a revoked row survives with its audit trail" do
      withPool \pool -> do
        upsertGrant pool "digest-watcher" SKawaDigest (Just "granter") >>= expectRight "upsertGrant"
        _ <- revokeGrant pool "digest-watcher" SKawaDigest (Just "revoker") >>= expectRight "revokeGrant"
        row <- findRow pool "digest-watcher"
        assertEqual "granted flag" False (granted' row)
        assertEqual "revoked_by" (Just "revoker") (revokedBy row)
        assertBool "revoked_at is set" (revokedAt row /= Nothing),
    testCase "re-granting clears the revocation rather than leaving it set" do
      -- A row claiming to be both granted and revoked would make the audit
      -- trail lie about the current state.
      withPool \pool -> do
        upsertGrant pool "digest-watcher" SKawaDigest (Just "granter") >>= expectRight "upsertGrant"
        _ <- revokeGrant pool "digest-watcher" SKawaDigest (Just "revoker") >>= expectRight "revokeGrant"
        upsertGrant pool "digest-watcher" SKawaDigest (Just "granter2") >>= expectRight "re-grant"
        assertGranted "re-granted" pool "digest-watcher" SKawaDigest
        row <- findRow pool "digest-watcher"
        assertEqual "granted flag" True (granted' row)
        assertEqual "revoked_by cleared" Nothing (revokedBy row)
        assertEqual "revoked_at cleared" Nothing (revokedAt row),
    testCase "revoking something never granted reports that it changed nothing" do
      withPool \pool -> do
        changed <- revokeGrant pool "nobody" SKawaDigest (Just "test") >>= expectRight "revokeGrant"
        assertEqual "no row affected" False changed
  ]

pagingTests :: [TestTree]
pagingTests =
  [ testCase "the default page returns the nine seed rows and no cursor" do
      withPool \pool -> do
        page <-
          listGrants pool GrantPageRequest {size = defaultPageSize, after = Nothing}
            >>= expectRight "listGrants"
        assertEqual "seed row count" 9 (length (items page))
        assertEqual "no next page" Nothing (fmap cursorKey (next page)),
    testCase "paging traverses every row exactly once, with no gaps or duplicates" do
      -- Seeded past one page on purpose: the bug this catches is an off-by-one
      -- in the keyset predicate, which a single-page table cannot expose.
      withPool \pool -> do
        mapM_
          (\i -> upsertGrant pool ("agent-" <> pad i) SKizashiSignal (Just "test") >>= expectRight "seed")
          [1 .. 11 :: Int]
        size <- either (assertFailure . show) pure (mkPageSize 4)
        collected <- drain pool size Nothing []
        let expectedCount = 9 + 11
        assertEqual "every row seen once" expectedCount (length collected)
        assertEqual "no duplicates" (length collected) (length (nub (sort collected)))
  ]
  where
    pad i = Text.justifyRight 2 '0' (Text.pack (show i))

-- | Walk every page, accumulating keys, until the cursor runs out.
drain :: Pool -> PageSize -> Maybe GrantCursor -> [(Text, Text)] -> IO [(Text, Text)]
drain pool size after acc = do
  page <- listGrants pool GrantPageRequest {size, after} >>= expectRight "listGrants"
  let acc' = acc <> fmap rowKey (items page)
  case next page of
    Nothing -> pure acc'
    Just cursor -> drain pool size (Just cursor) acc'

rowKey :: GrantRow -> (Text, Text)
rowKey GrantRow {agentName, sinkKind} = (agentName, sinkKind)

cursorKey :: GrantCursor -> (Text, Text)
cursorKey GrantCursor {agentName, sinkKind} = (agentName, sinkKind)

-- | The one row for an agent, failing the test if the table does not have
-- exactly one.
findRow :: Pool -> Text -> IO GrantRow
findRow pool agent = do
  page <-
    listGrants pool GrantPageRequest {size = defaultPageSize, after = Nothing}
      >>= expectRight "listGrants"
  case filter (\GrantRow {agentName} -> agentName == agent) (items page) of
    [row] -> pure row
    other -> assertFailure ("expected exactly one row for " <> show agent <> ", got " <> show (length other))

granted' :: GrantRow -> Bool
granted' GrantRow {granted = g} = g

expectRight :: (Show e) => String -> Either e a -> IO a
expectRight label = either (\e -> assertFailure (label <> " failed: " <> show e)) pure

isInfixOfT :: Text -> Text -> Bool
isInfixOfT = Text.isInfixOf

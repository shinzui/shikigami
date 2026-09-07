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
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Pool (Pool)
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Principal (AgentIdentity (VerifiedIdentity), AgentPrincipal, compatibilityIdentity, mkAgentPrincipal)
import Shikigami.Memory.AliasStore
  ( AliasReconciliation (..),
    aliasesForPrincipal,
    reconcileAlias,
  )
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Sink.GrantStore
  ( GrantCursor (..),
    GrantPage (..),
    GrantPageRequest (..),
    GrantPrincipalSync (..),
    GrantPrincipalSyncStatus (..),
    GrantRow (..),
    GrantSource (DbGrants),
    PageSize,
    checkGrant,
    defaultPageSize,
    listGrants,
    mkPageSize,
    reconcileGrantPrincipal,
    revokeGrant,
    upsertGrant,
  )
import Shikigami.Sink.Permission (Denied (..), SinkKind (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: DatabaseFixture -> TestTree
tests databaseFixture =
  testGroup
    "GrantStore"
    [ testGroup "seed data" (seedTests databaseFixture),
      testGroup "runtime grant and revoke" (runtimeTests databaseFixture),
      testGroup "principal reconciliation" (principalReconciliationTests databaseFixture),
      testGroup "principal-keyed grants" (principalGrantTests databaseFixture),
      testGroup "legacy aliases" (aliasTests databaseFixture),
      testGroup "paging" (pagingTests databaseFixture)
    ]

-- | Run a case against a fresh migrated database, handing it a pool.
withPool :: DatabaseFixture -> (Pool -> IO a) -> IO a
withPool databaseFixture use =
  (withShikigamiFreshDatabase databaseFixture) \connStr ->
    withStore (defaultConnectionSettings connStr) (use . pool)

-- | The gate's verdict, with the denial reason kept for failure messages.
-- Named @verdict@ rather than @granted@ because 'GrantRow' already has a
-- @granted@ field, which @DuplicateRecordFields@ makes ambiguous.
verdict :: Pool -> Text -> SinkKind -> IO (Either Text ())
verdict pool agent kind =
  checkGrant (DbGrants pool) (compatibilityIdentity agent) kind >>= \case
    Right () -> pure (Right ())
    Left (Denied reason) -> pure (Left reason)

compatGrant :: Pool -> Text -> SinkKind -> Maybe Text -> IO (Either Text ())
compatGrant pool agent = upsertGrant pool agent (compatibilityIdentity agent)

compatRevoke :: Pool -> Text -> SinkKind -> Maybe Text -> IO (Either Text Bool)
compatRevoke pool agent = revokeGrant pool (compatibilityIdentity agent)

agentPrincipal :: Text -> AgentPrincipal
agentPrincipal raw = either (error . Text.unpack) id (mkAgentPrincipal raw)

verifiedIdentity :: Text -> AgentIdentity
verifiedIdentity = VerifiedIdentity . agentPrincipal

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

seedTests :: DatabaseFixture -> [TestTree]
seedTests databaseFixture =
  [ -- The migration's seed rows must reproduce defaultGrantTable exactly, or
    -- applying it silently changes who may deliver what.
    testCase "a seeded agent is granted the kind it was seeded with" do
      (withPool databaseFixture) \pool -> do
        assertGranted "heartbeat/KawaDigest" pool "heartbeat" SKawaDigest
        assertGranted "heartbeat/DanwaConversation" pool "heartbeat" SDanwaConversation
        assertGranted "triage-note/ReiAction" pool "triage-note" SReiAction,
    testCase "an unknown agent is denied, and the reason says no grant exists" do
      (withPool databaseFixture) \pool -> do
        reason <- assertDenied "intruder" pool "intruder" SKawaDigest
        assertBool
          ("reason should name the missing grant: " <> show reason)
          ("has no grant for KawaDigest" `isInfixOfT` reason),
    testCase "a seeded agent is denied a kind it was not seeded with" do
      -- danwa-heartbeat has DanwaConversation only. This is the case that would
      -- pass by accident if the gate keyed on the agent rather than the pair.
      (withPool databaseFixture) \pool -> do
        assertGranted "danwa-heartbeat/DanwaConversation" pool "danwa-heartbeat" SDanwaConversation
        _ <- assertDenied "danwa-heartbeat/KizashiSignal" pool "danwa-heartbeat" SKizashiSignal
        pure (),
    testCase "the proof agents ship denied" do
      -- The behavior-preserving seed deliberately omits them; granting one at
      -- runtime is the demonstration that runtime grants work.
      (withPool databaseFixture) \pool -> do
        _ <- assertDenied "digest-watcher" pool "digest-watcher" SKawaDigest
        _ <- assertDenied "web-researcher" pool "web-researcher" SKizashiSignal
        pure ()
  ]

runtimeTests :: DatabaseFixture -> [TestTree]
runtimeTests databaseFixture =
  [ testCase "granting at runtime flips a denial to a grant" do
      (withPool databaseFixture) \pool -> do
        _ <- assertDenied "before" pool "digest-watcher" SKawaDigest
        compatGrant pool "digest-watcher" SKawaDigest (Just "test") >>= expectRight "upsertGrant"
        assertGranted "after" pool "digest-watcher" SKawaDigest,
    testCase "revoking flips it back, and the reason distinguishes revoked from absent" do
      (withPool databaseFixture) \pool -> do
        compatGrant pool "digest-watcher" SKawaDigest (Just "test") >>= expectRight "upsertGrant"
        assertGranted "granted" pool "digest-watcher" SKawaDigest
        revoked <- compatRevoke pool "digest-watcher" SKawaDigest (Just "test") >>= expectRight "revokeGrant"
        assertEqual "a row was revoked" True revoked
        reason <- assertDenied "revoked" pool "digest-watcher" SKawaDigest
        -- Not "has no grant for": an operator must be able to tell a deliberate
        -- revocation from a grant nobody ever made.
        assertBool
          ("reason should say revoked, got: " <> show reason)
          ("is revoked" `isInfixOfT` reason),
    testCase "a revoked row survives with its audit trail" do
      (withPool databaseFixture) \pool -> do
        compatGrant pool "digest-watcher" SKawaDigest (Just "granter") >>= expectRight "upsertGrant"
        _ <- compatRevoke pool "digest-watcher" SKawaDigest (Just "revoker") >>= expectRight "revokeGrant"
        row <- findRow pool "digest-watcher"
        assertEqual "granted flag" False (granted' row)
        assertEqual "revoked_by" (Just "revoker") ((.revokedBy) row)
        assertBool "revoked_at is set" ((.revokedAt) row /= Nothing),
    testCase "re-granting clears the revocation rather than leaving it set" do
      -- A row claiming to be both granted and revoked would make the audit
      -- trail lie about the current state.
      (withPool databaseFixture) \pool -> do
        compatGrant pool "digest-watcher" SKawaDigest (Just "granter") >>= expectRight "upsertGrant"
        _ <- compatRevoke pool "digest-watcher" SKawaDigest (Just "revoker") >>= expectRight "revokeGrant"
        compatGrant pool "digest-watcher" SKawaDigest (Just "granter2") >>= expectRight "re-grant"
        assertGranted "re-granted" pool "digest-watcher" SKawaDigest
        row <- findRow pool "digest-watcher"
        assertEqual "granted flag" True (granted' row)
        assertEqual "revoked_by cleared" Nothing ((.revokedBy) row)
        assertEqual "revoked_at cleared" Nothing ((.revokedAt) row),
    testCase "revoking something never granted reports that it changed nothing" do
      (withPool databaseFixture) \pool -> do
        changed <- compatRevoke pool "nobody" SKawaDigest (Just "test") >>= expectRight "revokeGrant"
        assertEqual "no row affected" False changed
  ]

principalReconciliationTests :: DatabaseFixture -> [TestTree]
principalReconciliationTests databaseFixture =
  [ testCase "fills null principal ids and verifies the same id idempotently" do
      (withPool databaseFixture) \pool -> do
        before <- findRows pool "heartbeat"
        assertBool "the seed unexpectedly carried a principal" (all ((== Nothing) . principalIdOf) before)
        first <-
          reconcileGrantPrincipal pool "heartbeat" "agent_heartbeat"
            >>= expectRight "first reconcileGrantPrincipal"
        assertEqual "first status" PrincipalSynced ((.status) first)
        assertEqual "filled every row" (fromIntegral (length before)) ((.filledCount) first)
        assertEqual "nothing was already verified" 0 ((.verifiedCount) first)
        after <- findRows pool "heartbeat"
        assertBool "a principal stayed null" (all ((== Just "agent_heartbeat") . principalIdOf) after)
        second <-
          reconcileGrantPrincipal pool "heartbeat" "agent_heartbeat"
            >>= expectRight "second reconcileGrantPrincipal"
        assertEqual "second status" PrincipalSynced ((.status) second)
        assertEqual "idempotent fill count" 0 ((.filledCount) second)
        assertEqual "verified every row" (fromIntegral (length after)) ((.verifiedCount) second),
    testCase "a conflicting principal leaves null rows untouched" do
      (withPool databaseFixture) \pool -> do
        compatGrant pool "digest-watcher" SKawaDigest (Just "test") >>= expectRight "first grant"
        _ <-
          reconcileGrantPrincipal pool "digest-watcher" "agent_wrong"
            >>= expectRight "seed conflicting principal"
        compatGrant pool "digest-watcher" SKizashiSignal (Just "test") >>= expectRight "second grant"
        result <-
          reconcileGrantPrincipal pool "digest-watcher" "agent_digest_watcher"
            >>= expectRight "conflicting reconcileGrantPrincipal"
        assertEqual "no row filled" 0 ((.filledCount) result)
        assertEqual "conflict is explicit" (PrincipalConflict (Set.singleton "agent_wrong")) ((.status) result)
        rows <- findRows pool "digest-watcher"
        assertEqual
          "the null and conflicting values are unchanged"
          [Nothing, Just "agent_wrong"]
          (sort (map principalIdOf rows))
  ]

principalGrantTests :: DatabaseFixture -> [TestTree]
principalGrantTests databaseFixture =
  [ testCase "verified lookup never falls back to a same-named compatibility grant" do
      (withPool databaseFixture) \pool -> do
        assertGranted "compatibility seed" pool "heartbeat" SKawaDigest
        checkGrant (DbGrants pool) (verifiedIdentity "agent_heartbeat") SKawaDigest >>= \case
          Left (Denied reason) -> assertBool "denial names the missing principal grant" ("has no grant" `isInfixOfT` reason)
          Right () -> assertFailure "verified lookup fell back to the compatibility row",
    testCase "a presentation rename retains the principal-keyed grant" do
      (withPool databaseFixture) \pool -> do
        _ <- reconcileGrantPrincipal pool "heartbeat" "agent_heartbeat" >>= expectRight "reconcile heartbeat"
        assertVerifiedGranted "before rename" pool "agent_heartbeat" SKawaDigest
        upsertGrant pool "heartbeat-renamed" (verifiedIdentity "agent_heartbeat") SKawaDigest (Just "test")
          >>= expectRight "rename presentation"
        assertVerifiedGranted "after rename" pool "agent_heartbeat" SKawaDigest
        rows <- findRows pool "heartbeat-renamed"
        assertEqual "the updated presentation has one row" 1 (length rows)
  ]

aliasTests :: DatabaseFixture -> [TestTree]
aliasTests databaseFixture =
  [ testCase "alias reconciliation is idempotent and sorted" do
      (withPool databaseFixture) \pool -> do
        let principal = agentPrincipal "agent_heartbeat"
        first <- reconcileAlias pool principal "old-heartbeat" >>= expectRight "insert alias"
        case first of
          AliasInserted {} -> pure ()
          other -> assertFailure ("expected inserted alias, got " <> show other)
        second <- reconcileAlias pool principal "old-heartbeat" >>= expectRight "repeat alias"
        case second of
          AliasAlreadyPresent {} -> pure ()
          other -> assertFailure ("expected present alias, got " <> show other)
        _ <- reconcileAlias pool principal "a-heartbeat" >>= expectRight "insert sorted alias"
        aliasesForPrincipal pool principal
          >>= expectRight "list aliases"
          >>= assertEqual "aliases are stable" ["a-heartbeat", "old-heartbeat"],
    testCase "an alias already owned by another principal is never reassigned" do
      (withPool databaseFixture) \pool -> do
        let firstPrincipal = agentPrincipal "agent_first"
            secondPrincipal = agentPrincipal "agent_second"
        _ <- reconcileAlias pool firstPrincipal "legacy-name" >>= expectRight "seed alias"
        conflict <- reconcileAlias pool secondPrincipal "legacy-name" >>= expectRight "conflicting alias"
        case conflict of
          AliasConflict {expectedPrincipalId, existingPrincipalId} -> do
            assertEqual "expected principal" "agent_second" expectedPrincipalId
            assertEqual "existing principal" "agent_first" existingPrincipalId
          other -> assertFailure ("expected alias conflict, got " <> show other)
        aliasesForPrincipal pool firstPrincipal
          >>= expectRight "original owner"
          >>= assertEqual "the original owner remains" ["legacy-name"]
        aliasesForPrincipal pool secondPrincipal
          >>= expectRight "rejected owner"
          >>= assertEqual "the rejected owner gets nothing" []
  ]

assertVerifiedGranted :: String -> Pool -> Text -> SinkKind -> IO ()
assertVerifiedGranted label pool principal kind =
  checkGrant (DbGrants pool) (verifiedIdentity principal) kind >>= \case
    Right () -> pure ()
    Left (Denied reason) -> assertFailure (label <> ": expected verified grant, got " <> Text.unpack reason)

pagingTests :: DatabaseFixture -> [TestTree]
pagingTests databaseFixture =
  [ testCase "the default page returns the nine seed rows and no cursor" do
      (withPool databaseFixture) \pool -> do
        page <-
          listGrants pool GrantPageRequest {size = defaultPageSize, after = Nothing}
            >>= expectRight "listGrants"
        assertEqual "seed row count" 9 (length ((.items) page))
        assertEqual "no next page" Nothing (fmap cursorKey ((.next) page)),
    testCase "paging traverses every row exactly once, with no gaps or duplicates" do
      -- Seeded past one page on purpose: the bug this catches is an off-by-one
      -- in the keyset predicate, which a single-page table cannot expose.
      (withPool databaseFixture) \pool -> do
        mapM_
          (\i -> compatGrant pool ("agent-" <> pad i) SKizashiSignal (Just "test") >>= expectRight "seed")
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
  let acc' = acc <> fmap rowKey ((.items) page)
  case (.next) page of
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
  case filter (\GrantRow {agentName} -> agentName == agent) ((.items) page) of
    [row] -> pure row
    other -> assertFailure ("expected exactly one row for " <> show agent <> ", got " <> show (length other))

findRows :: Pool -> Text -> IO [GrantRow]
findRows pool agent = do
  page <-
    listGrants pool GrantPageRequest {size = defaultPageSize, after = Nothing}
      >>= expectRight "listGrants"
  pure (filter (\GrantRow {agentName} -> agentName == agent) ((.items) page))

principalIdOf :: GrantRow -> Maybe Text
principalIdOf GrantRow {principalId} = principalId

granted' :: GrantRow -> Bool
granted' GrantRow {granted = g} = g

expectRight :: (Show e) => String -> Either e a -> IO a
expectRight label = either (\e -> assertFailure (label <> " failed: " <> show e)) pure

isInfixOfT :: Text -> Text -> Bool
isInfixOfT = Text.isInfixOf

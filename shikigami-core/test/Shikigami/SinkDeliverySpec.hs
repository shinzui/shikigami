module Shikigami.SinkDeliverySpec (tests) where

import Data.Aeson (Result (..), eitherDecode, encode, fromJSON, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToNominalDiffTime)
import Effectful (runEff)
import Hasql.Pool (Pool)
import Keiro.Integration.Event qualified as Integration
import Keiro.Outbox qualified as Outbox
import Keiro.Workflow (WorkflowId (..), WorkflowOutcome (..), loadStepIndex)
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Session (SessionRow (..))
import Kioku.Session qualified as Session
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Network.HTTP.Types (hContentType, status200, status204, status400, status404, status500)
import Network.Wai (Application, pathInfo, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Shikigami.Agent.Approval (defaultApprovalEnv)
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    Behavior (..),
    Priority (Normal),
    RecipientFrom (SubjectOwner),
    SignalType (Reminder),
    Sink (..),
    Trigger (..),
    defaultDelegationBudget,
    defaultMemoryPolicy,
  )
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), TriggerKind (TriggeredByEvent))
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.Attestation.Resolve (ProfileResolutionError (UnknownProfile))
import Shikigami.Behavior.Run (newBehaviorEnv)
import Shikigami.Directory (DirectoryHandle, Lifecycle (..), PrincipalRecord (..), disabledDirectoryHandle, newDirectoryHandle, refreshDirectory, staticDirectorySource)
import Shikigami.Log qualified as Log
import Shikigami.Memory.Access (shikigamiMemorySpace)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.Sink (GrantSource (DbGrants), SinkOutcome (Enqueued, SkippedLifecycle), SinkResult (..))
import Shikigami.Sink.Config (DanwaConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Sink.Delivery qualified as Delivery
import Shikigami.Sink.Wire qualified as Wire
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "SinkDelivery"
    [ testCase "workflow journals Enqueued (not Delivered) at enqueue time" journalTruth,
      testCase "paused enqueue journals a lifecycle skip without outbox or receipt" pausedEnqueue,
      testCase "pause before publish records a terminal non-send without HTTP" pauseBeforePublish,
      testCase "permanent failure becomes a bounded terminal rejection" permanentRejection,
      testCase "publish records a delivered receipt with the downstream id" receiptRecording,
      testCase "re-publish of a delivered message does not re-POST kizashi" sendGuard,
      testCase "terminal reconciliation materializes an unknown receipt" terminalReconciliation,
      testCase "danwa post-failure retry reuses the started conversation" danwaReuse,
      testCase "failing sink 0 does not block sink 1 in one publish pass" orderingIsolation
    ]

permanentRejection :: IO ()
permanentRejection = do
  case AgentWorkflow.permanentPublishOutcome "downstream refused this resource" of
    Right (Outbox.PublishRejected _) -> pure ()
    other -> assertFailure ("expected a terminal Keiro rejection, got " <> show other)
  case AgentWorkflow.permanentPublishOutcome (Text.replicate 1025 "x") of
    Left err -> assertBool ("invalid rejection should explain itself: " <> Text.unpack err) ("invalid terminal sink rejection" `Text.isPrefixOf` err)
    Right other -> assertFailure ("an oversized rejection detail must be refused, got " <> show other)

pausedEnqueue :: IO ()
pausedEnqueue =
  withFixture "paused-enqueue" [signalSink "paused"] unreachableKizashi unreachableDanwa \deps appEnv pool runJob -> do
    directory <- directoryWith Paused
    rows <- runWorkflowAndRows (deps {AgentWorkflow.directory = directory}) appEnv runJob
    assertEqual "lifecycle refusal creates no outbox row" [] rows
    receipt <- Delivery.lookupDelivery pool (Delivery.deliveryReceiptKey (idempotencyKey runJob <> ":sink:0"))
    assertEqual "lifecycle refusal creates no pending receipt" (Right Nothing) receipt
    index <- expectRight "loadStepIndex" =<< runAppIO appEnv (loadStepIndex AgentWorkflow.agentRunWorkflowName (WorkflowId (idempotencyKey runJob)) 0)
    encoded <- maybe (assertFailure "dispatch-sinks was not journaled") pure (Map.lookup "dispatch-sinks" index)
    case fromJSON encoded :: Result [SinkResult] of
      Success [SinkResult {outcome = SkippedLifecycle reason}] ->
        assertBool "journal names paused lifecycle" ("paused" `Text.isInfixOf` reason)
      other -> assertFailure ("expected one SkippedLifecycle result, got " <> show other)

pauseBeforePublish :: IO ()
pauseBeforePublish = do
  requests <- newIORef []
  lifecycleRef <- newIORef Active
  testWithApplication (pure (kizashiApp requests)) \port ->
    withFixture "pause-before-publish" [signalSink "paused-after-enqueue"] (kizashiAt port) unreachableDanwa \deps appEnv pool runJob -> do
      directory <- mutableDirectory lifecycleRef
      let gatedDeps = deps {AgentWorkflow.directory = directory}
      [row] <- runWorkflowAndRows gatedDeps appEnv runJob
      case Integration.decodeJsonIntegrationEvent (rowEvent row) of
        Right AgentWorkflow.SinkIntent {AgentWorkflow.principalId} ->
          assertEqual "outbox intent carries canonical principal" (Just "agent_heartbeat") principalId
        other -> assertFailure ("sink intent should decode, got " <> show other)

      sessions <- runAppIO appEnv (Session.getByScope shikigamiMemorySpace (agentScope "heartbeat"))
      case sessions of
        Right (Right [SessionRow {agentId}]) -> assertEqual "agent-run session uses principal id" "agent_heartbeat" agentId
        other -> assertFailure ("expected one attributed session, got " <> show other)

      writeIORef lifecycleRef Paused
      refreshDirectory directory >>= either (assertFailure . Text.unpack) pure
      summary <-
        expectRight "publishClaimedOutbox"
          =<< runAppIO
            appEnv
            ( Outbox.publishClaimedOutbox
                (traverse (\claimed -> (rowOutboxId claimed,) <$> AgentWorkflow.publishSinkIntent gatedDeps claimed))
                Outbox.defaultPublishOptions
                Nothing
            )
      assertEqual "lifecycle non-send publishes the outbox row" 1 (Outbox.published summary)
      assertEqual "paused publish performs no HTTP request" [] =<< readIORef requests
      receipt <- lookupReceipt pool row
      assertEqual "paused publish is terminal" Delivery.Dead (Delivery.status receipt)

journalTruth :: IO ()
journalTruth =
  withFixture "journal-truth" [signalSink "journal"] unreachableKizashi unreachableDanwa \deps appEnv _pool runJob -> do
    rows <- runWorkflowAndRows deps appEnv runJob
    assertEqual "one sink intent was enqueued" 1 (length rows)
    index <- expectRight "loadStepIndex" =<< runAppIO appEnv (loadStepIndex AgentWorkflow.agentRunWorkflowName (WorkflowId (idempotencyKey runJob)) 0)
    encoded <- maybe (assertFailure "dispatch-sinks was not journaled") pure (Map.lookup "dispatch-sinks" index)
    case fromJSON encoded :: Result [SinkResult] of
      Success [SinkResult {outcome = Enqueued detail}] ->
        assertBool ("enqueue detail should name the outbox row: " <> Text.unpack detail) ("outbox:" `Text.isPrefixOf` detail)
      other -> assertFailure ("expected one Enqueued result, got " <> show other)

receiptRecording :: IO ()
receiptRecording = do
  requests <- newIORef []
  testWithApplication (pure (kizashiApp requests)) \port ->
    withFixture "receipt" [signalSink "receipt"] (kizashiAt port) unreachableDanwa \deps appEnv pool runJob -> do
      [row] <- runWorkflowAndRows deps appEnv runJob
      before <- lookupReceipt pool row
      assertEqual "enqueue atomically records pending" Delivery.Pending (Delivery.status before)
      published <- runEff (AgentWorkflow.publishSinkIntent deps row)
      assertEqual "transport succeeds" Outbox.PublishSucceeded published
      receipt <- lookupReceipt pool row
      assertEqual "receipt is delivered" Delivery.Delivered (Delivery.status receipt)
      assertEqual "downstream signal id is retained" (Just "sig_stub") (Delivery.detail receipt)
      assertEqual "one downstream request" 1 . length =<< readIORef requests

sendGuard :: IO ()
sendGuard = do
  requests <- newIORef []
  testWithApplication (pure (kizashiApp requests)) \port ->
    withFixture "send-guard" [signalSink "guard"] (kizashiAt port) unreachableDanwa \deps appEnv _pool runJob -> do
      [row] <- runWorkflowAndRows deps appEnv runJob
      firstOutcome <- runEff (AgentWorkflow.publishSinkIntent deps row)
      secondOutcome <- runEff (AgentWorkflow.publishSinkIntent deps row)
      assertEqual "first publish succeeds" Outbox.PublishSucceeded firstOutcome
      assertEqual "guarded publish also succeeds" Outbox.PublishSucceeded secondOutcome
      assertEqual "the proved delivery is not sent twice" 1 . length =<< readIORef requests

terminalReconciliation :: IO ()
terminalReconciliation =
  withFixture "reconciliation" [signalSink "reconciliation"] unreachableKizashi unreachableDanwa \deps appEnv pool runJob -> do
    [row] <- runWorkflowAndRows deps appEnv runJob
    AgentWorkflow.reconcilePublishedSinkIntent deps row
    receipt <- lookupReceipt pool row
    assertEqual "unproved terminal publication is explicit" Delivery.Unknown (Delivery.status receipt)
    assertEqual
      "unknown explains why proof is missing"
      (Just "outbox published without a terminal delivery receipt")
      (Delivery.detail receipt)

danwaReuse :: IO ()
danwaReuse = do
  starts <- newIORef (0 :: Int)
  posts <- newIORef (0 :: Int)
  testWithApplication (pure (flakyDanwaApp starts posts)) \port ->
    withFixture "danwa-reuse" [DanwaConversation {topic = "support"}] unreachableKizashi (danwaAt port) \deps appEnv pool runJob -> do
      [row] <- runWorkflowAndRows deps appEnv runJob
      firstOutcome <- runEff (AgentWorkflow.publishSinkIntent deps row)
      firstError <- case firstOutcome of
        Outbox.PublishFailed err -> pure err
        other -> assertFailure ("first message post should be retryable, got " <> show other)
      startCount <- readIORef starts
      postCount <- readIORef posts
      assertEqual ("first attempt should start once; publish error: " <> Text.unpack firstError) 1 startCount
      assertEqual ("first attempt should reach the message post; publish error: " <> Text.unpack firstError) 1 postCount
      subReceipt <-
        expectRight "lookup conversation receipt"
          =<< Delivery.lookupDelivery pool (Delivery.subReceiptKey (Integration.messageId (rowEvent row)) "conv")
      case subReceipt of
        Just Delivery.DeliveryReceipt {Delivery.status = Delivery.ConversationStarted, Delivery.detail = Just "conv_stub"} -> pure ()
        other -> assertFailure ("expected the started conversation receipt after " <> Text.unpack firstError <> ", got " <> show other)
      secondOutcome <- runEff (AgentWorkflow.publishSinkIntent deps row)
      assertEqual "retry posts successfully" Outbox.PublishSucceeded secondOutcome
      assertEqual "retry reuses the first conversation" 1 =<< readIORef starts
      assertEqual "one failed and one successful post" 2 =<< readIORef posts

orderingIsolation :: IO ()
orderingIsolation = do
  requests <- newIORef []
  testWithApplication (pure (kizashiApp requests)) \port ->
    withFixture "ordering" [signalSink "fail", signalSink "succeed"] (kizashiAt port) unreachableDanwa \deps appEnv _pool runJob -> do
      rows <- runWorkflowAndRows deps appEnv runJob
      assertEqual "two independent rows" 2 (length rows)
      case Integration.key . rowEvent <$> rows of
        [Just key0, Just key1] -> do
          assertBool "sink 0 key carries ordinal 0" (":0" `Text.isSuffixOf` key0)
          assertBool "sink 1 key carries ordinal 1" (":1" `Text.isSuffixOf` key1)
          assertEqual "both keys use the same run id" (Text.dropEnd 2 key0) (Text.dropEnd 2 key1)
        other -> assertFailure ("expected two per-ordinal keys, got " <> show other)
      summary <-
        expectRight "publishClaimedOutbox"
          =<< runAppIO
            appEnv
            ( Outbox.publishClaimedOutbox
                (traverse (\row -> (rowOutboxId row,) <$> AgentWorkflow.publishSinkIntent deps row))
                Outbox.defaultPublishOptions
                Nothing
            )
      assertEqual "one independent sink publishes" 1 (Outbox.published summary)
      assertEqual "the failing sink remains retryable" 1 (Outbox.retried summary)

withFixture :: Text -> [Sink] -> KizashiConfig -> DanwaConfig -> (AgentWorkflow.AgentRunDeps -> AppEnv -> Pool -> RunJob -> IO a) -> IO a
withFixture label sinks kizashi danwa use =
  withShikigamiMigratedDatabase \connectionString ->
    withStore (defaultConnectionSettings connectionString) \kirokuStore -> do
      tracer <- noopTracer
      behaviorEnv <- newBehaviorEnv
      let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connectionString, tracer, metrics = Nothing}
          pool = Kiroku.Store.Connection.pool kirokuStore
          declaration = agentDeclaration sinks
          deps =
            AgentWorkflow.AgentRunDeps
              { AgentWorkflow.appEnv = appEnv,
                AgentWorkflow.behaviorEnv = behaviorEnv,
                AgentWorkflow.agents = [declaration],
                AgentWorkflow.kizashi = kizashi,
                AgentWorkflow.kawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = "shinzui/shikigami"},
                AgentWorkflow.danwa = danwa,
                AgentWorkflow.rei = ReiConfig {baseUrl = Nothing},
                AgentWorkflow.hooks = AgentWorkflow.defaultAgentRunHooks,
                AgentWorkflow.approval = defaultApprovalEnv,
                AgentWorkflow.deadline = Nothing,
                AgentWorkflow.runTimeout = secondsToNominalDiffTime 300,
                AgentWorkflow.delegationBudget = defaultDelegationBudget,
                AgentWorkflow.grants = DbGrants pool,
                AgentWorkflow.directory = disabledDirectoryHandle,
                AgentWorkflow.deliveryPool = Just pool,
                AgentWorkflow.logger = Log.silentLogger,
                AgentWorkflow.resolveRunProfile = \profileId version -> pure (Left (UnknownProfile profileId version))
              }
          runJob = testJob label
      use deps appEnv pool runJob

directoryWith :: Lifecycle -> IO DirectoryHandle
directoryWith lifecycle = do
  ref <- newIORef lifecycle
  mutableDirectory ref

mutableDirectory :: IORef Lifecycle -> IO DirectoryHandle
mutableDirectory lifecycleRef = do
  directory <-
    newDirectoryHandle do
      lifecycle <- readIORef lifecycleRef
      staticDirectorySource [PrincipalRecord {principalId = "agent_heartbeat", handle = "heartbeat", lifecycle}]
  refreshDirectory directory >>= either (assertFailure . Text.unpack) pure
  pure directory

runWorkflowAndRows :: AgentWorkflow.AgentRunDeps -> AppEnv -> RunJob -> IO [Outbox.OutboxRow]
runWorkflowAndRows deps appEnv runJob = do
  result <- AgentWorkflow.runAgentRunWorkflow deps runJob
  case result of
    Right (Completed (Right _)) -> pure ()
    other -> assertFailure ("agent workflow did not complete: " <> show other)
  expectRight "listOutbox" =<< runAppIO appEnv (Outbox.listOutbox "shinzui/shikigami")

lookupReceipt :: Pool -> Outbox.OutboxRow -> IO Delivery.DeliveryReceipt
lookupReceipt pool row = do
  found <-
    expectRight "lookupDelivery"
      =<< Delivery.lookupDelivery pool (Delivery.deliveryReceiptKey (Integration.messageId (rowEvent row)))
  maybe (assertFailure "delivery receipt was not recorded") pure found

agentDeclaration :: [Sink] -> AgentDecl
agentDeclaration sinks =
  AgentDecl
    { name = "heartbeat",
      description = "sink delivery test agent",
      trigger = Event {eventType = "test"},
      behavior =
        ShikumiProgram
          { task = "noop-summary",
            preferEnrichment = False,
            grounding = Nothing,
            enabledBy = Nothing
          },
      sinks,
      delegates = [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True
    }

testJob :: Text -> RunJob
testJob label =
  RunJob
    { agentName = "heartbeat",
      triggerKind = TriggeredByEvent,
      routeKind = AgentWorkflowRoute,
      occurredAt = UTCTime (fromGregorian 2026 8 21) 0,
      triggerPayload = object [],
      idempotencyKey = "heartbeat:sink-delivery:" <> label,
      parentSessionId = Nothing,
      parentRunWorkflowId = Nothing,
      delegationDepth = Nothing,
      lineage = [],
      delegationBudgetId = Nothing
    }

signalSink :: Text -> Sink
signalSink requestedIntent =
  KizashiSignal
    { source = "shinzui/shikigami",
      signalType = Reminder,
      priority = Normal,
      importance = 50,
      recipientFrom = SubjectOwner,
      defaultRecipient = Just "recipient",
      intentTemplate = requestedIntent,
      extraContextTags = []
    }

kizashiApp :: IORef [Wire.CreateSignalReq] -> Application
kizashiApp requests request respond =
  case (requestMethod request, pathInfo request) of
    ("POST", ["v1", "signals"]) -> do
      body <- strictRequestBody request
      case eitherDecode body of
        Left err -> respond (responseLBS status400 [] (LBS8.pack err))
        Right signal@Wire.CreateSignalReq {Wire.intent = requestedIntent} -> do
          modifyIORef' requests (signal :)
          if requestedIntent == "fail"
            then respond (responseLBS status500 [] "retry")
            else respond (responseLBS status200 [(hContentType, "application/json")] (encode (Wire.SignalResponse "sig_stub" "active")))
    _ -> respond (responseLBS status404 [] "not found")

flakyDanwaApp :: IORef Int -> IORef Int -> Application
flakyDanwaApp starts posts request respond =
  case (requestMethod request, pathInfo request) of
    ("POST", ["conversations"]) -> do
      modifyIORef' starts (+ 1)
      respond
        ( responseLBS
            status200
            [(hContentType, "application/json")]
            ( encode
                ( object
                    [ "conversationId" .= ("conv_stub" :: Text),
                      "status" .= ("active" :: Text),
                      "kind" .= ("thread" :: Text),
                      "startedBy" .= ("part_agent_test" :: Text),
                      "parentConversationId" .= ("" :: Text)
                    ]
                )
            )
        )
    ("POST", ["conversations", "conv_stub", "participants"]) ->
      respond (responseLBS status204 [] "")
    ("POST", ["conversations", "conv_stub", "messages"]) -> do
      modifyIORef' posts (+ 1)
      attempt <- readIORef posts
      if attempt == 1
        then respond (responseLBS status500 [] "retry")
        else
          respond
            ( responseLBS
                status200
                [(hContentType, "application/json")]
                ( encode
                    ( object
                        [ "messageId" .= ("msg_stub" :: Text),
                          "conversationId" .= ("conv_stub" :: Text),
                          "author" .= ("part_agent_test" :: Text),
                          "content" .= ("reply" :: Text),
                          "postedAt" .= ("2026-08-21T00:00:00Z" :: Text)
                        ]
                    )
                )
            )
    _ -> respond (responseLBS status404 [] "not found")

kizashiAt :: Int -> KizashiConfig
kizashiAt port = KizashiConfig {baseUrl = localBaseUrl port, defaultRecipient = "recipient"}

danwaAt :: Int -> DanwaConfig
danwaAt port = DanwaConfig {baseUrl = localBaseUrl port, agentParticipant = "part_agent_test"}

unreachableKizashi :: KizashiConfig
unreachableKizashi = KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "recipient"}

unreachableDanwa :: DanwaConfig
unreachableDanwa = DanwaConfig {baseUrl = "http://localhost:1", agentParticipant = "part_agent_test"}

localBaseUrl :: Int -> Text
localBaseUrl port = "http://localhost:" <> Text.pack (show port)

expectRight :: (Show error) => String -> Either error value -> IO value
expectRight label = either (assertFailure . ((label <> " failed: ") <>) . show) pure

rowEvent :: Outbox.OutboxRow -> Integration.IntegrationEvent
rowEvent Outbox.OutboxRow {Outbox.event = event} = event

rowOutboxId :: Outbox.OutboxRow -> Outbox.OutboxId
rowOutboxId Outbox.OutboxRow {Outbox.outboxId = outboxId} = outboxId

module Shikigami.SinkDeliverySpec (tests) where

import Control.Exception (bracket)
import Control.Monad (filterM, void)
import Data.Aeson (Result (..), eitherDecode, encode, fromJSON, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (UTCTime (..), fromGregorian, secondsToNominalDiffTime)
import Effectful (runEff)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Keiro.Integration.Event qualified as Integration
import Keiro.Outbox qualified as Outbox
import Keiro.Workflow (WorkflowId (..), WorkflowOutcome (..), loadStepIndex)
import Kikan.En.Action (AgentAction, actionResource, canonicalResourceText)
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Session (SessionRow (..))
import Kioku.Session qualified as Session
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Network.HTTP.Types (hAuthorization, hContentType, status200, status204, status400, status401, status403, status404, status500)
import Network.HTTP.Types.Header (Header)
import Network.Wai (Application, pathInfo, requestHeaders, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Propagator.W3CTraceContext (decodeSpanContext)
import OpenTelemetry.Trace.Core qualified as Otel
import Settei (answer, defaultResolveOptions, resolve)
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.Action.Authorization (ActionAuthorizationFailure (..), ActionAuthorizer (..), allowAllActionAuthorizerForTests)
import Shikigami.Activity qualified as Activity
import Shikigami.Agent.Approval (autoApprovePolicy, defaultApprovalEnv)
import Shikigami.Agent.Approval.Workflow qualified as ApprovalWorkflow
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
import Shikigami.Agent.Loader (AgentLoadEntry (AgentLoaded), AgentLoadReport (..))
import Shikigami.Agent.Principal (AgentIdentity (VerifiedIdentity), ResolvedAgentIdentity (VerifiedAgent), compatibilityIdentity, mkAgentPrincipal)
import Shikigami.Agent.RunJob (RunJob (..), RunRouteKind (AgentWorkflowRoute), TriggerKind (TriggeredByEvent))
import Shikigami.Agent.Workflow qualified as AgentWorkflow
import Shikigami.App.Config (AppConfig (..), appConfig, environmentBindings)
import Shikigami.Attestation.Resolve (ProfileResolutionError (UnknownProfile))
import Shikigami.Behavior.Run (newBehaviorEnv)
import Shikigami.Capability.Provider (emptyCapabilityRuntime)
import Shikigami.Directory (DirectoryHandle, Lifecycle (..), PrincipalRecord (..), disabledDirectoryHandle, newDirectoryHandle, refreshDirectory, staticDirectorySource)
import Shikigami.Fixture.SinkHttp (testHttpLimits, testSinkHttpFor)
import Shikigami.Flow.Routing qualified as Routing
import Shikigami.Log qualified as Log
import Shikigami.Memory.Access (shikigamiMemorySpace)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Migrations.TestSupport (withShikigamiMigratedDatabase)
import Shikigami.PracticeReview.Capability qualified as PracticeReviewCapability
import Shikigami.Sink (GrantSource (DbGrants), SinkKind (SChannelEgress), SinkOutcome (AuthorizationFailed, DeniedOutcome, Enqueued, SkippedLifecycle), SinkResult (..))
import Shikigami.Sink.Config (DanwaConfig (..), KanmonConfig (..), KawaConfig (..), KizashiConfig (..), ReiConfig (..))
import Shikigami.Sink.Delivery qualified as Delivery
import Shikigami.Sink.GrantStore qualified as GrantStore
import Shikigami.Sink.Http (credentialsFromConfig, newSinkHttp)
import Shikigami.Sink.Wire qualified as Wire
import Shikigami.Telemetry.TraceContext qualified as TraceContext
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "SinkDelivery"
    [ testCase "workflow journals Enqueued (not Delivered) at enqueue time" journalTruth,
      testCase "ChannelEgress enqueue snapshots minimal activity metadata" egressIntentMetadata,
      testCase "paused enqueue journals a lifecycle skip without outbox or receipt" pausedEnqueue,
      testCase "pause before publish records a terminal non-send without HTTP" pauseBeforePublish,
      testCase "permanent failure becomes a bounded terminal rejection" permanentRejection,
      testCase "outbox trace context parents sink.publish and its HTTP traceparent" tracePropagation,
      testCase "invalid traceparent is unparented and restores ambient context" invalidTraceContextIsolation,
      testCase "publish records a delivered receipt with the downstream id" receiptRecording,
      testCase "ChannelEgress publication records the Kanmon activity id and suppresses re-send" egressReceiptRecording,
      testCase "ChannelEgress 403 records a dead receipt and terminal publication" egressPermanentRejection,
      testCase "ungranted ChannelEgress creates no outbox, receipt, or HTTP effect" egressDenied,
      testCase "C13 denial at enqueue creates no outbox or downstream effect" actionDeniedAtEnqueue,
      testCase "C13 outage at enqueue is distinct and creates no outbox" actionUnavailableAtEnqueue,
      testCase "C13 is checked again at publish and revocation prevents HTTP" actionRevokedBeforePublish,
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

tracePropagation :: IO ()
tracePropagation =
  withTestTracer \tracer spansRef -> do
    requests <- newIORef []
    headers <- newIORef []
    testWithApplication (pure (captureHeaders headers (kizashiApp requests))) \port ->
      withFixtureUsingTracer tracer "trace-propagation" [signalSink "trace"] (kizashiAt port) unreachableDanwa \deps appEnv pool runJob -> do
        [row] <- runWorkflowAndRows deps appEnv runJob
        storedContext <-
          case Integration.traceContext (rowEvent row) of
            Nothing -> assertFailure "the sink outbox event has no trace context"
            Just context -> pure context
        persistedTraceparent <-
          expectRight "load persisted traceparent"
            =<< Pool.use pool (Session.statement (Integration.messageId (rowEvent row)) loadTraceparentStatement)
        assertEqual "keiro.keiro_outbox.traceparent is populated" (Just (Integration.traceparent storedContext)) persistedTraceparent
        assertBool "persisted traceparent uses W3C version 00" ("00-" `Text.isPrefixOf` Integration.traceparent storedContext)

        published <- runEff (AgentWorkflow.publishSinkIntent deps row)
        assertEqual "transport succeeds" Outbox.PublishSucceeded published
        observedHeaders <- readIORef headers
        outgoingTraceparent <-
          case observedHeaders >>= maybe [] pure . lookup "traceparent" of
            [] -> assertFailure "the sink HTTP request has no traceparent header"
            value : _ -> pure value

        void (Otel.forceFlushTracerProvider (Otel.getTracerTracerProvider tracer) Nothing)
        spans <- readIORef spansRef
        publishSpan <- findSpanNamed "sink.publish" spans
        storedParent <- decodeTraceContext "stored" storedContext
        outgoingContext <-
          maybe
            (assertFailure "the outbound traceparent is invalid")
            pure
            (decodeSpanContext (Just outgoingTraceparent) Nothing)
        actualParent <- maybe (assertFailure "sink.publish has no parent") pure (Otel.spanParent publishSpan)
        actualParentContext <- Otel.getSpanContext actualParent
        assertEqual "sink.publish keeps the producer trace id" (Otel.traceId storedParent) (Otel.traceId actualParentContext)
        assertEqual "sink.publish is parented by the stored producer span" (Otel.spanId storedParent) (Otel.spanId actualParentContext)
        assertEqual "HTTP propagation uses the sink.publish trace id" (Otel.traceId (Otel.spanContext publishSpan)) (Otel.traceId outgoingContext)
        assertEqual "HTTP propagation uses the sink.publish span id" (Otel.spanId (Otel.spanContext publishSpan)) (Otel.spanId outgoingContext)

invalidTraceContextIsolation :: IO ()
invalidTraceContextIsolation =
  withTestTracer \tracer spansRef -> do
    Otel.inSpan' tracer "ambient" Otel.defaultSpanArguments \_ -> do
      (continued, ()) <-
        TraceContext.withRemoteTraceContext
          Integration.TraceContext {Integration.traceparent = "not-a-traceparent", Integration.tracestate = Nothing}
          (Otel.inSpan tracer "invalid-remote" Otel.defaultSpanArguments (pure ()))
      assertBool "an invalid traceparent is reported" (not continued)
      Otel.inSpan tracer "restored" Otel.defaultSpanArguments (pure ())
    void (Otel.forceFlushTracerProvider (Otel.getTracerTracerProvider tracer) Nothing)
    spans <- readIORef spansRef
    ambient <- findSpanNamed "ambient" spans
    invalidRemote <- findSpanNamed "invalid-remote" spans
    restored <- findSpanNamed "restored" spans
    case Otel.spanParent invalidRemote of
      Nothing -> pure ()
      Just _ -> assertFailure "invalid remote context did not create an unparented span"
    restoredParent <- maybe (assertFailure "restored span has no ambient parent") Otel.getSpanContext (Otel.spanParent restored)
    assertEqual "the previous context is restored after dispatch" (Otel.spanId (Otel.spanContext ambient)) (Otel.spanId restoredParent)

findSpanNamed :: Text -> [Otel.ImmutableSpan] -> IO Otel.ImmutableSpan
findSpanNamed expected spans = do
  matching <- filterM (fmap ((== expected) . Otel.hotName) . readIORef . Otel.spanHot) spans
  case matching of
    [span'] -> pure span'
    other -> assertFailure ("expected one " <> Text.unpack expected <> " span, got " <> show (length other))

decodeTraceContext :: String -> Integration.TraceContext -> IO Otel.SpanContext
decodeTraceContext label Integration.TraceContext {Integration.traceparent, Integration.tracestate} =
  maybe
    (assertFailure (label <> " trace context is invalid"))
    pure
    (decodeSpanContext (Just (TextEncoding.encodeUtf8 traceparent)) (TextEncoding.encodeUtf8 <$> tracestate))

loadTraceparentStatement :: Statement Text (Maybe Text)
loadTraceparentStatement =
  preparable
    "SELECT traceparent FROM keiro.keiro_outbox WHERE message_id = $1"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.singleRow (Decoders.column (Decoders.nullable Decoders.text)))

captureHeaders :: IORef [[Header]] -> Application -> Application
captureHeaders headers app request respond = do
  modifyIORef' headers (requestHeaders request :)
  app request respond

pausedEnqueue :: IO ()
pausedEnqueue =
  withFixture "paused-enqueue" [signalSink "paused"] unreachableKizashi unreachableDanwa \deps appEnv pool runJob -> do
    directory <- directoryWith Paused
    rows <- runWorkflowAndRows (deps {AgentWorkflow.directory = directory}) appEnv (runJob {identity = verifiedHeartbeatAgentIdentity})
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
      _ <- expectRight "reconcile verified heartbeat grant" =<< GrantStore.reconcileGrantPrincipal pool "heartbeat" "agent_heartbeat"
      let gatedDeps = deps {AgentWorkflow.directory = directory}
      [row] <- runWorkflowAndRows gatedDeps appEnv (runJob {identity = verifiedHeartbeatAgentIdentity})
      case Integration.decodeJsonIntegrationEvent (rowEvent row) of
        Right AgentWorkflow.SinkIntent {AgentWorkflow.identity = intentIdentity} ->
          assertEqual "outbox intent carries canonical principal" verifiedHeartbeatAgentIdentity intentIdentity
        other -> assertFailure ("sink intent should decode, got " <> show other)

      sessions <- runAppIO appEnv (Session.getByScope shikigamiMemorySpace (agentScope verifiedHeartbeatIdentity))
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

egressIntentMetadata :: IO ()
egressIntentMetadata =
  withFixture "egress-metadata" [ChannelEgress {channel = "intercom", action = "reply_to_conversation", conversationKey = Nothing}] unreachableKizashi unreachableDanwa \deps appEnv pool runJob -> do
    _ <- expectRight "grant ChannelEgress" =<< GrantStore.upsertGrant pool "heartbeat" (compatibilityIdentity "heartbeat") SChannelEgress (Just "test")
    [row] <- runWorkflowAndRows deps appEnv (runJob {triggerPayload = Aeson.toJSON triggeringActivity})
    case Integration.decodeJsonIntegrationEvent (rowEvent row) of
      Right AgentWorkflow.SinkIntent {AgentWorkflow.conversationKey, AgentWorkflow.triggeringActivityId} -> do
        assertEqual "activity subject becomes the durable conversation key" (Just "conv_55012") conversationKey
        assertEqual "activity id is retained without the envelope" (Just "act_channel_1") triggeringActivityId
      other -> assertFailure ("ChannelEgress intent should decode, got " <> show other)

triggeringActivity :: Activity.ActivityEnvelope
triggeringActivity =
  Activity.ActivityEnvelope
    { Activity.activityId = "act_channel_1",
      Activity.occurredAt = "2026-08-23T12:00:00Z",
      Activity.source = "external/intercom",
      Activity.actor = Activity.Actor {Activity.kind = "human", Activity.id = "person_42", Activity.session = Nothing},
      Activity.subject = Activity.Subject {Activity.subjectType = "conversation", Activity.subjectId = "conv_55012"},
      Activity.verb = "conversation.message_received",
      Activity.payload = object ["text" .= ("Could I get an update?" :: Text)],
      Activity.contextRefs = [],
      Activity.idempotencyKey = "intercom-message-1"
    }

egressReceiptRecording :: IO ()
egressReceiptRecording = do
  requests <- newIORef []
  testWithApplication (pure (kanmonApp requests)) \port ->
    withFixture "egress-receipt" [ChannelEgress {channel = "intercom", action = "reply_to_conversation", conversationKey = Nothing}] unreachableKizashi unreachableDanwa \deps appEnv pool runJob -> do
      _ <- expectRight "grant ChannelEgress" =<< GrantStore.upsertGrant pool "heartbeat" (compatibilityIdentity "heartbeat") SChannelEgress (Just "test")
      authenticatedHttp <- expectRight "construct authenticated sink HTTP" =<< newSinkHttp testHttpLimits (credentialsFromConfig kanmonTestConfig) unreachableDanwa
      let configuredDeps =
            deps
              { AgentWorkflow.kanmon = KanmonConfig {baseUrl = localBaseUrl port},
                AgentWorkflow.http = authenticatedHttp
              }
      [row] <- runWorkflowAndRows configuredDeps appEnv (runJob {triggerPayload = Aeson.toJSON triggeringActivity})
      before <- lookupReceipt pool row
      assertEqual "enqueue atomically records pending" Delivery.Pending (Delivery.status before)
      index <- expectRight "loadStepIndex" =<< runAppIO appEnv (loadStepIndex AgentWorkflow.agentRunWorkflowName (WorkflowId (idempotencyKey runJob)) 0)
      case maybe (Error "missing dispatch-sinks") fromJSON (Map.lookup "dispatch-sinks" index) of
        Success [SinkResult {outcome = Enqueued _}] -> pure ()
        other -> assertFailure ("egress workflow did not journal Enqueued: " <> show other)
      first <- runEff (AgentWorkflow.publishSinkIntent configuredDeps row)
      second <- runEff (AgentWorkflow.publishSinkIntent configuredDeps row)
      assertEqual "first publication succeeds" Outbox.PublishSucceeded first
      assertEqual "delivered receipt suppresses the second HTTP request" Outbox.PublishSucceeded second
      receipt <- lookupReceipt pool row
      assertEqual "receipt is delivered" Delivery.Delivered (Delivery.status receipt)
      assertEqual "Kanmon activity id is retained" (Just "act_reply_1") (Delivery.detail receipt)
      observed <- readIORef requests
      assertEqual "Kanmon receives one request" 1 (length observed)
      case observed of
        [Wire.EgressActionRequest {Wire.conversationKey, Wire.triggeringActivityId}] -> do
          assertEqual "published conversation key" "conv_55012" conversationKey
          assertEqual "published triggering activity" (Just "act_channel_1") triggeringActivityId
        other -> assertFailure ("expected one decoded egress request, got " <> show other)

egressPermanentRejection :: IO ()
egressPermanentRejection = do
  requests <- newIORef (0 :: Int)
  testWithApplication (pure (rejectingKanmonApp requests)) \port ->
    withFixture "egress-403" [ChannelEgress {channel = "intercom", action = "reply_to_conversation", conversationKey = Nothing}] unreachableKizashi unreachableDanwa \deps appEnv pool runJob -> do
      _ <- expectRight "grant ChannelEgress" =<< GrantStore.upsertGrant pool "heartbeat" (compatibilityIdentity "heartbeat") SChannelEgress (Just "test")
      let configuredDeps = deps {AgentWorkflow.kanmon = KanmonConfig {baseUrl = localBaseUrl port}}
      [row] <- runWorkflowAndRows configuredDeps appEnv (runJob {triggerPayload = Aeson.toJSON triggeringActivity})
      published <- runEff (AgentWorkflow.publishSinkIntent configuredDeps row)
      case published of
        Outbox.PublishRejected _ -> pure ()
        other -> assertFailure ("403 should terminally reject publication, got " <> show other)
      receipt <- lookupReceipt pool row
      assertEqual "403 receipt is dead" Delivery.Dead (Delivery.status receipt)
      readIORef requests >>= assertEqual "one rejected HTTP request" 1

egressDenied :: IO ()
egressDenied = do
  requests <- newIORef (0 :: Int)
  testWithApplication (pure (rejectingKanmonApp requests)) \port ->
    withFixture "egress-denied" [ChannelEgress {channel = "intercom", action = "reply_to_conversation", conversationKey = Nothing}] unreachableKizashi unreachableDanwa \deps appEnv pool runJob -> do
      let configuredDeps = deps {AgentWorkflow.kanmon = KanmonConfig {baseUrl = localBaseUrl port}}
      rows <- runWorkflowAndRows configuredDeps appEnv (runJob {triggerPayload = Aeson.toJSON triggeringActivity})
      assertEqual "denied egress creates no outbox row" [] rows
      receipt <- Delivery.lookupDelivery pool (Delivery.deliveryReceiptKey (idempotencyKey runJob <> ":sink:0"))
      assertEqual "denied egress creates no receipt" (Right Nothing) receipt
      index <- expectRight "loadStepIndex" =<< runAppIO appEnv (loadStepIndex AgentWorkflow.agentRunWorkflowName (WorkflowId (idempotencyKey runJob)) 0)
      case maybe (Error "missing dispatch-sinks") fromJSON (Map.lookup "dispatch-sinks" index) of
        Success [SinkResult {outcome = DeniedOutcome _}] -> pure ()
        other -> assertFailure ("egress workflow did not journal DeniedOutcome: " <> show other)
      readIORef requests >>= assertEqual "denied egress sends no HTTP request" 0

actionDeniedAtEnqueue :: IO ()
actionDeniedAtEnqueue = do
  requests <- newIORef ([] :: [(Text, AgentAction)])
  withFixture "action-denied-enqueue" [signalSink "denied"] unreachableKizashi unreachableDanwa \deps appEnv pool runJob -> do
    _ <- expectRight "reconcile verified action grant" =<< GrantStore.reconcileGrantPrincipal pool "heartbeat" "agent_heartbeat"
    directory <- directoryWith Active
    let gatedDeps = deps {AgentWorkflow.actionAuthorizer = rejectingAuthorizer requests (ActionPolicyDenied "exact recipient denied"), AgentWorkflow.directory = directory}
    rows <- runWorkflowAndRows gatedDeps appEnv (runJob {identity = verifiedHeartbeatAgentIdentity})
    assertEqual "C13 denial creates no outbox" [] rows
    index <- expectRight "loadStepIndex" =<< runAppIO appEnv (loadStepIndex AgentWorkflow.agentRunWorkflowName (WorkflowId (idempotencyKey runJob)) 0)
    case maybe (Error "missing dispatch-sinks") fromJSON (Map.lookup "dispatch-sinks" index) of
      Success [SinkResult {outcome = DeniedOutcome reason}] ->
        assertBool "journal distinguishes exact policy denial" ("exact recipient denied" `Text.isInfixOf` reason)
      other -> assertFailure ("expected one C13 DeniedOutcome, got " <> show other)
    observed <- readIORef requests
    case observed of
      [(principal, action)] -> do
        assertEqual "authorization uses admitted Meibo principal" "agent_heartbeat" principal
        assertEqual "authorization uses exact recipient" "kizashi_recipient:recipient" (canonicalResourceText (actionResource action))
      other -> assertFailure ("expected one exact sink authorization, got " <> show other)

actionUnavailableAtEnqueue :: IO ()
actionUnavailableAtEnqueue = do
  requests <- newIORef ([] :: [(Text, AgentAction)])
  withFixture "action-unavailable-enqueue" [signalSink "unavailable"] unreachableKizashi unreachableDanwa \deps appEnv pool runJob -> do
    _ <- expectRight "reconcile verified action grant" =<< GrantStore.reconcileGrantPrincipal pool "heartbeat" "agent_heartbeat"
    directory <- directoryWith Active
    let gatedDeps = deps {AgentWorkflow.actionAuthorizer = rejectingAuthorizer requests (ActionServiceUnavailable "Kikan fixture outage"), AgentWorkflow.directory = directory}
    rows <- runWorkflowAndRows gatedDeps appEnv (runJob {identity = verifiedHeartbeatAgentIdentity})
    assertEqual "authorization outage creates no outbox" [] rows
    index <- expectRight "loadStepIndex" =<< runAppIO appEnv (loadStepIndex AgentWorkflow.agentRunWorkflowName (WorkflowId (idempotencyKey runJob)) 0)
    case maybe (Error "missing dispatch-sinks") fromJSON (Map.lookup "dispatch-sinks" index) of
      Success [SinkResult {outcome = AuthorizationFailed reason}] ->
        assertBool "journal distinguishes authorization outage" ("Kikan fixture outage" `Text.isInfixOf` reason)
      other -> assertFailure ("expected one AuthorizationFailed outcome, got " <> show other)
    readIORef requests >>= assertEqual "one fail-closed authorization attempt" 1 . length

actionRevokedBeforePublish :: IO ()
actionRevokedBeforePublish = do
  downstream <- newIORef []
  deny <- newIORef False
  decisions <- newIORef ([] :: [(Text, AgentAction)])
  testWithApplication (pure (kizashiApp downstream)) \port ->
    withFixture "action-revoked-publish" [signalSink "revoked"] (kizashiAt port) unreachableDanwa \deps appEnv pool runJob -> do
      _ <- expectRight "reconcile verified action grant" =<< GrantStore.reconcileGrantPrincipal pool "heartbeat" "agent_heartbeat"
      directory <- directoryWith Active
      let ActionAuthorizer {authorize = allowFixture} = allowAllActionAuthorizerForTests
          authorizer =
            ActionAuthorizer
              { authorize = \principal action -> do
                  modifyIORef' decisions (<> [(principal, action)])
                  denied <- readIORef deny
                  if denied
                    then pure (Left (ActionPolicyDenied "relationship revoked"))
                    else allowFixture principal action,
                kawaSource = "fixture"
              }
          gatedDeps = deps {AgentWorkflow.actionAuthorizer = authorizer, AgentWorkflow.directory = directory}
      [row] <- runWorkflowAndRows gatedDeps appEnv (runJob {identity = verifiedHeartbeatAgentIdentity})
      writeIORef deny True
      result <- runEff (AgentWorkflow.publishSinkIntent gatedDeps row)
      assertEqual "publish-time policy denial is a terminal non-send" Outbox.PublishSucceeded result
      readIORef downstream >>= assertEqual "revocation prevents downstream HTTP" []
      readIORef decisions >>= assertEqual "C13 runs once at enqueue and once at publish" 2 . length
      receipt <- lookupReceipt pool row
      assertEqual "publish-time denial closes the pending receipt" Delivery.Dead (Delivery.status receipt)

rejectingAuthorizer :: IORef [(Text, AgentAction)] -> ActionAuthorizationFailure -> ActionAuthorizer
rejectingAuthorizer requests failure =
  ActionAuthorizer
    { authorize = \principal action -> do
        modifyIORef' requests (<> [(principal, action)])
        pure (Left failure),
      kawaSource = "fixture"
    }

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
withFixture label sinks kizashi danwa use = do
  tracer <- noopTracer
  withFixtureUsingTracer tracer label sinks kizashi danwa use

withFixtureUsingTracer :: Otel.Tracer -> Text -> [Sink] -> KizashiConfig -> DanwaConfig -> (AgentWorkflow.AgentRunDeps -> AppEnv -> Pool -> RunJob -> IO a) -> IO a
withFixtureUsingTracer tracer label sinks kizashi danwa use =
  withShikigamiMigratedDatabase \connectionString ->
    withStore (defaultConnectionSettings connectionString) \kirokuStore -> do
      behaviorEnv <- newBehaviorEnv
      sinkHttp <- testSinkHttpFor danwa
      let appEnv = AppEnv {connectionSettings = defaultConnectionSettings connectionString, tracer, metrics = Nothing}
          pool = Kiroku.Store.Connection.pool kirokuStore
          declaration = agentDeclaration sinks
          deps =
            AgentWorkflow.AgentRunDeps
              { AgentWorkflow.appEnv = appEnv,
                AgentWorkflow.behaviorEnv = behaviorEnv,
                AgentWorkflow.actionAuthorizer = allowAllActionAuthorizerForTests,
                AgentWorkflow.capabilities = emptyCapabilityRuntime,
                AgentWorkflow.agents = [declaration],
                AgentWorkflow.kizashi = kizashi,
                AgentWorkflow.kawa = KawaConfig {baseUrl = "http://localhost:1", sourceSegment = "shinzui/shikigami"},
                AgentWorkflow.kanmon = KanmonConfig {baseUrl = "http://localhost:1"},
                AgentWorkflow.danwa = danwa,
                AgentWorkflow.rei = ReiConfig {baseUrl = Nothing},
                AgentWorkflow.http = sinkHttp,
                AgentWorkflow.hooks = AgentWorkflow.defaultAgentRunHooks,
                AgentWorkflow.approvalPolicy = autoApprovePolicy (secondsToNominalDiffTime 900),
                AgentWorkflow.approvalWorkflow = ApprovalWorkflow.defaultApprovalWorkflowEnv,
                AgentWorkflow.approval = defaultApprovalEnv,
                AgentWorkflow.deadline = Nothing,
                AgentWorkflow.runTimeout = secondsToNominalDiffTime 300,
                AgentWorkflow.delegationBudget = defaultDelegationBudget,
                AgentWorkflow.grants = DbGrants pool,
                AgentWorkflow.directory = disabledDirectoryHandle,
                AgentWorkflow.routing =
                  Routing.routingRuntime
                    (AgentLoadReport [AgentLoaded "sink-test.dhall" declaration])
                    disabledDirectoryHandle,
                AgentWorkflow.practiceReview = PracticeReviewCapability.unavailablePracticeReviewRuntime,
                AgentWorkflow.deliveryPool = Just pool,
                AgentWorkflow.logger = Log.silentLogger,
                AgentWorkflow.resolveRunProfile = \profileId version -> pure (Left (UnknownProfile profileId version))
              }
          runJob = testJob label
      use deps appEnv pool runJob

withTestTracer :: (Otel.Tracer -> IORef [Otel.ImmutableSpan] -> IO a) -> IO a
withTestTracer use =
  bracket acquire release \(tracer, spansRef) -> use tracer spansRef
  where
    acquire = do
      (processor, spansRef) <- inMemoryListExporter
      provider <- Otel.createTracerProvider [processor] Otel.emptyTracerProviderOptions
      let tracer = Otel.makeTracer provider "shikigami-sink-test" Otel.tracerOptions
      pure (tracer, spansRef)
    release (tracer, _) = void (Otel.shutdownTracerProvider (Otel.getTracerTracerProvider tracer) Nothing)

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
      enabled = True,
      expertise = [],
      routing = Nothing
    }

testJob :: Text -> RunJob
testJob label =
  RunJob
    { agentName = "heartbeat",
      identity = compatibilityIdentity "heartbeat",
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

verifiedHeartbeatAgentIdentity :: AgentIdentity
verifiedHeartbeatAgentIdentity = VerifiedIdentity (either (error . Text.unpack) id (mkAgentPrincipal "agent_heartbeat"))

verifiedHeartbeatIdentity :: ResolvedAgentIdentity
verifiedHeartbeatIdentity = VerifiedAgent (either (error . Text.unpack) id (mkAgentPrincipal "agent_heartbeat"))

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

kanmonApp :: IORef [Wire.EgressActionRequest] -> Application
kanmonApp requests request respond =
  case (requestMethod request, pathInfo request) of
    ("POST", ["channels", "intercom", "actions", "reply_to_conversation"])
      | lookup hAuthorization (requestHeaders request) /= Just "Bearer kanmon-e2e-token" ->
          respond (responseLBS status401 [] "unauthorized")
      | otherwise -> do
          body <- strictRequestBody request
          case eitherDecode body of
            Left err -> respond (responseLBS status400 [] (LBS8.pack err))
            Right actionRequest -> do
              modifyIORef' requests (actionRequest :)
              respond
                ( responseLBS
                    status200
                    [(hContentType, "application/json")]
                    (encode (Wire.EgressActionResponse "act_reply_1" "conversation.reply_sent"))
                )
    _ -> respond (responseLBS status404 [] "not found")

rejectingKanmonApp :: IORef Int -> Application
rejectingKanmonApp requests _ respond = do
  modifyIORef' requests (+ 1)
  respond (responseLBS status403 [] "forbidden")

kanmonTestConfig :: AppConfig
kanmonTestConfig =
  case answer (resolve defaultResolveOptions [source] appConfig) of
    Right config -> config
    Left failure -> error ("Kanmon E2E config did not resolve: " <> show failure)
  where
    source = environmentSource environmentBindings (envSnapshot [("SHIKIGAMI_KANMON_TOKEN", "kanmon-e2e-token")])

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

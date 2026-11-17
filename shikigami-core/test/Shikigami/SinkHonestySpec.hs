-- | A sink either delivers, or says it did not.
--
-- The failure this module guards against is specific and was live: the
-- @ReiAction@ handler logged a line, returned a @Stubbed@ outcome, and
-- 'Shikigami.Agent.Workflow.publishSinkIntent' mapped everything that was not
-- @Failed@ to @PublishSucceeded@. An outbox row published is published forever —
-- no retry, no dead letter, nothing to notice — so every finding bound for rei
-- was dropped while the ledger said delivered.
--
-- Two things therefore have to hold together, and testing either alone would
-- miss it. A handler with nowhere to send must produce @Failed@, /and/ @Failed@
-- must reach the outbox as @PublishFailed@. The cases below assert the pair, on
-- both sides of the mapping.
--
-- No database is involved: 'Shikigami.Sink.dispatchOutbox' is a pure-ish IO
-- call over the permission gate and one HTTP client, reached through the real
-- Kikan adapters ("Shikigami.Fixture.OutboxDispatch").
module Shikigami.SinkHonestySpec (tests) where

import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Either (isLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types (hContentType, status200, status404, status503)
import Network.Wai (Application, pathInfo, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Shikigami.Activity.Coordinate
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, mkAgentName)

-- Qualified: @Actor@ names both an activity's actor and the routing strategy
-- that reads it.

import Shikigami.Activity qualified as Activity
import Shikigami.Agent.Decl
  ( Priority (High),
    RecipientFrom (..),
    SignalType (Alert),
  )
import Shikigami.Agent.Principal (AgentIdentity (VerifiedIdentity), compatibilityIdentity, mkAgentPrincipal)
import Shikigami.Authority (OutputKind)
import Shikigami.Fixture.OutboxDispatch (DispatchContext, dispatchContext, dispatchOutput, withActivity, withIdentity, withServices)
import Shikigami.Output (OutputDecl (..))
import Shikigami.Output.Kikan (KikanServices (..))
import Shikigami.Sink (SinkOutcome (..), SinkResult (..))
import Shikigami.Sink.Config (KizashiConfig (..), ReiConfig (..))
import Shikigami.Sink.KizashiClient (buildSignalReq)
import Shikigami.Sink.Outputs
  ( ChannelEgressOutput (..),
    KizashiSignalOutput (..),
    ReiActionOutput (..),
    channelEgressOutput,
    kizashiSignalKind,
    kizashiSignalOutput,
    outputConfigErrors,
    reiActionKind,
    reiActionOutput,
    toRecipient,
    validateKanmonRouteSegment,
  )
import Shikigami.Sink.Recipient (resolveRecipient, unresolvableRecipientWarning)
import Shikigami.Sink.ReiAction (unconfiguredMessage)
import Shikigami.Sink.Wire (CreateSignalReq (..), ReiActionReq (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "sink honesty"
    [ reiActionTests,
      outcomeMappingTests,
      recipientTests,
      validationTests
    ]

-- ── Declarations that can never be honored ──────────────────────────────────

-- | The line between \"warn at dispatch\" and \"refuse at validate\".
--
-- A strategy that falls back to a declared default is recoverable and only
-- deserves a warning. A strategy that needs an ownership directory /and/ names
-- nobody to fall back to has no correct answer at all — every signal it produces
-- would go to the deployment-wide fallback, which is a person the manifest never
-- mentioned. That is refused where the author can see it.
validationTests :: TestTree
validationTests =
  testGroup
    "a declaration that can never route is refused up front"
    [ testCase "a directory strategy with no default is an error naming both" $
        case outputConfigErrors (kizashiSignalOutput (signalWith SubjectOwner Nothing)) of
          [err] -> do
            assertBool ("the error should name the strategy:\n" <> Text.unpack err) ("SubjectOwner" `Text.isInfixOf` err)
            assertBool ("the error should name what is missing:\n" <> Text.unpack err) ("defaultRecipient" `Text.isInfixOf` err)
          other -> assertFailure ("expected exactly one error, got " <> show other),
      testCase "both directory strategies are refused" $
        mapM_
          (\strategy -> length (outputConfigErrors (kizashiSignalOutput (signalWith strategy Nothing))) @?= 1)
          [SubjectOwner, AreaOwner],
      -- The shape agents/triage-note.dhall already ships: a directory strategy
      -- is fine as long as the author said who to fall back to.
      testCase "a directory strategy with a declared default is fine" $
        outputConfigErrors (kizashiSignalOutput (signalWith SubjectOwner (Just "person:nadeem"))) @?= [],
      testCase "Actor needs no default, because it resolves" $
        outputConfigErrors (kizashiSignalOutput (signalWith Actor Nothing)) @?= [],
      testCase "an exact recipient needs no default" $
        outputConfigErrors (toRecipient (declarationCoordinate "person:mai") (kizashiSignalOutput (signalWith SubjectOwner Nothing))) @?= [],
      testCase "outputs with no routing at all are not the subject" $
        outputConfigErrors sampleReiSink @?= [],
      testCase "Kanmon accepts its current channel and action segments" do
        validateKanmonRouteSegment "intercom" @?= Right "intercom"
        validateKanmonRouteSegment "reply_to_conversation" @?= Right "reply_to_conversation"
        outputConfigErrors (egressWith "intercom" "reply_to_conversation" Nothing) @?= [],
      testCase "Kanmon route segments refuse empty and unsafe values" do
        mapM_
          (\segment -> assertBool ("expected an invalid segment: " <> Text.unpack segment) (isLeft (validateKanmonRouteSegment segment)))
          ["", "inter/com", "reply?now", "..\\reply", "intercom/../other"]
        let errors = outputConfigErrors (egressWith "inter/com" "reply?now" Nothing)
        assertBool "the channel field is named" (any ("channel" `Text.isPrefixOf`) errors)
        assertBool "the action field is named" (any ("action" `Text.isPrefixOf`) errors),
      testCase "an explicitly blank conversation key is refused" $
        case outputConfigErrors (egressWith "intercom" "reply_to_conversation" (Just "  ")) of
          [err] -> assertBool "the field is named" ("conversationKey" `Text.isInfixOf` err)
          other -> assertFailure ("expected one conversation key error, got " <> show other),
      testCase "a configuration that does not decode is reported" $
        case outputConfigErrors (OutputDecl kizashiSignalKind (object ["source" .= ("shinzui/shikigami" :: Text)])) of
          [err] -> assertBool ("the error names the kind:\n" <> Text.unpack err) ("kizashi.signal" `Text.isInfixOf` err)
          other -> assertFailure ("expected one decode error, got " <> show other)
    ]

-- ── recipientFrom ───────────────────────────────────────────────────────────

-- | @recipientFrom@ was parsed, type-checked, and never read: every signal went
-- to the declared default or the configured fallback whatever the manifest said.
--
-- Only @Actor@ is resolvable, and only upstream of the client, where the trigger
-- activity is in scope — so the cases below check both ends. Resolution turns an
-- envelope into an actor id; the client prefers that over the declaration's
-- default; and the two strategies that need an ownership directory nobody has
-- resolve to nothing and say so out loud instead of inventing a recipient.
recipientTests :: TestTree
recipientTests =
  testGroup
    "recipientFrom is honored or reported, never ignored"
    [ testCase "Actor resolves to the triggering activity's actor" $
        resolveRecipient Actor (Just triggerActivity) @?= Just (declarationCoordinate ("person:mai")),
      testCase "Actor with no triggering activity resolves to nothing" $
        resolveRecipient Actor Nothing @?= Nothing,
      testCase "the strategies needing an ownership directory resolve to nothing" $
        mapM_
          (\strategy -> resolveRecipient strategy (Just triggerActivity) @?= Nothing)
          [SubjectOwner, AreaOwner],
      testCase "a resolved recipient beats the declaration's default" $
        recipientOf (Just "person:mai") (Just "ops") @?= Right "person:mai",
      testCase "the declaration's default beats the deployment fallback" $
        recipientOf Nothing (Just "ops") @?= Right "ops",
      testCase "the deployment fallback is the last resort" $
        recipientOf Nothing Nothing @?= Right "recipient_default",
      testCase "verified principal agent_heartbeat is the Kizashi actor" do
        principal <- either (assertFailure . Text.unpack) pure (mkAgentPrincipal "agent_heartbeat")
        request <-
          either (assertFailure . Text.unpack) pure $
            buildSignalReq
              KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = (declarationCoordinate "recipient_default")}
              Nothing
              (signalWith Actor (Just "ops"))
              (VerifiedIdentity principal)
              sampleOutput
        case request of
          CreateSignalReq {actor} -> actor @?= "agent_heartbeat",
      -- Silence here would mean a signal quietly reaching whoever the fallback
      -- names, which is the failure mode the whole plan is about.
      testCase "an unresolvable strategy produces a warning naming itself" $
        case unresolvableRecipientWarning (signalWith SubjectOwner (Just "ops")) Nothing of
          Just warning -> do
            assertBool ("the warning should name the strategy:\n" <> Text.unpack warning) ("SubjectOwner" `Text.isInfixOf` warning)
            assertBool ("the warning should say what it fell back to:\n" <> Text.unpack warning) ("defaultRecipient" `Text.isInfixOf` warning)
          Nothing -> assertFailure "an unresolvable strategy must warn",
      testCase "a strategy that was honored produces no warning" $
        unresolvableRecipientWarning (signalWith Actor Nothing) (Just (declarationCoordinate ("person:mai"))) @?= Nothing,
      testCase "Actor resolved from the trigger activity reaches the signal" do
        recorded <- newIORef []
        testWithApplication (pure (stubKizashiApp recorded)) \port -> do
          let ctx = withActivity triggerActivity (withServices (\services -> services {kizashi = KizashiConfig {baseUrl = localBaseUrl port, defaultRecipient = (declarationCoordinate "recipient_default")}}) dispatchContext)
          _ <- dispatchOutput ctx (kizashiSignalOutput (signalWith Actor (Just "ops"))) sampleOutput
          posted <- readIORef recorded
          case posted of
            [CreateSignalReq {recipient}] -> recipient @?= "person:mai"
            other -> assertFailure ("expected exactly one signal, got " <> show (length other)),
      testCase "the exact recipient reaches the signal the client builds" do
        recorded <- newIORef []
        testWithApplication (pure (stubKizashiApp recorded)) \port -> do
          let ctx = withServices (\services -> services {kizashi = KizashiConfig {baseUrl = localBaseUrl port, defaultRecipient = (declarationCoordinate "recipient_default")}}) dispatchContext
          _ <- dispatchOutput ctx (toRecipient (declarationCoordinate "person_mai") (kizashiSignalOutput (signalWith Actor (Just "ops")))) sampleOutput
          posted <- readIORef recorded
          case posted of
            [CreateSignalReq {recipient}] -> recipient @?= "person_mai"
            other -> assertFailure ("expected exactly one signal, got " <> show (length other))
    ]

-- | 'recipientFor' as the client applies it, wrapped so a failure prints the
-- built request rather than a bare string.
recipientOf :: Maybe Text -> Maybe Text -> Either Text Text
recipientOf resolved declared =
  fmap (\CreateSignalReq {recipient} -> recipient) $
    buildSignalReq
      KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = (declarationCoordinate "recipient_default")}
      (declarationCoordinate <$> resolved)
      (signalWith Actor declared)
      (compatibilityIdentity (fixtureAgentName "triage-note"))
      sampleOutput

signalWith :: RecipientFrom -> Maybe Text -> KizashiSignalOutput
signalWith recipientFrom defaultRecipient =
  KizashiSignalOutput
    { source = activityCoordinate ("shinzui/shikigami"),
      signalType = Alert,
      priority = High,
      importance = either (error . show) id (parseSignalImportance (7)),
      recipientFrom,
      defaultRecipient = declarationCoordinate <$> defaultRecipient,
      intentTemplate = "escalate this",
      extraContextTags = [],
      recipient = Nothing
    }

egressWith :: Text -> Text -> Maybe Text -> OutputDecl
egressWith channel action conversationKey =
  channelEgressOutput ChannelEgressOutput {channel = declarationCoordinate channel, action = declarationCoordinate action, conversationKey = declarationCoordinate <$> conversationKey}

-- | An activity whose actor is a person, so a resolved recipient is visibly not
-- the agent's own name or the fallback.
triggerActivity :: Activity.ActivityEnvelope
triggerActivity =
  Activity.ActivityEnvelope
    { Activity.activityId = activityCoordinate ("act_1"),
      Activity.occurredAt = activityCoordinate ("2026-07-31T09:00:00Z"),
      Activity.source = activityCoordinate ("shinzui/rei"),
      Activity.actor = Activity.Actor {Activity.kind = either (error . show) id (parseActorKind ("human")), Activity.id = activityCoordinate ("person:mai"), Activity.session = fmap activityCoordinate (Nothing)},
      Activity.subject = Activity.Subject {Activity.kind = activityCoordinate ("intention"), Activity.subjectId = activityCoordinate ("int_42")},
      Activity.verb = activityCoordinate ("intention.stalled"),
      Activity.payload = sampleOutput,
      Activity.contextRefs = [],
      Activity.idempotencyKey = activityCoordinate ("act_1")
    }

stubKizashiApp :: IORef [CreateSignalReq] -> Application
stubKizashiApp ref req respond =
  case (requestMethod req, pathInfo req) of
    ("POST", ["v1", "signals"]) -> do
      body <- strictRequestBody req
      case eitherDecode body of
        Right signal -> do
          modifyIORef' ref (signal :)
          respond (responseLBS status200 [(hContentType, "application/json")] (encode (object ["signalId" .= ("sig_stub" :: Text), "lifecycleState" .= ("active" :: Text)])))
        Left err -> respond (responseLBS status404 [] (LBS8.pack err))
    _ -> respond (responseLBS status404 [] "not found")

-- ── ReiAction ───────────────────────────────────────────────────────────────

reiActionTests :: TestTree
reiActionTests =
  testGroup
    "ReiAction reports what actually happened"
    [ testCase "with no endpoint configured it fails rather than claiming delivery" do
        result <- dispatchOutput (ctxWith (ReiConfig {baseUrl = Nothing})) sampleReiSink sampleOutput
        kindOf result @?= reiActionKind
        case (.outcome) result of
          Failed reason -> do
            reason @?= unconfiguredMessage "int_42"
            -- The operator reading a repeating publisher log needs the
            -- intention that was missed and the key that fixes it.
            assertBool ("the failure should name the intention:\n" <> Text.unpack reason) ("int_42" `Text.isInfixOf` reason)
            assertBool ("the failure should name the setting:\n" <> Text.unpack reason) ("sinks.rei.base_url" `Text.isInfixOf` reason)
          other -> assertFailure ("an unconfigured rei sink must fail, got " <> show other),
      testCase "with an endpoint it really POSTs the action" do
        recorded <- newIORef []
        testWithApplication (pure (stubReiApp recorded)) \port -> do
          result <- dispatchOutput (ctxWith (ReiConfig {baseUrl = Just (localBaseUrl port)})) sampleReiSink sampleOutput
          case (.outcome) result of
            Delivered detail -> assertBool ("the detail should name the intention: " <> Text.unpack (declarationCoordinateText detail)) ("int_42" `Text.isInfixOf` declarationCoordinateText detail)
            other -> assertFailure ("a configured rei sink should deliver, got " <> show other)
          posted <- readIORef recorded
          case posted of
            [ReiActionReq {intentionId, note, output, sourceEventId}] -> do
              intentionId @?= "int_42"
              note @?= "follow up on the stalled export"
              output @?= sampleOutput
              -- The deterministic dedup key: an outbox retry or a workflow
              -- replay re-POSTs this exact value, so a future rei can dedup the
              -- way kawa's doorway already does.
              sourceEventId @?= "shikigami.agent.v2.d17d72cd-aca1-5113-a70d-6c739e2164f5:kioku_session_01kvxa7d2cezhs874g3n8dfgme:0"
            other -> assertFailure ("expected exactly one recorded action, got " <> show (length other)),
      -- A reachable endpoint that refuses is a different failure from no
      -- endpoint at all, and both must be failures.
      testCase "an endpoint that refuses the request is a failure too" do
        recorded <- newIORef []
        testWithApplication (pure (refusingReiApp recorded)) \port -> do
          result <- dispatchOutput (ctxWith (ReiConfig {baseUrl = Just (localBaseUrl port)})) sampleReiSink sampleOutput
          case (.outcome) result of
            Failed reason -> assertBool ("the failure should name the status:\n" <> Text.unpack reason) ("503" `Text.isInfixOf` reason)
            other -> assertFailure ("a refused POST must fail, got " <> show other),
      testCase "a denied agent never reaches the handler at all" do
        recorded <- newIORef []
        testWithApplication (pure (stubReiApp recorded)) \port -> do
          let ctx = ctxWithIdentity (compatibilityIdentity (fixtureAgentName "intruder")) (ReiConfig {baseUrl = Just (localBaseUrl port)})
          result <- dispatchOutput ctx sampleReiSink sampleOutput
          case (.outcome) result of
            DeniedOutcome _ -> pure ()
            other -> assertFailure ("an ungranted agent must be denied, got " <> show other)
          posted <- readIORef recorded
          assertBool "a denied sink must not POST" (null posted)
    ]

-- ── The outcome mapping ─────────────────────────────────────────────────────

-- | 'Shikigami.Agent.Workflow.publishSinkIntent' turns a 'SinkOutcome' into one
-- of three outbox verdicts. Transient failures retry, permanent failures reject
-- terminally, and successful or intentional non-send outcomes acknowledge the
-- row. Keeping all three cases visible prevents a stable downstream rejection
-- from either retrying forever or masquerading as delivery.
outcomeMappingTests :: TestTree
outcomeMappingTests =
  testGroup
    "the outbox verdict follows the outcome"
    [ testCase "a failed outcome leaves the row retryable" $
        publicationDisposition (Failed "no rei endpoint is configured") @?= Retryable,
      testCase "a permanent failure terminally rejects the row" $
        publicationDisposition (PermanentFailure "downstream refused this resource") @?= Rejected,
      testCase "a delivered outcome acknowledges the row" $
        publicationDisposition (Delivered (declarationCoordinate "rei-action recorded for intention int_42")) @?= Acknowledged,
      -- The historical hazard, stated as a fact rather than as a warning: had
      -- ReiAction kept returning Stubbed, this is what the outbox would have
      -- done with it.
      testCase "the deprecated Stubbed outcome would still publish, which is why nothing returns it" $
        publicationDisposition Stubbed @?= Acknowledged,
      testCase "a denied sink publishes, because there is nothing to retry" $
        publicationDisposition (DeniedOutcome "agent 'intruder' has no sink grants") @?= Acknowledged
    ]

data PublicationDisposition
  = Acknowledged
  | Retryable
  | Rejected
  deriving stock (Eq, Show)

-- | The rule under test, mirrored from @publishSinkIntent@'s @case outcome@.
publicationDisposition :: SinkOutcome -> PublicationDisposition
publicationDisposition = \case
  Failed _ -> Retryable
  PermanentFailure _ -> Rejected
  Enqueued _ -> Retryable
  _ -> Acknowledged

-- ── Fixtures ────────────────────────────────────────────────────────────────

-- | @heartbeat@ is granted @rei.action@ in the static grant table, so the
-- permission gate is not what these cases are measuring.
ctxWith :: ReiConfig -> DispatchContext
ctxWith = ctxWithIdentity (compatibilityIdentity (fixtureAgentName "heartbeat"))

ctxWithIdentity :: AgentIdentity -> ReiConfig -> DispatchContext
ctxWithIdentity agentIdentity rei = withIdentity agentIdentity (withServices (\services -> services {rei}) dispatchContext)

sampleReiSink :: OutputDecl
sampleReiSink =
  reiActionOutput
    ReiActionOutput
      { intentionId = declarationCoordinate ("int_42"),
        note = "follow up on the stalled export"
      }

sampleOutput :: Value
sampleOutput = object ["summary" .= ("the weekly export has not run since Tuesday" :: Text)]

localBaseUrl :: Int -> Text
localBaseUrl port = "http://localhost:" <> Text.pack (show port)

-- | A rei that accepts agent actions and remembers them.
stubReiApp :: IORef [ReiActionReq] -> Application
stubReiApp ref req respond =
  case (requestMethod req, pathInfo req) of
    ("POST", ["v1", "agent-actions"]) -> do
      body <- strictRequestBody req
      case eitherDecode body of
        Right action -> do
          modifyIORef' ref (action :)
          respond (responseLBS status200 [(hContentType, "application/json")] (encode (object ["accepted" .= True])))
        Left err -> respond (responseLBS status404 [] (LBS8.pack err))
    _ -> respond (responseLBS status404 [] "not found")

-- | A rei that is reachable and unwilling.
refusingReiApp :: IORef [ReiActionReq] -> Application
refusingReiApp _ref _req respond =
  respond (responseLBS status503 [] "rei is not accepting agent actions")

kindOf :: SinkResult -> OutputKind
kindOf SinkResult {kind} = kind

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

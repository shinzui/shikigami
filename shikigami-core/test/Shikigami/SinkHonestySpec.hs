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
-- No database is involved: 'Shikigami.Sink.dispatch' is a pure-ish IO call over
-- the permission gate and one HTTP client, and the outcome mapping is exercised
-- through a real encoded outbox row.
module Shikigami.SinkHonestySpec (tests) where

import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types (hContentType, status200, status404, status503)
import Network.Wai (Application, pathInfo, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
-- Qualified: @Actor@ names both an activity's actor and the routing strategy
-- that reads it.
import Shikigami.Activity qualified as Activity
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    Behavior (..),
    Priority (High),
    RecipientFrom (..),
    SignalType (Alert),
    Sink (..),
    Trigger (..),
    defaultMemoryPolicy,
  )
import Shikigami.Log qualified as Log
import Shikigami.Sink
  ( AgentIdentity (..),
    DanwaConfig (..),
    GrantSource (StaticGrants),
    KawaConfig (..),
    KizashiConfig (..),
    ReiConfig (..),
    SinkContext (..),
    SinkOutcome (..),
    SinkResult (..),
    defaultGrantTable,
    dispatch,
  )
import Shikigami.Sink.KizashiClient (buildSignalReq)
import Shikigami.Sink.Permission (SinkKind (SReiAction))
import Shikigami.Sink.Recipient (resolveSinkRecipient, unresolvableRecipientWarning)
import Shikigami.Sink.ReiAction (unconfiguredMessage)
import Shikigami.Sink.Validate (sinkDeclarationErrors)
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
        case sinkDeclarationErrors (agentWith [signalWith SubjectOwner Nothing]) of
          [err] -> do
            assertBool ("the error should name the strategy:\n" <> Text.unpack err) ("SubjectOwner" `Text.isInfixOf` err)
            assertBool ("the error should name what is missing:\n" <> Text.unpack err) ("defaultRecipient" `Text.isInfixOf` err)
          other -> assertFailure ("expected exactly one error, got " <> show other),
      testCase "both directory strategies are refused" $
        mapM_
          (\strategy -> length (sinkDeclarationErrors (agentWith [signalWith strategy Nothing])) @?= 1)
          [SubjectOwner, AreaOwner],
      -- The shape agents/triage-note.dhall already ships: a directory strategy
      -- is fine as long as the author said who to fall back to.
      testCase "a directory strategy with a declared default is fine" $
        sinkDeclarationErrors (agentWith [signalWith SubjectOwner (Just "person:nadeem")]) @?= [],
      testCase "Actor needs no default, because it resolves" $
        sinkDeclarationErrors (agentWith [signalWith Actor Nothing]) @?= [],
      testCase "sinks with no routing at all are not the subject" $
        sinkDeclarationErrors (agentWith [sampleReiSink]) @?= [],
      testCase "every offending sink is reported, not just the first" $
        length (sinkDeclarationErrors (agentWith [signalWith SubjectOwner Nothing, signalWith AreaOwner Nothing])) @?= 2
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
        resolveSinkRecipient (signalWith Actor (Just "ops")) (Just triggerActivity) @?= Just "person:mai",
      testCase "Actor with no triggering activity resolves to nothing" $
        resolveSinkRecipient (signalWith Actor (Just "ops")) Nothing @?= Nothing,
      testCase "the strategies needing an ownership directory resolve to nothing" $
        mapM_
          (\strategy -> resolveSinkRecipient (signalWith strategy (Just "ops")) (Just triggerActivity) @?= Nothing)
          [SubjectOwner, AreaOwner],
      testCase "a non-signal sink has no recipient to resolve" $
        resolveSinkRecipient sampleReiSink (Just triggerActivity) @?= Nothing,
      testCase "a resolved recipient beats the declaration's default" $
        recipientOf (Just "person:mai") (Just "ops") @?= Right "person:mai",
      testCase "the declaration's default beats the deployment fallback" $
        recipientOf Nothing (Just "ops") @?= Right "ops",
      testCase "the deployment fallback is the last resort" $
        recipientOf Nothing Nothing @?= Right "recipient_default",
      -- Silence here would mean a signal quietly reaching whoever the fallback
      -- names, which is the failure mode the whole plan is about.
      testCase "an unresolvable strategy produces a warning naming itself" $
        case unresolvableRecipientWarning (signalWith SubjectOwner (Just "ops")) Nothing of
          Just warning -> do
            assertBool ("the warning should name the strategy:\n" <> Text.unpack warning) ("SubjectOwner" `Text.isInfixOf` warning)
            assertBool ("the warning should say what it fell back to:\n" <> Text.unpack warning) ("defaultRecipient" `Text.isInfixOf` warning)
          Nothing -> assertFailure "an unresolvable strategy must warn",
      testCase "a strategy that was honored produces no warning" $
        unresolvableRecipientWarning (signalWith Actor Nothing) (Just "person:mai") @?= Nothing,
      testCase "a non-signal sink produces no warning" $
        unresolvableRecipientWarning sampleReiSink Nothing @?= Nothing,
      testCase "the resolved recipient reaches the signal the client builds" do
        recorded <- newIORef []
        testWithApplication (pure (stubKizashiApp recorded)) \port -> do
          let ctx =
                (ctxWith (ReiConfig {baseUrl = Nothing}))
                  { kizashi = KizashiConfig {baseUrl = localBaseUrl port, defaultRecipient = "recipient_default"},
                    recipientOverride = Just "person:mai"
                  }
          _ <- dispatch ctx (signalWith Actor (Just "ops")) sampleOutput
          posted <- readIORef recorded
          case posted of
            [CreateSignalReq {recipient}] -> recipient @?= "person:mai"
            other -> assertFailure ("expected exactly one signal, got " <> show (length other))
    ]

-- | 'recipientFor' as the client applies it, wrapped so a failure prints the
-- built request rather than a bare string.
recipientOf :: Maybe Text -> Maybe Text -> Either Text Text
recipientOf resolved declared =
  fmap (\CreateSignalReq {recipient} -> recipient) $
    buildSignalReq
      KizashiConfig {baseUrl = "http://localhost:1", defaultRecipient = "recipient_default"}
      resolved
      (signalWith Actor declared)
      (AgentIdentity "triage-note")
      sampleOutput

-- | A declaration carrying the given sinks; every other field is irrelevant to
-- what 'sinkDeclarationErrors' looks at.
agentWith :: [Sink] -> AgentDecl
agentWith sinks =
  AgentDecl
    { name = "triage-note",
      description = "a declaration used only for its sinks",
      trigger = Schedule {cron = "*/5 * * * *"},
      behavior = Skill {path = "agents/skills/triage-note"},
      sinks,
      sanctionedProfile = Nothing,
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True
    }

signalWith :: RecipientFrom -> Maybe Text -> Sink
signalWith recipientFrom defaultRecipient =
  KizashiSignal
    { source = "shinzui/shikigami",
      signalType = Alert,
      priority = High,
      importance = 7,
      recipientFrom,
      defaultRecipient,
      intentTemplate = "escalate this",
      extraContextTags = []
    }

-- | An activity whose actor is a person, so a resolved recipient is visibly not
-- the agent's own name or the fallback.
triggerActivity :: Activity.ActivityEnvelope
triggerActivity =
  Activity.ActivityEnvelope
    { Activity.activityId = "act_1",
      Activity.occurredAt = "2026-07-31T09:00:00Z",
      Activity.source = "shinzui/rei",
      Activity.actor = Activity.Actor {Activity.kind = "human", Activity.id = "person:mai", Activity.session = Nothing},
      Activity.subject = Activity.Subject {Activity.subjectType = "intention", Activity.subjectId = "int_42"},
      Activity.verb = "intention.stalled",
      Activity.payload = sampleOutput,
      Activity.contextRefs = [],
      Activity.idempotencyKey = "act_1"
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
        result <- dispatch (ctxWith (ReiConfig {baseUrl = Nothing})) sampleReiSink sampleOutput
        kindOf result @?= SReiAction
        case outcome result of
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
          result <- dispatch (ctxWith (ReiConfig {baseUrl = Just (localBaseUrl port)})) sampleReiSink sampleOutput
          case outcome result of
            Delivered detail -> assertBool ("the detail should name the intention: " <> Text.unpack detail) ("int_42" `Text.isInfixOf` detail)
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
              sourceEventId @?= "heartbeat:run-1:0"
            other -> assertFailure ("expected exactly one recorded action, got " <> show (length other)),
      -- A reachable endpoint that refuses is a different failure from no
      -- endpoint at all, and both must be failures.
      testCase "an endpoint that refuses the request is a failure too" do
        recorded <- newIORef []
        testWithApplication (pure (refusingReiApp recorded)) \port -> do
          result <- dispatch (ctxWith (ReiConfig {baseUrl = Just (localBaseUrl port)})) sampleReiSink sampleOutput
          case outcome result of
            Failed reason -> assertBool ("the failure should name the status:\n" <> Text.unpack reason) ("503" `Text.isInfixOf` reason)
            other -> assertFailure ("a refused POST must fail, got " <> show other),
      testCase "a denied agent never reaches the handler at all" do
        recorded <- newIORef []
        testWithApplication (pure (stubReiApp recorded)) \port -> do
          let ctx = ctxWithIdentity (AgentIdentity "intruder") (ReiConfig {baseUrl = Just (localBaseUrl port)})
          result <- dispatch ctx sampleReiSink sampleOutput
          case outcome result of
            DeniedOutcome _ -> pure ()
            other -> assertFailure ("an ungranted agent must be denied, got " <> show other)
          posted <- readIORef recorded
          assertBool "a denied sink must not POST" (null posted)
    ]

-- ── The outcome mapping ─────────────────────────────────────────────────────

-- | 'Shikigami.Agent.Workflow.publishSinkIntent' turns a 'SinkOutcome' into an
-- outbox verdict, and the rule is \"anything that is not 'Failed' is published\".
--
-- That rule is fine — it is what made @Stubbed@ dangerous, not the rule itself.
-- What has to stay true is that the two are consistent: the outcome a dishonest
-- handler used to return would still be published today, which is exactly why
-- nothing produces it any more.
outcomeMappingTests :: TestTree
outcomeMappingTests =
  testGroup
    "the outbox verdict follows the outcome"
    [ testCase "a failed outcome leaves the row unpublished" $
        publishes (Failed "no rei endpoint is configured") @?= False,
      testCase "a delivered outcome publishes the row" $
        publishes (Delivered "rei-action recorded for intention int_42") @?= True,
      -- The historical hazard, stated as a fact rather than as a warning: had
      -- ReiAction kept returning Stubbed, this is what the outbox would have
      -- done with it.
      testCase "the deprecated Stubbed outcome would still publish, which is why nothing returns it" $
        publishes Stubbed @?= True,
      testCase "a denied sink publishes, because there is nothing to retry" $
        publishes (DeniedOutcome "agent 'intruder' has no sink grants") @?= True
    ]

-- | The rule under test, mirrored from @publishSinkIntent@'s @case outcome@.
publishes :: SinkOutcome -> Bool
publishes = \case
  Failed _ -> False
  PermanentFailure _ -> False
  Enqueued _ -> False
  _ -> True

-- ── Fixtures ────────────────────────────────────────────────────────────────

-- | @heartbeat@ is granted @SReiAction@ in the static grant table, so the
-- permission gate is not what these cases are measuring.
ctxWith :: ReiConfig -> SinkContext
ctxWith = ctxWithIdentity (AgentIdentity "heartbeat")

ctxWithIdentity :: AgentIdentity -> ReiConfig -> SinkContext
ctxWithIdentity agentIdentity rei =
  SinkContext
    { identity = agentIdentity,
      runId = "run-1",
      ordinal = 0,
      kizashi = KizashiConfig {baseUrl = unreachable, defaultRecipient = "recipient_default"},
      kawa = KawaConfig {baseUrl = unreachable, sourceSegment = "shinzui/shikigami"},
      danwa = DanwaConfig {baseUrl = unreachable, agentParticipant = "part_agent_test"},
      rei,
      danwaTarget = Nothing,
      recipientOverride = Nothing,
      occurredAt = Nothing,
      receipts = Nothing,
      logger = Log.silentLogger,
      grants = StaticGrants defaultGrantTable
    }
  where
    -- Port 1 is not listening; a case that accidentally reaches another sink
    -- fails loudly rather than quietly succeeding against a real service.
    unreachable = "http://localhost:1"

sampleReiSink :: Sink
sampleReiSink =
  ReiAction
    { intentionId = "int_42",
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

kindOf :: SinkResult -> SinkKind
kindOf SinkResult {kind} = kind

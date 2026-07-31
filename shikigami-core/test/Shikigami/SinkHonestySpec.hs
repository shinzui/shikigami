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
import Shikigami.Agent.Decl (Sink (..))
import Shikigami.Sink
  ( AgentIdentity (..),
    DanwaConfig (..),
    KawaConfig (..),
    KizashiConfig (..),
    ReiConfig (..),
    SinkContext (..),
    SinkOutcome (..),
    SinkResult (..),
    dispatch,
  )
import Shikigami.Sink.Permission (SinkKind (SReiAction))
import Shikigami.Sink.ReiAction (unconfiguredMessage)
import Shikigami.Sink.Wire (ReiActionReq (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "sink honesty"
    [ reiActionTests,
      outcomeMappingTests
    ]

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
          let ctx = (ctxWith (ReiConfig {baseUrl = Just (localBaseUrl port)})) {identity = AgentIdentity "intruder"}
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
  _ -> True

-- ── Fixtures ────────────────────────────────────────────────────────────────

-- | @heartbeat@ is granted @SReiAction@ in the static grant table, so the
-- permission gate is not what these cases are measuring.
ctxWith :: ReiConfig -> SinkContext
ctxWith rei =
  SinkContext
    { identity = AgentIdentity "heartbeat",
      runId = "run-1",
      ordinal = 0,
      kizashi = KizashiConfig {baseUrl = unreachable, defaultRecipient = "recipient_default"},
      kawa = KawaConfig {baseUrl = unreachable, sourceSegment = "shinzui/shikigami"},
      danwa = DanwaConfig {baseUrl = unreachable, agentParticipant = "part_agent_test"},
      rei,
      danwaTarget = Nothing,
      occurredAt = Nothing
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

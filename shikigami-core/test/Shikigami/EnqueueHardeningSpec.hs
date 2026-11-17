-- | The trigger→enqueue path's small correctness guarantees.
--
-- Each case here stands for one way the producer used to be quietly wrong: a
-- queue name that would crash the process on a typo nobody could see, a run
-- backdated to 1970 because an envelope's timestamp did not parse, an addressed
-- run that produced a second run every time an operator retried it, and a
-- deterministic id that collided two different names into one.
module Shikigami.EnqueueHardeningSpec (tests) where

import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import Data.Either (isLeft)
import Data.Foldable (for_)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), diffUTCTime, fromGregorian, getCurrentTime)
import Data.UUID qualified as UUID
import Pgmq (parseQueueName, queueNameToText)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), StreamMatch (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (compatibilityIdentity)
import Shikigami.Agent.Run.Key (RunKey, newCliRunKey, parseRunKey, runKeyFromUUID, runKeyText)
import Shikigami.Agent.RunJob (RunJob, RunRouteKind (AgentWorkflowRoute, ConversationWorkflowRoute))
import Shikigami.Agent.RunJob qualified as RunJob
import Shikigami.Flow (DecisionMode (..), FlowDef (..), LifecycleDiagram (..))
import Shikigami.Flow.Pack
import Shikigami.Pack.Setting (noPackSettings)
import Shikigami.Prelude (nameBytes)
import Shikigami.RuntimePolicy (DefaultModelRequirement (..))
import Shikigami.Trigger.Enqueue (addressedRunKey, addressedRunKeyWithKey, envelopeOccurredAt, runJobFromEnvelope, runQueueName)
import Shikigami.Trigger.Hook (PackDisposition (..))
import Shikigami.Trigger.RequestKey qualified as Addressed
import Shikigami.Trigger.Schedule (parseCron)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "EnqueueHardening"
    [ testCase "full and caller keys retain exact string codecs and refuse empty input" do
        for_ ["key", " 名 key \n", " "] \raw -> do
          let full = either (error . show) id (parseRunKey raw)
              caller = either (error . show) id (Addressed.parseRequestKey raw)
          encode full @?= encode raw
          encode caller @?= encode raw
          eitherDecode (encode full) @?= Right full
          eitherDecode (encode caller) @?= Right caller
        assertBool "empty full key factory" (isLeft (parseRunKey ""))
        assertBool "empty caller key factory" (isLeft (Addressed.parseRequestKey ""))
        assertBool "empty full key JSON" (isLeft (eitherDecode @RunKey "\"\""))
        assertBool "empty caller key JSON" (isLeft (eitherDecode @Addressed.RequestKey "\"\"")),
      testCase "caller keys retain agent and route coordinates" do
        let key = either (error . show) id (Addressed.parseRequestKey "shared")
            agent = fixtureAgentName "first"
            first = addressedRunKeyWithKey agent AgentWorkflowRoute key
        first @?= addressedRunKeyWithKey agent AgentWorkflowRoute key
        assertBool "another agent" (first /= addressedRunKeyWithKey (fixtureAgentName "second") AgentWorkflowRoute key)
        assertBool "another route" (first /= addressedRunKeyWithKey agent ConversationWorkflowRoute key),
      testCase "CLI invocation keys are fresh and retain the complete opaque codec" do
        first <- newCliRunKey (fixtureAgentName "first")
        second <- newCliRunKey (fixtureAgentName "first")
        assertBool "independent invocations" (first /= second)
        eitherDecode (encode first) @?= Right first
        eitherDecode (encode second) @?= Right second,
      testCase "native UUID capture retains its exact workflow coordinate" do
        runKeyText (runKeyFromUUID UUID.nil) @?= UUID.toText UUID.nil,
      -- 'runQueueName' resolves a compile-time literal through a partial parse
      -- and calls 'error' on failure. Threading an Either through every caller
      -- would be out of proportion to a constant; a test that would catch a
      -- future edit to the literal is not.
      testCase "runQueueName parses" do
        case parseQueueName "shikigami_run_jobs" of
          Left err -> assertBool ("the run-queue literal must parse: " <> show err) False
          Right queue -> queueNameToText queue @?= "shikigami_run_jobs"
        queueNameToText runQueueName @?= "shikigami_run_jobs",
      testCase "a well-formed occurredAt is the run's occurrence" do
        envelopeOccurredAt (envelopeAt "2026-06-20T07:00:00Z")
          @?= Just (UTCTime (fromGregorian 2026 6 20) (7 * 3600)),
      -- The fallback used to be 1970-01-01T00:00:00Z, chosen inside the pure
      -- job builder where there was no clock to ask and nowhere to report. That
      -- backdated the run's whole durable record by decades in silence.
      testCase "an unparseable occurredAt does not become the epoch" do
        envelopeOccurredAt (envelopeAt "yesterday afternoon") @?= Nothing
        now <- getCurrentTime
        let job = runJobFromEnvelope now streamAgent (envelopeAt "yesterday afternoon")
        assertBool
          ("the caller's clock is used, not the epoch: " <> show ((.occurredAt) job))
          (abs (diffUTCTime ((.occurredAt) job) now) < 1)
        assertBool
          "and it is nowhere near 1970"
          ((.occurredAt) job > UTCTime (fromGregorian 2000 1 1) 0),
      -- The key this replaced was built from getCurrentTime, so retrying
      -- `shikigami enqueue-run` after a timeout ran the agent a second time.
      testCase "the same logical event enqueues one stable idempotency key" do
        let first = addressedRunKey (fixtureAgentName "triage-note") AgentWorkflowRoute samplePayload
            again = addressedRunKey (fixtureAgentName "triage-note") AgentWorkflowRoute samplePayload
        assertEqual "two calls for one event agree" first again
        assertBool "the key names its versioned protocol" ("addressed-run-v2:" `Text.isPrefixOf` runKeyText first),
      testCase "different agents and payloads get different keys" do
        assertBool
          "a different agent is a different key"
          (addressedRunKey (fixtureAgentName "triage-note") AgentWorkflowRoute samplePayload /= addressedRunKey (fixtureAgentName "other-agent") AgentWorkflowRoute samplePayload)
        assertBool
          "a different payload is a different key"
          (addressedRunKey (fixtureAgentName "triage-note") AgentWorkflowRoute samplePayload /= addressedRunKey (fixtureAgentName "triage-note") AgentWorkflowRoute (object ["ticket" .= ("t-2" :: Text)])),
      -- Every deterministic id in the runtime hashed names with
      -- @fromIntegral . fromEnum@ over Chars, which truncates to the low byte.
      testCase "UUIDv5 name bytes separate names that differ above U+00FF" do
        assertBool
          "\xe9 and \x1e9 are different names"
          (nameBytes "caf\xe9" /= nameBytes "caf\x1e9")
        assertEqual
          "an ASCII name still hashes to its ASCII bytes"
          [104, 101, 97, 114, 116, 98, 101, 97, 116]
          (nameBytes "heartbeat"),
      -- A pack's stream hook has a say over the agents that run its own flows
      -- and over no other agent (docs/adr/0129).
      testCase "a matched record is put to the stream hook of the pack that owns the agent's flow" do
        let intake = streamIntakeOf (either (error . show) id (composeFlowRegistry [observingPack, plainPack])) noPackSettings
            candidateFor flow =
              StreamCandidate
                { activity = envelopeAt "2026-07-15T12:00:00Z",
                  agent = streamAgent {behavior = Flow {name = declarationCoordinate flow}},
                  identity = compatibilityIdentity (fixtureAgentName "triage-note"),
                  occurredAt = UTCTime (fromGregorian 2026 7 15) 0,
                  receivedAt = UTCTime (fromGregorian 2026 7 15) 1
                }
            verdictOf = fmap \PackDisposition {pack, disposition} -> (pack, case disposition of StreamSkipped skip -> skip.reason; _ -> "other")
        verdictOf (intake (candidateFor "observed-flow")) @?= Just ("observing", "not-worth-a-run")
        verdictOf (intake (candidateFor "plain-flow")) @?= Nothing
        verdictOf (intake (candidateFor "no-such-flow")) @?= Nothing
        verdictOf (intake ((candidateFor "observed-flow") {agent = streamAgent {behavior = Skill {path = declarationCoordinate "skills/none"}}})) @?= Nothing
    ]
  where
    packWith name flow triggers =
      FlowPack
        { name = either (error . show) id (parseFlowPackName name),
          flows =
            [ kernelCapabilityFlow
                FlowDef
                  { name = declarationCoordinate flow,
                    lifecycle = LifecycleDiagram "flowchart LR\n Start --> End" [],
                    decisionSlots = [],
                    requiresDefaultModel = DefaultModelOptional,
                    decisionMode = StrictDecisions
                  }
                (const (pure (object [])))
            ],
          decisionPrograms = [],
          retainedCodecs = [],
          tasks = [],
          settings = [],
          triggers,
          adminVerbs = [],
          gauges = [],
          authorities = []
        }
    observingPack = packWith "observing" "observed-flow" noTriggerHooks {stream = Just (StreamHook \_ _ -> StreamSkipped StreamSkip {reason = "not-worth-a-run", record = pure ()})}
    plainPack = packWith "plain" "plain-flow" noTriggerHooks

envelopeAt :: Text -> ActivityEnvelope
envelopeAt occurred =
  ActivityEnvelope
    { activityId = activityCoordinate ("act_1"),
      occurredAt = activityCoordinate (occurred),
      source = activityCoordinate ("shinzui/rei"),
      actor = Actor {kind = either (error . show) id (parseActorKind ("human")), id = activityCoordinate ("someone"), session = fmap activityCoordinate (Nothing)},
      subject = Subject {kind = activityCoordinate ("ticket"), subjectId = activityCoordinate ("t-1")},
      verb = activityCoordinate ("ticket.received"),
      payload = object [],
      contextRefs = [],
      idempotencyKey = activityCoordinate ("act_1")
    }

samplePayload :: Value
samplePayload = object ["ticket" .= ("t-1" :: Text)]

streamAgent :: AgentDecl
streamAgent =
  AgentDecl
    { name = fixtureAgentName "triage-note",
      description = "enqueue hardening fixture",
      trigger =
        Stream
          { match =
              StreamMatch
                { verb = fmap activityCoordinate (Just "ticket.received"),
                  source = fmap activityCoordinate (Nothing),
                  subjectType = fmap activityCoordinate (Just "ticket"),
                  verbs = map activityCoordinate ([])
                }
          },
      behavior = Flow {name = declarationCoordinate "test-flow"},
      delegates = map fixtureAgentName [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      tools = [],
      outputs = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = agentEnablement (True),
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

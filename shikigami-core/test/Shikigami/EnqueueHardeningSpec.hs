-- | The trigger→enqueue path's small correctness guarantees.
--
-- Each case here stands for one way the producer used to be quietly wrong: a
-- queue name that would crash the process on a typo nobody could see, a run
-- backdated to 1970 because an envelope's timestamp did not parse, an addressed
-- run that produced a second run every time an operator retried it, and a
-- deterministic id that collided two different names into one.
module Shikigami.EnqueueHardeningSpec (tests) where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), diffUTCTime, fromGregorian, getCurrentTime)
import Pgmq (parseQueueName, queueNameToText)
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), StreamMatch (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Agent.RunJob (RunJob)
import Shikigami.Agent.RunJob qualified as RunJob
import Shikigami.Id.Name (nameBytes)
import Shikigami.Trigger.Enqueue (addressedRunKey, envelopeOccurredAt, runJobFromEnvelope, runQueueName)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "EnqueueHardening"
    [ -- 'runQueueName' resolves a compile-time literal through a partial parse
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
        let first = addressedRunKey "triage-note" samplePayload
            again = addressedRunKey "triage-note" samplePayload
        assertEqual "two calls for one event agree" first again
        assertBool "the key names the agent" ("triage-note:evt:" `Text.isPrefixOf` first),
      testCase "different agents and payloads get different keys" do
        assertBool
          "a different agent is a different key"
          (addressedRunKey "triage-note" samplePayload /= addressedRunKey "other-agent" samplePayload)
        assertBool
          "a different payload is a different key"
          (addressedRunKey "triage-note" samplePayload /= addressedRunKey "triage-note" (object ["ticket" .= ("t-2" :: Text)])),
      -- Every deterministic id in the runtime hashed names with
      -- @fromIntegral . fromEnum@ over Chars, which truncates to the low byte.
      testCase "UUIDv5 name bytes separate names that differ above U+00FF" do
        assertBool
          "\xe9 and \x1e9 are different names"
          (nameBytes "caf\xe9" /= nameBytes "caf\x1e9")
        assertEqual
          "an ASCII name still hashes to its ASCII bytes"
          [104, 101, 97, 114, 116, 98, 101, 97, 116]
          (nameBytes "heartbeat")
    ]

envelopeAt :: Text -> ActivityEnvelope
envelopeAt occurred =
  ActivityEnvelope
    { activityId = "act_1",
      occurredAt = occurred,
      source = "shinzui/rei",
      actor = Actor {kind = "human", id = "someone", session = Nothing},
      subject = Subject {subjectType = "ticket", subjectId = "t-1"},
      verb = "ticket.received",
      payload = object [],
      contextRefs = [],
      idempotencyKey = "act_1"
    }

samplePayload :: Value
samplePayload = object ["ticket" .= ("t-1" :: Text)]

streamAgent :: AgentDecl
streamAgent =
  AgentDecl
    { name = "triage-note",
      description = "enqueue hardening fixture",
      trigger =
        Stream
          { match =
              StreamMatch
                { verb = Just "ticket.received",
                  source = Nothing,
                  subjectType = Just "ticket",
                  verbs = []
                }
          },
      behavior = Deterministic {rule = "test", params = mempty},
      sinks = [],
      delegates = [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = True,
      expertise = [],
      decisionModels = [],
      routing = Nothing
    }

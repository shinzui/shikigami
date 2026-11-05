-- | What a behavior is actually handed.
--
-- Every agent run recalls the agent's prior learnings before the behavior
-- executes, and durably journals them — but until this plan the recalled list
-- went only into the run's /result/ record and never into the behavior. The
-- program arm was worse: it parsed an empty argument map, so a task could not
-- see the payload that triggered it either. Both failures are silent. A skill
-- still answers, a program still returns its digest, and nothing in the output
-- says the agent was reasoning without its memory.
--
-- These cases pin the request side, which is where the evidence is. The skill
-- arm's completion function is a parameter ('runSkillWith'), so a test can read
-- the exact 'Context' that would have gone to a model without a key, a network,
-- or a registered provider; the program arm's task is an ordinary value, so a
-- test can read the original input supplied to its parser. Whether a model then
-- makes good use of the context is not something a test can assert.
module Shikigami.BehaviorInputSpec (tests) where

import Baikai.Content (TextContent (..), UserContent (UserText))
import Baikai.Context (Context, messages)
import Baikai.Message (Message (UserMessage), UserPayload (..))
import Baikai.Model (emptyModel)
import Baikai.Options (emptyOptions)
import Baikai.Response (emptyResponse)
import Data.Aeson (Value, object, (.=))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Data.Vector qualified as V
import Kioku.Api.Types (MemoryRecord (..))
import Shikigami.Activity (ActivityEnvelope (..), Actor (..), Subject (..))
import Shikigami.Activity.Coordinate
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Trigger (..), defaultMemoryPolicy)
import Shikigami.Agent.DeclarationValue
import Shikigami.Agent.Name (AgentName, mkAgentName)
import Shikigami.Agent.Principal (ResolvedAgentIdentity (CompatibilityAgent))
import Shikigami.Agent.Run (recallQuery)
import Shikigami.Behavior.Error (RunError (..))
import Shikigami.Behavior.Input (BehaviorInput (..), memoryContentText, triggerOnly)
import Shikigami.Behavior.Run (defaultToolTurnLimit, newBehaviorEnv, runBehavior, runProgramTask)
import Shikigami.Behavior.Skill (SkillDir (..), runSkillWith)
import Shikigami.Flow.AtRiskCustomer (RiskLevel (..), RiskVerdict (..), classifyRisk)
import Shikigami.Memory.Scope (agentScope)
import Shikigami.Program.Registry (codeResearcherTask, webResearcherTask)
import Shikigami.Program.Runtime (newProgramRuntime)
import Shikigami.Program.Task (ProgramTask (..))
import Shikigami.Trigger.Schedule (cronExpressionClaim, parseCron)
import Shikumi.Tool (mkRegistry)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "behavior input"
    [ skillContextTests,
      programArgumentTests,
      recallQueryTests,
      classificationTests
    ]

-- ── Memory that changes a decision ──────────────────────────────────────────

-- | The at-risk-customer flow is the repository's teaching example, and it
-- recalled prior memories and then discarded them (@classifyRisk activity
-- _prior input@). These are the pure half of the proof that it no longer does;
-- the durable half is in "Shikigami.AgentWorkflowSpec".
classificationTests :: TestTree
classificationTests =
  testGroup
    "a recalled escalation changes the at-risk verdict"
    [ testCase "a calm message about a previously escalated subject is high risk" do
        let verdict = classifyRisk (activityFor "tkt_42") [escalationMemory "tkt_42"] calmPayload
        (.level) verdict @?= HighRisk
        (.rationale) verdict @?= "prior escalation on this subject: customer relationship at risk",
      testCase "the same message with nothing recalled is unchanged" do
        let verdict = classifyRisk (activityFor "tkt_42") [] calmPayload
        (.level) verdict @?= LowRisk
        (.rationale) verdict @?= "no high-risk signal detected",
      -- Memory about a different customer is not evidence about this one.
      testCase "an escalation on another subject does not carry over" do
        let verdict = classifyRisk (activityFor "tkt_42") [escalationMemory "tkt_99"] calmPayload
        (.level) verdict @?= LowRisk,
      testCase "a memory that merely mentions the subject is not an escalation" do
        let remembered = memoryWith "tkt_42 asked about invoicing"
            verdict = classifyRisk (activityFor "tkt_42") [remembered] calmPayload
        (.level) verdict @?= LowRisk
    ]

calmPayload :: Value
calmPayload = object ["text" .= ("customer says thanks, all good" :: Text)]

activityFor :: Text -> ActivityEnvelope
activityFor ticket =
  ActivityEnvelope
    { activityId = activityCoordinate ("act_" <> ticket),
      occurredAt = activityCoordinate ("2026-07-15T12:00:00Z"),
      source = activityCoordinate ("shinzui/shikigami"),
      actor = Actor {kind = either (error . show) id (parseActorKind ("human")), id = activityCoordinate ("someone"), session = fmap activityCoordinate (Nothing)},
      subject = Subject {kind = activityCoordinate ("ticket"), subjectId = activityCoordinate (ticket)},
      verb = activityCoordinate ("ticket.updated"),
      payload = object [],
      contextRefs = [],
      idempotencyKey = activityCoordinate ("act_" <> ticket)
    }

escalationMemory :: Text -> MemoryRecord
escalationMemory ticket =
  memoryWith (ticket <> " escalated after acknowledgement timeout")

-- ── What a run recalls against ──────────────────────────────────────────────

recallQueryTests :: TestTree
recallQueryTests =
  testGroup
    "the recall query is about this event"
    [ -- The query used to be the agent name, the behavior kind, and the fixed
      -- words "summary digest learning prior memory" — identical on every run,
      -- so a hybrid recall ranked memories against a constant.
      testCase "the trigger payload's words are in the query" do
        let query = recallQuery triageDecl "Skill" samplePayload
        assertContains "the payload's text" "customer says cancel" query
        assertContains "the agent's name" "triage-note" query
        assertContains "the agent's description" "triage inbound tickets" query,
      testCase "a nested payload contributes its words too" do
        let nested = object ["payload" .= object ["text" .= ("refund requested" :: Text)]]
        assertContains "the nested text" "refund requested" (recallQuery triageDecl "Skill" nested),
      testCase "a payload with no strings leaves a query about the agent" do
        let query = recallQuery triageDecl "Skill" (object ["count" .= (3 :: Int)])
        assertContains "the agent's description" "triage inbound tickets" query,
      -- The query feeds an embedding, not a prompt: a chatty payload must not
      -- push the agent's own description out of it.
      testCase "a long payload is capped" do
        let long = object ["text" .= Text.replicate 400 "verbose "]
            query = recallQuery triageDecl "Skill" long
        Text.length query @?= 512
    ]

-- ── What the skill arm sends ────────────────────────────────────────────────

skillContextTests :: TestTree
skillContextTests =
  testGroup
    "the skill arm's request carries what the agent remembers"
    [ testCase "a recalled memory reaches the model context" do
        sent <- capturedContext BehaviorInput {payload = samplePayload, recalled = [priorLearning]}
        assertContains "the recalled content" priorContent sent
        assertContains "the memory's identity" priorMemoryId sent
        -- The heading is what tells the model these are memories rather than
        -- more of the instruction body.
        assertContains "the prior-learnings heading" "Prior learnings (most relevant first):" sent,
      testCase "the trigger payload is still there alongside it" do
        sent <- capturedContext BehaviorInput {payload = samplePayload, recalled = [priorLearning]}
        assertContains "the trigger payload heading" "Trigger payload: " sent
        assertContains "the payload's own text" "customer says cancel" sent,
      -- A first run has nothing to recall, and should send exactly what it sent
      -- before memory injection existed rather than a heading over an empty list.
      testCase "an agent with nothing recalled sends no memory section" do
        sent <- capturedContext (triggerOnly samplePayload)
        assertBool
          ("a request with no memories should not mention prior learnings:\n" <> Text.unpack sent)
          (not ("Prior learnings" `Text.isInfixOf` sent))
        assertContains "the trigger payload" "customer says cancel" sent
    ]

-- | Run a skill through a completion function that records the context instead
-- of answering, and return the text of the single user message.
capturedContext :: BehaviorInput -> IO Text
capturedContext input = do
  root <- repositoryRoot
  seen <- newIORef Nothing
  result <-
    runSkillWith
      emptyModel
      emptyOptions
      (mkRegistry [])
      defaultToolTurnLimit
      (SkillDir (root </> "agents" </> "skills" </> "triage-note"))
      input
      (\_model ctx _opts -> writeIORef seen (Just ctx) >> pure emptyResponse)
  case result of
    Left err -> assertFailure ("the capturing run should succeed, got " <> show err)
    Right _ ->
      readIORef seen >>= \case
        Nothing -> assertFailure "the completion function was never called"
        Just ctx -> pure (userText ctx)

-- | All user-message text in a context, concatenated. The skill arm builds
-- exactly one user message; concatenating keeps the assertion honest if that
-- ever becomes several.
userText :: Context -> Text
userText ctx =
  Text.concat
    [ chunk
    | UserMessage UserPayload {content = blocks} <- V.toList (messages ctx),
      UserText (TextContent chunk) <- V.toList blocks
    ]

assertContains :: String -> Text -> Text -> IO ()
assertContains label needle haystack =
  assertBool
    (label <> " is missing from the request:\n" <> Text.unpack haystack)
    (needle `Text.isInfixOf` haystack)

-- ── What the program arm passes ─────────────────────────────────────────────

programArgumentTests :: TestTree
programArgumentTests =
  testGroup
    "the program arm's task receives the payload and prior learnings"
    [ testCase "a real dispatch parses the original payload and recalled learnings" do
        runtime <- newProgramRuntime
        seen <- newIORef Nothing
        let input = BehaviorInput {payload = samplePayload, recalled = [priorLearning]}
        result <- runProgramTask runtime (echoInputTask seen) input
        result @?= Right samplePayload
        captured <- readIORef seen
        case captured of
          Nothing -> assertFailure "the task did not receive parsed input"
          Just actual -> do
            actual.payload @?= samplePayload
            map memoryContentText actual.recalled @?= [priorContent],
      testCase "an empty recall reaches the parser as an empty list" do
        runtime <- newProgramRuntime
        seen <- newIORef Nothing
        _ <- runProgramTask runtime (echoInputTask seen) (triggerOnly samplePayload)
        captured <- readIORef seen
        fmap (map memoryContentText . (.recalled)) captured @?= Just [],
      testCase "parse rejection is an input failure and does not execute" do
        runtime <- newProgramRuntime
        let task =
              ProgramTask
                { name = "reject-input",
                  parse = \_ -> Left "invalid payload" :: Either Text (),
                  run = \_ () -> assertFailure "rejected input executed"
                }
        result <- runProgramTask runtime task (triggerOnly samplePayload)
        result @?= Left (ProgramInputFailed "invalid payload"),
      testCase "execution failure retains its runtime error" do
        runtime <- newProgramRuntime
        let task =
              ProgramTask
                { name = "fail-runtime",
                  parse = \_ -> Right (),
                  run = \_ () -> pure (Left (ProgramRuntimeFailed "execution failed"))
                }
        result <- runProgramTask runtime task (triggerOnly samplePayload)
        result @?= Left (ProgramRuntimeFailed "execution failed"),
      testCase "the fixed researcher findings retain their JSON" do
        runtime <- newProgramRuntime
        web <- runProgramTask runtime webResearcherTask (triggerOnly samplePayload)
        web
          @?= Right
            ( object
                [ "agent" .= ("web-researcher" :: Text),
                  "finding" .= ("Web sources indicate durable workflow delegation should journal child waits." :: Text)
                ]
            )
        code <- runProgramTask runtime codeResearcherTask (triggerOnly samplePayload)
        code
          @?= Right
            ( object
                [ "agent" .= ("code-researcher" :: Text),
                  "finding" .= ("The code path should spawn child workflows before awaiting their results." :: Text)
                ]
            ),
      testCase "an unknown task retains its lookup failure" do
        env <- newBehaviorEnv
        let decl = heartbeatDecl {behavior = ShikumiProgram (declarationCoordinate "missing-task") False Nothing Nothing}
        result <- runBehavior env decl (triggerOnly samplePayload)
        result @?= Left (UnknownTask "missing-task"),
      -- End to end through the declaration union, on the shipped stub program:
      -- the heartbeat agent's digest now shows what triggered it.
      testCase "the shipped noop-summary program echoes the payload it was given" do
        env <- newBehaviorEnv
        result <- runBehavior env heartbeatDecl (triggerOnly samplePayload)
        case result of
          Left err -> assertFailure ("the stub program should succeed, got " <> show err)
          Right value ->
            value
              @?= object
                [ "summary" .= ("noop-summary produced a fixed digest" :: Text),
                  "verb" .= ("heartbeat.tick" :: Text),
                  "input" .= samplePayload
                ]
    ]

-- | Keep the parsed input observable without adding a production task.
echoInputTask :: IORef (Maybe BehaviorInput) -> ProgramTask
echoInputTask seen =
  ProgramTask
    { name = "echo-input",
      parse = Right,
      run = \_rt input -> do
        writeIORef seen (Just input)
        pure (Right input.payload)
    }

-- ── Fixtures ────────────────────────────────────────────────────────────────

samplePayload :: Value
samplePayload = object ["text" .= ("customer says cancel" :: Text)]

priorMemoryId :: Text
priorMemoryId = "mem_prior_learning_1"

priorContent :: Text
priorContent = "acme escalated after a billing complaint"

priorLearning :: MemoryRecord
priorLearning = memoryWith priorContent

-- | A recalled memory carrying the given prose. Built by constructor rather
-- than by record update on a shared value: @content@ is also a field of
-- baikai's 'Baikai.Message.UserPayload', which this module pattern-matches on,
-- and @DuplicateRecordFields@ rejects the ambiguous update.
memoryWith :: Text -> MemoryRecord
memoryWith prose =
  MemoryRecord
    { memoryId = priorMemoryId,
      agentId = "triage-note",
      sessionId = Nothing,
      scope = agentScope (CompatibilityAgent (fixtureAgentName "triage-note")),
      memoryType = "pattern",
      content = prose,
      priority = 100,
      confidence = "medium",
      tags = Set.empty,
      status = "active",
      createdAt = epoch
    }

triageDecl :: AgentDecl
triageDecl =
  AgentDecl
    { name = fixtureAgentName "triage-note",
      description = "triage inbound tickets into a short note",
      trigger = Event {eventType = declarationCoordinate ("ticket.received")},
      behavior = Skill {path = declarationCoordinate ("agents/skills/triage-note")},
      sinks = [],
      delegates = map fixtureAgentName [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = agentEnablement (True),
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

heartbeatDecl :: AgentDecl
heartbeatDecl =
  AgentDecl
    { name = fixtureAgentName "heartbeat",
      description = "",
      trigger = Schedule {cron = cronExpressionClaim "* * * * *"},
      behavior =
        ShikumiProgram
          { task = declarationCoordinate ("noop-summary"),
            preferEnrichment = False,
            grounding = Nothing,
            enabledBy = Nothing
          },
      sinks = [],
      delegates = map fixtureAgentName [],
      delegationBudget = Nothing,
      sanctionedProfile = Nothing,
      capabilityOverlays = [],
      identity = Nothing,
      memory = defaultMemoryPolicy,
      enabled = agentEnablement (True),
      expertise = [],
      execution = Nothing,
      harness = Nothing,
      decisionModels = [],
      routing = Nothing
    }

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 7 15) 43200

-- | Cabal runs a test suite from its package directory, so the skill fixture is
-- located relative to the repository root rather than the working directory.
repositoryRoot :: IO FilePath
repositoryRoot = go [".", ".."]
  where
    go [] = assertFailure "cannot find cabal.project from the working directory"
    go (candidate : rest) = do
      exists <- doesFileExist (candidate </> "cabal.project")
      if exists then pure candidate else go rest

fixtureAgentName :: Text -> AgentName
fixtureAgentName = either (error . show) id . mkAgentName

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
-- test can read the exact argument map a dispatch built. Whether a model then
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
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Data.Vector qualified as V
import Handan.Contract (Envelope (..), Kind (Effect), Status (Ok))
import Handan.Runtime (newRuntime)
import Handan.Task (EvalHandle, Task (..), TaskKind (KEffect))
import Kioku.Api.Types (MemoryRecord (..))
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Trigger (..))
import Shikigami.Behavior.Input (BehaviorInput (..), triggerOnly)
import Shikigami.Behavior.Run (newBehaviorEnv, programArgs, runBehavior, runProgramTask)
import Shikigami.Behavior.Skill (SkillDir (..), runSkillWith)
import Shikigami.Memory.Scope (agentScope)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "behavior input"
    [ skillContextTests,
      programArgumentTests
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
    [ testCase "the argument map carries both, as JSON text" do
        let args = programArgs BehaviorInput {payload = samplePayload, recalled = [priorLearning]}
        Map.lookup "payload" args @?= Just "{\"text\":\"customer says cancel\"}"
        Map.lookup "prior" args @?= Just ("[\"" <> priorContent <> "\"]"),
      testCase "an empty recall is an empty list, not a missing key" do
        let args = programArgs (triggerOnly samplePayload)
        Map.lookup "prior" args @?= Just "[]",
      -- The map above is only worth building if handan's parse seam sees it.
      -- Before this plan every task was handed an empty map.
      testCase "a real dispatch hands that map to the task's parser" do
        runtime <- newRuntime
        seen <- newIORef Map.empty
        let input = BehaviorInput {payload = samplePayload, recalled = [priorLearning]}
        result <- runProgramTask runtime (echoArgsTask seen) input
        case result of
          Left err -> assertFailure ("the echo task should succeed, got " <> show err)
          Right _ -> pure ()
        args <- readIORef seen
        args @?= programArgs input,
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

-- | A task that records the argument map it was parsed from and returns nothing
-- of interest. Constructed here rather than registered, so the production
-- registry stays the catalog of programs shikigami actually runs.
echoArgsTask :: IORef (Map Text Text) -> Task
echoArgsTask seen =
  Task
    { taskName = "echo-args",
      taskKind = KEffect,
      taskSummary = "Test fixture: records the argument map it was given.",
      taskParse = \args -> Right args,
      taskRun = \_rt (args :: Map Text Text) -> do
        writeIORef seen args
        pure
          Envelope
            { program = "echo-args",
              kind = Effect,
              status = Ok,
              verdict = Nothing,
              artifacts = [],
              trace = Nothing,
              message = "echo-args ok"
            },
      taskEval = Nothing :: Maybe (EvalHandle (Map Text Text) (Map Text Text))
    }

-- ── Fixtures ────────────────────────────────────────────────────────────────

samplePayload :: Value
samplePayload = object ["text" .= ("customer says cancel" :: Text)]

priorMemoryId :: Text
priorMemoryId = "mem_prior_learning_1"

priorContent :: Text
priorContent = "acme escalated after a billing complaint"

priorLearning :: MemoryRecord
priorLearning =
  MemoryRecord
    { memoryId = priorMemoryId,
      agentId = "triage-note",
      sessionId = Nothing,
      scope = agentScope "triage-note",
      memoryType = "pattern",
      content = priorContent,
      priority = 100,
      confidence = "medium",
      tags = Set.empty,
      status = "active",
      createdAt = epoch
    }

heartbeatDecl :: AgentDecl
heartbeatDecl =
  AgentDecl
    { name = "heartbeat",
      description = "",
      trigger = Schedule {cron = "* * * * *"},
      behavior =
        ShikumiProgram
          { task = "noop-summary",
            preferEnrichment = False,
            grounding = Nothing,
            enabledBy = Nothing
          },
      sinks = []
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
